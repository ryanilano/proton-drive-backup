#!/usr/bin/env bash
# proton-backup.sh: upload a local directory of backup files to Proton Drive
# using Proton's official Drive CLI (built on the official Drive SDK).
#
# Commands:
#   proton-backup.sh login
#   proton-backup.sh upload <local-src-dir> <remote-parent-path> [--split-gb N] [--retries N] [--staging DIR]
#   proton-backup.sh verify <local-file> <remote-parent-path>
#
# Remote paths use Proton Drive CLI path syntax, e.g. /my-files/backups/pbs
#
# Resume semantics (verified against SDK source, see README):
#   - Within a run, dropped connections retry per 4 MiB block; no restart.
#   - Across a killed run, re-running skips files already uploaded with
#     identical content (SHA1 match). A file that was mid-upload restarts
#     from byte 0. Use --split-gb for huge single files so a kill loses at
#     most one part.

set -euo pipefail

BIN="${PROTON_DRIVE_BIN:-proton-drive}"
LOG="${PROTON_BACKUP_LOG:-$HOME/.local/state/proton-backup/proton-backup.log}"
STAGING_DEFAULT="${TMPDIR:-/tmp}/proton-backup-staging"

log() {
    mkdir -p "$(dirname "$LOG")"
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2
}

log_quiet() {
    mkdir -p "$(dirname "$LOG")"
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"
}

die() {
    log "FATAL: $*"
    exit 1
}

require_bin() {
    command -v "$BIN" >/dev/null 2>&1 || die "proton-drive CLI not found. Set PROTON_DRIVE_BIN or add it to PATH. See README for install."
}

# Run one CLI upload invocation, capturing its JSON summary into the log.
# Returns the CLI exit code.
run_upload_once() {
    local src="$1" remote="$2"
    local out rc=0
    out="$("$BIN" filesystem upload "$src" "$remote" \
        --json --skip-thumbnails \
        --file-conflict-strategy create-new-revision \
        --folder-conflict-strategy merge 2>&1)" || rc=$?
    log_quiet "upload attempt src=$src remote=$remote rc=$rc"
    printf '%s\n' "$out" >> "$LOG"
    printf '%s\n' "$out"
    return "$rc"
}

cmd_login() {
    require_bin
    log "Starting browser-based login. Open the printed URL on any device."
    "$BIN" auth login
    log "Login complete. Session stored per PROTON_DRIVE_CREDENTIALS_STORE (default: OS keychain)."
}

cmd_upload() {
    local src="" remote="" split_gb=0 retries=8 staging="$STAGING_DEFAULT"
    local positional=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --split-gb) split_gb="$2"; shift 2 ;;
            --retries)  retries="$2";  shift 2 ;;
            --staging)  staging="$2";  shift 2 ;;
            *) positional+=("$1"); shift ;;
        esac
    done
    [ "${#positional[@]}" -eq 2 ] || die "usage: proton-backup.sh upload <local-src-dir> <remote-parent-path> [--split-gb N] [--retries N] [--staging DIR]"
    src="${positional[0]}"
    remote="${positional[1]}"
    [ -d "$src" ] || die "source directory not found: $src"
    require_bin

    log "Upload starting: $src -> $remote (split-gb=$split_gb retries=$retries)"
    ensure_remote_folder "$remote"

    if [ "$split_gb" -gt 0 ]; then
        upload_dir_with_split "$src" "$remote" "$split_gb" "$retries" "$staging"
    else
        upload_with_retries "$src" "$remote" "$retries"
    fi

    log "Upload finished: $src -> $remote"
}

# Retry wrapper: re-running is the resume mechanism. Completed files are
# skipped by SHA1 on the server side, so each retry only moves what is left.
upload_with_retries() {
    local src="$1" remote="$2" retries="$3"
    local attempt=1 delay=30
    while true; do
        if run_upload_once "$src" "$remote"; then
            return 0
        fi
        if [ "$attempt" -ge "$retries" ]; then
            die "upload failed after $attempt attempts: $src -> $remote"
        fi
        log "Attempt $attempt failed. Retrying in ${delay}s (completed files will be skipped)."
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
        [ "$delay" -gt 600 ] && delay=600
    done
}

# Split mode: files larger than the threshold are uploaded as fixed-size
# parts extracted one at a time with dd, so staging needs only one part of
# disk space and a killed run loses at most one part. Small files upload
# as-is. Restore: cat name.part-* > name, then check against the manifest.
upload_dir_with_split() {
    local src="$1" remote="$2" split_gb="$3" retries="$4" staging="$5"
    local threshold=$((split_gb * 1024 * 1024 * 1024))
    local part_bytes=$threshold

    mkdir -p "$staging"

    # Pass 1: everything at or under the threshold, as a normal tree upload.
    # find writes a NUL-separated list of big files we exclude here.
    local bigfiles=()
    while IFS= read -r -d '' f; do
        bigfiles+=("$f")
    done < <(find "$src" -type f -size +"${threshold}c" -print0)

    if [ "${#bigfiles[@]}" -eq 0 ]; then
        upload_with_retries "$src" "$remote" "$retries"
        return 0
    fi

    log "Found ${#bigfiles[@]} file(s) over ${split_gb}G; those upload as parts, the rest as a normal tree."

    # Normal tree upload of the small files: copy-free approach is not
    # possible with the CLI's directory upload, so upload small files
    # individually to mirrored remote folders.
    while IFS= read -r -d '' f; do
        local rel dir_remote
        rel="${f#"$src"/}"
        dir_remote="$remote/$(basename "$src")"
        case "$rel" in
            */*) dir_remote="$dir_remote/$(dirname "$rel")" ;;
        esac
        ensure_remote_folder "$dir_remote"
        upload_with_retries "$f" "$dir_remote" "$retries"
    done < <(find "$src" -type f ! -size +"${threshold}c" -print0)

    # Pass 2: big files, one part at a time.
    local f
    for f in "${bigfiles[@]}"; do
        upload_file_as_parts "$f" "$src" "$remote" "$part_bytes" "$retries" "$staging"
    done
}

ensure_remote_folder() {
    # The CLI does not create missing parent folders on upload (verified on
    # 0.8.0: "Node not found"). Walk the path and create each level; the
    # create-folder call fails harmlessly when the folder already exists.
    local path="$1" parent="" seg
    local IFS='/'
    for seg in $path; do
        [ -n "$seg" ] || continue
        # Skip the fixed root (/my-files, /devices, ...), it always exists.
        if [ -z "$parent" ]; then
            parent="/$seg"
            continue
        fi
        # create-folder takes <parentPath> <name> and fails harmlessly when
        # the folder already exists.
        "$BIN" filesystem create-folder "$parent" "$seg" --json >> "$LOG" 2>&1 || true
        parent="$parent/$seg"
    done
}

upload_file_as_parts() {
    local file="$1" src="$2" remote="$3" part_bytes="$4" retries="$5" staging="$6"
    local base rel parts_remote size nparts i
    base="$(basename "$file")"
    rel="${file#"$src"/}"
    parts_remote="$remote/$(basename "$src")"
    case "$rel" in
        */*) parts_remote="$parts_remote/$(dirname "$rel")" ;;
    esac
    parts_remote="$parts_remote/${base}.parts"

    size="$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file")"
    nparts=$(( (size + part_bytes - 1) / part_bytes ))

    log "Splitting $base ($size bytes) into $nparts part(s) of $part_bytes bytes; remote folder $parts_remote"
    ensure_remote_folder "$parts_remote"

    # Manifest first, so a restore always knows what complete looks like.
    local manifest="$staging/${base}.manifest"
    {
        printf 'file\t%s\n' "$base"
        printf 'size\t%s\n' "$size"
        printf 'part_bytes\t%s\n' "$part_bytes"
        printf 'parts\t%s\n' "$nparts"
        printf 'sha256\t%s\n' "$(sha256sum "$file" | cut -d' ' -f1)"
    } > "$manifest"
    upload_with_retries "$manifest" "$parts_remote" "$retries"
    rm -f "$manifest"

    i=0
    while [ "$i" -lt "$nparts" ]; do
        local partname part
        partname="$(printf '%s.part-%04d' "$base" "$i")"
        part="$staging/$partname"
        log "Extracting part $((i + 1))/$nparts: $partname"
        dd if="$file" of="$part" bs=64M iflag=skip_bytes,count_bytes \
            skip=$((i * part_bytes)) count="$part_bytes" status=none
        # Re-uploading an existing identical part is skipped server-side by
        # SHA1 comparison, so re-running after a kill is safe and cheap.
        upload_with_retries "$part" "$parts_remote" "$retries"
        rm -f "$part"
        i=$((i + 1))
    done

    log "All $nparts part(s) of $base uploaded to $parts_remote"
}

cmd_verify() {
    [ $# -eq 2 ] || die "usage: proton-backup.sh verify <local-file> <remote-parent-path>"
    local file="$1" remote="$2"
    [ -f "$file" ] || die "file not found: $file"
    require_bin

    local base
    base="$(basename "$file")"
    # Not local: the EXIT trap runs at script scope, after locals are gone.
    VERIFY_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/proton-verify.XXXXXX")"
    workdir="$VERIFY_WORKDIR"
    trap 'rm -rf "$VERIFY_WORKDIR"' EXIT

    log "Verify step 1/3: uploading $file to $remote"
    ensure_remote_folder "$remote"
    upload_with_retries "$file" "$remote" 3

    log "Verify step 2/3: downloading $remote/$base back"
    "$BIN" filesystem download "$remote/$base" "$workdir" --json \
        --file-conflict-strategy rename >> "$LOG" 2>&1

    log "Verify step 3/3: byte-for-byte comparison"
    if cmp -s "$file" "$workdir/$base"; then
        local sha
        sha="$(sha256sum "$file" | cut -d' ' -f1)"
        log "VERIFY OK: round trip is byte-identical (sha256 $sha)"
    else
        log "VERIFY FAILED: downloaded copy differs from original"
        cmp "$file" "$workdir/$base" | head -5 >&2 || true
        exit 1
    fi
}

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

main() {
    [ $# -ge 1 ] || usage
    local cmd="$1"
    shift
    case "$cmd" in
        login)  cmd_login "$@" ;;
        upload) cmd_upload "$@" ;;
        verify) cmd_verify "$@" ;;
        *) usage ;;
    esac
}

main "$@"

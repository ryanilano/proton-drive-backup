#!/usr/bin/env bash
# proton-backup.sh: upload a local directory of files (backups, exports, a
# photo library, restored VM images) to Proton Drive using Proton's official
# Drive CLI (built on the official Drive SDK).
#
# Commands:
#   proton-backup.sh check-cli
#   proton-backup.sh login
#   proton-backup.sh status
#   proton-backup.sh upload <local-src-dir> <remote-parent-path>
#                    [--split-gb N] [--retries N] [--staging DIR] [--dry-run]
#                    [--age-recipient age1...]
#   proton-backup.sh verify <local-file> <remote-parent-path> [--age-recipient R --age-identity FILE]
#   proton-backup.sh verify-remote <remote-parent-path>
#   proton-backup.sh restore-parts <downloaded-parts-dir> <out-file> [--age-identity FILE]
#   proton-backup.sh last [N]                 show the last N run summaries (default 10)
#
# Zero trust: with --age-recipient (or PROTON_BACKUP_AGE_RECIPIENT) every file
# and every split part is encrypted with age on this machine before it leaves,
# so Proton stores ciphertext it cannot read even if its own end-to-end layer
# were broken. Names get a .age suffix. Keep the identity somewhere that
# survives the same disaster as the backup; without it the data is gone.
#
# Exit codes:
#   0 ok   2 usage   3 CLI binary missing or wrong hash   4 auth or session dead
#   5 upload failed after retries   6 verify mismatch   7 staging disk full
#
# Remote paths use Proton Drive CLI path syntax, e.g. /my-files/backups/host
#
# Resume semantics (verified against SDK source, see README):
#   - Within a run, dropped connections retry per 4 MiB block; no restart.
#   - Across a killed run, re-running skips files already uploaded with
#     identical content (SHA1 match). A file that was mid-upload restarts
#     from byte 0. Files over --split-gb (default 8) upload as parts so a
#     kill loses at most one part, and a finished file carries a .complete
#     marker so a re-run skips it without re-hashing.

set -euo pipefail

# ---------------------------------------------------------------- constants

PINNED_CLI_VERSION="0.8.0"
# SHA-512 per platform from https://proton.me/download/drive/cli/index.html,
# read 2026-09-21. A silent CLI upgrade fails check-cli instead of running.
pinned_sha512() {
    case "$1" in
        darwin-arm64) echo 1483a2fa6afe7a49abdc34f66420b87e0a5d48d236f6f4a79eae7f7d76dc3a6beebedcde5e229ce5fdef42450ada41bbcc02161a64afb473bcaa4fda938c7329 ;;
        darwin-x64)   echo 4fed939abfbab4a7a96e2aaf164d672ce3e2c6cc0717e65b18c31caa5f52ce66e3ab843ec2f3c451a3268b38291cd964632a8abf6c9c8ec37f5428973106c9dd ;;
        linux-arm64)  echo 27a1aec1d2095fd4a1a81e1d47cd1f9fd4901bd579ffe50342d15e2e52078d6e8b2dddcf58a4a386438dc7562017778be26c1ba62399f901ae82c7430e2140a3 ;;
        linux-x64)    echo cf61c2688c45e1055d8add6221d9471a5a5b64bf3bcdb86460f5cb18414596cc4df3cdb6627c9097c94bec32a3c9915ada3211ef2ae5be33c46ebbc996ccaa28 ;;
        linux-x64-baseline) echo a730f9e420fef69244acb9b12aa8e0c03b8216f5d94ff2181cf3df2859a143fc2693fe201c3a00fddaff5d702c34435af72a5283dbbe1da9e038d77a107e24f3 ;;
        linux-arm64-musl)   echo fb386cab36bc346e8bae1f3e79efdd14810de748e762a2c88f384016199ff7211304cc0ec4d220c260c67b83bbe4d3a8d4dd2a2ea0e93b9fdd25c1e42f448165 ;;
        linux-x64-musl)     echo c76e2c000cc22c01842c05fd7122a4ffbccbe8c0938b8ac892a125cdcbea1e8d374be89916b6b2fddf7f1678105b67283f75a1f9a44f62df478be119b7dc857b ;;
        *) echo "" ;;
    esac
}

EXIT_USAGE=2 EXIT_NO_CLI=3 EXIT_AUTH=4 EXIT_UPLOAD=5 EXIT_VERIFY=6 EXIT_DISK=7

BIN="${PROTON_DRIVE_BIN:-proton-drive}"
if [ -z "${PROTON_BACKUP_LOG:-}" ]; then
    if [ -d /var/log/proton-backup ] && [ -w /var/log/proton-backup ]; then
        PROTON_BACKUP_LOG=/var/log/proton-backup/proton-backup.log
    else
        PROTON_BACKUP_LOG="$HOME/.local/state/proton-backup/proton-backup.log"
    fi
fi
LOG="$PROTON_BACKUP_LOG"
JSONL="${PROTON_BACKUP_JSONL:-${LOG%.log}.ndjson}"
SUMMARY="${PROTON_BACKUP_SUMMARY:-${LOG%.log}.summary.log}"
# Run counters, printed as one readable line at the end of upload.
RUN_FILES=0 RUN_BYTES=0 RUN_SKIPPED=0 RUN_FAILED=0 RUN_PARTS=0 RUN_START=0
STAGING_DEFAULT="${TMPDIR:-/tmp}/proton-backup-staging"
DRY_RUN=0
SPLIT_GB_DEFAULT=8
AGE_RECIPIENT="${PROTON_BACKUP_AGE_RECIPIENT:-}"
AGE_IDENTITY="${PROTON_BACKUP_AGE_IDENTITY:-}"

# ---------------------------------------------------------------- portability

# GNU coreutils are not a given: the Air, any BSD, and busybox boxes lack
# sha256sum and stat -c. Every helper below has a fallback.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

sha512_of() {
    if command -v sha512sum >/dev/null 2>&1; then
        sha512sum "$1" | cut -d' ' -f1
    else
        shasum -a 512 "$1" | cut -d' ' -f1
    fi
}

size_of() {
    stat -c %s "$1" 2>/dev/null || stat -f %z "$1"
}

free_bytes_in() {
    # POSIX df -P prints 1024-byte blocks in column 4.
    df -P "$1" | awk 'NR==2 {print $4 * 1024}'
}

# Extract byte range [offset, offset+count) of a file. Offsets and counts are
# whole MiB so this works with any dd (no GNU iflag=skip_bytes).
extract_range_mib() {
    local file="$1" out="$2" skip_mib="$3" count_mib="$4"
    dd if="$file" of="$out" bs=1048576 skip="$skip_mib" count="$count_mib" 2>/dev/null
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Bytes to a size a person reads: 1.2 GB, 480 MB, 12 KB. Decimal units, like
# a shop label, because that is what people compare against a drive size.
human_size() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1e12) printf "%.2f TB", b/1e12;
        else if (b >= 1e9) printf "%.2f GB", b/1e9;
        else if (b >= 1e6) printf "%.1f MB", b/1e6;
        else if (b >= 1e3) printf "%.0f KB", b/1e3;
        else printf "%d B", b }'
}
human_secs() {
    local s="$1"
    if [ "$s" -ge 3600 ]; then printf '%dh %02dm' $((s/3600)) $(((s%3600)/60))
    elif [ "$s" -ge 60 ]; then printf '%dm %02ds' $((s/60)) $((s%60))
    else printf '%ds' "$s"; fi
}
count_file() { RUN_FILES=$((RUN_FILES + 1)); RUN_BYTES=$((RUN_BYTES + ${1:-0})); }

# --- client-side encryption (age). Off unless a recipient is set.
age_on() { [ -n "$AGE_RECIPIENT" ]; }
require_age() { command -v age >/dev/null 2>&1 || die "$EXIT_USAGE" "age not installed (brew install age / apt install age)"; }
# Encrypt src to dst. Streams; needs no memory and only dst's size on disk.
age_encrypt_file() { age -r "$AGE_RECIPIENT" -o "$2" "$1"; }
age_decrypt_file() {
    [ -n "$AGE_IDENTITY" ] || die "$EXIT_USAGE" "--age-identity FILE (or PROTON_BACKUP_AGE_IDENTITY) is required to decrypt"
    age -d -i "$AGE_IDENTITY" -o "$2" "$1"
}
# Remote name of a file: plain name, or name.age when encrypting.
remote_name() { if age_on; then printf '%s.age' "$1"; else printf '%s' "$1"; fi; }

# ---------------------------------------------------------------- logging

log() {
    mkdir -p "$(dirname "$LOG")"
    printf '%s %s\n' "$(now_utc)" "$*" | tee -a "$LOG" >&2
}

log_quiet() {
    mkdir -p "$(dirname "$LOG")"
    printf '%s %s\n' "$(now_utc)" "$*" >> "$LOG"
}

# One JSON line per file, so an agent can read outcomes without parsing prose.
# Values are escaped minimally; paths with quotes are rare and still parse.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
jsonl_file() {
    local path="$1" remote="$2" bytes="$3" parts="$4" sha="$5" secs="$6" result="$7"
    case "$result" in
        ok)      count_file "$bytes"; RUN_PARTS=$((RUN_PARTS + ${parts:-0})) ;;
        skipped) RUN_SKIPPED=$((RUN_SKIPPED + 1)) ;;
        failed)  RUN_FAILED=$((RUN_FAILED + 1)) ;;
    esac
    [ "$DRY_RUN" -eq 0 ] || return 0
    mkdir -p "$(dirname "$JSONL")"
    printf '{"ts":"%s","path":"%s","remote":"%s","bytes":%s,"parts":%s,"sha256":"%s","seconds":%s,"result":"%s"}\n' \
        "$(now_utc)" "$(json_escape "$path")" "$(json_escape "$remote")" \
        "${bytes:-0}" "${parts:-0}" "$sha" "${secs:-0}" "$result" >> "$JSONL"
}

die() {
    local code="$1"; shift
    log "FATAL: $*"
    exit "$code"
}

usage_die() { die "$EXIT_USAGE" "$*"; }

# ---------------------------------------------------------------- CLI plumbing

require_bin() {
    command -v "$BIN" >/dev/null 2>&1 || die "$EXIT_NO_CLI" "proton-drive CLI not found. Set PROTON_DRIVE_BIN or add it to PATH. See README for install."
}

# Run the CLI, capture output, return its exit code. Output goes to the log
# and to stdout so callers can inspect it.
cli() {
    local out rc=0
    out="$("$BIN" "$@" 2>&1)" || rc=$?
    log_quiet "cli rc=$rc: $*"
    printf '%s\n' "$out" >> "$LOG"
    printf '%s\n' "$out"
    return "$rc"
}

is_auth_error() {
    printf '%s' "$1" | grep -qi 'need to login'
}

# True when the CLI can list the root; exit 4 otherwise. Runs before any
# upload so a dead session fails the unit instead of retrying blindly.
require_session() {
    local out rc=0
    out="$(cli filesystem list /my-files --json)" || rc=$?
    if [ "$rc" -ne 0 ] || is_auth_error "$out"; then
        die "$EXIT_AUTH" "Proton session is dead or missing. Run: proton-backup.sh login"
    fi
}

# Does <parent> contain an entry called <name>? Reads list --json and matches
# the name field. python3 when available (exact JSON), grep fallback otherwise.
remote_has() {
    local parent="$1" name="$2" out rc=0
    out="$(cli filesystem list "$parent" --json)" || rc=$?
    [ "$rc" -eq 0 ] || return 1
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$out" | python3 -c '
import json, sys
want = sys.argv[1]
raw = sys.stdin.read()
items = []
try:
    d = json.loads(raw)
    items = d if isinstance(d, list) else [d]
except ValueError:
    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            items.append(json.loads(line))
        except ValueError:
            pass
def name_of(n):
    v = n.get("name")
    if isinstance(v, dict):
        return v.get("value") or v.get("ok") or ""
    return v or ""
sys.exit(0 if any(name_of(n) == want for n in items) else 1)
' "$name"
    else
        printf '%s' "$out" | grep -Fq "\"$name\""
    fi
}

remote_exists() {
    local path="$1" out rc=0
    out="$(cli filesystem info "$path" --json)" || rc=$?
    [ "$rc" -eq 0 ] && ! is_auth_error "$out"
}

# The CLI does not create missing parents on upload (verified on 0.8.0,
# "Node not found"). Walk the path and create each level. A create that fails
# is only tolerated when the folder turns out to exist; anything else stops
# the run, because a swallowed error here used to cost whole nights.
ensure_remote_folder() {
    local path="$1" parent="" seg out rc
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN ensure folder $path"
        return 0
    fi
    local IFS='/'
    for seg in $path; do
        [ -n "$seg" ] || continue
        if [ -z "$parent" ]; then
            parent="/$seg"       # fixed root (/my-files, /devices) always exists
            continue
        fi
        rc=0
        out="$(cli filesystem create-folder "$parent" "$seg" --json)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            is_auth_error "$out" && die "$EXIT_AUTH" "session died while creating $parent/$seg"
            if printf '%s' "$out" | grep -qi 'already exists' || remote_exists "$parent/$seg"; then
                log_quiet "folder exists: $parent/$seg"
            else
                die "$EXIT_UPLOAD" "could not create remote folder $parent/$seg: $out"
            fi
        fi
        parent="$parent/$seg"
    done
}

run_upload_once() {
    local src="$1" remote="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN upload $src -> $remote"
        return 0
    fi
    cli filesystem upload "$src" "$remote" \
        --json --skip-thumbnails \
        --file-conflict-strategy create-new-revision \
        --folder-conflict-strategy merge
}

# Retry wrapper: re-running is the resume mechanism. Completed files are
# skipped by SHA1 on the server side, so each retry only moves what is left.
# A dead session is not retried; it exits 4 at once.
upload_with_retries() {
    local src="$1" remote="$2" retries="$3"
    local attempt=1 delay=30 out rc
    while true; do
        rc=0
        out="$(run_upload_once "$src" "$remote")" || rc=$?
        [ "$rc" -eq 0 ] && return 0
        is_auth_error "$out" && die "$EXIT_AUTH" "session died during upload of $src"
        if [ "$attempt" -ge "$retries" ]; then
            log "upload failed after $attempt attempts: $src -> $remote"
            return "$EXIT_UPLOAD"
        fi
        log "Attempt $attempt failed (rc=$rc). Retrying in ${delay}s (completed files will be skipped)."
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
        [ "$delay" -gt 600 ] && delay=600
    done
}

# ---------------------------------------------------------------- commands

cmd_check_cli() {
    require_bin
    local path plat os arch have want
    path="$(command -v "$BIN")"
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$arch" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; esac
    plat="${PROTON_CLI_PLATFORM:-$os-$arch}"
    want="$(pinned_sha512 "$plat")"
    [ -n "$want" ] || die "$EXIT_NO_CLI" "no pinned hash for platform $plat (set PROTON_CLI_PLATFORM, e.g. linux-x64-baseline)"
    have="$(sha512_of "$path")"
    if [ "$have" = "$want" ]; then
        log "CLI ok: $path is Proton Drive CLI $PINNED_CLI_VERSION ($plat)"
        return 0
    fi
    die "$EXIT_NO_CLI" "CLI at $path does not match pinned $PINNED_CLI_VERSION for $plat. Re-download from https://proton.me/download/drive/cli/index.html or update the pin."
}

cmd_login() {
    require_bin
    log "Starting browser-based login. Open the printed URL on any device."
    "$BIN" auth login
    log "Login complete. Session stored per PROTON_DRIVE_CREDENTIALS_STORE (default: OS keychain)."
}

cmd_status() {
    require_bin
    require_session
    log "Session ok: /my-files listed"
}

cmd_upload() {
    local src="" remote="" split_gb="$SPLIT_GB_DEFAULT" retries=8 staging="$STAGING_DEFAULT"
    local positional=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --split-gb) split_gb="${2:-}"; shift 2 ;;
            --retries)  retries="${2:-}";  shift 2 ;;
            --staging)  staging="${2:-}";  shift 2 ;;
            --dry-run)  DRY_RUN=1; shift ;;
            --age-recipient) AGE_RECIPIENT="${2:-}"; shift 2 ;;
            --) shift; positional+=("$@"); break ;;
            -*) usage_die "unknown option $1" ;;
            *) positional+=("$1"); shift ;;
        esac
    done
    [ "${#positional[@]}" -eq 2 ] || usage_die "usage: proton-backup.sh upload <local-src-dir> <remote-parent-path> [--split-gb N] [--retries N] [--staging DIR] [--dry-run] [--age-recipient age1...]"
    src="${positional[0]%/}"
    remote="${positional[1]%/}"
    [ -d "$src" ] || usage_die "source directory not found: $src"
    case "$split_gb$retries" in *[!0-9]*) usage_die "--split-gb and --retries take whole numbers" ;; esac
    require_bin
    age_on && require_age
    [ "$DRY_RUN" -eq 1 ] || require_session

    RUN_START=$(date +%s)
    UPLOAD_SRC="$src"; UPLOAD_REMOTE="$remote"
    trap 'print_summary' EXIT
    log "Upload starting: $src -> $remote (split-gb=$split_gb retries=$retries dry-run=$DRY_RUN age=$(age_on && echo on || echo off))"
    if [ "$DRY_RUN" -eq 1 ]; then
        plan_summary "$src" "$split_gb"
    fi
    ensure_remote_folder "$remote"
    if age_on && [ "$split_gb" -eq 0 ]; then
        # No tree upload when encrypting: every file passes through staging.
        mkdir -p "$staging"
        upload_dir_with_split "$src" "$remote" 0 "$retries" "$staging"
    elif [ "$split_gb" -gt 0 ]; then
        upload_dir_with_split "$src" "$remote" "$split_gb" "$retries" "$staging"
    else
        upload_tree_plain "$src" "$remote" "$retries"
    fi
    log "Upload finished: $src -> $remote"
}

# What a dry run tells a person before anything moves.
plan_summary() {
    local src="$1" split_gb="$2" n=0 bytes=0 big=0 f sz threshold
    threshold=$(( ${PB_TEST_PART_MIB:-$((split_gb * 1024))} * 1048576 ))
    while IFS= read -r -d '' f; do
        sz="$(size_of "$f")"; n=$((n + 1)); bytes=$((bytes + sz))
        if [ "$split_gb" -gt 0 ] && [ "$sz" -gt "$threshold" ]; then big=$((big + 1)); fi
        log "  plan: $(human_size "$sz")  $f"
    done < <(find "$src" -type f -print0 | sort -z)
    local splitmsg="splitting off"
    [ "$split_gb" -gt 0 ] && splitmsg="$big to be split into ${split_gb} GB parts"
    log "PLAN: $n file(s), $(human_size "$bytes") total, $splitmsg, encryption $(age_on && echo age || echo none). Nothing was uploaded."
}

# One line a person can read, printed at the end and appended to the summary
# log. Runs whether the upload finished or died, so a failed run still leaves
# a line that says how far it got.
print_summary() {
    local rc=$? secs verdict enc
    [ "${RUN_START:-0}" -gt 0 ] || return 0
    [ "$DRY_RUN" -eq 0 ] || return 0
    secs=$(( $(date +%s) - RUN_START ))
    enc="$(age_on && echo ', encrypted with age' || echo '')"
    if [ "$rc" -eq 0 ]; then verdict="OK"; else verdict="FAILED (exit $rc)"; fi
    local line
    line="$verdict: $RUN_FILES file(s), $(human_size "$RUN_BYTES") uploaded"
    [ "$RUN_PARTS" -gt 0 ] && line="$line in $RUN_PARTS part(s)"
    [ "$RUN_SKIPPED" -gt 0 ] && line="$line, $RUN_SKIPPED skipped (already complete)"
    [ "$RUN_FAILED" -gt 0 ] && line="$line, $RUN_FAILED failed"
    line="$line, $(human_secs "$secs")$enc. ${UPLOAD_SRC:-?} -> ${UPLOAD_REMOTE:-?}"
    mkdir -p "$(dirname "$SUMMARY")"
    printf '%s %s\n' "$(now_utc)" "$line" >> "$SUMMARY"
    printf '\n%s\n' "$line" >&2
}

cmd_last() {
    local n="${1:-10}"
    case "$n" in *[!0-9]*) usage_die "usage: proton-backup.sh last [N]" ;; esac
    [ -f "$SUMMARY" ] || { echo "no runs recorded yet ($SUMMARY)"; return 0; }
    tail -n "$n" "$SUMMARY"
}

# Whole tree in one CLI call. Records one JSON line per file afterwards.
upload_tree_plain() {
    local src="$1" remote="$2" retries="$3" started rc=0 f
    started=$(date +%s)
    upload_with_retries "$src" "$remote" "$retries" || rc=$?
    while IFS= read -r -d '' f; do
        jsonl_file "$f" "$remote/$(basename "$src")" "$(size_of "$f")" 0 "" 0 "$([ "$rc" -eq 0 ] && echo ok || echo failed)"
    done < <(find "$src" -type f -print0)
    [ "$rc" -eq 0 ] || die "$EXIT_UPLOAD" "tree upload failed: $src"
    log_quiet "tree upload took $(( $(date +%s) - started ))s"
}

# Files over the threshold go as parts; everything else uploads file by file
# into mirrored remote folders (the CLI cannot exclude paths from a tree).
upload_dir_with_split() {
    local src="$1" remote="$2" split_gb="$3" retries="$4" staging="$5"
    # PB_TEST_PART_MIB lets the test suite exercise split mode on small files.
    local part_mib="${PB_TEST_PART_MIB:-$((split_gb * 1024))}"
    local threshold=$((part_mib * 1048576))
    local bigfiles=() f

    if [ "$split_gb" -gt 0 ]; then
        while IFS= read -r -d '' f; do
            bigfiles+=("$f")
        done < <(find "$src" -type f -size +"${threshold}c" -print0)
    fi

    if [ "${#bigfiles[@]}" -eq 0 ] && ! age_on; then
        upload_tree_plain "$src" "$remote" "$retries"
        return 0
    fi

    log "Found ${#bigfiles[@]} file(s) over ${split_gb}G; those upload as parts, the rest file by file."
    [ "$DRY_RUN" -eq 1 ] || mkdir -p "$staging"

    while IFS= read -r -d '' f; do
        local rel dir_remote started rc=0
        rel="${f#"$src"/}"
        dir_remote="$remote/$(basename "$src")"
        case "$rel" in */*) dir_remote="$dir_remote/$(dirname "$rel")" ;; esac
        ensure_remote_folder "$dir_remote"
        started=$(date +%s)
        if age_on && [ "$DRY_RUN" -eq 0 ]; then
            local enc
            enc="$staging/$(basename "$f").age"
            age_encrypt_file "$f" "$enc"
            upload_with_retries "$enc" "$dir_remote" "$retries" || rc=$?
            rm -f "$enc"
        else
            upload_with_retries "$f" "$dir_remote" "$retries" || rc=$?
        fi
        jsonl_file "$f" "$dir_remote/$(remote_name "$(basename "$f")")" "$(size_of "$f")" 0 "" "$(( $(date +%s) - started ))" "$([ "$rc" -eq 0 ] && echo ok || echo failed)"
        [ "$rc" -eq 0 ] || die "$EXIT_UPLOAD" "upload failed: $f"
    done < <(if [ "$split_gb" -gt 0 ]; then find "$src" -type f ! -size +"${threshold}c" -print0; else find "$src" -type f -print0; fi)

    for f in "${bigfiles[@]}"; do
        upload_file_as_parts "$f" "$src" "$remote" "$part_mib" "$retries" "$staging"
    done
}

upload_file_as_parts() {
    local file="$1" src="$2" remote="$3" part_mib="$4" retries="$5" staging="$6"
    local base rel parts_remote size nparts i part_bytes started sha_whole
    base="$(basename "$file")"
    rel="${file#"$src"/}"
    parts_remote="$remote/$(basename "$src")"
    case "$rel" in */*) parts_remote="$parts_remote/$(dirname "$rel")" ;; esac
    parts_remote="$parts_remote/${base}.parts"
    part_bytes=$((part_mib * 1048576))
    size="$(size_of "$file")"
    nparts=$(( (size + part_bytes - 1) / part_bytes ))
    started=$(date +%s)

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN $base: $size bytes -> $nparts part(s) of $part_bytes bytes in $parts_remote"
        return 0
    fi

    # A finished file carries a .complete marker; skip without re-hashing.
    if remote_has "$parts_remote" "${base}.complete"; then
        log "Skip $base: ${base}.complete already in $parts_remote"
        jsonl_file "$file" "$parts_remote" "$size" "$nparts" "" 0 skipped
        return 0
    fi

    # Staging needs one part plus slack, or the run dies mid-part.
    local free
    free="$(free_bytes_in "$staging")"
    if [ "$free" -lt $((part_bytes + 67108864)) ]; then
        die "$EXIT_DISK" "staging $staging has $free bytes free, needs one part ($part_bytes) plus 64 MiB"
    fi

    log "Splitting $base ($size bytes) into $nparts part(s) of $part_bytes bytes; remote folder $parts_remote"
    ensure_remote_folder "$parts_remote"

    # Manifest first, so a restore always knows what complete looks like.
    sha_whole="$(sha256_of "$file")"
    local manifest="$staging/${base}.manifest"
    {
        printf 'file\t%s\n' "$base"
        printf 'size\t%s\n' "$size"
        printf 'part_bytes\t%s\n' "$part_bytes"
        printf 'parts\t%s\n' "$nparts"
        printf 'sha256\t%s\n' "$sha_whole"
        printf 'encryption\t%s\n' "$(age_on && echo age || echo none)"
        age_on && printf 'age_recipient\t%s\n' "$AGE_RECIPIENT"
    } > "$manifest"
    upload_with_retries "$manifest" "$parts_remote" "$retries" || die "$EXIT_UPLOAD" "manifest upload failed for $base"
    rm -f "$manifest"

    # Per-part hashes accumulate here and upload after the last part.
    local partsums="$staging/${base}.parts.sha256"
    : > "$partsums"

    i=0
    while [ "$i" -lt "$nparts" ]; do
        local partname part
        partname="$(printf '%s.part-%04d' "$base" "$i")"
        part="$staging/$partname"
        log "Extracting part $((i + 1))/$nparts: $partname"
        extract_range_mib "$file" "$part" $((i * part_mib)) "$part_mib"
        if age_on; then
            # Encrypt the part in place; the remote sees only <part>.age and
            # the checksum line names the ciphertext, so verify-remote needs
            # no key.
            age_encrypt_file "$part" "$part.age"
            rm -f "$part"
            part="$part.age"; partname="$partname.age"
        fi
        printf '%s  %s\n' "$(sha256_of "$part")" "$partname" >> "$partsums"
        # Re-uploading an identical part is skipped server-side by SHA1, so
        # re-running after a kill is safe and cheap.
        upload_with_retries "$part" "$parts_remote" "$retries" || { rm -f "$part"; die "$EXIT_UPLOAD" "part upload failed: $partname"; }
        rm -f "$part"
        i=$((i + 1))
    done

    upload_with_retries "$partsums" "$parts_remote" "$retries" || die "$EXIT_UPLOAD" "part checksum upload failed for $base"
    rm -f "$partsums"

    local complete="$staging/${base}.complete"
    printf 'sha256\t%s\ncompleted\t%s\n' "$sha_whole" "$(now_utc)" > "$complete"
    upload_with_retries "$complete" "$parts_remote" "$retries" || die "$EXIT_UPLOAD" ".complete upload failed for $base"
    rm -f "$complete"

    jsonl_file "$file" "$parts_remote" "$size" "$nparts" "$sha_whole" "$(( $(date +%s) - started ))" ok
    log "All $nparts part(s) of $base uploaded to $parts_remote"
}

cmd_verify() {
    local positional=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --age-recipient) AGE_RECIPIENT="${2:-}"; shift 2 ;;
            --age-identity)  AGE_IDENTITY="${2:-}";  shift 2 ;;
            -*) usage_die "unknown option $1" ;;
            *) positional+=("$1"); shift ;;
        esac
    done
    [ "${#positional[@]}" -eq 2 ] || usage_die "usage: proton-backup.sh verify <local-file> <remote-parent-path> [--age-recipient R --age-identity FILE]"
    local file="${positional[0]}" remote="${positional[1]%/}"
    [ -f "$file" ] || usage_die "file not found: $file"
    require_bin
    age_on && require_age
    require_session

    local base rname up
    base="$(basename "$file")"
    rname="$(remote_name "$base")"
    VERIFY_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/proton-verify.XXXXXX")"
    trap 'rm -rf "$VERIFY_WORKDIR"' EXIT

    up="$file"
    if age_on; then
        up="$VERIFY_WORKDIR/up/$rname"; mkdir -p "$VERIFY_WORKDIR/up"
        age_encrypt_file "$file" "$up"
    fi
    log "Verify step 1/3: uploading $rname to $remote"
    ensure_remote_folder "$remote"
    upload_with_retries "$up" "$remote" 3 || die "$EXIT_UPLOAD" "verify upload failed"

    log "Verify step 2/3: downloading $remote/$rname back"
    mkdir -p "$VERIFY_WORKDIR/down"
    cli filesystem download "$remote/$rname" "$VERIFY_WORKDIR/down" --json --file-conflict-strategy rename >/dev/null \
        || die "$EXIT_VERIFY" "download failed for $remote/$rname"
    local got="$VERIFY_WORKDIR/down/$rname"
    if age_on; then
        age_decrypt_file "$got" "$VERIFY_WORKDIR/down/$base" || die "$EXIT_VERIFY" "downloaded copy does not decrypt with the given identity"
        got="$VERIFY_WORKDIR/down/$base"
    fi

    log "Verify step 3/3: byte-for-byte comparison"
    if cmp -s "$file" "$got"; then
        log "VERIFY OK: round trip is byte-identical (sha256 $(sha256_of "$file"))"
    else
        log "VERIFY FAILED: downloaded copy differs from original"
        exit "$EXIT_VERIFY"
    fi
}

# Download every <name>.parts folder's manifest and parts, one part at a
# time, hash each, and compare. The only true integrity check the service
# allows, since it exposes SHA1 for dedupe and nothing else.
cmd_verify_remote() {
    [ $# -eq 1 ] || usage_die "usage: proton-backup.sh verify-remote <remote-parent-path>"
    local parent="${1%/}" out names failures=0 checked=0
    require_bin
    require_session
    VERIFY_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/proton-verify.XXXXXX")"
    trap 'rm -rf "$VERIFY_WORKDIR"' EXIT

    out="$(cli filesystem list "$parent" --json)" || die "$EXIT_VERIFY" "cannot list $parent"
    names="$(printf '%s' "$out" | remote_names)"
    local n
    while IFS= read -r n; do
        case "$n" in *.parts) ;; *) continue ;; esac
        checked=$((checked + 1))
        verify_one_parts_folder "$parent/$n" || failures=$((failures + 1))
    done <<< "$names"
    log "verify-remote: $checked parts folder(s) checked, $failures failed"
    [ "$checked" -gt 0 ] || log "note: plain files are not verifiable without a manifest; only *.parts folders were checked"
    [ "$failures" -eq 0 ] || exit "$EXIT_VERIFY"
}

# Names from a list --json blob, one per line.
remote_names() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
raw = sys.stdin.read()
items = []
try:
    d = json.loads(raw)
    items = d if isinstance(d, list) else [d]
except ValueError:
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                items.append(json.loads(line))
            except ValueError:
                pass
for n in items:
    v = n.get("name")
    if isinstance(v, dict):
        v = v.get("value") or v.get("ok") or ""
    if v:
        print(v)
'
    else
        grep -o '"name": *"[^"]*"' | sed 's/.*"name": *"//; s/"$//'
    fi
}

verify_one_parts_folder() {
    local folder="$1" base d expected got partname sumline
    base="$(basename "$folder")"; base="${base%.parts}"
    d="$VERIFY_WORKDIR/$base"; mkdir -p "$d"
    log "verify-remote: $folder"
    cli filesystem download "$folder/${base}.manifest" "$d" --json >/dev/null || { log "  missing manifest"; return 1; }
    cli filesystem download "$folder/${base}.parts.sha256" "$d" --json >/dev/null || { log "  missing parts.sha256 (upload predates it, or did not finish)"; return 1; }
    if ! remote_has "$folder" "${base}.complete"; then
        log "  no .complete marker: upload did not finish"
        return 1
    fi
    local bad=0
    while IFS= read -r sumline; do
        expected="${sumline%%  *}"; partname="${sumline##*  }"
        [ -n "$partname" ] || continue
        cli filesystem download "$folder/$partname" "$d" --json >/dev/null || { log "  download failed: $partname"; bad=1; continue; }
        got="$(sha256_of "$d/$partname")"
        if [ "$got" = "$expected" ]; then
            log_quiet "  ok $partname"
        else
            log "  MISMATCH $partname expected $expected got $got"
            bad=1
        fi
        rm -f "$d/$partname"
    done < "$d/${base}.parts.sha256"
    if [ "$bad" -eq 0 ]; then
        log "  ok: every part matches ($(grep -c . "$d/${base}.parts.sha256") parts)"
    fi
    rm -rf "$d"
    return "$bad"
}

# Rebuild a file from a downloaded <name>.parts directory. Checks every part
# against <name>.parts.sha256, decrypts with age when the manifest says so,
# joins in order, and checks the whole against the manifest's sha256.
cmd_restore_parts() {
    local positional=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --age-identity) AGE_IDENTITY="${2:-}"; shift 2 ;;
            -*) usage_die "unknown option $1" ;;
            *) positional+=("$1"); shift ;;
        esac
    done
    [ "${#positional[@]}" -eq 2 ] || usage_die "usage: proton-backup.sh restore-parts <downloaded-parts-dir> <out-file> [--age-identity FILE]"
    local dir="${positional[0]%/}" out="${positional[1]}" base manifest sums enc expected got line partname
    [ -d "$dir" ] || usage_die "not a directory: $dir"
    base="$(basename "$dir")"; base="${base%.parts}"
    manifest="$dir/$base.manifest"; sums="$dir/$base.parts.sha256"
    [ -f "$manifest" ] || die "$EXIT_VERIFY" "missing $manifest"
    [ -f "$sums" ] || die "$EXIT_VERIFY" "missing $sums"
    [ -f "$dir/$base.complete" ] || log "warning: no $base.complete in $dir, the upload may not have finished"
    enc="$(awk -F'\t' '$1=="encryption"{print $2}' "$manifest")"
    if [ "$enc" = age ]; then
        require_age
        [ -n "$AGE_IDENTITY" ] || die "$EXIT_USAGE" "manifest says encryption=age; pass --age-identity FILE"
    fi
    : > "$out"
    while IFS= read -r line; do
        expected="${line%%  *}"; partname="${line##*  }"
        [ -n "$partname" ] || continue
        [ -f "$dir/$partname" ] || die "$EXIT_VERIFY" "missing part $partname"
        got="$(sha256_of "$dir/$partname")"
        [ "$got" = "$expected" ] || die "$EXIT_VERIFY" "part $partname sha256 mismatch"
        if [ "$enc" = age ]; then
            age -d -i "$AGE_IDENTITY" "$dir/$partname" >> "$out" || die "$EXIT_VERIFY" "part $partname does not decrypt"
        else
            cat "$dir/$partname" >> "$out"
        fi
    done < "$sums"
    expected="$(awk -F'\t' '$1=="sha256"{print $2}' "$manifest")"
    got="$(sha256_of "$out")"
    [ "$got" = "$expected" ] || die "$EXIT_VERIFY" "restored file sha256 $got does not match manifest $expected"
    log "restored $out ($(size_of "$out") bytes), sha256 matches the manifest"
}

usage() {
    sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
    exit "$EXIT_USAGE"
}

main() {
    [ $# -ge 1 ] || usage
    local cmd="$1"
    shift
    case "$cmd" in
        check-cli)     cmd_check_cli "$@" ;;
        login)         cmd_login "$@" ;;
        status)        cmd_status "$@" ;;
        upload)        cmd_upload "$@" ;;
        verify)        cmd_verify "$@" ;;
        verify-remote) cmd_verify_remote "$@" ;;
        restore-parts) cmd_restore_parts "$@" ;;
        last)          cmd_last "$@" ;;
        -h|--help|help) usage ;;
        *) usage ;;
    esac
}

main "$@"

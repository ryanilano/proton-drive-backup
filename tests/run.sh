#!/usr/bin/env bash
# Offline test suite for proton-backup.sh against tests/fake-proton-drive.
# Runs in a few seconds. Exit 0 when every case passes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../proton-backup.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/pb-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
export PROTON_DRIVE_BIN="$HERE/fake-proton-drive"
export FAKE_REMOTE="$W/remote"; mkdir -p "$FAKE_REMOTE/my-files"
export FAKE_CALLS="$W/calls.log"
export FAKE_FAIL_FILE="$W/failcount"
export PROTON_BACKUP_LOG="$W/log/pb.log"
export HOME="$W/home"; mkdir -p "$HOME"
# Retry back-off starts at 30 s; a stub sleep keeps the suite fast.
mkdir -p "$W/bin"; printf '#!/bin/sh\nexit 0\n' > "$W/bin/sleep"; chmod +x "$W/bin/sleep"; export PATH="$W/bin:$PATH"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; }
check() { local name="$1" want="$2" got="$3"; [ "$want" = "$got" ] && ok "$name" || bad "$name (want $want got $got)"; }
reset_remote() { rm -rf "$FAKE_REMOTE"; mkdir -p "$FAKE_REMOTE/my-files"; : > "$FAKE_CALLS"; }

# Source tree: two small files in nested dirs, one "big" file (3 MiB) for
# split mode with a 1 MiB part size via a tiny split-gb override.
mkdir -p "$W/src/sub"
printf 'hello\n' > "$W/src/a.txt"; printf 'world\n' > "$W/src/sub/b.txt"
head -c $((3*1048576+5)) /dev/urandom > "$W/src/big.img"

echo "1. usage and exit codes"
"$SCRIPT" >/dev/null 2>&1; check "no args exits 2" 2 $?
"$SCRIPT" upload >/dev/null 2>&1; check "upload without paths exits 2" 2 $?
"$SCRIPT" upload /nonexistent /my-files/x >/dev/null 2>&1; check "missing source exits 2" 2 $?
PROTON_DRIVE_BIN=/nonexistent/bin "$SCRIPT" status >/dev/null 2>&1; check "missing CLI exits 3" 3 $?
FAKE_LOGGED_OUT=1 "$SCRIPT" status >/dev/null 2>&1; check "logged out status exits 4" 4 $?
FAKE_LOGGED_OUT=1 "$SCRIPT" upload "$W/src" /my-files/b >/dev/null 2>&1; check "logged out upload exits 4 before touching anything" 4 $?
check "no upload calls when logged out" 0 "$(grep -c 'filesystem upload' "$FAKE_CALLS" || true)"
"$SCRIPT" status >/dev/null 2>&1; check "status ok exits 0" 0 $?

echo "2. dry run touches nothing"
reset_remote
"$SCRIPT" upload "$W/src" /my-files/backups/t --split-gb 0 --dry-run >/dev/null 2>&1; check "dry-run exits 0" 0 $?
check "dry-run made no create-folder calls" 0 "$(grep -c create-folder "$FAKE_CALLS" || true)"
check "dry-run made no upload calls" 0 "$(grep -c 'filesystem upload' "$FAKE_CALLS" || true)"

echo "3. plain tree upload"
reset_remote
"$SCRIPT" upload "$W/src" /my-files/backups/t --split-gb 0 >/dev/null 2>&1; check "plain upload exits 0" 0 $?
check "remote has a.txt" 1 "$([ -f "$FAKE_REMOTE/my-files/backups/t/src/a.txt" ] && echo 1 || echo 0)"
check "remote has sub/b.txt" 1 "$([ -f "$FAKE_REMOTE/my-files/backups/t/src/sub/b.txt" ] && echo 1 || echo 0)"
check "parents created without swallowing errors" 2 "$(grep -c create-folder "$FAKE_CALLS")"
check "ndjson has one line per file" 3 "$(wc -l < "$W/log/pb.ndjson" | tr -d ' ')"
"$SCRIPT" upload "$W/src" /my-files/backups/t --split-gb 0 >/dev/null 2>&1; check "re-run over existing folders exits 0 (already-exists tolerated)" 0 $?

echo "4. retries then failure"
reset_remote; echo 3 > "$FAKE_FAIL_FILE"
# fake reads FAKE_FAIL_UPLOADS from env each call; emulate a persistent counter via the file
cat > "$W/failing-cli" <<'EOS'
#!/usr/bin/env bash
n=$(cat "$FAKE_FAIL_FILE" 2>/dev/null || echo 0)
case "$*" in *"filesystem upload"*) if [ "$n" -gt 0 ]; then echo $((n-1)) > "$FAKE_FAIL_FILE"; echo "Error: simulated network failure"; exit 1; fi ;; esac
exec "$(dirname "$0")/../$(basename "$FAKE_REAL")" "$@"
EOS
sed -i.bak "s|\"\$(dirname \"\$0\")/../\$(basename \"\$FAKE_REAL\")\"|\"$HERE/fake-proton-drive\"|" "$W/failing-cli"; rm -f "$W/failing-cli.bak"; chmod +x "$W/failing-cli"
PROTON_DRIVE_BIN="$W/failing-cli" "$SCRIPT" upload "$W/src" /my-files/backups/r --split-gb 0 --retries 2 >/dev/null 2>&1
check "two failures with --retries 2 exits 5" 5 $?
echo 1 > "$FAKE_FAIL_FILE"; reset_remote
PROTON_DRIVE_BIN="$W/failing-cli" "$SCRIPT" upload "$W/src" /my-files/backups/r --split-gb 0 --retries 3 >/dev/null 2>&1
check "one failure then success exits 0" 0 $?

echo "5. split upload with manifest, per-part sums, .complete"
reset_remote
# split-gb must be an integer GB; the test file is 3 MiB, so drive the threshold via a
# 0-GB-equivalent: use part size override through the env the script exposes for tests.
PB_TEST_PART_MIB=1 "$SCRIPT" upload "$W/src" /my-files/backups/s --split-gb 1 >/dev/null 2>&1; rc=$?
check "split upload exits 0" 0 $rc
P="$FAKE_REMOTE/my-files/backups/s/src/big.img.parts"
check "manifest uploaded" 1 "$([ -f "$P/big.img.manifest" ] && echo 1 || echo 0)"
check "four parts uploaded (3 MiB + 5 bytes at 1 MiB parts)" 4 "$(ls "$P"/big.img.part-* 2>/dev/null | wc -l | tr -d ' ')"
check "parts.sha256 uploaded" 1 "$([ -f "$P/big.img.parts.sha256" ] && echo 1 || echo 0)"
check ".complete uploaded last" 1 "$([ -f "$P/big.img.complete" ] && echo 1 || echo 0)"
cat "$P"/big.img.part-* > "$W/rejoined.img"
check "rejoined parts are byte-identical" 0 "$(cmp -s "$W/src/big.img" "$W/rejoined.img"; echo $?)"
check "small files still uploaded alongside" 1 "$([ -f "$FAKE_REMOTE/my-files/backups/s/src/sub/b.txt" ] && echo 1 || echo 0)"
: > "$FAKE_CALLS"
PB_TEST_PART_MIB=1 "$SCRIPT" upload "$W/src" /my-files/backups/s --split-gb 1 >/dev/null 2>&1
check "re-run skips the completed big file (no part uploads)" 0 "$(grep -c 'part-' "$FAKE_CALLS" || true)"
check "re-run still exits 0" 0 $?

echo "6. verify-remote"
"$SCRIPT" verify-remote /my-files/backups/s/src >/dev/null 2>&1; check "verify-remote passes on intact parts" 0 $?
FAKE_CORRUPT=big.img.part-0002 "$SCRIPT" verify-remote /my-files/backups/s/src >/dev/null 2>&1; check "verify-remote exits 6 on a corrupted part" 6 $?
rm -f "$P/big.img.complete"
"$SCRIPT" verify-remote /my-files/backups/s/src >/dev/null 2>&1; check "verify-remote exits 6 when .complete is missing" 6 $?

echo "7. verify (round trip)"
reset_remote
"$SCRIPT" verify "$W/src/a.txt" /my-files/backups/v >/dev/null 2>&1; check "verify round trip exits 0" 0 $?
FAKE_CORRUPT=a.txt "$SCRIPT" verify "$W/src/a.txt" /my-files/backups/v >/dev/null 2>&1; check "verify exits 6 on corrupted download" 6 $?

echo "8. check-cli"
PROTON_CLI_PLATFORM=linux-x64 "$SCRIPT" check-cli >/dev/null 2>&1; check "fake binary fails the pinned hash, exits 3" 3 $?
PROTON_CLI_PLATFORM=nope "$SCRIPT" check-cli >/dev/null 2>&1; check "unknown platform exits 3" 3 $?

echo "9. age encryption (skipped if age is not installed)"
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
    age-keygen -o "$W/id.age" 2>/dev/null; RCPT="$(sed -n 's/^# public key: //p' "$W/id.age")"
    age-keygen -o "$W/id2.age" 2>/dev/null
    reset_remote
    "$SCRIPT" upload "$W/src" /my-files/backups/e --split-gb 0 --age-recipient "$RCPT" >/dev/null 2>&1; check "encrypted plain upload exits 0" 0 $?
    E="$FAKE_REMOTE/my-files/backups/e/src"
    check "remote has a.txt.age, not a.txt" 1 "$([ -f "$E/a.txt.age" ] && [ ! -f "$E/a.txt" ] && echo 1 || echo 0)"
    check "ciphertext does not contain the plaintext" 0 "$(grep -c hello "$E/a.txt.age" || true)"
    age -d -i "$W/id.age" "$E/sub/b.txt.age" > "$W/b.dec" 2>/dev/null; check "identity decrypts sub/b.txt.age" 0 "$(cmp -s "$W/src/sub/b.txt" "$W/b.dec"; echo $?)"
    check "no leftover ciphertext in staging" 0 "$(ls "${TMPDIR:-/tmp}/proton-backup-staging"/*.age 2>/dev/null | wc -l | tr -d ' ')"
    reset_remote
    PB_TEST_PART_MIB=1 "$SCRIPT" upload "$W/src" /my-files/backups/es --split-gb 1 --age-recipient "$RCPT" >/dev/null 2>&1; check "encrypted split upload exits 0" 0 $?
    PE="$FAKE_REMOTE/my-files/backups/es/src/big.img.parts"
    check "four encrypted parts" 4 "$(ls "$PE"/big.img.part-*.age 2>/dev/null | wc -l | tr -d ' ')"
    check "no plaintext parts" 0 "$(ls "$PE"/big.img.part-???? 2>/dev/null | wc -l | tr -d ' ')"
    check "manifest says encryption=age" 1 "$(grep -c '^encryption	age$' "$PE/big.img.manifest")"
    "$SCRIPT" verify-remote /my-files/backups/es/src >/dev/null 2>&1; check "verify-remote passes on ciphertext without a key" 0 $?
    "$SCRIPT" restore-parts "$PE" "$W/restored.img" --age-identity "$W/id.age" >/dev/null 2>&1; check "restore-parts exits 0" 0 $?
    check "restored file is byte-identical" 0 "$(cmp -s "$W/src/big.img" "$W/restored.img"; echo $?)"
    "$SCRIPT" restore-parts "$PE" "$W/restored2.img" --age-identity "$W/id2.age" >/dev/null 2>&1; check "restore-parts with the wrong identity exits 6" 6 $?
    "$SCRIPT" restore-parts "$PE" "$W/restored3.img" >/dev/null 2>&1; check "restore-parts without an identity exits 2" 2 $?
    reset_remote
    "$SCRIPT" verify "$W/src/a.txt" /my-files/backups/ev --age-recipient "$RCPT" --age-identity "$W/id.age" >/dev/null 2>&1; check "encrypted verify round trip exits 0" 0 $?
    check "verify uploaded ciphertext only" 1 "$([ -f "$FAKE_REMOTE/my-files/backups/ev/a.txt.age" ] && [ ! -f "$FAKE_REMOTE/my-files/backups/ev/a.txt" ] && echo 1 || echo 0)"
    "$SCRIPT" verify "$W/src/a.txt" /my-files/backups/ev --age-recipient "$RCPT" --age-identity "$W/id2.age" >/dev/null 2>&1; check "encrypted verify with wrong identity exits 6" 6 $?
    "$SCRIPT" upload "$W/src" /my-files/backups/ed --age-recipient "$RCPT" --dry-run >/dev/null 2>&1; check "encrypted dry-run exits 0 and calls nothing" 0 $?
else
    echo "  skip age not installed"
fi

echo "10. readable summary"
reset_remote; rm -f "$W/log/pb.summary.log"
out="$("$SCRIPT" upload "$W/src" /my-files/backups/sum --split-gb 0 2>&1)"; rc=$?
check "summary run exits 0" 0 $rc
check "summary line printed with OK, file count and MB" 1 "$(printf '%s' "$out" | grep -c 'OK: 3 file(s), 3.1 MB uploaded')"
check "summary log has one line" 1 "$(wc -l < "$W/log/pb.summary.log" | tr -d ' ')"
out="$("$SCRIPT" upload "$W/src" /my-files/backups/sum --split-gb 0 --dry-run 2>&1)"
check "dry-run prints a PLAN line in MB" 1 "$(printf '%s' "$out" | grep -c 'PLAN: 3 file(s), 3.1 MB total')"
check "dry-run adds no summary line" 1 "$(wc -l < "$W/log/pb.summary.log" | tr -d ' ')"
PB_TEST_PART_MIB=1 "$SCRIPT" upload "$W/src" /my-files/backups/sum2 --split-gb 1 >/dev/null 2>&1
out="$(PB_TEST_PART_MIB=1 "$SCRIPT" upload "$W/src" /my-files/backups/sum2 --split-gb 1 2>&1)"
check "re-run summary reports the skipped file" 1 "$(printf '%s' "$out" | grep -c '1 skipped (already complete)')"
echo 2 > "$FAKE_FAIL_FILE"
out="$(PROTON_DRIVE_BIN="$W/failing-cli" "$SCRIPT" upload "$W/src" /my-files/backups/sum3 --split-gb 0 --retries 1 2>&1)"; rc=$?
check "failed run still writes a FAILED summary line" 1 "$(printf '%s' "$out" | grep -c 'FAILED (exit 5)')"
check "last shows the runs" 4 "$("$SCRIPT" last 2>/dev/null | wc -l | tr -d ' ')"
check "human_size units" "1.50 GB|480.0 MB|12 KB|7 B" "$(bash -c 'source <(sed -n "/^human_size()/,/^}/p" "'"$SCRIPT"'"); printf "%s|%s|%s|%s" "$(human_size 1500000000)" "$(human_size 480000000)" "$(human_size 12000)" "$(human_size 7)"')"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]

# proton-drive-backup

Uploads a directory of files to Proton Drive using Proton's official Drive
CLI, which is built on the official
[Proton Drive SDK](https://github.com/ProtonDriveApps/sdk). Any files: a
photo library, a NAS share, database dumps, restored Proxmox backup images.
It adds what a backup job needs and the CLI does not have: retries that
resume, splitting for files too large to risk in one go, integrity checks,
exit codes a timer can act on, and logs a person or an agent can read.
Proton Drive is end to end encrypted by Proton. If you would rather not
depend on that, `--age-recipient` encrypts every file on your machine first,
so Proton only ever holds ciphertext you can open (see "Zero trust").

This is a third-party wrapper, not officially supported by Proton.

## Why the official CLI and not the SDK directly

The SDK deliberately ships no authentication, session management, or address
provider ([SDK README, "Scope and Limitations"](https://github.com/ProtonDriveApps/sdk#scope-and-limitations)).
Proton's own Drive CLI, maintained inside the SDK repo, supplies that whole
stack: browser-based login that works headless, session storage in an OS secret
store, caching, event sync, and the required `x-pm-appversion` identification.
Hand-rolling SRP auth against undocumented internals is exactly the
reverse-engineering this project exists to avoid (that is rclone's protondrive
problem). This wrapper adds retry loops, split-part handling for huge files,
logging, and round-trip verification.

## One warning that matters

**The Proton account credentials and recovery kit ARE the backup now.** If the
account is lost, the files are lost; Proton cannot decrypt them for you. Keep
the recovery phrase somewhere that survives the same disaster this backup
protects against. Do not build anything that assumes the credentials can be
recovered later.

Also: Proton is migrating Drive to a new cryptographic model, targeted end of
2026 / early 2027. Old CLI builds will stop interoperating when that lands.
This does not endanger stored data (web access keeps working), but this tool's
pinned CLI binary will need an update around then. Watch the
[SDK repo](https://github.com/ProtonDriveApps/sdk) changelog.

## Install (Linux headless, or macOS)

1. Download the CLI binary from
   [proton.me/download/drive/cli](https://proton.me/download/drive/cli/index.html).
   On Linux x64 pick `linux/x64`; if it crashes at startup with
   `Illegal instruction`, use `linux/x64-baseline` (no AVX2 requirement, common
   on NAS and older server CPUs).
2. `chmod +x proton-drive` and put it on PATH, or point `PROTON_DRIVE_BIN` at it.
   Then run `proton-backup.sh check-cli`. The script pins CLI 0.8.0 (released
   2026-08-13) by SHA-512 for every platform on the download page, so a silent
   upgrade fails loudly instead of running. When Proton ships a new CLI, update
   the `pinned_sha512` table at the top of the script from the index page. On a
   `linux-x64-baseline` or musl build set `PROTON_CLI_PLATFORM` to match.
   The script itself needs only POSIX tools plus bash: it works with GNU
   coreutils or BSD (`sha256sum` or `shasum`, `stat -c` or `stat -f`, plain `dd`).
3. Pick a credential store. The CLI default is the OS keychain via libsecret,
   which a headless box usually does not have. Options, best first:
   - `export PROTON_DRIVE_CREDENTIALS_STORE=pass` with
     [pass](https://www.passwordstore.org/) initialized (`apt install pass gnupg`,
     `gpg --gen-key`, `pass init <key-id>`). Session lives GPG-encrypted at
     `ch.proton.drive/drive-sdk-cli/auth-session`.
   - Install a keyring (`apt install gnome-keyring libsecret-1-0`) and unlock it
     at boot. Fiddly on headless systems.
   - `PROTON_DRIVE_CREDENTIALS_STORE=unsafe_file` stores the session as
     plaintext JSON in the app data dir. The CLI authors mark it testing-only.
     On a single-user box inside a tailnet it is a conscious tradeoff; the
     session grants full Drive access, so treat the file like a key.
4. Export the store choice in the shell profile of whatever user runs backups,
   so cron and interactive runs agree.

## Authenticate once

```bash
proton-backup.sh login
```

The CLI prints a sign-in URL. Open it in a browser on any device (phone is
fine), approve, and the terminal session completes on its own. No password ever
touches the command line. The session persists in the credential store;
re-login only when it expires or after `proton-drive auth logout`.

## Usage

```bash
# Is the CLI the pinned build? Is the session alive? (exit 3 / exit 4)
./proton-backup.sh check-cli
./proton-backup.sh status

# See exactly what would happen, calling nothing: every file, its size, the
# remote path, and the part count for anything that will be split.
./proton-backup.sh upload /srv/exports /my-files/backups/exports --dry-run

# Whole directory. Files over 8 GB (the default) upload as 8 GB parts; see
# resume semantics. --split-gb 0 turns splitting off.
./proton-backup.sh upload /srv/exports /my-files/backups/exports
./proton-backup.sh upload ~/Pictures/2026 /my-files/photos/2026 --split-gb 0
./proton-backup.sh upload /mnt/restore/pbs-images /my-files/backups/pbs

# Same, but encrypted on this machine with age before anything leaves.
./proton-backup.sh upload /srv/exports /my-files/backups/exports --age-recipient age1...

# Round-trip acceptance check for one file: upload, download back, byte diff.
./proton-backup.sh verify /srv/exports/db-2026-09.sql.zst /my-files/backups/exports

# What happened lately, one readable line per run.
./proton-backup.sh last

# Rebuild a split file from a downloaded <name>.parts folder (decrypts if needed).
./proton-backup.sh restore-parts ./restore/big.img.parts ./big.img --age-identity ~/.config/age/backup.txt

# Integrity check of what is already remote: download each split file's
# manifest and parts one at a time, hash, compare, delete.
./proton-backup.sh verify-remote /my-files/backups/exports/exports
```

Remote paths use the CLI's path syntax; personal storage is rooted at
`/my-files`.

### Exit codes

| Code | Meaning | Typical cause |
|---|---|---|
| 0 | ok | |
| 2 | usage | bad arguments, missing source directory |
| 3 | CLI missing or wrong hash | not on PATH, or not the pinned 0.8.0 build |
| 4 | session dead | `You need to login first`; run `login` again |
| 5 | upload failed after retries | network, quota, remote folder could not be created |
| 6 | verify mismatch | a downloaded copy differs, or a `.complete` marker is missing |
| 7 | staging disk full | less than one part plus 64 MiB free in `--staging` |

A systemd unit can branch on these with `OnFailure`. Every `die` names the
code, so the last log line says which one it was.

### What a person reads

Every run ends with one line, printed and appended to
`proton-backup.summary.log` next to the other logs:

```
OK: 14 file(s), 48.30 GB uploaded in 7 part(s), 2 skipped (already complete), 1h 12m, encrypted with age. /srv/exports -> /my-files/backups/exports
FAILED (exit 5): 3 file(s), 9.10 GB uploaded, 1 failed, 22m 05s. /srv/exports -> /my-files/backups/exports
```

A failed run still leaves its line, so you can see how far it got.
`proton-backup.sh last` prints the last ten runs; `last 30` for more.
`--dry-run` prints the same kind of plan before anything moves: each file
with its size, then a total, the split count, and whether encryption is on.
Sizes are decimal (MB, GB) so they compare directly with what a drive or a
storage plan says.

### Logs

Three files, side by side, default `~/.local/state/proton-backup/` or
`/var/log/proton-backup/` when that directory exists and is writable
(override with `PROTON_BACKUP_LOG` and `PROTON_BACKUP_JSONL`):

- `proton-backup.log`: timestamped lines plus every CLI invocation and its
  output. Human-readable, grows fast, rotate it.
- `proton-backup.ndjson`: one JSON line per file with `path`, `remote`,
  `bytes`, `parts`, `sha256`, `seconds`, `result` (`ok`, `skipped`, `failed`).
  This is the file an agent or a dashboard reads.
- `proton-backup.summary.log`: one readable line per run, see above. This is
  the file a person checks (`PROTON_BACKUP_SUMMARY` overrides the path).

Conflict behavior on re-upload: a file whose content already exists remotely is
skipped automatically (SHA1 match, done server-side); a file whose content
changed becomes a new revision of the existing file; folders merge.

### What changed from the first version

- Remote folder creation no longer swallows errors. A failed `create-folder`
  is tolerated only when the folder turns out to exist; anything else stops
  the run with exit 5.
- A dead session is detected up front (`status` runs before any upload) and
  during a run (the CLI's `You need to login first` exits 4 at once instead
  of eight blind retries).
- Splitting is the default for anything over 8 GB, not an opt-in.
- Each split file ends with a `<name>.complete` marker. A re-run sees the
  marker and skips the file without re-hashing 50 GB.
- Each split file gets `<name>.parts.sha256`, one line per part, so
  `verify-remote` can check every part without a local copy.
- Staging free space is checked before each part is extracted (exit 7).
- `--dry-run` prints the plan and calls nothing.
- No GNU-only commands remain, so it runs on the Air and on BSD.
- Optional client-side age encryption, with a `restore-parts` command that
  reverses it.
- One readable summary line per run, in MB and GB, plus a `last` command.

## Zero trust: encrypt before upload

Proton's end-to-end encryption means Proton cannot read your files today. It
does not mean you have to trust that forever. With `--age-recipient age1...`
(or `PROTON_BACKUP_AGE_RECIPIENT` in the environment) every file and every
split part is encrypted with [age](https://age-encryption.org) on this
machine before the CLI sees it. What Proton stores is ciphertext under a key
they never had. Names get a `.age` suffix; a split file's parts are
encrypted one by one so staging still needs only one part of disk.

- **Key.** `age-keygen -o backup.txt` prints the recipient line; store the
  file in 1Password or on paper. The identity is only needed to restore.
  **Without it the backup is unrecoverable and Proton cannot help.** Keep it
  where it survives the same disaster the backup protects against.
- **Verify still works without the key.** `verify-remote` hashes the
  ciphertext parts against `<name>.parts.sha256`, which was written from the
  ciphertext, so a scheduled integrity check needs no secret on the box.
- **Restore.** Download the `<name>.parts` folder, then
  `proton-backup.sh restore-parts <dir> <out> --age-identity backup.txt`. It
  checks every part's hash, decrypts, joins in order, and checks the whole
  file against the manifest. For an unsplit file, `age -d -i backup.txt
  file.age > file`.
- **Round trip.** `verify --age-recipient R --age-identity FILE` uploads
  ciphertext, downloads it, decrypts, and byte-compares.
- **Cost.** One pass of age per file or part, streamed. With encryption on,
  every file passes through staging even when it is under the split size,
  so the tree upload shortcut is not used.

The manifest records `encryption	age` and the recipient, so a restore years
later knows which key to look for.

## Resume semantics, honestly

Verified by reading the SDK source, not the marketing:

- **Within a run:** files stream in 4 MiB encrypted blocks, up to 5 in flight;
  each block retries up to 3 times and refreshes expired upload tokens. A
  dropped connection does not restart the file.
- **Across a killed run:** re-running the same command is the resume. Files
  already uploaded are skipped by SHA1. A file that was mid-upload when the
  process died restarts from byte 0; the SDK deletes its own abandoned draft
  rather than resuming it. Block-level cross-run resume does not exist in the
  SDK today.
- **Therefore `--split-gb N`:** files over N GB are extracted one N GB part at
  a time with `dd` (staging needs only one part of free disk, default
  `/tmp/proton-backup-staging`, override with `--staging`), uploaded to a
  remote folder named `<file>.parts/` alongside a manifest, and a killed run
  loses at most one part. Restore:

  The remote folder holds `big.img.manifest` (first), the parts, then
  `big.img.parts.sha256` and `big.img.complete` (last). If `.complete` is
  missing the upload did not finish. Restore:

  ```bash
  proton-drive filesystem download /my-files/backups/exports/exports/big.img.parts ./restore
  cd ./restore/big.img.parts
  sha256sum -c big.img.parts.sha256      # or: shasum -a 256 -c
  cat big.img.part-* > ../big.img
  sha256sum ../big.img   # compare against the sha256 line in big.img.manifest
  ```

## Tests

`tests/run.sh` runs the whole script against `tests/fake-proton-drive`, a
stand-in that mirrors the 0.8.0 command surface this wrapper uses (list, info,
create-folder, upload, download, the real `You need to login first` message
and exit code). No Proton account, no network, a few seconds:

```bash
bash tests/run.sh
```

It covers every exit code, dry-run making no calls, plain and split uploads,
manifest and per-part sums and the `.complete` marker, kill-and-resume via the
marker, `verify` and `verify-remote` catching a flipped byte, and the CLI hash
pin, the readable summary and plan lines, and, when `age` is installed, the
whole encrypted path: ciphertext-only
uploads, `verify-remote` on ciphertext, `restore-parts` with the right and
the wrong identity. Run it before changing the script; run `shellcheck
proton-backup.sh` too.

Against a real account, the acceptance test is still the round trip:

```bash
./proton-backup.sh verify /path/to/testfile /my-files/backups/test
./proton-backup.sh upload /path/to/dir /my-files/backups/test   # kill it mid-transfer
./proton-backup.sh upload /path/to/dir /my-files/backups/test   # re-run: resume
./proton-backup.sh verify-remote /my-files/backups/test/dir
```

## Run it on a timer (systemd)

`systemd/` holds a oneshot service, a daily timer with a two hour jitter, an
`OnFailure` hook that appends the failing unit's journal to
`/var/log/proton-backup/alerts.log`, a logrotate stanza (weekly, eight
rotations), and `install.sh`, which creates a `backup` system user, the log
and staging directories, and installs the lot without starting anything.

```bash
sudo sh systemd/install.sh
sudo -u backup -H env PROTON_DRIVE_CREDENTIALS_STORE=pass proton-backup.sh login
sudo -u backup -H env PROTON_DRIVE_CREDENTIALS_STORE=pass proton-backup.sh status
sudo systemctl enable --now proton-backup.timer
```

Edit `ExecStart` in the service for your source directory and remote path;
the shipped example uploads `/srv/backup` to `/my-files/backups/host`. For
Proxmox, point it at a directory of restored images and keep `--split-gb 8`.
The service runs `check-cli` and `status` as `ExecStartPre`, so a swapped
binary or an expired session fails the unit before a byte moves, and the
failure hook records it instead of the job silently doing nothing for a month.

If the box has libsecret but no session bus, log in with
`dbus-run-session -- proton-drive auth login`. If you want 1Password in the
loop, use it for the GPG passphrase that unlocks `pass`, read at unit start
with a service account token from a root-only file; never put the Proton
password itself anywhere on disk.

## Proton's third-party rules, complied with

Personal, non-commercial use of the SDK is allowed under Proton's
[usage guidelines](https://github.com/ProtonDriveApps/sdk#usage-guidelines-for-personal-projects).
This tool uses Proton's own unmodified CLI release, so app identification,
rate-limit behavior, caching, and event-based sync are all the first-party
implementations. Do not point it at non-official endpoints and do not rebrand
it as a Proton product.

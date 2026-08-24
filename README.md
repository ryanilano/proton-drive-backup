# proton-drive-backup

Uploads a local directory of backup files (restored PBS images) to Proton Drive,
using Proton's official Drive CLI, which is built on the official
[Proton Drive SDK](https://github.com/ProtonDriveApps/sdk). Proton Drive is end
to end encrypted, so files are encrypted at rest by Proton and no extra
encryption layer is added here.

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

## Install (Linux, headless)

1. Download the CLI binary from
   [proton.me/download/drive/cli](https://proton.me/download/drive/cli/index.html).
   On Linux x64 pick `linux/x64`; if it crashes at startup with
   `Illegal instruction`, use `linux/x64-baseline` (no AVX2 requirement, common
   on NAS and older server CPUs).
2. `chmod +x proton-drive` and put it on PATH, or point `PROTON_DRIVE_BIN` at it.
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
# Whole directory, files uploaded as-is:
./proton-backup.sh upload /mnt/restore/pbs-images /my-files/backups/pbs

# Same, but files over 8 GB upload as 8 GB parts (see resume semantics):
./proton-backup.sh upload /mnt/restore/pbs-images /my-files/backups/pbs --split-gb 8

# Round-trip acceptance check: upload, download back, byte-for-byte diff:
./proton-backup.sh verify /mnt/restore/pbs-images/test.img /my-files/backups/pbs
```

Remote paths use the CLI's path syntax; personal storage is rooted at
`/my-files`. Every run appends timestamped lines plus the CLI's JSON transfer
summaries to `~/.local/state/proton-backup/proton-backup.log` (override with
`PROTON_BACKUP_LOG`).

Conflict behavior on re-upload: a file whose content already exists remotely is
skipped automatically (SHA1 match, done server-side); a file whose content
changed becomes a new revision of the existing file; folders merge.

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

  ```bash
  proton-drive filesystem download /my-files/backups/pbs/pbs-images/big.img.parts ./restore
  cat ./restore/big.img.parts/big.img.part-* > big.img
  sha256sum big.img   # compare against the sha256 line in big.img.manifest
  ```

## Acceptance test

```bash
# 1. Round trip:
./proton-backup.sh verify /path/to/testfile /my-files/backups/test

# 2. Kill and resume: start an upload, kill -9 the process partway,
#    re-run the identical command, then verify the file(s):
./proton-backup.sh upload /path/to/dir /my-files/backups/test
# (ctrl-c or kill it mid-transfer)
./proton-backup.sh upload /path/to/dir /my-files/backups/test
./proton-backup.sh verify /path/to/dir/somefile /my-files/backups/test/dir
```

## Proton's third-party rules, complied with

Personal, non-commercial use of the SDK is allowed under Proton's
[usage guidelines](https://github.com/ProtonDriveApps/sdk#usage-guidelines-for-personal-projects).
This tool uses Proton's own unmodified CLI release, so app identification,
rate-limit behavior, caching, and event-based sync are all the first-party
implementations. Do not point it at non-official endpoints and do not rebrand
it as a Proton product.

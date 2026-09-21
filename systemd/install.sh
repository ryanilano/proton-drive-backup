#!/bin/sh
# Install the units on a Debian/Ubuntu box. Run as root. Idempotent.
# Does not start the timer; do that yourself after `proton-backup.sh login`
# as the backup user and a green `proton-backup.sh status`.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
id backup >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin backup
install -d -o backup -g backup -m 0750 /var/log/proton-backup /var/tmp/proton-backup-staging
install -m 0755 "$HERE/../proton-backup.sh" /usr/local/bin/proton-backup.sh
install -m 0644 "$HERE/proton-backup.service" "$HERE/proton-backup.timer" "$HERE/proton-backup-failed@.service" /etc/systemd/system/
install -m 0644 "$HERE/proton-backup.logrotate" /etc/logrotate.d/proton-backup
systemctl daemon-reload
echo "installed. next: sudo -u backup -H env PROTON_DRIVE_CREDENTIALS_STORE=pass proton-backup.sh login"
echo "then:      sudo -u backup -H env PROTON_DRIVE_CREDENTIALS_STORE=pass proton-backup.sh status"
echo "then:      systemctl enable --now proton-backup.timer"

# Changelog

## 1.0.1 (2026-11-01)

- The installer stopped with «sshd's current settings fail sshd -t» on a machine whose sshd had not
  started since boot, as on Ubuntu 24.04 (socket activation) before the first SSH connection: sshd -t
  needs /run/sshd, which systemd creates only when sshd starts. The installer, the uninstaller and
  backup-vault now create it when it is missing.
- The CI's end-to-end test no longer starts sshd before installing, so it covers that case.

## 1.0.0 (2026-11-01)

First public release.

- Backup accounts (group `sftp_backups`): SFTP only, chrooted, upload-only. sshd refuses reading,
  deleting, links and server-side copies, and every kind of forwarding; each account can be kept
  to its server's address, and those addresses to backup accounts.
- `ingest` every minute: finished uploads move into a root-only vault, read-only and immutable,
  with their SHA-256 recorded. Zip, gzip and tar files are checked for being whole, and backup
  folders against their `SHA256SUMS` or `manifest.json`.
- `rotate` every night: grandfather-father-son by time windows, per series and per account, with
  a trash kept for a week. It never deletes to make room or with an unsynchronised clock.
- `verify` every week, `status` in the login message, the accounts' SFTP actions in `auth.log`.
- Commands to add, pin, key, disable and remove accounts, copy a backup out, and test the setup
  (`selftest`).
- `install.sh` (one line through curl, or from a clone) and `uninstall.sh`, which never deletes a backup.

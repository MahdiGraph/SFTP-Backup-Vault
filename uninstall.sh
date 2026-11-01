#!/usr/bin/env bash
# SFTP Backup Vault uninstaller: https://github.com/MahdiGraph/SFTP-Backup-Vault
#
#   sudo ./uninstall.sh [--yes] [--keep-accounts]
#
# Removes the program, its timers, its sshd and rsyslog rules and the login message. It never deletes
# a backup: the vault, the accounts' folders, the settings and the history stay where they are. The
# backup accounts are locked, because without these rules they would be ordinary users of this
# server; --keep-accounts leaves them able to log in (only do that if you replace the rules yourself).
set -euo pipefail

GROUP=sftp_backups
SSHD_DIR=/etc/ssh/sshd_config.d
yes=0
keep_accounts=0
for arg in "$@"; do
  case "$arg" in
    -y | --yes) yes=1 ;;
    --keep-accounts) keep_accounts=1 ;;
    -h | --help)
      echo "usage: sudo ./uninstall.sh [--yes] [--keep-accounts]"
      exit 0
      ;;
    *)
      echo "unknown option: $arg (see --help)" >&2
      exit 2
      ;;
  esac
done
say() { printf '\n== %s\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "run it as root: sudo $0" >&2; exit 1; }

if [ "$yes" != 1 ]; then
  [ -r /dev/tty ] || { echo "pass --yes to uninstall without a terminal" >&2; exit 1; }
  printf 'Remove SFTP Backup Vault (backups are kept)? [y/N] ' > /dev/tty
  read -r answer < /dev/tty
  [ "$answer" = y ] || [ "$answer" = Y ] || exit 1
fi

members=""
if getent group "$GROUP" > /dev/null; then
  members=$(python3 -I -c 'import grp, pwd, sys; g = grp.getgrnam(sys.argv[1]); print(" ".join(sorted(set(g.gr_mem) | {p.pw_name for p in pwd.getpwall() if p.pw_gid == g.gr_gid})))' "$GROUP")
fi
if [ -n "$members" ] && [ "$keep_accounts" != 1 ]; then
  say "Locking the backup accounts: $members"
  for account in $members; do
    usermod --expiredate 1 "$account"
    pkill -u "$account" 2> /dev/null || true
  done
fi

say "Timers"
for unit in backup-vault-ingest.timer backup-vault-rotate.timer backup-vault-verify.timer; do
  systemctl disable --now "$unit" 2> /dev/null || true
done
rm -f /etc/systemd/system/backup-vault-ingest.service /etc/systemd/system/backup-vault-ingest.timer \
  /etc/systemd/system/backup-vault-rotate.service /etc/systemd/system/backup-vault-rotate.timer \
  /etc/systemd/system/backup-vault-verify.service /etc/systemd/system/backup-vault-verify.timer
systemctl daemon-reload

say "SSH rules"
rm -f "$SSHD_DIR/40-backup-vault.conf" "$SSHD_DIR/41-backup-vault-access.conf"
if /usr/sbin/sshd -t; then
  for unit in ssh.service sshd.service; do
    if systemctl cat "$unit" > /dev/null 2>&1; then
      systemctl try-reload-or-restart "$unit"
      break
    fi
  done
else
  echo "  ! sshd -t fails now; fix /etc/ssh/sshd_config before the next restart of sshd"
fi
[ -f "$SSHD_DIR/39-backup-vault-local.conf" ] && echo "kept $SSHD_DIR/39-backup-vault-local.conf (your own settings)"

say "Logging and the login message"
if [ -f /etc/rsyslog.d/40-backup-vault.conf ]; then
  rm -f /etc/rsyslog.d/40-backup-vault.conf
  systemctl try-restart rsyslog.service || true
fi
if [ -f /etc/apparmor.d/rsyslog.d/backup-vault ]; then
  rm -f /etc/apparmor.d/rsyslog.d/backup-vault
  if grep -q '^rsyslogd ' /sys/kernel/security/apparmor/profiles 2> /dev/null; then
    apparmor_parser -r /etc/apparmor.d/usr.sbin.rsyslogd || true
  fi
fi
rm -f /etc/update-motd.d/60-backup-vault /usr/local/sbin/backup-vault

say "Done. Kept, for you to keep or delete:"
cat << EOF
  /var/backups/vault         the backups (immutable: sudo chattr -R -i /var/backups/vault before deleting any)
  /var/backups/sftp          the accounts' chroots and upload folders
  /etc/backup-vault          settings, README and the accounts' SSH keys
  /var/lib/backup-vault      the history (SHA-256 of every backup) and the install logs
  group $GROUP and its accounts${members:+: $members}$([ "$keep_accounts" = 1 ] && echo " (still able to log in!)" || echo " (locked)")
EOF

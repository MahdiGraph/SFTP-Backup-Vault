#!/usr/bin/env bash
# SFTP Backup Vault installer: https://github.com/MahdiGraph/SFTP-Backup-Vault
#
#   curl -fsSL https://raw.githubusercontent.com/MahdiGraph/SFTP-Backup-Vault/main/install.sh | sudo bash
#   or, from a clone of the repository:   sudo ./install.sh
#
# Options:
#   -y, --yes          install missing packages without asking
#   --keys-only        backup accounts log in with SSH keys only (default: passwords too)
#   --no-selftest      skip the self-test at the end
#   --version=X.Y.Z    install that release (when run through curl)
#
# Installs or upgrades backup-vault, the sshd rules of the group sftp_backups, the vault, its timers
# and the login message. Running it again is safe: it keeps the settings, the accounts and the backups.
set -euo pipefail
umask 022

VERSION=1.0.0
REPO=MahdiGraph/SFTP-Backup-Vault
GROUP=sftp_backups
SSHD_DIR=/etc/ssh/sshd_config.d

yes=0
keys_only=""
selftest=1
for arg in "$@"; do
  case "$arg" in
    -y | --yes) yes=1 ;;
    --keys-only) keys_only=1 ;;
    --no-selftest) selftest=0 ;;
    --version=*) VERSION=${arg#--version=} ;;
    -h | --help)
      echo "usage: sudo ./install.sh [--yes] [--keys-only] [--no-selftest] [--version=X.Y.Z]"
      echo "guide: https://github.com/$REPO"
      exit 0
      ;;
    *)
      echo "unknown option: $arg (see --help)" >&2
      exit 2
      ;;
  esac
done

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }
ask() {
  # A yes/no question from the terminal, even when this script itself comes through a pipe.
  [ "$yes" = 1 ] && return 0
  [ -r /dev/tty ] || return 1
  local answer
  printf '%s [Y/n] ' "$1" > /dev/tty
  read -r answer < /dev/tty || return 1
  [ -z "$answer" ] || [ "$answer" = y ] || [ "$answer" = Y ]
}

[ "$(id -u)" = 0 ] || die "run it as root: sudo $0"

# The files to install: next to this script in a clone, or this version's release when piped.
src=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [ -f "$here/backup-vault" ] && [ -d "$here/system" ]; then
    src=$here
  fi
fi
if [ -z "$src" ]; then
  # Run through a pipe: fetch the release and run its own installer from a file.
  tmp=$(mktemp -d)
  url="https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz"
  echo "Downloading SFTP Backup Vault $VERSION: $url"
  if command -v curl > /dev/null; then
    curl -fsSL "$url" | tar -xz -C "$tmp"
  elif command -v wget > /dev/null; then
    wget -qO- "$url" | tar -xz -C "$tmp"
  else
    die "curl or wget is needed to download it"
  fi
  release=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -f "$release/install.sh" ] || die "the download holds no installer"
  status=0
  bash "$release/install.sh" "$@" < /dev/null || status=$?
  rm -rf "${tmp:?}"
  exit "$status"
fi
VERSION=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$src/backup-vault")

stamp=$(date +%Y%m%d-%H%M%S)
install -d -m 0700 /var/lib/backup-vault
saved=/var/lib/backup-vault/install-$stamp
mkdir -m 0700 "$saved"
exec > >(tee -a "$saved/install.log") 2>&1
echo "SFTP Backup Vault $VERSION installer, $(date). Log and previous settings: $saved"

say "Checking the system"
[ -d /run/systemd/system ] || die "systemd is needed"
manager=""
if command -v apt-get > /dev/null; then
  manager=apt
elif command -v dnf > /dev/null; then
  manager=dnf
elif command -v yum > /dev/null; then
  manager=yum
fi
missing=()
want() { # want COMMAND APT_PACKAGE RPM_PACKAGE
  command -v "$1" > /dev/null || [ -x "/usr/sbin/$1" ] || missing+=("$([ "$manager" = apt ] && echo "$2" || echo "$3")")
}
want python3 python3 python3
want sshd openssh-server openssh-server
want sftp openssh-client openssh-clients
want ssh-keygen openssh-client openssh-clients
want chattr e2fsprogs e2fsprogs
want pgrep procps procps-ng
want logger bsdutils util-linux
want rsyslogd rsyslog rsyslog
if [ "${#missing[@]}" -gt 0 ]; then
  mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
  echo "missing: ${missing[*]}"
  [ -n "$manager" ] || die "install them with your package manager and run this again"
  ask "Install them with $manager?" || die "install them and run this again (or pass --yes)"
  if [ "$manager" = apt ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  else
    "$manager" install -y "${missing[@]}"
  fi
fi
SSHD=$(command -v sshd || echo /usr/sbin/sshd)
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || die "Python 3.8 or newer is needed"
ssh_version=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
read -r major minor <<< "${ssh_version:-0 0}"
[ "$major" -gt 7 ] || { [ "$major" = 7 ] && [ "$minor" -ge 8 ]; } || die "OpenSSH 7.8 or newer is needed (found ${major}.${minor})"
grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
  || die "/etc/ssh/sshd_config does not include $SSHD_DIR/*.conf; add the line «Include $SSHD_DIR/*.conf» at its top, then run this again"
"$SSHD" -t || die "sshd's current settings fail «sshd -t»; fix them first"
echo "OpenSSH ${major}.${minor}, $(python3 --version), packages: ${manager:-unknown}"

# The address this session comes from: the new rules must never refuse it.
client=$(tr '\0' '\n' < "/proc/$PPID/environ" 2> /dev/null | sed -n 's/^SSH_CONNECTION=\([^ ]*\) .*/\1/p' || true)
admin=${SUDO_USER:-root}

say "Saving the current SSH settings in $saved"
cp -a /etc/ssh/sshd_config "$saved/"
cp -a "$SSHD_DIR" "$saved/sshd_config.d"
reload_sshd() {
  # ssh.service on Debian and Ubuntu, sshd.service elsewhere; a socket-activated one reads the rules when it starts.
  local unit
  for unit in ssh.service sshd.service; do
    if systemctl cat "$unit" > /dev/null 2>&1; then
      systemctl try-reload-or-restart "$unit"
      return
    fi
  done
}
restore_ssh() {
  cp -a "$saved/sshd_config" /etc/ssh/sshd_config
  rm -f "$SSHD_DIR/39-backup-vault-local.conf" "$SSHD_DIR/40-backup-vault.conf" "$SSHD_DIR/41-backup-vault-access.conf"
  cp -a "$saved/sshd_config.d/." "$SSHD_DIR/"
}

say "Installing backup-vault $VERSION"
getent group "$GROUP" > /dev/null || groupadd --system "$GROUP"
install -m 0755 "$src/backup-vault" /usr/local/sbin/backup-vault
install -d -m 0755 /etc/backup-vault /etc/backup-vault/keys
if [ -f /etc/backup-vault/backup-vault.conf ]; then
  echo "keeping /etc/backup-vault/backup-vault.conf"
else
  install -m 0644 "$src/backup-vault.conf.example" /etc/backup-vault/backup-vault.conf
fi
install -m 0644 "$src/README.md" /etc/backup-vault/README.md
install -d -m 0755 /var/backups /var/backups/sftp
install -d -m 0700 /var/backups/vault
install -m 0644 "$src"/system/systemd/backup-vault-*.service "$src"/system/systemd/backup-vault-*.timer /etc/systemd/system/
if [ -d /etc/update-motd.d ]; then
  install -m 0755 "$src/system/motd/60-backup-vault" /etc/update-motd.d/60-backup-vault
fi
backup-vault policy > /dev/null

say "SSH rules for the group $GROUP"
ours=$SSHD_DIR/40-backup-vault.conf
if [ -f "$ours" ]; then
  # Keep the login method chosen before, and any setting someone added above our Match block.
  if [ -z "$keys_only" ] && ! grep -qE '^[[:space:]]+PasswordAuthentication[[:space:]]+yes' "$ours"; then
    keys_only=1
  fi
  local_lines=$(awk '/^[[:space:]]*Match[[:space:]]/ {exit} /^[[:space:]]*($|#)/ {next} {print}' "$ours")
  if [ -n "$local_lines" ] && [ ! -f "$SSHD_DIR/39-backup-vault-local.conf" ]; then
    { echo "# Settings once added to 40-backup-vault.conf, kept here by install.sh: this file is yours."; echo "$local_lines"; } > "$SSHD_DIR/39-backup-vault-local.conf"
    echo "your settings from $ours are now in $SSHD_DIR/39-backup-vault-local.conf"
  fi
fi
if [ -n "$keys_only" ]; then
  grep -vE '^[[:space:]]+PasswordAuthentication[[:space:]]+yes' "$src/system/sshd/40-backup-vault.conf" > "$ours"
  echo "backup accounts log in with SSH keys only"
else
  install -m 0644 "$src/system/sshd/40-backup-vault.conf" "$ours"
fi
chmod 0644 "$ours"
# An older block for the same group in sshd_config would shadow nothing but confuse: comment it out.
python3 -I - "$GROUP" << 'EOF'
import re, sys
path = "/etc/ssh/sshd_config"
text = open(path).read()
out, inside = [], False
for line in text.split("\n"):
    if re.match(rf"\s*Match\s+Group\s+{re.escape(sys.argv[1])}\s*$", line):
        inside = True
        out.append("# Now in /etc/ssh/sshd_config.d/40-backup-vault.conf (SFTP Backup Vault):")
    elif inside and re.match(r"\s*Match\s", line):
        inside = False
    out.append("#" + line if inside else line)
if out != text.split("\n"):
    open(path, "w").write("\n".join(out))
    print("commented out the old «Match Group %s» block of %s" % (sys.argv[1], path))
EOF

say "Letting chrooted SFTP sessions log"
if command -v rsyslogd > /dev/null; then
  if [ -f /etc/apparmor.d/usr.sbin.rsyslogd ]; then
    install -d -m 0755 /etc/apparmor.d/rsyslog.d
    install -m 0644 "$src/system/apparmor/rsyslog-backup-vault" /etc/apparmor.d/rsyslog.d/backup-vault
    if grep -q '^rsyslogd ' /sys/kernel/security/apparmor/profiles 2> /dev/null; then
      apparmor_parser -r /etc/apparmor.d/usr.sbin.rsyslogd
      echo "rsyslog's AppArmor profile reloaded"
    fi
  fi
else
  echo "rsyslog is not installed: the backup accounts' SFTP actions will not be logged"
fi

say "Applying"
"$SSHD" -t || { restore_ssh; die "sshd refused the new rules; the previous ones are back"; }
backup-vault apply || { restore_ssh; die "backup-vault apply failed; SSH is back as it was"; }
if [ -n "$client" ] && "$SSHD" -T -C "user=$admin,host=$client,addr=$client" | grep -qE '^(denyusers|allowgroups) '; then
  restore_ssh
  "$SSHD" -t && reload_sshd
  die "the rules would refuse $admin from $client (allow_from holds that address); SSH is back as it was"
fi
reload_sshd
echo "sshd reloaded (open sessions stay)"
if ! systemctl is-active --quiet ssh.socket ssh.service sshd.service 2> /dev/null; then
  for unit in ssh.service sshd.service; do
    if systemctl cat "$unit" > /dev/null 2>&1; then
      systemctl enable --now "$unit"
      echo "sshd was not running: started and enabled $unit"
      break
    fi
  done
fi

say "Timers"
systemctl daemon-reload
systemctl enable --now backup-vault-ingest.timer backup-vault-rotate.timer backup-vault-verify.timer
systemctl list-timers 'backup-vault-*' --no-pager || true

members=$(python3 -I -c 'import grp, pwd, sys; g = grp.getgrnam(sys.argv[1]); print(",".join(sorted(set(g.gr_mem) | {p.pw_name for p in pwd.getpwall() if p.pw_gid == g.gr_gid})))' "$GROUP")
if [ -n "$members" ] && find /var/backups/sftp -mindepth 3 -path '*/upload/*' -type f -print -quit 2> /dev/null | grep -q .; then
  say "Moving the backups already uploaded into the vault"
  for _ in $(seq 1 90); do
    pgrep -u "$members" > /dev/null || break
    echo "an upload is in progress; waiting..."
    sleep 10
  done
  backup-vault ingest --migrate || echo "  ! some files could not be moved; see above"
fi

result=0
if [ "$selftest" = 1 ]; then
  say "Self-test"
  backup-vault selftest || result=1
fi

say "Done: SFTP Backup Vault $VERSION ($([ "$result" = 0 ] && echo ok || echo "the self-test failed, see above"))"
cat << EOF
Next:
  1. Create a backup account (the client's server address keeps it to that server):
       sudo backup-vault add-user site1 --from 203.0.113.10 --password
  2. In the backup client: SFTP to this server as site1, into the folder "upload".
  3. Watch it:  sudo backup-vault status   (also shown when you log in)
Settings: /etc/backup-vault/backup-vault.conf   Guide: /etc/backup-vault/README.md
Log of this install: $saved/install.log
EOF
exit "$result"

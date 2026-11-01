#!/usr/bin/env bash
# End-to-end test of SFTP Backup Vault on a throwaway machine (the CI runs it): install, back up like a
# client, try what an attacker would, upgrade in place, uninstall. It creates accounts and installs
# packages: never run it on a server you care about.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || { echo "run it as root" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

# No SSH server started beforehand: the installer handles one that never ran since boot (or is missing).

say "Install"
"$here/install.sh" --yes

say "A backup account with a key, used like a backup client"
work=$(mktemp -d)
ssh-keygen -q -t ed25519 -N "" -C ci -f "$work/key"
backup-vault add-user ci_site --set-by folder --key "$(cat "$work/key.pub")"
sftp_as() {
  sftp -F /dev/null -i "$work/key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -b - ci_site@127.0.0.1
}
printf 'CREATE TABLE t (id int);\n' | gzip > "$work/database.sql.gz"
(cd "$work" && sha256sum database.sql.gz > SHA256SUMS)
sftp_as << SFTP || fail "the upload failed"
mkdir upload/ci-2026-01-01
put $work/database.sql.gz upload/ci-2026-01-01/database.sql.gz
put $work/SHA256SUMS upload/ci-2026-01-01/SHA256SUMS
SFTP
for attempt in "get upload/ci-2026-01-01/database.sql.gz $work/copy" "rm upload/ci-2026-01-01/database.sql.gz" \
  "rmdir upload/ci-2026-01-01" "symlink upload/ci-2026-01-01/SHA256SUMS upload/link" "put $work/SHA256SUMS /outside"; do
  if echo "$attempt" | sftp_as > /dev/null 2>&1; then fail "the account could: $attempt"; fi
done
echo "refused: download, delete, rmdir, symlink, writing outside upload/"
if ssh -F /dev/null -i "$work/key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null ci_site@127.0.0.1 id 2> /dev/null | grep -q uid=; then
  fail "the account got a shell"
fi

say "Into the vault"
backup-vault ingest --settle 0 --account ci_site
stored=/var/backups/vault/ci_site/ci-2026-01-01/database.sql.gz
[ -f "$stored" ] || fail "the backup is not in the vault"
[ "$(stat -c %U:%a "$stored")" = root:400 ] || fail "the vault copy is not root's and read-only"
lsattr "$stored" | cut -d' ' -f1 | grep -q i || fail "the vault copy is not immutable"
if (echo tampered >> "$stored") 2> /dev/null; then fail "root changed an immutable backup"; fi
grep -q '"result": "verified"' /var/lib/backup-vault/ci_site.jsonl || fail "SHA256SUMS was not checked"
grep -q '"check": "gzip ok"' /var/lib/backup-vault/ci_site.jsonl || fail "the gzip was not checked"
[ -z "$(find /var/backups/sftp/ci_site/upload -type f)" ] || fail "the upload folder still holds files"

say "Reports"
backup-vault status || true
backup-vault list ci_site
backup-vault policy
backup-vault verify --account ci_site
backup-vault rotate --dry-run --force

say "Upgrade in place"
"$here/install.sh" --yes --no-selftest
[ -f "$stored" ] || fail "the upgrade lost a backup"
grep -q "account ci_site" /etc/backup-vault/backup-vault.conf || fail "the upgrade lost the settings"

say "Uninstall"
"$here/uninstall.sh" --yes
[ ! -e /etc/ssh/sshd_config.d/40-backup-vault.conf ] || fail "the sshd rules are still there"
/usr/sbin/sshd -t || fail "sshd's settings are broken after the uninstall"
[ -f "$stored" ] || fail "the uninstall touched a backup"
[ "$(getent shadow ci_site | cut -d: -f8)" = 1 ] || fail "the backup account was not locked"
echo
echo "integration test passed"

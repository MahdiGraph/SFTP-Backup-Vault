# Security

SFTP Backup Vault exists to keep backups safe from a compromised client server, so a way around it
matters. That covers, for example:
- a backup account reading, changing or deleting something in the vault;
- a backup account escaping its chroot or getting a shell;
- rotation deleting backups it should keep.

**Report it privately**, through GitHub's
[private vulnerability reporting](https://github.com/MahdiGraph/SFTP-Backup-Vault/security/advisories/new),
not in a public issue. Please include the version (`backup-vault --version`), the distribution and
OpenSSH version, and the steps.

Out of scope, by design (see the README's security notes):
- root on the backup server itself;
- backups sent after a client server was taken;
- filling the disk.

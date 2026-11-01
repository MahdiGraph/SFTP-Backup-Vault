# SFTP Backup Vault

[![CI](https://github.com/MahdiGraph/SFTP-Backup-Vault/actions/workflows/ci.yml/badge.svg)](https://github.com/MahdiGraph/SFTP-Backup-Vault/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**An append-only SFTP drop box for backups.** Your servers push their backups over plain SFTP, but the backup accounts can only *upload*. Every finished upload is moved, within minutes, into a vault the accounts cannot even see: there it is owned by root, read-only and immutable, with its SHA-256 on record. Old backups are rotated grandfather-father-son.

So when one of your servers is hacked, the attacker holds its backup credentials and still cannot delete, overwrite, encrypt or download a single backup it sent before.

[فارسی](README.fa.md)

---

- [Why](#why)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Backup clients](#backup-clients)
- [Rotation](#rotation)
- [Settings](#settings)
- [Commands](#commands)
- [Restoring a backup](#restoring-a-backup)
- [Watching it](#watching-it)
- [Security notes](#security-notes)
- [Upgrade and uninstall](#upgrade-and-uninstall)
- [Troubleshooting](#troubleshooting)

## Why

The usual way to keep backups off a server is to have it upload them over SFTP to another machine, with a password or key that lives on the server. That credential is the weak spot: whoever breaks into the server can log in to the backup machine with it and delete, replace or steal every backup there. Ransomware does exactly this before it encrypts anything.

The usual workarounds each give something up:
- pull backups from the backup machine, so it holds credentials to your servers;
- use object storage with object locks;
- use a backup tool with append-only modes, which only that tool's own clients can speak to.

SFTP Backup Vault keeps the simple setup every hosting panel, CMS plugin and script already supports, which is "upload a file over SFTP", and takes the danger out of it on the receiving side.

## How it works

```
 your server ──SFTP──► /var/backups/sftp/<account>/upload    the only folder the account sees (chroot)
                                 │
                                 │  every minute: each upload closed and unchanged for 2 minutes
                                 ▼
                        /var/backups/vault/<account>/         root only · 0400 · chattr +i · SHA-256 recorded
                                 │
                                 │  every night: grandfather-father-son rotation
                                 ▼
                        /var/backups/vault/.trash/<date>/     kept 7 days, then deleted
```

| A backup account can | It cannot |
|---|---|
| log in over SFTP (password or key) | get a shell, run commands or forward ports |
| create folders and upload files under `upload/` | read (download) any file |
| list `upload/`, see its own uploads in progress | delete a file or a folder |
| rename or `chmod` an upload in progress (some clients upload under a temporary name) | make links or server-side copies |
| | see the vault, or anything outside its chroot |
| | log in from any address but its own server's (optional, recommended) |

- **The rules are sshd's own.** `Match Group sftp_backups` with `ChrootDirectory`, `ForceCommand internal-sftp -P read,readlink,remove,rmdir,symlink,hardlink,copy-data` and every kind of forwarding disabled.
- **Moving uploads into the vault.** `backup-vault ingest` runs every minute and takes an upload only once it is closed and has not changed for `settle_seconds`. It records the time it arrived from the file's ctime, which a client cannot set, so a client cannot fake its age to make rotation drop it.
- **Locking them there.** In the vault a file belongs to root, with mode 0400 and the immutable flag set. Until someone runs `chattr -i`, not even root can change or delete it.
- **Checking what arrived.** Zip, gzip and tar files are checked for being complete, since an interrupted upload leaves a truncated one. A backup folder that brings its own `SHA256SUMS` or `manifest.json` is compared against it.
- **Rotation.** `backup-vault rotate` runs every night and keeps a grandfather-father-son selection, by time windows counted back from today. A flood of junk uploads therefore cannot push your old backups out early. Whatever it drops waits in a trash folder for a week.
- **Checking the vault again.** `backup-vault verify` runs every week, hashes every file again and compares it with the SHA-256 recorded on arrival.
- **Logs and status.** Each account's SFTP session logs every file and every refused request to `/var/log/auth.log`. The state of the backups shows in the message you get when you log in.

It is one Python file with no dependencies, plus a few systemd units and sshd and rsyslog snippets.

## Requirements

- Linux with systemd. It is tested in CI on **Ubuntu 22.04 and 24.04** and should work on Debian 11+ and other distributions. The RHEL family is untested; SELinux may need attention there.
- OpenSSH server 7.8 or newer, whose `sshd_config` includes `/etc/ssh/sshd_config.d/*.conf` (Debian, Ubuntu, RHEL 9 and most current distributions do).
- Python 3.8 or newer, e2fsprogs (`chattr`), procps. rsyslog is optional but needed to log the accounts' SFTP actions.
- A filesystem with the immutable flag (ext4, XFS, Btrfs) for `/var/backups`.

The installer offers to install the missing packages with apt, dnf or yum.

## Install

On the backup server:

```bash
curl -fsSL https://raw.githubusercontent.com/MahdiGraph/SFTP-Backup-Vault/main/install.sh | sudo bash
```

Add ` -s -- --yes` after `bash` to accept missing packages without a prompt. Or, to read it first (recommended for anything you pipe into a root shell):

```bash
git clone https://github.com/MahdiGraph/SFTP-Backup-Vault.git
cd SFTP-Backup-Vault
sudo ./install.sh
```

The installer:
1. checks the system and offers to install missing packages (`--yes` to accept);
2. saves your SSH settings in `/var/lib/backup-vault/install-<time>/`;
3. creates the group `sftp_backups`, installs `/usr/local/sbin/backup-vault`, its settings (`/etc/backup-vault/`), the systemd timers and the login message;
4. adds `/etc/ssh/sshd_config.d/40-backup-vault.conf`. That file is only a `Match Group sftp_backups` block, so it leaves every other account alone;
5. checks the result with `sshd -t` and makes sure it does not lock you out, then reloads sshd (open sessions stay);
6. moves files already sitting in the accounts' `upload/` folders into the vault;
7. runs `backup-vault selftest`, which uses a temporary account to try everything an attacker would.

Options:
- `--keys-only`: backup accounts may log in with SSH keys only. Without it they may also use passwords, because many backup clients offer nothing else.
- `--no-selftest`: skip the self-test.
- `--version=X.Y.Z`: install a given release.

## Quick start

Create an account for each server that sends backups. `--from` keeps it to that server's address:

```bash
sudo backup-vault add-user site1 --from 203.0.113.10 --password
```

Then point the server's backup client at:

| | |
|---|---|
| protocol | SFTP |
| host / port | your backup server, its SSH port |
| user | `site1` |
| password or key | as set above |
| remote folder | `upload` (absolute path: `/upload`) |

Check it after the first backup:

```bash
sudo backup-vault status          # every account: how many backups, how big, the newest one's age
sudo backup-vault list site1      # its backups, newest first, and why rotation keeps each one
```

If a backup is a folder with several files, such as `site1-2026-11-01/` holding a database dump, an archive of the files and a checksum list, add `--set-by folder` so that rotation treats the folder as one backup.

## Backup clients

Anything that just uploads files works. That includes:
- `sftp`, `scp` (OpenSSH 9+) and `lftp`;
- rclone;
- PHP's Flysystem SFTP adapter, and so Laravel backups;
- cron scripts that dump and upload;
- hosting panels and CMS plugins that "send backups to a remote SFTP server".

Things to know:
- **Deleting old backups from the client side is refused.** Leave rotation to the vault and switch off the client's remote cleanup if it has one. Some clients ignore the refusal; others report it.
- **A client that reads a file back to verify it will fail at that step.** If yours insists, look at the "refused" lines in `auth.log` (see [Troubleshooting](#troubleshooting)).
- **Tools that need to read their remote repository or run commands do not work, by design.** restic, Borg, Kopia, Duplicity and rsync over SSH are in this group. Run them into a local folder and upload the result, or use their own append-only modes.
- **A connection test that uploads and then deletes a file** will see the delete refused; that is expected. Add the test file's name to `discard` so it goes straight to the trash.
- **Encrypt your backups on the client.** The vault protects them from being deleted or changed; anyone with root on the backup server can still read them.

Checksums: in folder mode, drop a `SHA256SUMS` file (the output of `sha256sum *`) or a `manifest.json` into the backup folder. The vault compares every file against it when it arrives and records `verified`, `mismatch` or `incomplete`. In `manifest.json`, any object with a 64-hex `sha256` and a `file`, `path` or `name` counts.

## Rotation

Every night at 05:15, for each account, rotation keeps:

| setting | default | keeps |
|---|---|---|
| `keep_all_days` | 7 | every backup received in the last 7 days |
| `daily` | 30 | the newest backup of each of the last 30 days |
| `weekly` | 12 | the newest of each of the last 12 weeks |
| `monthly` | 12 | the newest of each of the last 12 months |
| `yearly` | 3 | the newest of each of the last 3 years |
| `keep_last` | 7 | always the newest 7, however old (at least 1) |
| `trash_days` | 7 | days a dropped backup waits in the trash before it is deleted |

How it decides:
- **Windows count back from today.** A week of junk uploads cannot push last month's backups out early; they leave only when their window ends.
- **Series are counted apart.** Backups whose names differ only in numbers form one series, and each series is rotated on its own. For example, `db-2026-11-01.sql.gz` and `files-2026-11-01.tar.gz` are two series, each kept by its own daily, weekly and monthly windows.
- **Space is never a reason to delete.** Rotation never deletes to make room, so filling the disk cannot become a way to destroy backups. It warns instead (see [Watching it](#watching-it)).
- **A wrong clock stops it.** It does nothing while the clock is not NTP-synchronised, because it deletes by age.

With the defaults an account keeps about 50 backups. The space you need is roughly that times the size of one backup, plus a week of trash.

Before relying on a change, look at what it would do:

```bash
sudo backup-vault policy               # the settings each account works with
sudo backup-vault rotate --dry-run     # what tonight's rotation would put in the trash
```

To run it at another time: `sudo systemctl edit backup-vault-rotate.timer`, then add

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 06:00:00
```

## Settings

`/etc/backup-vault/backup-vault.conf` (an INI file; see [the example](backup-vault.conf.example)):

```ini
[retention]
keep_all_days = 7
daily = 30
weekly = 12
monthly = 12
yearly = 3
keep_last = 7
trash_days = 7

[ingest]
settle_seconds = 120     # an upload moves once closed and unchanged this long
alert_hours = 30         # warn when an account has sent nothing for this long (0: never)
min_free_percent = 15    # warn when the disk gets fuller than this

[server]
public_host = backup.example.com   # shown by add-user
public_port = 22

[account site1]
set_by = folder                    # one backup = one top folder under upload/ (default: one file)
discard = connection-test-*.txt    # uploads that go straight to the trash
allow_from = 203.0.113.10          # its server's address(es) or networks
daily = 60                         # any retention or ingest setting, for this account alone
```

- Changes take effect at the next run of the timers.
- `sudo backup-vault policy` reports any mistake in the file.
- After changing `allow_from` by hand, run `sudo backup-vault apply`. It rewrites sshd's rules, checks them and reloads sshd. `set-ip` does all of that for you.

## Commands

| command | does |
|---|---|
| `status [--brief]` | every account's backups, the disk, and warnings |
| `list ACCOUNT` | an account's backups, newest first, with checks and why each is kept |
| `policy` | the settings each account works with |
| `add-user NAME [--from IP] [--key KEY] [--password] [--set-by folder]` | create a backup account |
| `set-ip NAME IP[,IP...]` / `set-ip NAME none` | the address(es) it may log in from |
| `set-key NAME "ssh-ed25519 AAAA..."` / `set-key NAME none` | its SSH public key |
| `disable-user NAME` / `enable-user NAME` | refuse or allow its logins (its backups stay) |
| `remove-user NAME [--delete-backups]` | remove an account (its backups stay unless asked) |
| `copy-out ACCOUNT BACKUP FOLDER` | copy one backup out of the vault, owned by you |
| `rotate [--dry-run]` | rotate now (the timer does it nightly) |
| `ingest` | move finished uploads now (the timer does it every minute) |
| `verify` | hash every stored file again (the timer does it weekly) |
| `apply` | bring folders, keys, sshd and rsyslog in line with the settings |
| `selftest` | try a temporary account's rights against the real sshd |

Each command runs as `sudo backup-vault COMMAND`; `backup-vault --help` lists the options.

## Restoring a backup

```bash
sudo backup-vault list site1
mkdir -p ~/restore
sudo backup-vault copy-out site1 site1-2026-11-01 ~/restore
```

The copy belongs to you. Fetch it from your computer with `scp -r backup-server:restore/site1-2026-11-01 .`.

Something rotation already put in the trash stays in `/var/backups/vault/.trash/<date>/<account>/` until `trash_days` have passed; copy it from there with `sudo cp -a`.

Don't delete or move files inside the vault by hand; rotation does that. If you really must, `sudo chattr -i FILE` first.

## Watching it

- **The login message** shows one line per account (backups, size, age of the newest) and any warning:
  - an account has sent nothing for `alert_hours`;
  - the disk is fuller than `min_free_percent` allows;
  - a timer failed;
  - an account cannot log.
- **The journal:**
  - `journalctl -u backup-vault-ingest` lists every stored file;
  - `journalctl -u backup-vault-rotate` shows the nightly rotation.
- **auth.log:** `sudo grep internal-sftp /var/log/auth.log` shows every session, file and refusal of the backup accounts. `Refusing denylisted remove request` is an attempt to delete. The two lines `Refusing denylisted hardlink/copy-data request` at the start of each session are normal: the server just doesn't offer those features.
- **History:** `/var/lib/backup-vault/<account>.jsonl` holds what arrived, with its SHA-256, plus every check, rotation and deletion.

## Security notes

**It protects** backups that arrived before a client server was compromised. They cannot be deleted, changed or read through that server's backup account.

**It does not protect against:**
- **Root on the backup server itself.** Keep that machine separate and minimal, and log in to it with keys only.
- **Backups sent after the compromise.** Treat them as untrusted.
- **A full disk.** An attacker can upload junk until the disk is full. New backups then fail, but none of the existing ones is lost. Watch the disk warnings, or give `/var/backups` its own filesystem.

**Recommended:**
- **Pin every account** to its server with `--from` or `set-ip`. That also forbids all non-backup logins from those addresses, so an intruder there cannot even try your admin password.
- **Prefer keys to passwords** (`--key`, `--keys-only`).
- **Firewall SSH** down to your servers and your admin addresses.
- **Encrypt the backups on the client.**

**What sshd refuses**, and why rename and chmod stay allowed:
- Refused: `read`, `readlink`, `remove`, `rmdir`, `symlink`, `hardlink` and `copy-data` (see `sftp-server -Q requests`).
- `rename` and `setstat` only ever touch an upload in progress, because finished files are gone from the account's view. Some clients need them.

## Upgrade and uninstall

- **Upgrade:** run the installer again. It keeps the settings, accounts, keys and backups, and replaces the program, the timers and its own sshd file. If you had added settings to `40-backup-vault.conf`, they are moved to `39-backup-vault-local.conf`, which the installer never touches again.
- **Uninstall:**

  ```bash
  sudo ./uninstall.sh
  ```

  It removes the program, its timers and its sshd, rsyslog and login-message pieces. It never deletes the backups, the settings or the history. It locks the backup accounts, because without the rules they would be ordinary users of the server.

## Troubleshooting

- **A backup client fails after the switch.** `sudo grep internal-sftp /var/log/auth.log | tail -50` shows what it asked for and what was refused.
  - A client that reads its upload back (`Refusing denylisted read request`) cannot be satisfied.
  - A delete it attempts can usually be turned off in the client.
- **`backup-vault selftest` fails to connect.** It logs in to sshd on this machine (loopback, or the first `ListenAddress`), so a firewall that drops local connections stops it.
- **Locked out of SSH.** Use your provider's console. The installer saved your previous settings in `/var/lib/backup-vault/install-<time>/`; copy back `sshd_config` and remove `40-` and `41-backup-vault*.conf` from `/etc/ssh/sshd_config.d/`.
- **Nothing is moved into the vault.** Check `systemctl status backup-vault-ingest.timer` and `journalctl -u backup-vault-ingest`. An upload stays in `upload/` while a process still has it open.

## License

[MIT](LICENSE). The guide in Persian: [README.fa.md](README.fa.md).

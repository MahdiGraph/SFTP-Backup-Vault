"""Tests of backup-vault (Linux: they read /proc). Run: python3 -I tests/test_backup_vault.py -v

Every test loads the tool afresh with its paths below a temporary folder (BACKUP_VAULT_ROOT), so it
runs without root and touches nothing of the machine.
"""

from __future__ import annotations

import datetime as dt
import gzip
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import sys
import tarfile
import tempfile
import time
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent / "backup-vault"
sys.dont_write_bytecode = True  # no __pycache__ next to the tool
DAY = 86400


def load(root: Path):
    os.environ["BACKUP_VAULT_ROOT"] = str(root)
    name = f"backup_vault_{abs(hash(root))}"
    loader = importlib.machinery.SourceFileLoader(name, str(TOOL))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses look their module up
    loader.exec_module(module)
    return module


def zip_bytes(name="database.sql.gz", content=b"data") -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(name, content)
    return buffer.getvalue()


class VaultTest(unittest.TestCase):
    CONFIG = """
[retention]
keep_all_days = 2
daily = 5
weekly = 3
monthly = 3
yearly = 1
keep_last = 2
trash_days = 7

[account site1]
set_by = folder
discard = connection-test-*.txt
allow_from = 192.0.2.10

[account site2]
allow_from = 192.0.2.20
"""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="bv-test-"))
        self.bv = load(self.root)
        self.bv.CONF.parent.mkdir(parents=True)
        self.bv.CONF.write_text(self.CONFIG)
        for name in ("site1", "site2"):
            (self.bv.SFTP_ROOT / name / "upload").mkdir(parents=True)
        self.cfg = self.bv.Config()
        self.out = io.StringIO()

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def upload(self, account: str, rel: str, data: bytes = b"backup", mtime: float | None = None) -> Path:
        path = self.bv.SFTP_ROOT / account / "upload" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path

    def ingest(self, **kwargs):
        with redirect_stdout(self.out):
            return self.bv.ingest(self.cfg, **kwargs)

    def vault_set(self, account: str, rel: str, arrival: float, data: bytes = b"x") -> Path:
        path = self.bv.VAULT / account / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        os.utime(path, (arrival, arrival))
        return path


class IngestTest(VaultTest):
    def test_moves_a_finished_upload_into_the_vault_and_records_it(self):
        data = zip_bytes()
        self.upload("site1", "site1-2026-11-01-043007/database.zip", data)
        self.upload("site1", "site1-2026-11-01-043007/manifest.json", b"{}")

        self.assertEqual(self.ingest(settle=0), 0)

        stored = self.bv.VAULT / "site1" / "site1-2026-11-01-043007" / "database.zip"
        self.assertEqual(stored.read_bytes(), data)
        self.assertEqual(stored.stat().st_mode & 0o777, 0o400)
        self.assertFalse((self.bv.SFTP_ROOT / "site1/upload/site1-2026-11-01-043007/database.zip").exists())
        entry = next(e for e in self.bv.history("site1") if e.get("path") == "site1-2026-11-01-043007/database.zip")
        self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(entry["check"], "zip ok")

    def test_waits_for_a_file_to_settle_and_never_takes_an_open_one(self):
        self.upload("site2", "database/2026/11/new.zip", zip_bytes())
        self.ingest(settle=3600)
        self.assertTrue((self.bv.SFTP_ROOT / "site2/upload/database/2026/11/new.zip").exists())

        writing = self.upload("site2", "database/2026/11/writing.zip")
        with writing.open("ab"):
            self.ingest(settle=0)
            self.assertTrue(writing.exists(), "a file still open for writing stays put")
        self.assertTrue((self.bv.VAULT / "site2/database/2026/11/new.zip").exists())
        self.ingest(settle=0)
        self.assertTrue((self.bv.VAULT / "site2/database/2026/11/writing.zip").exists())

    def test_never_overwrites_a_backup_with_the_same_name(self):
        self.upload("site2", "backup.tar.gz", b"first")
        self.ingest(settle=0)
        self.upload("site2", "backup.tar.gz", b"second")
        self.ingest(settle=0)
        self.assertEqual((self.bv.VAULT / "site2/backup.tar.gz").read_bytes(), b"first")
        self.assertEqual((self.bv.VAULT / "site2/backup~2.tar.gz").read_bytes(), b"second")

    def test_puts_discarded_test_files_in_the_trash(self):
        self.upload("site1", "connection-test-bca7e294.txt", b"test")
        self.ingest(settle=0)
        self.assertFalse((self.bv.VAULT / "site1" / "connection-test-bca7e294.txt").exists())
        trashed = self.bv.TRASH / dt.date.today().isoformat() / "site1" / "connection-test-bca7e294.txt"
        self.assertEqual(trashed.read_bytes(), b"test")

    def test_migration_dates_backups_by_their_modification_time_and_clears_folders(self):
        then = time.time() - 10 * DAY
        self.upload("site1", "site1-2026-10-20-125142/files.zip", zip_bytes(), mtime=then)

        self.ingest(migrate=True)

        stored = self.bv.VAULT / "site1/site1-2026-10-20-125142/files.zip"
        self.assertAlmostEqual(stored.stat().st_mtime, then, delta=1)
        self.assertEqual(list((self.bv.SFTP_ROOT / "site1/upload").iterdir()), [])
        self.assertTrue(next(e for e in self.bv.history("site1") if e.get("event") == "stored")["migrated"])

    def test_keeps_a_fresh_empty_folder_a_client_may_be_filling(self):
        (self.bv.SFTP_ROOT / "site2/upload/database/2026/12").mkdir(parents=True)
        self.ingest(settle=0)
        self.assertTrue((self.bv.SFTP_ROOT / "site2/upload/database/2026/12").is_dir())
        old = time.time() - 3600
        for folder in ("database/2026/12", "database/2026", "database"):
            os.utime(self.bv.SFTP_ROOT / "site2/upload" / folder, (old, old))
        self.ingest(settle=0)
        self.assertFalse((self.bv.SFTP_ROOT / "site2/upload/database/2026/12").exists())
        self.assertTrue((self.bv.SFTP_ROOT / "site2/upload").is_dir())

    def test_removes_links_from_the_upload_folder(self):
        target = self.upload("site2", "real.zip", zip_bytes())
        link = self.bv.SFTP_ROOT / "site2/upload/link.zip"
        link.symlink_to(target)
        self.ingest(settle=0)
        self.assertFalse(os.path.lexists(link))
        self.assertTrue((self.bv.VAULT / "site2/real.zip").exists())

    def test_flags_a_zip_cut_short(self):
        self.upload("site2", "database/cut.zip", zip_bytes()[:-30])
        self.ingest(settle=0)
        entry = next(e for e in self.bv.history("site2") if e.get("event") == "stored")
        self.assertEqual(entry["check"], "zip damaged or incomplete")

    def test_compares_a_backup_folder_with_the_checksums_it_lists(self):
        database, files = zip_bytes(), zip_bytes("storage/a.jpg", b"jpeg")
        sums = f"{hashlib.sha256(database).hexdigest()}  database.zip\n{hashlib.sha256(files).hexdigest()} *files.zip\n"
        self.upload("site1", "site1-2026-11-01-043007/database.zip", database)
        self.upload("site1", "site1-2026-11-01-043007/files.zip", files)
        self.upload("site1", "site1-2026-11-01-043007/SHA256SUMS", sums.encode())
        manifest = {"app": "x", "parts": [{"file": "database.zip", "sha256": hashlib.sha256(database).hexdigest()}, {"path": "files.zip", "sha256": "0" * 64}]}
        self.upload("site1", "site1-2026-11-02-043007/database.zip", database)
        self.upload("site1", "site1-2026-11-02-043007/files.zip", files)
        self.upload("site1", "site1-2026-11-02-043007/manifest.json", json.dumps(manifest).encode())
        self.upload("site1", "site1-2026-11-03-043007/database.zip", database)
        self.upload("site1", "site1-2026-11-03-043007/database.zip.sha256", f"SHA256 (database.zip) = {hashlib.sha256(database).hexdigest()}\nSHA256 (missing.zip) = {'1' * 64}\n".encode())
        self.upload("site1", "site1-2026-11-04-043007/a.zip", database)
        self.upload("site1", "site1-2026-11-04-043007/SHA256SUMS", f"{hashlib.sha256(b'other').hexdigest()}  ../../site2/secret\n".encode())

        self.ingest(settle=0)

        results = {e["set"]: e["result"] for e in self.bv.history("site1") if e.get("event") == "checked"}
        self.assertEqual(results, {
            "site1-2026-11-01-043007": "verified",
            "site1-2026-11-02-043007": "mismatch",
            "site1-2026-11-03-043007": "incomplete",
        }, "a name that climbs out of the folder is ignored")

    def test_knows_a_gzip_or_a_tar_cut_short(self):
        whole = gzip.compress(b"-- dump\n" * 5000) + gzip.compress(b"second member\n")
        self.upload("site2", "db-whole.sql.gz", whole)
        self.upload("site2", "db-cut.sql.gz", whole[: len(whole) // 3])
        self.upload("site2", "db-padded.tgz", whole + bytes(512))
        self.upload("site2", "db-fake.gz", b"not gzip at all")
        tar = io.BytesIO()
        with tarfile.open(fileobj=tar, mode="w") as archive:
            info = tarfile.TarInfo("dump.sql")
            info.size = 3000
            archive.addfile(info, io.BytesIO(b"x" * 3000))
        self.upload("site2", "files.tar", tar.getvalue())
        self.upload("site2", "files-cut.tar", tar.getvalue()[:2048])
        self.ingest(settle=0)
        checks = {e["path"]: e.get("check") for e in self.bv.history("site2") if e.get("event") == "stored"}
        self.assertEqual(checks, {
            "db-whole.sql.gz": "gzip ok", "db-cut.sql.gz": "gzip damaged or incomplete", "db-padded.tgz": "gzip ok",
            "db-fake.gz": "gzip damaged or incomplete", "files.tar": "tar ok", "files-cut.tar": "tar damaged or incomplete",
        })

    def test_a_name_taken_by_a_file_never_blocks_a_backup(self):
        self.upload("site2", "daily", b"a file called daily")
        self.ingest(settle=0)
        self.upload("site2", "daily/db.zip", zip_bytes())
        self.ingest(settle=0)
        self.assertEqual((self.bv.VAULT / "site2/daily").read_bytes(), b"a file called daily")
        self.assertTrue((self.bv.VAULT / "site2/daily~2/db.zip").is_file())

    def test_verify_notices_a_file_changed_in_the_vault(self):
        self.upload("site2", "database/a.zip", zip_bytes())
        self.ingest(settle=0)
        with redirect_stdout(self.out):
            self.assertEqual(self.bv.verify(self.cfg), 0)
        stored = self.bv.VAULT / "site2/database/a.zip"
        stored.chmod(0o600)
        stored.write_bytes(b"tampered")
        with redirect_stdout(self.out):
            self.assertEqual(self.bv.verify(self.cfg), 1)


class RotationTest(VaultTest):
    NOW = dt.datetime(2026, 11, 1, 14, 0)

    def at(self, days_ago: float, hour: int = 4) -> float:
        day = self.NOW - dt.timedelta(days=days_ago)
        return day.replace(hour=hour, minute=30).timestamp()

    def sets(self, account: str):
        return self.bv.collect_sets(self.cfg.account(account))

    def test_keeps_a_grandfather_father_son_selection(self):
        # site1: a backup a day for 120 days (NOW is Sunday 1 November), and a second one 3 days ago.
        for days in range(120):
            stamp = (self.NOW - dt.timedelta(days=days)).strftime("%Y-%m-%d")
            self.vault_set("site1", f"site1-{stamp}-043007/database.zip", self.at(days))
        extra = (self.NOW - dt.timedelta(days=3)).strftime("%Y-%m-%d")
        self.vault_set("site1", f"site1-{extra}-023007/database.zip", self.at(3, hour=2))

        keep = self.bv.plan(self.cfg.account("site1"), self.sets("site1"), self.NOW)

        kept = {round((self.NOW.replace(hour=4, minute=30).timestamp() - s.arrival) / DAY) for s in self.sets("site1") if s.name in keep}
        # The last 5 days (keep_all_days 2, daily 5), the newest of the 2 weeks before (25 and 18 October)
        # and of September (the 30th); October's and the year's newest are already in.
        self.assertEqual(kept, {0, 1, 2, 3, 4, 7, 14, 32})
        self.assertNotIn(f"site1-{extra}-023007", keep, "the day's earlier backup goes, its newest stays")
        self.assertEqual(keep[f"site1-{(self.NOW - dt.timedelta(days=32)).strftime('%Y-%m-%d')}-043007"], "monthly")

    def test_a_flood_of_new_uploads_does_not_push_old_backups_out(self):
        for days in (1, 3, 20, 40):
            self.vault_set("site2", f"database/site2-database-{days}.zip", self.at(days))
        before = set(self.bv.plan(self.cfg.account("site2"), self.sets("site2"), self.NOW))
        for i in range(300):
            self.vault_set("site2", f"database/site2-database-flood{i}.zip", self.at(0.01, hour=13))
        after = set(self.bv.plan(self.cfg.account("site2"), self.sets("site2"), self.NOW))
        self.assertTrue(before <= after)

    def test_series_are_kept_apart(self):
        self.vault_set("site2", "database/2026/10/site2-database-20261020-033001-3.zip", self.at(12))
        self.vault_set("site2", "full/2026/10/site2-full-20261020-040001-4.zip", self.at(12, hour=5))
        keep = self.bv.plan(self.cfg.account("site2"), self.sets("site2"), self.NOW)
        self.assertEqual(len(keep), 2, "the newest of the week in each series")
        names = {s.series for s in self.sets("site2")}
        self.assertEqual(names, {"database/#/#/site#-database-#-#-#.zip", "full/#/#/site#-full-#-#-#.zip"})

    def test_rotation_moves_to_the_trash_which_is_emptied_later(self):
        now = time.time()
        for days in range(0, 400, 15):
            self.vault_set("site2", f"db-{days}.zip", now - days * DAY)
        with redirect_stdout(self.out):
            self.assertEqual(self.bv.rotate(self.cfg, dry_run=True), 0)
        self.assertEqual(len(self.sets("site2")), 27, "a dry run changes nothing")

        with redirect_stdout(self.out):
            self.assertEqual(self.bv.rotate(self.cfg), 0)

        left = {s.name for s in self.sets("site2")}
        self.assertIn("db-0.zip", left)
        self.assertLess(len(left), 27)
        trash_day = self.bv.TRASH / dt.date.today().isoformat()
        self.assertTrue((trash_day / "site2").is_dir())
        old_day = self.bv.TRASH / (dt.date.today() - dt.timedelta(days=8)).isoformat()
        trash_day.rename(old_day)
        with redirect_stdout(self.out):
            self.bv.purge_trash(self.cfg)
        self.assertFalse(old_day.exists())
        self.assertTrue(any(e.get("event") == "purged" for e in self.bv.history("site2")))

    def test_the_newest_backup_always_stays(self):
        self.vault_set("site2", "db-old.zip", time.time() - 3000 * DAY)
        with redirect_stdout(self.out):
            self.bv.rotate(self.cfg)
        self.assertEqual([s.name for s in self.sets("site2")], ["db-old.zip"])


class SettingsTest(VaultTest):
    def test_refuses_unknown_or_unsafe_settings(self):
        for text in ("[retention]\nkeep_last = 0\n", "[retention]\nkeepdaily = 3\n", "[account x]\nallow_from = 1.2.3\n", "[nope]\n", "[account Bad!]\n"):
            self.bv.CONF.write_text(text)
            with self.assertRaises(self.bv.Failure, msg=text):
                self.bv.Config()

    def test_an_account_overrides_the_retention(self):
        self.bv.CONF.write_text(self.CONFIG + "\n[account x]\ndaily = 60\n")
        account = self.bv.Config().account("x")
        self.assertEqual((account.number("daily"), account.number("weekly")), (60, 3))

    def test_writes_who_may_log_in_from_where(self):
        text = self.bv.sshd_access(self.cfg.accounts())
        self.assertIn("Match Address 192.0.2.10,192.0.2.20\n    AllowGroups sftp_backups", text)
        self.assertIn("Match User site1 Address *,!192.0.2.10\n    DenyUsers *", text)
        self.assertIn("Match User site2 Address *,!192.0.2.20\n    DenyUsers *", text)

    def test_edits_a_section_and_keeps_the_comments(self):
        self.bv.CONF.write_text("# keep me\n[account site1]\n# and me\nallow_from = 1.1.1.1\n\n[account site2]\nset_by = file\n")
        self.bv.edit_section("site1", "allow_from", "2.2.2.2")
        self.bv.edit_section("site2", "allow_from", "3.3.3.3")
        self.bv.edit_section("new", "set_by", "folder")
        text = self.bv.CONF.read_text()
        self.assertIn("# keep me", text)
        self.assertIn("# and me\nallow_from = 2.2.2.2", text)
        self.assertIn("[account site2]\nallow_from = 3.3.3.3\nset_by = file", text)
        self.assertIn("[account new]\nset_by = folder", text)
        self.bv.edit_section("site2", "", None, remove=True)
        self.assertNotIn("site2", self.bv.CONF.read_text())
        with self.assertRaises(self.bv.Failure):
            self.bv.edit_section("site1", "daily", "-1")
        self.assertIn("allow_from = 2.2.2.2", self.bv.CONF.read_text(), "a refused edit leaves the file as it was")

    def test_names_never_collide(self):
        first = self.root / "a.sql.gz"
        first.write_bytes(b"1")
        self.assertEqual(self.bv.unique(first).name, "a~2.sql.gz")
        self.assertEqual(self.bv.unique(self.root / "free.zip").name, "free.zip")

    def test_status_and_list_report(self):
        self.upload("site1", "site1-2026-11-01-043007/database.zip", zip_bytes())
        self.ingest(settle=0)
        out = io.StringIO()
        with redirect_stdout(out):
            self.bv.status(self.cfg)
            self.bv.status(self.cfg, brief=True)
            self.bv.list_sets(self.cfg, "site1")
            self.bv.policy(self.cfg)
        self.assertIn("site1-2026-11-01-043007", out.getvalue())
        self.assertIn("site2: no backup received yet", out.getvalue())


if __name__ == "__main__":
    unittest.main()

"""Private SQLite data: encrypted email/refresh credentials; hashed bearer tokens."""
from contextlib import contextmanager
import hashlib
import hmac
import os
import sqlite3
import stat

from cryptography.fernet import Fernet


class Store:
    def __init__(self, settings):
        self.path = settings.private_dir / "accounts.sqlite3"
        self.crypto = Fernet(settings.encryption_key_path.read_bytes().strip())
        self.lookup_key = settings.lookup_key_path.read_bytes()
        if len(self.lookup_key) < 32:
            raise ValueError("lookup key must have at least 32 random bytes")
        if self.path.exists():
            if self.path.is_symlink() or stat.S_IMODE(self.path.stat().st_mode) != 0o600:
                raise ValueError("database must be private, regular 0600 file")
        else:
            fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
        with self.db() as db:
            db.executescript("""
              CREATE TABLE IF NOT EXISTS challenges (
                id TEXT PRIMARY KEY, nonce TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS accounts (
                id TEXT PRIMARY KEY, subject_key TEXT UNIQUE NOT NULL,
                email BLOB, email_consent INTEGER NOT NULL, marketing_consent INTEGER NOT NULL,
                consent_version TEXT NOT NULL, consent_at INTEGER NOT NULL,
                refresh BLOB NOT NULL, verified_at INTEGER NOT NULL, refresh_attempt INTEGER NOT NULL DEFAULT 0,
                created INTEGER NOT NULL, authorized_at INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS grants (
                id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                refresh BLOB NOT NULL, created INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS grant_reservations (
                id TEXT PRIMARY KEY, subject_key TEXT NOT NULL, expires INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS sessions (
                token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                issued INTEGER NOT NULL, expires INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS revocations (
                id TEXT PRIMARY KEY, refresh BLOB NOT NULL, created INTEGER NOT NULL,
                subject_key TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0);
              CREATE TABLE IF NOT EXISTS deletion_fences (subject_key TEXT PRIMARY KEY, deleted_at INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS notifications (id TEXT PRIMARY KEY, issued INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS limits (bucket TEXT PRIMARY KEY, start INTEGER NOT NULL, count INTEGER NOT NULL);
            """)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA secure_delete=ON")
        try:
            db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def key(self, purpose, value):
        return hmac.new(self.lookup_key, (purpose + ":" + value).encode(), hashlib.sha256).hexdigest()

    def encrypt(self, text):
        return self.crypto.encrypt(text.encode())

    def decrypt(self, value):
        return self.crypto.decrypt(value).decode()

    @staticmethod
    def token_hash(value):
        return hashlib.sha256(value.encode()).hexdigest()

    def prune(self, db, now):
        db.execute("DELETE FROM challenges WHERE expires <= ?", (now,))
        db.execute("DELETE FROM sessions WHERE expires <= ?", (now,))
        db.execute("DELETE FROM limits WHERE start <= ?", (now - 3600,))
        db.execute("DELETE FROM deletion_fences WHERE deleted_at < ?", (now - 600,))
        db.execute("DELETE FROM notifications WHERE issued < ?", (now - 7*86400,))

    def rate_limit(self, identity, now, maximum):
        bucket = self.key("rate", identity)
        with self.db() as db:
            self.prune(db, now)
            row = db.execute("SELECT * FROM limits WHERE bucket=?", (bucket,)).fetchone()
            if row and row["start"] > now - 60:
                if row["count"] >= maximum:
                    return False
                db.execute("UPDATE limits SET count=count+1 WHERE bucket=?", (bucket,))
            else:
                if not row and db.execute("SELECT COUNT(*) FROM limits").fetchone()[0] >= 10000:
                    return False
                db.execute("INSERT OR REPLACE INTO limits VALUES(?,?,1)", (bucket, now))
            return True

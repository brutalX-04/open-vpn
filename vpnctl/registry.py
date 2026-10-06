"""SQLite account registry. Each write uses its own transaction."""
import json
import os
import sqlite3
import time
import uuid
import contextlib


DEFAULT_DB = os.environ.get("VPN_REGISTRY_DB", "/var/lib/vpn/accounts.db")


class ConflictError(ValueError):
    pass


class Registry:
    def __init__(self, path=None):
        self.path = path or DEFAULT_DB
        if self.path != ":memory:":
            directory = os.path.dirname(os.path.abspath(self.path))
            os.makedirs(directory, mode=0o750, exist_ok=True)
        self._initialize()

    @contextlib.contextmanager
    def _connect(self):
        conn = sqlite3.connect(self.path, timeout=15, isolation_level="IMMEDIATE")
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=15000")
        conn.execute("PRAGMA foreign_keys=ON")
        if self.path != ":memory:":
            try: os.chmod(self.path, 0o600)
            except OSError: pass
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def _initialize(self):
        with self._connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS accounts (
                    id TEXT PRIMARY KEY, service TEXT NOT NULL, username TEXT NOT NULL,
                    created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
                    max_sessions INTEGER NOT NULL DEFAULT 1, status TEXT NOT NULL DEFAULT 'active',
                    meta_json TEXT NOT NULL DEFAULT '{}', UNIQUE(service, username)
                );
                CREATE INDEX IF NOT EXISTS idx_accounts_expiry ON accounts(status, expires_at);
                CREATE TABLE IF NOT EXISTS idempotency (
                    key TEXT PRIMARY KEY, request_hash TEXT NOT NULL, response_json TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );
            """)

    @staticmethod
    def _dict(row):
        if row is None:
            return None
        result = dict(row)
        result["meta"] = json.loads(result.pop("meta_json"))
        return result

    def add(self, service, username, created_at, expires_at, max_sessions=1, meta=None, account_id=None):
        try:
            with self._connect() as db:
                db.execute("INSERT INTO accounts VALUES (?, ?, ?, ?, ?, ?, 'active', ?)",
                           (account_id or str(uuid.uuid4()), service, username, int(created_at), int(expires_at),
                            int(max_sessions), json.dumps(meta or {}, separators=(",", ":"))))
                row = db.execute("SELECT * FROM accounts WHERE service=? AND username=?", (service, username)).fetchone()
                return self._dict(row)
        except sqlite3.IntegrityError as exc:
            raise ConflictError(f"account already exists: {service}/{username}") from exc

    def get(self, service, username):
        with self._connect() as db:
            return self._dict(db.execute("SELECT * FROM accounts WHERE service=? AND username=?", (service, username)).fetchone())

    def list(self, service=None, limit=100, offset=0):
        if not 1 <= limit <= 1000 or offset < 0:
            raise ValueError("invalid pagination")
        query, params = "SELECT * FROM accounts", []
        if service is not None:
            query += " WHERE service=?"
            params.append(service)
        query += " ORDER BY created_at, id LIMIT ? OFFSET ?"
        params.extend((limit, offset))
        with self._connect() as db:
            return [self._dict(row) for row in db.execute(query, params).fetchall()]

    def remove(self, service, username):
        with self._connect() as db:
            cursor = db.execute("DELETE FROM accounts WHERE service=? AND username=?", (service, username))
            return cursor.rowcount > 0

    def renew(self, service, username, expires_at):
        with self._connect() as db:
            db.execute("UPDATE accounts SET expires_at=? WHERE service=? AND username=?", (int(expires_at), service, username))
            return self._dict(db.execute("SELECT * FROM accounts WHERE service=? AND username=?", (service, username)).fetchone())

    def expired(self, now=None):
        with self._connect() as db:
            rows = db.execute("SELECT * FROM accounts WHERE status='active' AND expires_at<=? ORDER BY expires_at", (int(now if now is not None else time.time()),)).fetchall()
            return [self._dict(row) for row in rows]

    def count_by_service(self):
        with self._connect() as db:
            return {row["service"]: row["n"] for row in db.execute("SELECT service, COUNT(*) AS n FROM accounts WHERE status='active' GROUP BY service")}

    def save_idempotency(self, key, request_hash, response, created_at=None):
        with self._connect() as db:
            db.execute("DELETE FROM idempotency WHERE created_at < ?", (int(created_at or time.time()) - 86400,))
            try:
                db.execute("INSERT INTO idempotency VALUES (?, ?, ?, ?)", (key, request_hash, json.dumps(response), int(created_at or time.time())))
            except sqlite3.IntegrityError as exc:
                raise ConflictError("idempotency key already exists") from exc

    def get_idempotency(self, key, now=None):
        with self._connect() as db:
            row = db.execute("SELECT * FROM idempotency WHERE key=?", (key,)).fetchone()
        if row is None or row["created_at"] < int(now or time.time()) - 86400:
            return None
        result = dict(row)
        result["response"] = json.loads(result.pop("response_json"))
        return result

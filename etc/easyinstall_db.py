#!/usr/bin/env python3
"""
EasyInstall Enterprise Database Manager — v7.0
===============================================
SQLite-first (PostgreSQL-ready) persistence layer for enterprise features.
Tracks sites, backups, metrics, users, audit logs and alerts.

Deploy to: /usr/local/lib/easyinstall_db.py
Init:      python3 /usr/local/lib/easyinstall_db.py --init
"""

import os
import json
import time
import logging
import hashlib
import secrets
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, List, Dict, Any, Generator

# ── Logging ───────────────────────────────────────────────────────────────────

LOG_DIR = Path("/var/log/easyinstall")
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[
        logging.FileHandler(LOG_DIR / "db.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("easyinstall.db")

# ── Configuration ─────────────────────────────────────────────────────────────

CONFIG_DIR = Path("/etc/easyinstall")
CONFIG_DIR.mkdir(parents=True, exist_ok=True)
DATA_DIR = Path("/var/lib/easyinstall")
DATA_DIR.mkdir(parents=True, exist_ok=True)

_DEFAULT_DB_CFG: Dict[str, Any] = {
    "engine": "sqlite",
    "sqlite_path": str(DATA_DIR / "easyinstall.db"),
    # PostgreSQL settings (used when engine = "postgresql")
    "pg_host": "localhost",
    "pg_port": 5432,
    "pg_user": "easyinstall",
    "pg_password": "",
    "pg_database": "easyinstall",
    # Retention
    "metrics_retention_days": 30,
    "audit_retention_days": 90,
    "backup_record_retention_days": 365,
}

def _load_db_cfg() -> Dict[str, Any]:
    cfg = dict(_DEFAULT_DB_CFG)
    conf_file = CONFIG_DIR / "database.conf"
    if conf_file.exists():
        try:
            cfg.update(json.loads(conf_file.read_text()))
        except Exception as exc:
            logger.warning("Failed to parse database.conf: %s", exc)
    return cfg

DB_CFG = _load_db_cfg()

# ── Schema ────────────────────────────────────────────────────────────────────

_SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    username    TEXT UNIQUE NOT NULL,
    email       TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role        TEXT NOT NULL DEFAULT 'viewer',
    active      INTEGER NOT NULL DEFAULT 1,
    mfa_enabled INTEGER NOT NULL DEFAULT 0,
    mfa_secret  TEXT,
    created_at  TEXT NOT NULL,
    updated_at  TEXT,
    last_login  TEXT
);

CREATE TABLE IF NOT EXISTS api_keys (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    key_hash    TEXT UNIQUE NOT NULL,
    key_preview TEXT NOT NULL,
    role        TEXT NOT NULL DEFAULT 'viewer',
    created_at  TEXT NOT NULL,
    expires_at  TEXT,
    last_used   TEXT
);

CREATE TABLE IF NOT EXISTS sites (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    domain              TEXT UNIQUE NOT NULL,
    php_version         TEXT NOT NULL DEFAULT '8.3',
    redis_port          INTEGER,
    database_name       TEXT,
    database_user       TEXT,
    ssl_enabled         INTEGER NOT NULL DEFAULT 0,
    backup_enabled      INTEGER NOT NULL DEFAULT 1,
    monitoring_enabled  INTEGER NOT NULL DEFAULT 1,
    status              TEXT NOT NULL DEFAULT 'active',
    created_at          TEXT NOT NULL,
    updated_at          TEXT,
    extra_json          TEXT DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_sites_domain ON sites(domain);
CREATE INDEX IF NOT EXISTS idx_sites_status ON sites(status);

CREATE TABLE IF NOT EXISTS backups (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    site_id         INTEGER REFERENCES sites(id) ON DELETE SET NULL,
    domain          TEXT NOT NULL,
    backup_type     TEXT NOT NULL DEFAULT 'full',
    status          TEXT NOT NULL DEFAULT 'pending',
    size_bytes      INTEGER DEFAULT 0,
    location        TEXT,
    retention_days  INTEGER DEFAULT 30,
    created_at      TEXT NOT NULL,
    completed_at    TEXT,
    notes           TEXT
);
CREATE INDEX IF NOT EXISTS idx_backups_domain    ON backups(domain);
CREATE INDEX IF NOT EXISTS idx_backups_created   ON backups(created_at);

CREATE TABLE IF NOT EXISTS metrics (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    site_id         INTEGER REFERENCES sites(id) ON DELETE CASCADE,
    domain          TEXT NOT NULL,
    timestamp       TEXT NOT NULL,
    cpu_usage       REAL DEFAULT 0,
    memory_usage    REAL DEFAULT 0,
    disk_usage      REAL DEFAULT 0,
    php_workers     INTEGER DEFAULT 0,
    redis_memory_mb REAL DEFAULT 0,
    active_connections INTEGER DEFAULT 0,
    extra_json      TEXT DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_metrics_domain_ts ON metrics(domain, timestamp);

CREATE TABLE IF NOT EXISTS audit_logs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id         INTEGER REFERENCES users(id) ON DELETE SET NULL,
    username        TEXT,
    action          TEXT NOT NULL,
    resource_type   TEXT NOT NULL,
    resource_id     TEXT,
    status          TEXT NOT NULL DEFAULT 'success',
    ip_address      TEXT,
    details_json    TEXT DEFAULT '{}',
    timestamp       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_logs(timestamp);
CREATE INDEX IF NOT EXISTS idx_audit_user      ON audit_logs(user_id, timestamp);

CREATE TABLE IF NOT EXISTS alerts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    domain          TEXT,
    alert_type      TEXT NOT NULL,
    severity        TEXT NOT NULL DEFAULT 'warning',
    title           TEXT NOT NULL,
    message         TEXT NOT NULL,
    acknowledged    INTEGER NOT NULL DEFAULT 0,
    acknowledged_by TEXT,
    acknowledged_at TEXT,
    created_at      TEXT NOT NULL,
    resolved_at     TEXT,
    data_json       TEXT DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_alerts_domain  ON alerts(domain);
CREATE INDEX IF NOT EXISTS idx_alerts_created ON alerts(created_at);

CREATE TABLE IF NOT EXISTS licenses (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    license_key     TEXT UNIQUE NOT NULL,
    license_type    TEXT NOT NULL DEFAULT 'community',
    customer_name   TEXT,
    customer_email  TEXT,
    max_sites       INTEGER DEFAULT 0,
    features_json   TEXT DEFAULT '[]',
    issued_at       TEXT NOT NULL,
    expires_at      TEXT NOT NULL,
    last_validated  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);
"""


# ── Password hashing (stdlib only — no bcrypt dependency) ────────────────────

def _hash_password(password: str) -> str:
    """PBKDF2-HMAC-SHA256 with a random salt, encoded as hex."""
    salt = secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 260_000)
    return f"pbkdf2:sha256:260000:{salt}:{dk.hex()}"


def _verify_password(password: str, stored: str) -> bool:
    """Verify a PBKDF2 password hash."""
    try:
        _, algo, iterations, salt, dk_hex = stored.split(":", 4)
        dk = hashlib.pbkdf2_hmac(algo, password.encode(), salt.encode(), int(iterations))
        return secrets.compare_digest(dk.hex(), dk_hex)
    except Exception:
        return False


# ── Database connection ───────────────────────────────────────────────────────

class DatabaseManager:
    """
    Thin SQLite wrapper with helper methods for all EasyInstall enterprise data.
    All public methods open/close their own connection — safe for multi-threaded use.
    """

    def __init__(self, db_path: Optional[str] = None):
        self._db_path = db_path or DB_CFG["sqlite_path"]
        Path(self._db_path).parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()
        logger.info("DatabaseManager ready: %s", self._db_path)

    @contextmanager
    def _conn(self) -> Generator[sqlite3.Connection, None, None]:
        con = sqlite3.connect(self._db_path, timeout=10, check_same_thread=False)
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA journal_mode=WAL")
        con.execute("PRAGMA foreign_keys=ON")
        try:
            yield con
            con.commit()
        except Exception:
            con.rollback()
            raise
        finally:
            con.close()

    def _init_schema(self) -> None:
        with self._conn() as con:
            con.executescript(_SCHEMA)
            # Record schema version
            con.execute(
                "INSERT OR IGNORE INTO schema_version(version, applied_at) VALUES(1, ?)",
                (datetime.utcnow().isoformat(),),
            )
        logger.debug("Schema initialised")

    # ── Helpers ───────────────────────────────────────────────────────────────

    @staticmethod
    def _now() -> str:
        return datetime.utcnow().isoformat()

    @staticmethod
    def _row_to_dict(row: Optional[sqlite3.Row]) -> Optional[Dict[str, Any]]:
        return dict(row) if row else None

    # ── Users ─────────────────────────────────────────────────────────────────

    def create_user(self, username: str, email: str, password: str, role: str = "viewer") -> Optional[Dict]:
        """Create a new user. Returns the user dict or None if username/email exists."""
        with self._conn() as con:
            existing = con.execute(
                "SELECT id FROM users WHERE username=? OR email=?", (username, email)
            ).fetchone()
            if existing:
                logger.warning("User already exists: %s / %s", username, email)
                return None
            pw_hash = _hash_password(password)
            now = self._now()
            con.execute(
                "INSERT INTO users(username, email, password_hash, role, created_at) VALUES(?,?,?,?,?)",
                (username, email, pw_hash, role, now),
            )
        logger.info("User created: %s (%s)", username, role)
        return self.get_user(username=username)

    def authenticate_user(self, username: str, password: str) -> Optional[Dict]:
        """Verify credentials and update last_login. Returns user dict or None."""
        with self._conn() as con:
            row = con.execute(
                "SELECT * FROM users WHERE (username=? OR email=?) AND active=1",
                (username, username),
            ).fetchone()
            if not row:
                return None
            if not _verify_password(password, row["password_hash"]):
                logger.warning("Bad password attempt: %s", username)
                return None
            con.execute("UPDATE users SET last_login=? WHERE id=?", (self._now(), row["id"]))
        logger.info("Authenticated: %s", username)
        user = dict(row)
        user.pop("password_hash", None)
        return user

    def get_user(self, user_id: int = None, username: str = None) -> Optional[Dict]:
        with self._conn() as con:
            if user_id:
                row = con.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
            elif username:
                row = con.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
            else:
                return None
        if not row:
            return None
        user = dict(row)
        user.pop("password_hash", None)
        return user

    def list_users(self) -> List[Dict]:
        with self._conn() as con:
            rows = con.execute("SELECT * FROM users ORDER BY created_at DESC").fetchall()
        result = []
        for r in rows:
            d = dict(r)
            d.pop("password_hash", None)
            result.append(d)
        return result

    def update_user_role(self, user_id: int, role: str) -> bool:
        with self._conn() as con:
            cur = con.execute(
                "UPDATE users SET role=?, updated_at=? WHERE id=?",
                (role, self._now(), user_id),
            )
        return cur.rowcount > 0

    def deactivate_user(self, user_id: int) -> bool:
        with self._conn() as con:
            cur = con.execute(
                "UPDATE users SET active=0, updated_at=? WHERE id=?",
                (self._now(), user_id),
            )
        return cur.rowcount > 0

    def change_password(self, user_id: int, new_password: str) -> bool:
        pw_hash = _hash_password(new_password)
        with self._conn() as con:
            cur = con.execute(
                "UPDATE users SET password_hash=?, updated_at=? WHERE id=?",
                (pw_hash, self._now(), user_id),
            )
        return cur.rowcount > 0

    # ── API Keys ──────────────────────────────────────────────────────────────

    def create_api_key(self, user_id: int, name: str, role: str = "viewer",
                       expires_days: Optional[int] = None) -> Optional[str]:
        """Returns the raw key (only time it is visible) or None on failure."""
        raw_key = f"ei_{secrets.token_urlsafe(32)}"
        key_hash = hashlib.sha256(raw_key.encode()).hexdigest()
        preview = raw_key[:12] + "..."
        expires_at = (datetime.utcnow() + timedelta(days=expires_days)).isoformat() if expires_days else None
        with self._conn() as con:
            con.execute(
                "INSERT INTO api_keys(user_id, name, key_hash, key_preview, role, created_at, expires_at) VALUES(?,?,?,?,?,?,?)",
                (user_id, name, key_hash, preview, role, self._now(), expires_at),
            )
        logger.info("API key created: %s (user_id=%s)", name, user_id)
        return raw_key

    def validate_api_key(self, raw_key: str) -> Optional[Dict]:
        """Validate a raw API key and return the associated user dict or None."""
        key_hash = hashlib.sha256(raw_key.encode()).hexdigest()
        with self._conn() as con:
            row = con.execute(
                "SELECT ak.*, u.username, u.role AS user_role FROM api_keys ak "
                "JOIN users u ON u.id = ak.user_id "
                "WHERE ak.key_hash=? AND (ak.expires_at IS NULL OR ak.expires_at > ?)",
                (key_hash, self._now()),
            ).fetchone()
            if row:
                con.execute("UPDATE api_keys SET last_used=? WHERE key_hash=?", (self._now(), key_hash))
        return self._row_to_dict(row)

    def revoke_api_key(self, name: str, user_id: int) -> bool:
        with self._conn() as con:
            cur = con.execute("DELETE FROM api_keys WHERE name=? AND user_id=?", (name, user_id))
        return cur.rowcount > 0

    def list_api_keys(self, user_id: Optional[int] = None) -> List[Dict]:
        with self._conn() as con:
            if user_id:
                rows = con.execute("SELECT * FROM api_keys WHERE user_id=?", (user_id,)).fetchall()
            else:
                rows = con.execute("SELECT * FROM api_keys ORDER BY created_at DESC").fetchall()
        return [self._row_to_dict(r) for r in rows]

    # ── Sites ─────────────────────────────────────────────────────────────────

    def upsert_site(self, domain: str, **kwargs) -> Dict:
        """Insert or update a site record (called after easyinstall create/clone)."""
        now = self._now()
        with self._conn() as con:
            existing = con.execute("SELECT id FROM sites WHERE domain=?", (domain,)).fetchone()
            extra = json.dumps(kwargs.pop("extra", {}))
            if existing:
                set_clauses = ", ".join(f"{k}=?" for k in kwargs)
                values = list(kwargs.values()) + [now, extra, domain]
                con.execute(f"UPDATE sites SET {set_clauses}, updated_at=?, extra_json=? WHERE domain=?", values)
            else:
                keys = ", ".join(kwargs.keys())
                placeholders = ", ".join("?" * len(kwargs))
                values = list(kwargs.values())
                con.execute(
                    f"INSERT INTO sites(domain, {keys}, created_at, extra_json) VALUES(?, {placeholders}, ?, ?)",
                    [domain] + values + [now, extra],
                )
        return self.get_site(domain=domain)

    def get_site(self, domain: str = None, site_id: int = None) -> Optional[Dict]:
        with self._conn() as con:
            if domain:
                row = con.execute("SELECT * FROM sites WHERE domain=?", (domain,)).fetchone()
            elif site_id:
                row = con.execute("SELECT * FROM sites WHERE id=?", (site_id,)).fetchone()
            else:
                return None
        return self._row_to_dict(row)

    def list_sites(self, status: Optional[str] = "active") -> List[Dict]:
        with self._conn() as con:
            if status:
                rows = con.execute("SELECT * FROM sites WHERE status=? ORDER BY domain", (status,)).fetchall()
            else:
                rows = con.execute("SELECT * FROM sites ORDER BY domain").fetchall()
        return [self._row_to_dict(r) for r in rows]

    def mark_site_deleted(self, domain: str) -> bool:
        with self._conn() as con:
            cur = con.execute(
                "UPDATE sites SET status='deleted', updated_at=? WHERE domain=?",
                (self._now(), domain),
            )
        return cur.rowcount > 0

    def update_site_status(self, domain: str, status: str) -> bool:
        with self._conn() as con:
            cur = con.execute(
                "UPDATE sites SET status=?, updated_at=? WHERE domain=?",
                (status, self._now(), domain),
            )
        return cur.rowcount > 0

    # ── Backups ───────────────────────────────────────────────────────────────

    def record_backup_start(self, domain: str, backup_type: str = "full",
                             retention_days: int = 30) -> int:
        """Insert a backup record in 'running' state. Returns the backup ID."""
        site = self.get_site(domain=domain)
        site_id = site["id"] if site else None
        with self._conn() as con:
            cur = con.execute(
                "INSERT INTO backups(site_id, domain, backup_type, status, retention_days, created_at) VALUES(?,?,?,?,?,?)",
                (site_id, domain, backup_type, "running", retention_days, self._now()),
            )
            return cur.lastrowid

    def update_backup(self, backup_id: int, status: str, size_bytes: int = 0,
                      location: str = None, notes: str = None) -> bool:
        completed_at = self._now() if status in ("completed", "failed") else None
        with self._conn() as con:
            cur = con.execute(
                "UPDATE backups SET status=?, size_bytes=?, location=?, completed_at=?, notes=? WHERE id=?",
                (status, size_bytes, location, completed_at, notes, backup_id),
            )
        return cur.rowcount > 0

    def list_backups(self, domain: Optional[str] = None, limit: int = 50) -> List[Dict]:
        with self._conn() as con:
            if domain:
                rows = con.execute(
                    "SELECT * FROM backups WHERE domain=? ORDER BY created_at DESC LIMIT ?",
                    (domain, limit),
                ).fetchall()
            else:
                rows = con.execute(
                    "SELECT * FROM backups ORDER BY created_at DESC LIMIT ?", (limit,)
                ).fetchall()
        return [self._row_to_dict(r) for r in rows]

    def purge_old_backups(self) -> int:
        cutoff = (datetime.utcnow() - timedelta(days=DB_CFG["backup_record_retention_days"])).isoformat()
        with self._conn() as con:
            cur = con.execute("DELETE FROM backups WHERE created_at < ?", (cutoff,))
        logger.info("Purged %d old backup records", cur.rowcount)
        return cur.rowcount

    # ── Metrics ───────────────────────────────────────────────────────────────

    def record_metric(self, domain: str, data: Dict[str, Any]) -> int:
        site = self.get_site(domain=domain)
        site_id = site["id"] if site else None
        extra = json.dumps({k: v for k, v in data.items()
                             if k not in ("cpu_usage","memory_usage","disk_usage","php_workers","redis_memory_mb","active_connections")})
        with self._conn() as con:
            cur = con.execute(
                "INSERT INTO metrics(site_id, domain, timestamp, cpu_usage, memory_usage, disk_usage, "
                "php_workers, redis_memory_mb, active_connections, extra_json) VALUES(?,?,?,?,?,?,?,?,?,?)",
                (
                    site_id, domain, data.get("timestamp", self._now()),
                    data.get("cpu_usage", 0), data.get("memory_usage", 0),
                    data.get("disk_usage", 0), data.get("php_workers", 0),
                    data.get("redis_memory_mb", 0), data.get("active_connections", 0),
                    extra,
                ),
            )
        return cur.lastrowid

    def get_metrics(self, domain: str, hours: int = 24, limit: int = 1440) -> List[Dict]:
        cutoff = (datetime.utcnow() - timedelta(hours=hours)).isoformat()
        with self._conn() as con:
            rows = con.execute(
                "SELECT * FROM metrics WHERE domain=? AND timestamp >= ? ORDER BY timestamp DESC LIMIT ?",
                (domain, cutoff, limit),
            ).fetchall()
        return [self._row_to_dict(r) for r in rows]

    def purge_old_metrics(self) -> int:
        cutoff = (datetime.utcnow() - timedelta(days=DB_CFG["metrics_retention_days"])).isoformat()
        with self._conn() as con:
            cur = con.execute("DELETE FROM metrics WHERE timestamp < ?", (cutoff,))
        logger.info("Purged %d old metric rows", cur.rowcount)
        return cur.rowcount

    def aggregate_metrics(self, domain: str, days: int = 7) -> List[Dict]:
        """Daily averages over the last N days."""
        cutoff = (datetime.utcnow() - timedelta(days=days)).isoformat()
        with self._conn() as con:
            rows = con.execute(
                """
                SELECT substr(timestamp, 1, 10) AS day,
                       AVG(cpu_usage) AS avg_cpu,
                       AVG(memory_usage) AS avg_memory,
                       AVG(disk_usage) AS avg_disk,
                       AVG(redis_memory_mb) AS avg_redis_mb,
                       COUNT(*) AS samples
                FROM metrics
                WHERE domain=? AND timestamp >= ?
                GROUP BY day
                ORDER BY day
                """,
                (domain, cutoff),
            ).fetchall()
        return [self._row_to_dict(r) for r in rows]

    # ── Audit Logs ────────────────────────────────────────────────────────────

    def audit(self, action: str, resource_type: str, resource_id: str = None,
              user_id: Optional[int] = None, username: str = "system",
              status: str = "success", ip_address: str = None,
              details: Dict = None) -> int:
        details_json = json.dumps(details or {})
        with self._conn() as con:
            cur = con.execute(
                "INSERT INTO audit_logs(user_id, username, action, resource_type, resource_id, "
                "status, ip_address, details_json, timestamp) VALUES(?,?,?,?,?,?,?,?,?)",
                (user_id, username, action, resource_type, resource_id,
                 status, ip_address, details_json, self._now()),
            )
        return cur.lastrowid

    def get_audit_logs(self, user_id: int = None, resource_type: str = None,
                       days: int = 7, limit: int = 200) -> List[Dict]:
        cutoff = (datetime.utcnow() - timedelta(days=days)).isoformat()
        params: list = [cutoff]
        query = "SELECT * FROM audit_logs WHERE timestamp >= ?"
        if user_id:
            query += " AND user_id=?"
            params.append(user_id)
        if resource_type:
            query += " AND resource_type=?"
            params.append(resource_type)
        query += " ORDER BY timestamp DESC LIMIT ?"
        params.append(limit)
        with self._conn() as con:
            rows = con.execute(query, params).fetchall()
        return [self._row_to_dict(r) for r in rows]

    def purge_old_audit(self) -> int:
        cutoff = (datetime.utcnow() - timedelta(days=DB_CFG["audit_retention_days"])).isoformat()
        with self._conn() as con:
            cur = con.execute("DELETE FROM audit_logs WHERE timestamp < ?", (cutoff,))
        logger.info("Purged %d old audit log entries", cur.rowcount)
        return cur.rowcount

    # ── Alerts ────────────────────────────────────────────────────────────────

    def create_alert(self, alert_type: str, severity: str, title: str, message: str,
                     domain: str = None, data: Dict = None) -> int:
        with self._conn() as con:
            cur = con.execute(
                "INSERT INTO alerts(domain, alert_type, severity, title, message, created_at, data_json) VALUES(?,?,?,?,?,?,?)",
                (domain, alert_type, severity, title, message, self._now(), json.dumps(data or {})),
            )
        return cur.lastrowid

    def get_active_alerts(self, domain: str = None, severity: str = None) -> List[Dict]:
        params: list = []
        query = "SELECT * FROM alerts WHERE acknowledged=0 AND resolved_at IS NULL"
        if domain:
            query += " AND domain=?"
            params.append(domain)
        if severity:
            query += " AND severity=?"
            params.append(severity)
        query += " ORDER BY created_at DESC"
        with self._conn() as con:
            rows = con.execute(query, params).fetchall()
        return [self._row_to_dict(r) for r in rows]

    def acknowledge_alert(self, alert_id: int, by_user: str) -> bool:
        with self._conn() as con:
            cur = con.execute(
                "UPDATE alerts SET acknowledged=1, acknowledged_by=?, acknowledged_at=? WHERE id=?",
                (by_user, self._now(), alert_id),
            )
        return cur.rowcount > 0

    def resolve_alert(self, alert_id: int) -> bool:
        with self._conn() as con:
            cur = con.execute(
                "UPDATE alerts SET resolved_at=? WHERE id=?",
                (self._now(), alert_id),
            )
        return cur.rowcount > 0

    # ── License ───────────────────────────────────────────────────────────────

    def set_license(self, license_key: str, license_type: str, expires_at: str,
                    customer_name: str = None, customer_email: str = None,
                    max_sites: int = 0, features: List[str] = None) -> Dict:
        now = self._now()
        with self._conn() as con:
            con.execute("DELETE FROM licenses")
            con.execute(
                "INSERT INTO licenses(license_key, license_type, customer_name, customer_email, "
                "max_sites, features_json, issued_at, expires_at, last_validated) VALUES(?,?,?,?,?,?,?,?,?)",
                (license_key, license_type, customer_name, customer_email,
                 max_sites, json.dumps(features or []), now, expires_at, now),
            )
        return self.get_license()

    def get_license(self) -> Optional[Dict]:
        with self._conn() as con:
            row = con.execute("SELECT * FROM licenses LIMIT 1").fetchone()
        if not row:
            return None
        d = self._row_to_dict(row)
        d["features"] = json.loads(d.pop("features_json", "[]"))
        d["valid"] = d["expires_at"] > self._now()
        return d

    def has_feature(self, feature: str) -> bool:
        lic = self.get_license()
        if not lic or not lic.get("valid"):
            return feature in ("basic",)
        if lic["license_type"] == "enterprise":
            return True
        return feature in lic.get("features", [])

    # ── Housekeeping ──────────────────────────────────────────────────────────

    def run_housekeeping(self) -> Dict[str, int]:
        """Purge expired data. Call nightly from cron."""
        return {
            "metrics_purged": self.purge_old_metrics(),
            "audit_purged": self.purge_old_audit(),
            "backups_purged": self.purge_old_backups(),
        }

    def get_stats(self) -> Dict[str, Any]:
        """Return row counts for all main tables."""
        with self._conn() as con:
            def count(table: str) -> int:
                return con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            return {
                "sites": count("sites"),
                "active_sites": con.execute("SELECT COUNT(*) FROM sites WHERE status='active'").fetchone()[0],
                "backups": count("backups"),
                "metrics_rows": count("metrics"),
                "audit_entries": count("audit_logs"),
                "active_alerts": con.execute("SELECT COUNT(*) FROM alerts WHERE acknowledged=0").fetchone()[0],
                "users": count("users"),
                "api_keys": count("api_keys"),
            }


# ── Singleton ─────────────────────────────────────────────────────────────────

_manager_instance: Optional[DatabaseManager] = None

def get_db() -> DatabaseManager:
    """Return the shared DatabaseManager singleton."""
    global _manager_instance
    if _manager_instance is None:
        _manager_instance = DatabaseManager()
    return _manager_instance


# ── CLI / setup ───────────────────────────────────────────────────────────────

def _bootstrap_admin(db: DatabaseManager) -> None:
    """Create the default super_admin account if no users exist."""
    with db._conn() as con:
        count = con.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    if count == 0:
        default_pass = secrets.token_urlsafe(12)
        db.create_user("admin", "admin@localhost", default_pass, role="super_admin")
        creds_file = Path("/root/easyinstall-api-admin.txt")
        creds_file.write_text(
            f"EasyInstall API — Default Admin Credentials\n"
            f"Username : admin\n"
            f"Password : {default_pass}\n"
            f"CHANGE THIS IMMEDIATELY after first login.\n"
        )
        creds_file.chmod(0o600)
        logger.info("Default admin created — credentials at /root/easyinstall-api-admin.txt")


def _write_default_config() -> None:
    conf_file = CONFIG_DIR / "database.conf"
    if not conf_file.exists():
        conf_file.write_text(json.dumps(_DEFAULT_DB_CFG, indent=2))
        conf_file.chmod(0o600)
        logger.info("Wrote default database.conf")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="EasyInstall DB Manager")
    parser.add_argument("--init", action="store_true", help="Initialise DB and write default config")
    parser.add_argument("--stats", action="store_true", help="Print table stats")
    parser.add_argument("--housekeep", action="store_true", help="Run data retention purge")
    args = parser.parse_args()

    if args.init:
        _write_default_config()
        db = DatabaseManager()
        _bootstrap_admin(db)
        print("Database initialised. Run 'easyinstall api start' to launch the API.")
    elif args.stats:
        db = get_db()
        import pprint
        pprint.pprint(db.get_stats())
    elif args.housekeep:
        db = get_db()
        result = db.run_housekeeping()
        print("Housekeeping complete:", result)
    else:
        parser.print_help()

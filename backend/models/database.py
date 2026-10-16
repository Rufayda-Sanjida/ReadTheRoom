"""Database connection, table setup, and demo seed data.

Uses SQLite by default (local dev). If DATABASE_URL or the standard PGHOST/PGUSER/...
variables are set (as they are on AWS, pointing at RDS), it uses Postgres instead.
Models write SQL with `?` placeholders either way; the Postgres wrapper translates them.
"""

import json
import os
import sqlite3
from contextlib import contextmanager
from typing import Iterator

import config

DATABASE_URL = os.environ.get("DATABASE_URL", "")
USE_POSTGRES = bool(DATABASE_URL or os.environ.get("PGHOST"))

if USE_POSTGRES:
    import psycopg
    from psycopg.rows import dict_row

    IntegrityError: tuple[type[Exception], ...] = (psycopg.IntegrityError,)
else:
    IntegrityError = (sqlite3.IntegrityError,)

SQLITE_SCHEMA = """
    CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        name TEXT,
        video_url TEXT,
        created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS reactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        timestamp REAL NOT NULL,
        type TEXT NOT NULL,
        intensity REAL NOT NULL,
        confidence REAL NOT NULL,
        breathing_rate REAL
    );
    CREATE INDEX IF NOT EXISTS idx_reactions_session_ts
        ON reactions(session_id, timestamp);
"""

# Same tables. DOUBLE PRECISION, not REAL: Postgres REAL is 4 bytes and would turn 127.4 into 127.40000152.
POSTGRES_SCHEMA = """
    CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        name TEXT,
        video_url TEXT,
        created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS reactions (
        id BIGSERIAL PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        timestamp DOUBLE PRECISION NOT NULL,
        type TEXT NOT NULL,
        intensity DOUBLE PRECISION NOT NULL,
        confidence DOUBLE PRECISION NOT NULL,
        breathing_rate DOUBLE PRECISION
    );
    CREATE INDEX IF NOT EXISTS idx_reactions_session_ts
        ON reactions(session_id, timestamp);
"""


class _PostgresConn:
    """Gives a psycopg connection the sqlite3 methods the models use."""

    def __init__(self, conn):
        self._conn = conn

    def execute(self, sql: str, params=None):
        # No params -> simple query protocol, which also allows several statements (the schema) at once.
        return self._conn.execute(sql.replace("?", "%s"), params or None)

    def executemany(self, sql: str, rows) -> None:
        with self._conn.cursor() as cur:
            cur.executemany(sql.replace("?", "%s"), rows)


@contextmanager
def get_conn() -> Iterator:
    """A connection that commits on success and rolls back on error."""
    if USE_POSTGRES:
        # An empty conninfo makes libpq read PGHOST, PGUSER, PGPASSWORD, PGDATABASE from the environment.
        with psycopg.connect(DATABASE_URL, row_factory=dict_row) as conn:
            yield _PostgresConn(conn)
        return

    conn = sqlite3.connect(config.DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        with conn:
            yield conn
    finally:
        conn.close()


def init_db() -> None:
    with get_conn() as conn:
        if USE_POSTGRES:
            conn.execute(POSTGRES_SCHEMA)
        else:
            conn.executescript(SQLITE_SCHEMA)
            # Added after launch: SQLite databases created earlier don't have this column yet.
            columns = {row["name"] for row in conn.execute("PRAGMA table_info(reactions)")}
            if "breathing_rate" not in columns:
                conn.execute("ALTER TABLE reactions ADD COLUMN breathing_rate REAL")
    seed_demo()


def seed_demo() -> None:
    """Create the `demo` session from data/mock_reactions.json if it doesn't exist."""
    from models import reaction, session  # imported here to avoid a circular import

    if session.get(config.DEMO_SESSION_ID):
        return
    try:
        session.create(
            config.DEMO_SESSION_ID,
            name="Demo video",
            video_url="/api/videos/product_demo.mp4",
        )
    except IntegrityError:
        return  # another server instance seeded it at the same moment
    reaction.add_many(config.DEMO_SESSION_ID, json.loads(config.MOCK_REACTIONS_PATH.read_text()))

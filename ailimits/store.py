# -*- coding: utf-8 -*-
"""Magazyn statystyk: SQLite + kursory plików do przyrostowego wczytywania."""

import os
import sqlite3
import time
from datetime import datetime, timedelta

DATA_DIR = os.path.expanduser("~/Library/Application Support/AILimits")
DB_PATH = os.path.join(DATA_DIR, "stats.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
    path   TEXT PRIMARY KEY,
    app    TEXT NOT NULL,
    size   INTEGER NOT NULL,
    offset INTEGER NOT NULL,
    mtime  REAL NOT NULL
);

-- Jedno zdarzenie = jedna odpowiedź modelu (Claude) albo jeden turn (Codex).
-- (app, uniq) jest kluczem głównym, więc ponowne wczytanie pliku jest idempotentne.
CREATE TABLE IF NOT EXISTS usage_events (
    app         TEXT NOT NULL,
    uniq        TEXT NOT NULL,
    session_id  TEXT NOT NULL,
    ts          REAL NOT NULL,
    model       TEXT,
    input       INTEGER NOT NULL DEFAULT 0,
    output      INTEGER NOT NULL DEFAULT 0,
    cache_read  INTEGER NOT NULL DEFAULT 0,
    cache_write INTEGER NOT NULL DEFAULT 0,
    reasoning   INTEGER NOT NULL DEFAULT 0,
    sidechain   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (app, uniq)
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON usage_events (ts);
CREATE INDEX IF NOT EXISTS idx_events_session ON usage_events (app, session_id);

CREATE TABLE IF NOT EXISTS sessions (
    app        TEXT NOT NULL,
    session_id TEXT NOT NULL,
    title      TEXT,
    cwd        TEXT,
    origin     TEXT,
    first_ts   REAL,
    last_ts    REAL,
    PRIMARY KEY (app, session_id)
);

-- Próbki wykorzystania limitów, zbierane przy każdym odświeżeniu widgetu.
CREATE TABLE IF NOT EXISTS limit_samples (
    ts          REAL NOT NULL,
    app         TEXT NOT NULL,
    window_mins INTEGER NOT NULL,
    pct         REAL NOT NULL,
    resets_at   REAL,
    PRIMARY KEY (ts, app, window_mins)
);
CREATE INDEX IF NOT EXISTS idx_limits_ts ON limit_samples (ts);
"""

TOTAL_SQL = "input + output + cache_read + cache_write"


def connect():
    os.makedirs(DATA_DIR, exist_ok=True)
    con = sqlite3.connect(DB_PATH, timeout=20)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    con.executescript(SCHEMA)
    return con


# ------------------------------------------------------------------ kursory

def cursor_for(con, path, app):
    """Ile bajtów pliku już wczytaliśmy. Skrócony plik => czytamy od zera."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    row = con.execute("SELECT size, offset, mtime FROM files WHERE path = ?", (path,)).fetchone()
    if row is None:
        return 0, st.st_size, st.st_mtime
    if st.st_size < row["offset"]:      # rotacja albo obcięcie – parsujemy całość
        return 0, st.st_size, st.st_mtime
    if st.st_size == row["offset"] and abs(st.st_mtime - row["mtime"]) < 1:
        return None                      # bez zmian
    return row["offset"], st.st_size, st.st_mtime


def save_cursor(con, path, app, offset, size, mtime):
    con.execute(
        "INSERT INTO files (path, app, size, offset, mtime) VALUES (?,?,?,?,?) "
        "ON CONFLICT(path) DO UPDATE SET size=excluded.size, offset=excluded.offset, mtime=excluded.mtime",
        (path, app, size, offset, mtime),
    )


# ------------------------------------------------------------------ zapisy

def add_events(con, rows):
    con.executemany(
        "INSERT OR IGNORE INTO usage_events "
        "(app, uniq, session_id, ts, model, input, output, cache_read, cache_write, reasoning, sidechain) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        rows,
    )


def touch_session(con, app, session_id, title=None, cwd=None, origin=None, ts=None):
    con.execute(
        "INSERT INTO sessions (app, session_id, title, cwd, origin, first_ts, last_ts) VALUES (?,?,?,?,?,?,?) "
        "ON CONFLICT(app, session_id) DO UPDATE SET "
        "  title    = COALESCE(excluded.title, sessions.title), "
        "  cwd      = COALESCE(excluded.cwd, sessions.cwd), "
        "  origin   = COALESCE(excluded.origin, sessions.origin), "
        "  first_ts = MIN(COALESCE(excluded.first_ts, sessions.first_ts), COALESCE(sessions.first_ts, excluded.first_ts)), "
        "  last_ts  = MAX(COALESCE(excluded.last_ts, sessions.last_ts), COALESCE(sessions.last_ts, excluded.last_ts))",
        (app, session_id, title, cwd, origin, ts, ts),
    )


def add_limit_sample(con, app, window_mins, pct, resets_at, ts=None):
    con.execute(
        "INSERT OR IGNORE INTO limit_samples (ts, app, window_mins, pct, resets_at) VALUES (?,?,?,?,?)",
        (ts or time.time(), app, window_mins, pct, resets_at),
    )


# ------------------------------------------------------------------ odczyty

def prune_limits(con, days=30):
    """Próbki limitów starsze niż `days` nie są już do niczego potrzebne."""
    con.execute("DELETE FROM limit_samples WHERE ts < ?", (time.time() - days * 86400,))


def day_start(days_ago=0):
    d = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=days_ago)
    return d.timestamp()


def totals(con, since=None, until=None):
    """Sumy tokenów per aplikacja w oknie czasu."""
    sql = ("SELECT app, SUM(input) i, SUM(output) o, SUM(cache_read) cr, SUM(cache_write) cw, "
           "COUNT(*) n, COUNT(DISTINCT session_id) s FROM usage_events WHERE 1=1")
    args = []
    if since is not None:
        sql += " AND ts >= ?"; args.append(since)
    if until is not None:
        sql += " AND ts < ?"; args.append(until)
    sql += " GROUP BY app"
    out = {}
    for r in con.execute(sql, args):
        out[r["app"]] = {
            "input": r["i"] or 0, "output": r["o"] or 0,
            "cache_read": r["cr"] or 0, "cache_write": r["cw"] or 0,
            "events": r["n"], "sessions": r["s"],
            "total": (r["i"] or 0) + (r["o"] or 0) + (r["cr"] or 0) + (r["cw"] or 0),
        }
    return out


def threads(con, since=None, limit=None, app=None):
    """Wątki posortowane po zużyciu, z tytułem i katalogiem projektu."""
    sql = (
        "SELECT e.app, e.session_id, "
        "       SUM(e.input) i, SUM(e.output) o, SUM(e.cache_read) cr, SUM(e.cache_write) cw, "
        "       SUM(CASE WHEN e.sidechain THEN e.input+e.output+e.cache_read+e.cache_write ELSE 0 END) sub, "
        "       MIN(e.ts) t0, MAX(e.ts) t1, COUNT(*) n, "
        "       s.title, s.cwd, s.origin "
        "FROM usage_events e LEFT JOIN sessions s ON s.app = e.app AND s.session_id = e.session_id "
        "WHERE 1=1"
    )
    args = []
    if since is not None:
        sql += " AND e.ts >= ?"; args.append(since)
    if app is not None:
        sql += " AND e.app = ?"; args.append(app)
    sql += " GROUP BY e.app, e.session_id ORDER BY (SUM(e.input)+SUM(e.output)+SUM(e.cache_read)+SUM(e.cache_write)) DESC"
    if limit:
        sql += " LIMIT %d" % int(limit)
    rows = []
    for r in con.execute(sql, args):
        d = dict(r)
        d["total"] = (r["i"] or 0) + (r["o"] or 0) + (r["cr"] or 0) + (r["cw"] or 0)
        rows.append(d)
    return rows


def hourly(con, since, buckets=24):
    """Tokeny w kubełkach godzinowych (czas lokalny), per aplikacja."""
    out = {}
    sql = ("SELECT app, ts, input+output+cache_read+cache_write tot, output FROM usage_events "
           "WHERE ts >= ? ORDER BY ts")
    for r in con.execute(sql, (since,)):
        hour = datetime.fromtimestamp(r["ts"]).replace(minute=0, second=0, microsecond=0)
        key = (r["app"], hour.timestamp())
        cell = out.setdefault(key, {"total": 0, "output": 0})
        cell["total"] += r["tot"] or 0
        cell["output"] += r["output"] or 0
    return out


def limit_history(con, since):
    rows = []
    for r in con.execute(
        "SELECT ts, app, window_mins, pct FROM limit_samples WHERE ts >= ? ORDER BY ts", (since,)
    ):
        rows.append(dict(r))
    return rows

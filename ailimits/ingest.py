# -*- coding: utf-8 -*-
"""Przyrostowe wczytywanie logów Claude Code i Codeksa do bazy statystyk."""

import glob
import json
import os
import re
from datetime import datetime, timezone

from . import store

CLAUDE_GLOBS = [
    os.path.expanduser("~/.claude/projects/*/*.jsonl"),
    # transkrypty subagentów – ten sam sessionId co rodzic, klucz (msg.id, requestId) chroni przed podwójnym liczeniem
    os.path.expanduser("~/.claude/projects/*/*/subagents/*.jsonl"),
]
CODEX_GLOBS = [
    os.path.expanduser("~/.codex/sessions/*/*/*/*.jsonl"),
    os.path.expanduser("~/.codex/archived_sessions/*.jsonl"),
    os.path.expanduser("~/.codex/archived_sessions/*/*/*/*.jsonl"),
]
UUID_RE = re.compile(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})")
TAGS_RE = re.compile(r"<[^>]{1,60}>")
# bloki kontekstu, które Codex wstrzykuje przed prawdziwym promptem
CONTEXT_MARKERS = ("# AGENTS.md", "AGENTS.md instructions", "<user_instructions>",
                   "<environment_context>", "<recommended_plugins>", "<plugin")


def _codex_title_from_text(text):
    """Tytuł wątku z pierwszej ludzkiej wiadomości. None, jeśli to tylko kontekst."""
    text = (text or "").strip()
    if not text:
        return None
    # bootstrap ustawiający nazwę wątku w aplikacji: '... Title: <nazwa>'
    for line in text.splitlines():
        if line.startswith("Title:"):
            name = line[len("Title:"):].strip()
            if name:
                return name[:200]
    if any(marker in text[:400] for marker in CONTEXT_MARKERS):
        return None
    clean = " ".join(TAGS_RE.sub(" ", text).split())
    return clean[:200] if len(clean) > 4 else None


def _ts(value):
    """ISO-8601 (zwykle z 'Z') -> epoch. Zwraca None, gdy się nie da."""
    if not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        dt = datetime.fromisoformat(value)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except Exception:
        return None


def _lines(path, offset):
    """Czyta od bajtu `offset`, oddaje (surowa_linia, nowy_offset).

    Niedokończona ostatnia linia (plik właśnie jest zapisywany) nie jest konsumowana.
    """
    with open(path, "rb") as fh:
        fh.seek(offset)
        pos = offset
        for raw in fh:
            if not raw.endswith(b"\n"):
                return                      # ogonek bez \n – dokończymy przy następnym biegu
            pos += len(raw)
            yield raw, pos


# ------------------------------------------------------------------- Claude

def ingest_claude(con, max_bytes=None):
    seen_bytes = 0
    files = 0
    paths = []
    for pattern in CLAUDE_GLOBS:
        paths += glob.glob(pattern)
    for path in sorted(set(paths), key=os.path.getmtime, reverse=True):
        cur = store.cursor_for(con, path, "claude")
        if cur is None:
            continue
        offset, size, mtime = cur
        if max_bytes is not None and seen_bytes >= max_bytes:
            break
        rows = []
        last_pos = offset
        for raw, pos in _lines(path, offset):
            last_pos = pos
            seen_bytes += len(raw)
            if b'"usage"' not in raw and b'"ai-title"' not in raw:
                continue
            try:
                o = json.loads(raw)
            except Exception:
                continue
            kind = o.get("type")
            sid = o.get("sessionId")
            if kind == "ai-title" and sid:
                store.touch_session(con, "claude", sid, title=o.get("aiTitle"))
                continue
            if kind != "assistant" or not sid:
                continue
            msg = o.get("message") or {}
            usage = msg.get("usage") or {}
            if not usage:
                continue
            ts = _ts(o.get("timestamp"))
            if ts is None:
                continue
            uniq = "%s:%s" % (msg.get("id") or o.get("uuid"), o.get("requestId") or "")
            rows.append((
                "claude", uniq, sid, ts, msg.get("model"),
                int(usage.get("input_tokens") or 0),
                int(usage.get("output_tokens") or 0),
                int(usage.get("cache_read_input_tokens") or 0),
                int(usage.get("cache_creation_input_tokens") or 0),
                int((usage.get("output_tokens_details") or {}).get("thinking_tokens") or 0),
                1 if o.get("isSidechain") else 0,
            ))
            store.touch_session(con, "claude", sid, cwd=o.get("cwd"), origin="cli", ts=ts)
            if len(rows) >= 2000:
                store.add_events(con, rows); rows = []
        if rows:
            store.add_events(con, rows)
        store.save_cursor(con, path, "claude", last_pos, size, mtime)
        con.commit()
        files += 1
    return files


# -------------------------------------------------------------------- Codex

def _codex_session_id(payload, path):
    sid = payload.get("session_id") or payload.get("id")
    if sid:
        return sid
    m = UUID_RE.search(os.path.basename(path))
    return m.group(1) if m else None


def ingest_codex(con, max_bytes=None):
    seen_bytes = 0
    files = 0
    paths = []
    for pattern in CODEX_GLOBS:
        paths += glob.glob(pattern)
    for path in sorted(set(paths), key=os.path.getmtime, reverse=True):
        cur = store.cursor_for(con, path, "codex")
        if cur is None:
            continue
        offset, size, mtime = cur
        if max_bytes is not None and seen_bytes >= max_bytes:
            break
        fallback_sid = None
        m = UUID_RE.search(os.path.basename(path))
        if m:
            fallback_sid = m.group(1)
        # id wątku trzymamy w bazie – przy dopisywaniu do pliku nagłówka już nie zobaczymy
        row = con.execute(
            "SELECT session_id FROM sessions WHERE app='codex' AND session_id = ?", (fallback_sid,)
        ).fetchone()
        sid = row["session_id"] if row else fallback_sid
        titled = set(
            r["session_id"] for r in con.execute(
                "SELECT session_id FROM sessions WHERE app='codex' AND title IS NOT NULL")
        )
        rows = []
        last_pos = offset
        for raw, pos in _lines(path, offset):
            last_pos = pos
            seen_bytes += len(raw)
            looking_for_title = sid not in titled
            if (b'"token_count"' not in raw and b'"session_meta"' not in raw
                    and b'"thread_goal_updated"' not in raw
                    and not (looking_for_title and b'"input_text"' in raw)):
                continue
            try:
                o = json.loads(raw)
            except Exception:
                continue
            payload = o.get("payload") or {}
            kind = o.get("type")
            ptype = payload.get("type")
            if kind == "session_meta":
                sid = _codex_session_id(payload, path) or sid
                if sid:
                    store.touch_session(
                        con, "codex", sid, cwd=payload.get("cwd"),
                        origin=payload.get("originator") or payload.get("source"),
                        ts=_ts(payload.get("timestamp") or o.get("timestamp")),
                    )
                continue
            if payload.get("role") == "user" and looking_for_title and sid:
                for chunk in payload.get("content") or []:
                    if not isinstance(chunk, dict):
                        continue
                    title = _codex_title_from_text(chunk.get("text"))
                    if title:
                        store.touch_session(con, "codex", sid, title=title)
                        titled.add(sid)
                        break
                continue
            if ptype == "thread_goal_updated" and sid:
                goal = payload.get("goal") or {}
                objective = goal.get("objective")
                if objective:
                    store.touch_session(con, "codex", sid, title=objective.strip()[:200])
                    titled.add(sid)
                continue
            if ptype != "token_count" or not sid:
                continue
            info = payload.get("info") or {}
            last = info.get("last_token_usage") or {}
            if not last:
                continue
            ts = _ts(o.get("timestamp"))
            if ts is None:
                continue
            cached = int(last.get("cached_input_tokens") or 0)
            inp = int(last.get("input_tokens") or 0)
            rows.append((
                "codex", "%s:%s" % (sid, o.get("ordinal")), sid, ts,
                info.get("model") or payload.get("model"),
                max(inp - cached, 0),                       # Codex liczy cache wewnątrz input_tokens
                int(last.get("output_tokens") or 0),
                cached,
                int(last.get("cache_write_input_tokens") or 0),
                int(last.get("reasoning_output_tokens") or 0),
                0,
            ))
            # historia limitów prosto z logu – dzięki temu wykres ma przeszłość, nie tylko od dziś
            rl = payload.get("rate_limits") or {}
            for node in (rl.get("primary"), rl.get("secondary")):
                if node and node.get("window_minutes"):
                    store.add_limit_sample(
                        con, "codex", int(node["window_minutes"]),
                        float(node.get("used_percent") or 0), node.get("resets_at"), ts=ts,
                    )
            if len(rows) >= 2000:
                store.add_events(con, rows); rows = []
        if rows:
            store.add_events(con, rows)
        store.save_cursor(con, path, "codex", last_pos, size, mtime)
        con.commit()
        files += 1
    return files


def ingest_all(con, max_bytes=None):
    return {"claude": ingest_claude(con, max_bytes), "codex": ingest_codex(con, max_bytes)}

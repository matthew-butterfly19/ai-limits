# -*- coding: utf-8 -*-
"""Renderowanie paska menu dla SwiftBara."""

import json
import os
import time
from datetime import datetime

from . import fmt, limits, store

MONO = "font=Menlo size=12"
CACHE_JSON = os.path.join(store.DATA_DIR, "last_limits.json")
DASHBOARD_BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "dashboard")
THREADS_IN_MENU = 6


def _color(value):
    if value is None:
        return ""
    if value >= 90:
        return " color=#e34948"
    if value >= 70:
        return " color=#eb6834"
    return ""


def _cell(win):
    if not win:
        return None
    return "%s→%s" % (fmt.pct(win.get("pct")), fmt.left(win.get("left")))


def _refresh(win):
    """Przelicza czas do resetu – dane z cache mają stary 'left', ale dobry 'resets'."""
    if not win or not win.get("resets"):
        return win
    win = dict(win)
    win["left"] = win["resets"] - time.time()
    return win


def _load_cache():
    try:
        with open(CACHE_JSON) as fh:
            return json.load(fh)
    except Exception:
        return {}


def _save_cache(data):
    try:
        os.makedirs(store.DATA_DIR, exist_ok=True)
        with open(CACHE_JSON, "w") as fh:
            json.dump(data, fh)
    except Exception:
        pass


# Natywna aplikacja trzyma tu swój ostatni odczyt. Kiedy chodzi, to ona pyta
# dostawców – dwa procesy odpytujące ten sam endpoint co 2 minuty dostają 429
# i oba lądują na nieświeżych danych.
NATIVE_CACHE = os.path.join(store.DATA_DIR, "limits-%s.json")
NATIVE_MAX_AGE = 180


def _native(app):
    """Odczyt natywnej aplikacji, jeśli jest świeży. None, gdy jej nie ma."""
    # Wąsko, bo gołe `except Exception` zamieniłoby literówkę w kodzie w ciche
    # „brak cache" – dokładnie tak ta funkcja zgubiła NameError za pierwszym razem.
    try:
        with open(NATIVE_CACHE % app) as fh:
            snap = json.load(fh)
    except (OSError, ValueError):
        return None
    if time.time() - (snap.get("takenAt") or 0) > NATIVE_MAX_AGE:
        return None

    now = time.time()

    def win(node):
        resets = node.get("resetsAt")
        return {"pct": node.get("pct"), "resets": resets,
                "left": (resets - now) if resets else None, "severity": None}

    wins = {int(w["minutes"]): win(w) for w in snap.get("windows") or []}
    if not wins:
        return None
    if app == "claude":
        out = {"plan": snap.get("planName"), "tier": None,
               "five_hour": wins.get(300), "seven_day": wins.get(10080),
               "scoped": [], "extra": {}}
        for entry in snap.get("scoped") or []:
            row = win(entry.get("window") or {})
            row["label"] = entry.get("label") or "model"
            out["scoped"].append(row)
    else:
        out = {"plan": snap.get("planName"), "windows": wins,
               "credits": {}, "reached": None}
    out["_from_app"] = True
    return out


def _fetch(con):
    """Bieżące limity + zapis próbki do historii. Przy błędzie wraca ostatnia znana wartość."""
    cache = _load_cache()
    stale, errors = [], {}

    def one(name, fn, app):
        shared = _native(app)
        if shared:
            cache[name] = {"data": shared, "at": time.time()}
            return shared
        try:
            data = fn()
            cache[name] = {"data": data, "at": time.time()}
            return data
        except Exception as exc:
            errors[name] = str(exc) or exc.__class__.__name__
            entry = cache.get(name) or {}
            if entry.get("data"):
                stale.append("%s (%s)" % (name, fmt.when(entry.get("at"))))
                return entry["data"]
            return None

    cc = one("ClaudeCode", limits.claude_limits, "claude")
    cx = one("Codex", limits.codex_limits, "codex")
    _save_cache(cache)

    # historia do wykresu – tylko świeże odczyty
    # Próbki zapisuje ten, kto naprawdę pytał – inaczej ta sama wartość wpada do
    # historii dwa razy, pod dwoma znacznikami czasu.
    if cc and "ClaudeCode" not in errors and not cc.get("_from_app"):
        for mins, key in ((300, "five_hour"), (10080, "seven_day")):
            w = cc.get(key)
            if w and w.get("pct") is not None:
                store.add_limit_sample(con, "claude", mins, w["pct"], w.get("resets"))
    if cx and "Codex" not in errors and not cx.get("_from_app"):
        for mins, w in (cx.get("windows") or {}).items():
            if w.get("pct") is not None:
                store.add_limit_sample(con, "codex", int(mins), w["pct"], w.get("resets"))
    store.prune_limits(con)
    con.commit()
    return cc, cx, stale, errors


def _codex_windows(cx):
    wins = cx.get("windows") or {}
    order = [300, 10080] + sorted(k for k in wins if k not in (300, 10080))
    return [(k, wins[k]) for k in order if wins.get(k)]


def render():
    con = store.connect()
    from . import ingest
    try:
        ingest.ingest_all(con, max_bytes=300 * 1024 * 1024)
    except Exception:
        pass                                    # brak statystyk nie może wyłączyć paska

    cc, cx, stale, errors = _fetch(con)
    today = store.day_start()
    try:
        tot_today = store.totals(con, since=today)
        tot_week = store.totals(con, since=store.day_start(6))
        tot_all = store.totals(con)
    except Exception as exc:                    # baza niedostępna -> pasek pokazuje same limity
        tot_today = tot_week = tot_all = {}
        errors["Statystyki"] = str(exc) or exc.__class__.__name__
    out = []

    # ---------------------------------------------------------------- pasek
    def segment(name, tokens_today, windows):
        cells = [c for c in (_cell(_refresh(w)) for w in windows) if c]
        bits = [name, fmt.tokens(tokens_today)] if tokens_today else [name]
        return " · ".join([" ".join(bits)] + cells) if cells else " ".join(bits) + " ✕"

    parts = []
    if cc:
        parts.append(segment("ClaudeCode", tot_today.get("claude", {}).get("total", 0),
                             [cc.get("five_hour"), cc.get("seven_day")]))
    else:
        parts.append("ClaudeCode ✕")
    if cx:
        parts.append(segment("Codex", tot_today.get("codex", {}).get("total", 0),
                             [w for _, w in _codex_windows(cx)]))
    else:
        parts.append("Codex ✕")

    title = " ┃ ".join(parts)
    if errors:
        title += " ?"
    out.append(title + "| " + MONO)
    out.append("---")

    # ------------------------------------------------------------- ClaudeCode
    if cc:
        out.append("ClaudeCode · plan %s| %s" % (cc.get("plan"), MONO))
        _limit_rows(out, [("Sesja 5h", cc.get("five_hour")), ("Tydzień", cc.get("seven_day"))] +
                    [("Tydzień · " + (w.get("label") or "model"), w) for w in cc.get("scoped") or []])
        _token_rows(out, tot_today.get("claude"), tot_week.get("claude"), tot_all.get("claude"))
    if "Statystyki" in errors:
        out.append("Statystyki niedostępne: %s| color=#e34948 %s" % (errors["Statystyki"][:80], MONO))
    if "ClaudeCode" in errors:
        out.append("ClaudeCode: błąd odczytu| color=#e34948 %s" % MONO)
        out.append("--%s| %s" % (errors["ClaudeCode"][:120], MONO))
    _thread_rows(out, con, "claude", today)
    out.append("---")

    # ------------------------------------------------------------------ Codex
    if cx:
        out.append("Codex · plan %s| %s" % (cx.get("plan"), MONO))
        _limit_rows(out, [("Okno " + fmt.window_name(mins), w) for mins, w in _codex_windows(cx)])
        _token_rows(out, tot_today.get("codex"), tot_week.get("codex"), tot_all.get("codex"))
    if "Codex" in errors:
        out.append("Codex: błąd odczytu| color=#e34948 %s" % MONO)
        out.append("--%s| %s" % (errors["Codex"][:120], MONO))
    _thread_rows(out, con, "codex", today)
    out.append("---")

    if stale:
        out.append("Dane z cache: %s| color=#eb6834 %s" % (", ".join(stale), MONO))
    out.append("Pełny dashboard (24 h, wątki, wykresy) | bash=\"%s\" terminal=false refresh=false" % DASHBOARD_BIN)
    out.append("Odśwież teraz | refresh=true")
    out.append("Odświeżono %s| %s" % (datetime.now().strftime("%H:%M:%S"), MONO))
    return "\n".join(out)


def _limit_rows(out, rows):
    for name, win in rows:
        win = _refresh(win)
        if not win:
            continue
        out.append("--%-17s %4s   reset za %-7s %s| %s%s" % (
            name, fmt.pct(win.get("pct")), fmt.left(win.get("left")),
            fmt.when(win.get("resets")), MONO, _color(win.get("pct"))))


def _token_rows(out, today, week, alltime):
    today = today or {}
    out.append("--%-17s %s| %s" % ("Tokeny dziś", fmt.tokens(today.get("total", 0)), MONO))
    out.append("----wejście %s · wyjście %s| %s" % (
        fmt.tokens_full(today.get("input", 0)), fmt.tokens_full(today.get("output", 0)), MONO))
    out.append("----cache odczyt %s · zapis %s| %s" % (
        fmt.tokens_full(today.get("cache_read", 0)), fmt.tokens_full(today.get("cache_write", 0)), MONO))
    out.append("--%-17s %s| %s" % ("Tokeny 7 dni", fmt.tokens((week or {}).get("total", 0)), MONO))
    out.append("--%-17s %s| %s" % ("Tokeny łącznie", fmt.tokens((alltime or {}).get("total", 0)), MONO))


def _thread_rows(out, con, app, since):
    try:
        rows = store.threads(con, since=since, app=app, limit=THREADS_IN_MENU)
    except Exception:
        return
    if not rows:
        return
    out.append("--Wątki dziś:| %s" % MONO)
    for r in rows:
        label = (r.get("title") or "bez tytułu").replace("|", "/")
        if len(label) > 42:
            label = label[:41] + "…"
        out.append("--  %7s  %-14s %s| %s" % (
            fmt.tokens(r["total"]), fmt.project(r.get("cwd"))[:14], label, MONO))

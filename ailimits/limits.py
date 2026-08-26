# -*- coding: utf-8 -*-
"""Odczyt bieżącego wykorzystania limitów – Claude Code i Codex."""

import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime

CODEX_BIN = os.path.expanduser("~/.local/bin/codex")


def claude_limits():
    """Endpoint OAuth Claude Code. Token bierzemy z Keychaina, nigdy go nie zapisujemy."""
    tok = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
        capture_output=True, text=True, timeout=10,
    )
    if tok.returncode != 0:
        raise RuntimeError("brak dostępu do Keychaina")
    creds = json.loads(tok.stdout)["claudeAiOauth"]
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": "Bearer " + creds["accessToken"],
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            raise RuntimeError("token wygasł – uruchom Claude Code, odświeży go sam")
        raise

    if not data.get("five_hour") and not data.get("seven_day"):
        raise RuntimeError("odpowiedź bez danych o limitach")

    now = time.time()

    def window(node):
        if not node:
            return None
        resets = node.get("resets_at")
        epoch = datetime.fromisoformat(resets).timestamp() if resets else None
        return {
            "pct": node.get("utilization", node.get("percent")),
            "resets": epoch,
            "left": (epoch - now) if epoch else None,
            "severity": node.get("severity"),
        }

    out = {
        "plan": creds.get("subscriptionType"),
        "tier": creds.get("rateLimitTier"),
        "five_hour": window(data.get("five_hour")),
        "seven_day": window(data.get("seven_day")),
        "scoped": [],
        "extra": data.get("extra_usage") or {},
    }
    for row in data.get("limits") or []:
        if row.get("kind") == "weekly_scoped":
            w = window(row)
            model = (row.get("scope") or {}).get("model") or {}
            w["label"] = model.get("display_name") or "model"
            out["scoped"].append(w)
    return out


def codex_limits():
    """`codex app-server` -> account/rateLimits/read. Proces ubijamy po odczycie."""
    exe = CODEX_BIN if os.path.exists(CODEX_BIN) else "codex"
    proc = subprocess.Popen(
        [exe, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, bufsize=1,
    )
    result, done = {}, threading.Event()

    def reader():
        for line in proc.stdout:
            try:
                msg = json.loads(line)
            except Exception:
                continue
            if msg.get("id") == 2:
                result.update(msg.get("result") or {})
                done.set()
                return

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    try:
        threading.Thread(target=reader, daemon=True).start()
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"clientInfo": {"name": "ai-limits", "title": "AI limits", "version": "1.0.0"}}})
        send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
        send({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": {}})
        if not done.wait(20):
            raise RuntimeError("app-server nie odpowiedział")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    rl = result.get("rateLimits") or {}
    now = time.time()
    windows = {}
    for node in (rl.get("primary"), rl.get("secondary")):
        if not node:
            continue
        epoch = node.get("resetsAt")
        windows[node.get("windowDurationMins")] = {
            "pct": node.get("usedPercent"),
            "resets": epoch,
            "left": (epoch - now) if epoch else None,
        }
    if not windows:
        raise RuntimeError("app-server nie zwrócił limitów")
    return {
        "plan": rl.get("planType"),
        "windows": windows,
        "credits": rl.get("credits") or {},
        "reached": rl.get("rateLimitReachedType"),
    }

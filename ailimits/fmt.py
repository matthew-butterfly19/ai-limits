# -*- coding: utf-8 -*-
"""Formatowanie liczb i czasu – wspólne dla paska i dashboardu."""

from datetime import datetime

WINDOW_NAME = {60: "1h", 300: "5h", 1440: "24h", 10080: "7d", 43200: "30d"}


def window_name(mins):
    if mins in WINDOW_NAME:
        return WINDOW_NAME[mins]
    return "%dmin" % mins if mins else "?"


def tokens(n):
    """1234567 -> '1.2M'. Skrótowo, bo to ma się zmieścić w pasku menu."""
    n = int(n or 0)
    if n >= 1_000_000_000:
        return "%.1fB" % (n / 1_000_000_000)
    if n >= 1_000_000:
        return "%.0fM" % (n / 1_000_000) if n >= 10_000_000 else "%.1fM" % (n / 1_000_000)
    if n >= 1_000:
        return "%.0fk" % (n / 1_000)
    return str(n)


def tokens_full(n):
    return "{:,}".format(int(n or 0)).replace(",", " ")


def left(seconds):
    if seconds is None:
        return "?"
    s = int(seconds)
    if s <= 0:
        return "teraz"
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m = s // 60
    if d:
        return "%dd%dh" % (d, h)
    if h:
        return "%dh%02dm" % (h, m)
    return "%dm" % m


def when(epoch):
    if not epoch:
        return ""
    t = datetime.fromtimestamp(epoch)
    if t.date() == datetime.now().date():
        return t.strftime("dziś %H:%M")
    return t.strftime("%d.%m %H:%M")


DAYS = ["poniedziałek", "wtorek", "środa", "czwartek", "piątek", "sobota", "niedziela"]


def day_hour(dt):
    """'Wtorek 15:00' – strftime('%A') dałoby angielski, bo locale jest C."""
    return "%s %s" % (DAYS[dt.weekday()].capitalize(), dt.strftime("%H:00"))


def pct(value):
    return "—" if value is None else "%d%%" % round(value)


def project(cwd):
    """Katalog roboczy -> czytelna nazwa projektu."""
    if not cwd:
        return "—"
    base = cwd.rstrip("/").split("/")
    return base[-1] if base else cwd

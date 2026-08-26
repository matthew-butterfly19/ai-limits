# -*- coding: utf-8 -*-
"""Pełny dashboard: kafle, dwa wykresy 24 h i tabela wątków. Jeden plik HTML."""

import html
import json
import os
import time
from datetime import datetime, timedelta

from . import charts, fmt, store

APPS = [("claude", "ClaudeCode", "--series-1"), ("codex", "Codex", "--series-2")]
OUT_PATH = os.path.join(store.DATA_DIR, "dashboard.html")

CSS = """
:root {
  color-scheme: light;
  --bg: #f4f3f0; --surface-1: #fcfcfb; --border: #e6e5e1;
  --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #86847d;
  --series-1: #2a78d6; --series-2: #eb6834;
  --grid: #e6e5e1; --warn: #eb6834; --crit: #e34948; --ok: #1baf7a;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --bg: #121211; --surface-1: #1a1a19; --border: #2e2e2c;
    --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #8d8b82;
    --series-1: #3987e5; --series-2: #d95926;
    --grid: #2e2e2c; --warn: #d95926; --crit: #e66767; --ok: #199e70;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 28px 24px 64px; background: var(--bg); color: var(--text-primary);
  font: 15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", Helvetica, sans-serif;
}
.wrap { max-width: 1100px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 4px; letter-spacing: -0.01em; }
h2 { font-size: 15px; margin: 34px 0 10px; letter-spacing: 0.02em; text-transform: uppercase;
     color: var(--text-secondary); font-weight: 600; }
.sub { color: var(--text-secondary); font-size: 13px; margin: 0 0 22px; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 12px; }
.tile { background: var(--surface-1); border: 1px solid var(--border); border-radius: 12px; padding: 16px 18px; }
.tile .name { display: flex; align-items: center; gap: 8px; font-size: 13px; color: var(--text-secondary); }
.swatch { width: 10px; height: 10px; border-radius: 3px; display: inline-block; }
.hero { font-size: 32px; font-weight: 650; letter-spacing: -0.02em; margin: 6px 0 2px;
        font-variant-numeric: tabular-nums; }
.split { color: var(--text-muted); font-size: 12px; font-variant-numeric: tabular-nums; }
.split b { color: var(--text-secondary); font-weight: 600; }
.meter { height: 6px; border-radius: 3px; background: var(--grid); margin: 10px 0 6px; overflow: hidden; }
.meter i { display: block; height: 100%; border-radius: 3px; }
.card { background: var(--surface-1); border: 1px solid var(--border); border-radius: 12px;
        padding: 14px 16px 6px; overflow-x: auto; position: relative; }
.chart { width: 100%; height: auto; display: block; }
.grid { stroke: var(--grid); stroke-width: 1; }
.axis-line { stroke: var(--border); stroke-width: 1; }
.axis { fill: var(--text-muted); font-size: 11px; font-family: ui-monospace, Menlo, monospace; }
.direct { font-size: 11px; font-family: ui-monospace, Menlo, monospace; font-weight: 600; }
.line { fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
.hit { fill: transparent; }
.hit:hover { fill: var(--grid); fill-opacity: 0.45; }
.legend { display: flex; flex-wrap: wrap; gap: 14px; margin: 2px 0 12px; font-size: 12px;
          color: var(--text-secondary); }
.legend span { display: inline-flex; align-items: center; gap: 6px; }
.legend .dash { width: 16px; height: 0; border-top: 2px dashed currentColor; }
.legend .solid { width: 16px; height: 0; border-top: 2px solid currentColor; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th { text-align: left; font-weight: 600; color: var(--text-secondary); font-size: 11px;
     text-transform: uppercase; letter-spacing: 0.04em; padding: 8px 10px; border-bottom: 1px solid var(--border); }
td { padding: 9px 10px; border-bottom: 1px solid var(--border); vertical-align: top; }
tr:last-child td { border-bottom: 0; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums;
                 font-family: ui-monospace, Menlo, monospace; }
.badge { display: inline-block; padding: 1px 7px; border-radius: 999px; font-size: 11px;
         font-weight: 600; color: #fff; }
.mono { font-family: ui-monospace, Menlo, monospace; font-size: 12px; }
.title-cell { max-width: 380px; }
.dim { color: var(--text-muted); }
details { margin-top: 6px; }
details summary { cursor: pointer; color: var(--text-secondary); font-size: 12px; }
details .inner { margin-top: 8px; }
.note { color: var(--text-muted); font-size: 12px; margin-top: 10px; }
#tip { position: fixed; pointer-events: none; opacity: 0; transition: opacity .08s;
       background: var(--surface-1); border: 1px solid var(--border); border-radius: 8px;
       padding: 8px 10px; font-size: 12px; box-shadow: 0 6px 24px rgba(0,0,0,.18); z-index: 10;
       font-variant-numeric: tabular-nums; }
#tip .row { display: flex; gap: 10px; justify-content: space-between; }
#tip .head { font-weight: 600; margin-bottom: 4px; }
"""

JS = """
const tip = document.getElementById('tip');
function showTip(html, ev) {
  tip.innerHTML = html; tip.style.opacity = 1;
  const w = tip.offsetWidth, h = tip.offsetHeight;
  let x = ev.clientX + 14, y = ev.clientY - h - 10;
  if (x + w > window.innerWidth - 8) x = ev.clientX - w - 14;
  if (y < 8) y = ev.clientY + 16;
  tip.style.left = x + 'px'; tip.style.top = y + 'px';
}
function hideTip() { tip.style.opacity = 0; }

document.querySelectorAll('[data-hover]').forEach(card => {
  const data = JSON.parse(document.getElementById(card.dataset.hover).textContent);
  card.querySelectorAll('.hit').forEach(hit => {
    hit.addEventListener('mousemove', ev => {
      const d = data[+hit.dataset.i];
      if (!d) return;
      let h = '<div class="head">' + d.label + '</div>';
      d.rows.forEach(r => {
        h += '<div class="row"><span><span class="swatch" style="background:' + r.color +
             '"></span> ' + r.name + '</span><b>' + r.value + '</b></div>';
      });
      showTip(h, ev);
    });
    hit.addEventListener('mouseleave', hideTip);
  });
});
"""


def _tile(name, color_var, today, week, alltime, limits_html):
    today = today or {}
    return (
        '<div class="tile">'
        '<div class="name"><span class="swatch" style="background:var(%s)"></span>%s</div>'
        '<div class="hero">%s</div>'
        '<div class="split">dziś · wyjście <b>%s</b> · wejście <b>%s</b><br>'
        'cache odczyt <b>%s</b> · zapis <b>%s</b></div>'
        '%s'
        '<div class="split" style="margin-top:10px">7 dni <b>%s</b> &nbsp;·&nbsp; łącznie <b>%s</b> '
        '&nbsp;·&nbsp; wątków dziś <b>%d</b></div>'
        '</div>'
    ) % (color_var, html.escape(name), fmt.tokens(today.get("total", 0)),
         fmt.tokens(today.get("output", 0)), fmt.tokens(today.get("input", 0)),
         fmt.tokens(today.get("cache_read", 0)), fmt.tokens(today.get("cache_write", 0)),
         limits_html,
         fmt.tokens((week or {}).get("total", 0)), fmt.tokens((alltime or {}).get("total", 0)),
         today.get("sessions", 0))


def _meters(con, app):
    """Ostatnia znana wartość każdego okna limitu – pasek + podpis."""
    # tylko okna widziane niedawno – stare próbki (inny plan, inny zestaw okien) wprowadzałyby w błąd
    rows = con.execute(
        "SELECT window_mins, pct, resets_at, MAX(ts) ts FROM limit_samples "
        "WHERE app = ? AND ts > ? GROUP BY window_mins ORDER BY window_mins",
        (app, time.time() - 6 * 3600)
    ).fetchall()
    if not rows:
        return ""
    out = []
    for r in rows:
        p = r["pct"] or 0
        color = "var(--crit)" if p >= 90 else ("var(--warn)" if p >= 70 else "var(--ok)")
        resets = r["resets_at"]
        left = fmt.left(resets - time.time()) if resets else "?"
        out.append(
            '<div class="split" style="margin-top:10px">okno %s — <b>%d%%</b>, reset za %s</div>'
            '<div class="meter"><i style="width:%.1f%%;background:%s"></i></div>'
            % (fmt.window_name(r["window_mins"]), round(p), left, min(p, 100), color)
        )
    return "".join(out)


def _hourly_chart(con):
    now = datetime.now().replace(minute=0, second=0, microsecond=0)
    hours = [now - timedelta(hours=23 - i) for i in range(24)]
    since = hours[0].timestamp()
    data = store.hourly(con, since)
    series, hover_rows = [], []
    per_app = {}
    for app, label, var in APPS:
        values = [data.get((app, h.timestamp()), {}).get("total", 0) for h in hours]
        per_app[app] = values
        series.append((label, var, values))
    for i, h in enumerate(hours):
        rows = []
        for app, label, var in APPS:
            v = per_app[app][i]
            if v:
                rows.append({"name": label, "value": fmt.tokens_full(v),
                             "color": "var(%s)" % var})
        if not rows:
            rows = [{"name": "brak ruchu", "value": "0", "color": "var(--grid)"}]
        hover_rows.append({"label": fmt.day_hour(h), "rows": rows})
    labels = [h.strftime("%H") for h in hours]
    svg, hover = charts.bars(series, labels, hover_rows, "Tokeny na godzinę, ostatnie 24 h")
    total = sum(sum(v) for v in per_app.values())
    return svg, hover, total, hours


def _limits_chart(con, hours):
    since = hours[0].timestamp()
    rows = store.limit_history(con, since)
    grouped = {}
    for r in rows:
        grouped.setdefault((r["app"], r["window_mins"]), []).append((r["ts"], r["pct"]))
    series, legend = [], []
    style = {300: ("solid", "0"), 10080: ("dash", "5 4"), 43200: ("dot", "2 4")}
    for app, label, var in APPS:
        for mins in sorted({k[1] for k in grouped if k[0] == app}):
            pts = sorted(grouped[(app, mins)])
            if len(pts) < 2:
                continue
            kind, dash = style.get(mins, ("dash", "5 4"))
            name = "%s · %s" % (label, fmt.window_name(mins))
            series.append((name, var, dash, pts))
            legend.append('<span style="color:var(%s)"><i class="%s"></i>&nbsp;<span style="color:var(--text-secondary)">%s</span></span>'
                          % (var, "solid" if kind == "solid" else "dash", html.escape(name)))
    if not series:
        return None, "", "[]"

    # warstwa hoveru: 48 półgodzinnych slotów, w każdym ostatnia znana wartość każdej serii
    slots = 48
    now = time.time()
    step = (now - since) / slots
    hover = []
    for i in range(slots):
        t_end = since + step * (i + 1)
        rows = []
        for name, var, dash, pts in series:
            val = None
            for ts, pv in pts:
                if ts <= t_end:
                    val = (ts, pv)
                else:
                    break
            if val and (t_end - val[0]) < 3600:
                rows.append({"name": name, "value": "%d%%" % round(val[1]), "color": "var(%s)" % var})
        hover.append({"label": datetime.fromtimestamp(since + step * i).strftime("%d.%m %H:%M"),
                      "rows": rows or [{"name": "brak próbek", "value": "—", "color": "var(--grid)"}]})

    xs = [since, now]
    svg = charts.lines(series, xs, "Wykorzystanie limitów, ostatnie 24 h", hit_slots=slots)
    return svg, "".join(legend), json.dumps(hover)


def _threads_table(con, since, limit=40):
    rows = store.threads(con, since=since, limit=limit)
    if not rows:
        return '<div class="card" style="padding:16px"><span class="dim">Brak ruchu w tym oknie.</span></div>'
    out = ['<div class="card"><table><thead><tr>'
           '<th>Aplikacja</th><th>Projekt</th><th>Wątek</th>'
           '<th class="num">Tokeny</th><th class="num">Wyjście</th><th class="num">Cache</th>'
           '<th class="num">Subagenci</th><th class="num">Aktywny</th>'
           '</tr></thead><tbody>']
    colors = {"claude": "--series-1", "codex": "--series-2"}
    names = {"claude": "ClaudeCode", "codex": "Codex"}
    for r in rows:
        sub = (r["sub"] / r["total"] * 100) if r["total"] else 0
        t0 = datetime.fromtimestamp(r["t0"]).strftime("%d.%m %H:%M")
        t1 = datetime.fromtimestamp(r["t1"]).strftime("%H:%M")
        title = html.escape((r.get("title") or "bez tytułu"))
        out.append(
            '<tr><td><span class="badge" style="background:var(%s)">%s</span></td>'
            '<td class="mono">%s</td>'
            '<td class="title-cell">%s<details><summary>szczegóły</summary><div class="inner split">'
            'wejście %s · wyjście %s · cache odczyt %s · zapis %s<br>'
            'zdarzeń %d · id <span class="mono">%s</span><br>katalog <span class="mono">%s</span>'
            '</div></details></td>'
            '<td class="num">%s</td><td class="num">%s</td><td class="num">%s</td>'
            '<td class="num">%s</td><td class="num">%s–%s</td></tr>'
            % (colors[r["app"]], names[r["app"]], html.escape(fmt.project(r.get("cwd"))), title,
               fmt.tokens_full(r["i"]), fmt.tokens_full(r["o"]),
               fmt.tokens_full(r["cr"]), fmt.tokens_full(r["cw"]),
               r["n"], html.escape((r["session_id"] or "")[:8]),
               html.escape(r.get("cwd") or "—"),
               fmt.tokens(r["total"]), fmt.tokens(r["o"]), fmt.tokens(r["cr"] + r["cw"]),
               ("%.0f%%" % sub) if sub else "—", t0, t1))
    out.append("</tbody></table></div>")
    return "".join(out)


def build():
    con = store.connect()
    today = store.day_start()
    tot_today = store.totals(con, since=today)
    tot_week = store.totals(con, since=store.day_start(6))
    tot_all = store.totals(con)

    svg_bars, hover_json, total_24h, hours = _hourly_chart(con)
    svg_lines, legend, hover_lines = _limits_chart(con, hours)

    first = con.execute("SELECT MIN(ts) t FROM usage_events").fetchone()["t"]
    first_limit = con.execute("SELECT MIN(ts) t FROM limit_samples").fetchone()["t"]

    tiles = "".join(
        _tile(label, var, tot_today.get(app), tot_week.get(app), tot_all.get(app), _meters(con, app))
        for app, label, var in APPS
    )

    body = ['<div class="wrap">']
    body.append("<h1>Zużycie tokenów i limitów</h1>")
    body.append('<p class="sub">Claude Code i Codex · dane z lokalnych logów, stan na %s · '
                'historia od %s</p>' % (datetime.now().strftime("%d.%m.%Y %H:%M"),
                                        datetime.fromtimestamp(first).strftime("%d.%m.%Y") if first else "—"))
    body.append('<div class="tiles">%s</div>' % tiles)

    body.append("<h2>Tokeny na godzinę · ostatnie 24 h</h2>")
    body.append('<div class="legend">%s</div>' % "".join(
        '<span><span class="swatch" style="background:var(%s)"></span>%s</span>' % (var, label)
        for _, label, var in APPS))
    body.append('<div class="card" data-hover="hover-bars">%s</div>' % svg_bars)
    body.append('<script type="application/json" id="hover-bars">%s</script>' % hover_json)
    body.append('<p class="note">Łącznie w tym oknie: <b>%s</b> tokenów. Godziny lokalne.</p>' % fmt.tokens(total_24h))

    body.append("<h2>Wykorzystanie limitów · ostatnie 24 h</h2>")
    if svg_lines:
        body.append('<div class="legend">%s</div>' % legend)
        body.append('<div class="card" data-hover="hover-lines">%s</div>' % svg_lines)
        body.append('<script type="application/json" id="hover-lines">%s</script>' % hover_lines)
        body.append('<p class="note">Kolor = aplikacja, linia ciągła = okno 5 h, przerywana = tygodniowe. '
                    'Próbki Codeksa odtworzone z logów sesji, próbki Claude Code zbierane od %s.</p>'
                    % (datetime.fromtimestamp(first_limit).strftime("%d.%m %H:%M") if first_limit else "—"))
    else:
        body.append('<div class="card" style="padding:16px"><span class="dim">'
                    'Za mało próbek – wykres pojawi się po kilku odświeżeniach widgetu.</span></div>')

    body.append("<h2>Wątki · ostatnie 24 h</h2>")
    body.append(_threads_table(con, since=time.time() - 24 * 3600))

    body.append("<h2>Wątki · ostatnie 7 dni</h2>")
    body.append(_threads_table(con, since=store.day_start(6), limit=25))

    body.append('<p class="note">Tokeny liczone z lokalnych transkryptów: jedna odpowiedź modelu = jedno '
                'zdarzenie. Claude Code zapisuje wieloblokową odpowiedź (myślenie + wywołania narzędzi) '
                'w kilku liniach z tym samym <span class="mono">message.id</span> i tym samym licznikiem '
                'zużycia — deduplikujemy je po (message.id, requestId), więc te liczby są niższe niż to, '
                'co pokazuje <span class="mono">/stats</span> w Claude Code, które sumuje każdą linię.</p>')
    body.append("</div>")
    body.append('<div id="tip"></div>')

    return ("<!doctype html><html lang=\"pl\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<title>Zużycie tokenów — ClaudeCode i Codex</title>"
            "<style>%s</style></head><body>%s<script>%s</script></body></html>"
            % (CSS, "".join(body), JS))


def write(path=None):
    path = path or OUT_PATH
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(build())
    return path

# -*- coding: utf-8 -*-
"""Wykresy SVG budowane po stronie Pythona – bez zewnętrznych bibliotek."""

import html
import json
from datetime import datetime, timedelta

from . import fmt

W, H = 1040, 300
PAD_L, PAD_R, PAD_T, PAD_B = 62, 16, 18, 34


def _nice_max(value):
    if value <= 0:
        return 1
    import math
    exp = math.floor(math.log10(value))
    base = 10 ** exp
    for mult in (1, 1.5, 2, 2.5, 3, 4, 5, 7.5, 10):
        if value <= mult * base:
            return mult * base
    return 10 * base


def _y_ticks(top, count=4):
    return [top * i / count for i in range(count + 1)]


def bars(series, labels, hover, title, y_fmt=fmt.tokens):
    """Słupki skumulowane: series = [(nazwa, kolor_css_var, [wartości])]."""
    plot_w = W - PAD_L - PAD_R
    plot_h = H - PAD_T - PAD_B
    n = len(labels)
    totals = [sum(s[2][i] for s in series) for i in range(n)]
    top = _nice_max(max(totals) if totals else 0)
    group = plot_w / max(n, 1)
    bw = min(group * 0.62, 28)

    svg = ['<svg class="chart" viewBox="0 0 %d %d" role="img" aria-label="%s">' % (W, H, html.escape(title))]
    for t in _y_ticks(top):
        y = PAD_T + plot_h - (t / top) * plot_h
        svg.append('<line class="grid" x1="%d" y1="%.1f" x2="%d" y2="%.1f"/>' % (PAD_L, y, W - PAD_R, y))
        svg.append('<text class="axis" x="%d" y="%.1f" text-anchor="end">%s</text>' % (PAD_L - 8, y + 4, y_fmt(t)))

    for i, label in enumerate(labels):
        x = PAD_L + group * i + (group - bw) / 2
        base = PAD_T + plot_h
        stack = []
        for name, var, values in series:
            v = values[i]
            if v <= 0:
                continue
            h = (v / top) * plot_h
            stack.append((name, var, v, h))
        acc = 0
        for j, (name, var, v, h) in enumerate(stack):
            y = base - acc - h
            gap = 2 if j < len(stack) - 1 else 0     # 2px przerwy między segmentami
            radius = 4 if j == len(stack) - 1 else 0
            svg.append(
                '<path class="bar" fill="var(%s)" d="%s"/>' % (var, _round_top(x, y + gap, bw, max(h - gap, 0.5), radius))
            )
            acc += h
        if i % 3 == 0:
            svg.append('<text class="axis" x="%.1f" y="%d" text-anchor="middle">%s</text>'
                       % (x + bw / 2, H - 10, label))
        svg.append('<rect class="hit" x="%.1f" y="%d" width="%.1f" height="%d" data-i="%d"/>'
                   % (PAD_L + group * i, PAD_T, group, plot_h, i))
    svg.append('<line class="axis-line" x1="%d" y1="%d" x2="%d" y2="%d"/>'
               % (PAD_L, PAD_T + plot_h, W - PAD_R, PAD_T + plot_h))
    svg.append('</svg>')
    return "".join(svg), json.dumps(hover)


def _round_top(x, y, w, h, r):
    if r <= 0 or h < r:
        return "M%.1f %.1f h%.1f v%.1f h-%.1f Z" % (x, y, w, h, w)
    return ("M%.1f %.1f h%.1f a%d %d 0 0 1 %d %d v%.1f h-%.1f v-%.1f a%d %d 0 0 1 %d -%d Z"
            % (x + r, y, w - 2 * r, r, r, r, r, h - r, w, h - r, r, r, r, r))


def lines(series, x_values, title, max_gap=1800, hit_slots=0):
    """Wykres liniowy 0–100%: series = [(nazwa, kolor_css_var, dash, [(x, y)])].

    Przerwa w próbkowaniu dłuższa niż `max_gap` przerywa linię – inaczej wykres
    rysowałby ukośną „interpolację” przez godziny, w których nic nie mierzyliśmy.
    """
    plot_w = W - PAD_L - PAD_R
    plot_h = H - PAD_T - PAD_B
    x0, x1 = x_values[0], x_values[-1]
    span = max(x1 - x0, 1)

    def px(x):
        return PAD_L + (x - x0) / span * plot_w

    def py(v):
        return PAD_T + plot_h - (min(v, 100) / 100.0) * plot_h

    svg = ['<svg class="chart" viewBox="0 0 %d %d" role="img" aria-label="%s">' % (W, H, html.escape(title))]
    for t in (0, 25, 50, 75, 100):
        y = py(t)
        svg.append('<line class="grid" x1="%d" y1="%.1f" x2="%d" y2="%.1f"/>' % (PAD_L, y, W - PAD_R, y))
        svg.append('<text class="axis" x="%d" y="%.1f" text-anchor="end">%d%%</text>' % (PAD_L - 8, y + 4, t))

    labels = []
    for name, var, dash, points in series:
        if not points:
            continue
        d, prev_x = [], None
        for x, y in points:
            cmd = "M" if prev_x is None or (x - prev_x) > max_gap else "L"
            d.append("%s%.1f %.1f" % (cmd, px(x), py(y)))
            prev_x = x
        svg.append('<path class="line" stroke="var(%s)" stroke-dasharray="%s" d="%s"/>'
                   % (var, dash, " ".join(d)))
        lx, ly = px(points[-1][0]), py(points[-1][1])
        svg.append('<circle class="dot" cx="%.1f" cy="%.1f" r="4" fill="var(%s)"/>' % (lx, ly, var))
        labels.append([ly, lx, var, round(points[-1][1])])

    # etykiety końcowe rozsuwane w pionie, żeby się nie nakładały
    labels.sort()
    for i in range(1, len(labels)):
        if labels[i][0] - labels[i - 1][0] < 14:
            labels[i][0] = labels[i - 1][0] + 14
    for ly, lx, var, value in labels:
        svg.append('<text class="direct" x="%.1f" y="%.1f" fill="var(%s)">%d%%</text>'
                   % (min(lx + 9, W - PAD_R - 34), ly + 4, var, value))

    step = max(len(x_values) // 8, 1)
    for i in range(0, len(x_values), step):
        t = x_values[i]
        svg.append('<text class="axis" x="%.1f" y="%d" text-anchor="middle">%s</text>'
                   % (px(t), H - 10, datetime.fromtimestamp(t).strftime("%H:%M")))
    for i in range(hit_slots):
        x = PAD_L + plot_w * i / hit_slots
        svg.append('<rect class="hit" x="%.1f" y="%d" width="%.1f" height="%d" data-i="%d"/>'
                   % (x, PAD_T, plot_w / hit_slots, plot_h, i))
    svg.append('<line class="axis-line" x1="%d" y1="%d" x2="%d" y2="%d"/>'
               % (PAD_L, PAD_T + plot_h, W - PAD_R, PAD_T + plot_h))
    svg.append('</svg>')
    return "".join(svg)

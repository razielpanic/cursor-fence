"""Score a Cursor Fence trace.csv window by window.

A window starts at each "activate <app>" mark. For every motion event that
followed a disassociated one, it asks where the cursor went: if the event's
location is where the app last put the cursor, the disassociation and warp
held; if not, the mouse moved the cursor anyway (a slip). Breaches are
events that reached the zone while the app believed it was not driving.

    python3 scripts/trace-windows.py trace.csv
"""
import csv
import sys

MOTION = {"5", "6", "7", "27"}
rows = list(csv.DictReader(open(sys.argv[1])))
f = lambda r, k: float(r[k])

windows = [{"app": "(before first mark)", "t": 0.0, "held": 0, "slip": 0, "clicks": 0, "events": 0}]
prev = None
for r in rows:
    if not r["type"]:
        windows.append({"app": r["mark"].removeprefix("activate "), "t": f(r, "t_ms") / 1000,
                        "held": 0, "slip": 0, "clicks": 0, "events": 0})
        prev = None
        continue
    w = windows[-1]
    if r["type"] not in MOTION:
        w["clicks"] += r["type"] in ("1", "3")
        prev = None
        continue
    w["events"] += 1
    if prev is not None and prev["dis"] == "1":
        held = abs(f(r, "loc_x") - f(prev, "pos_x")) < 2 and abs(f(r, "loc_y") - f(prev, "pos_y")) < 2
        w["held" if held else "slip"] += 1
    prev = r

print(f"{'t (s)':>8}  {'front app':<22}{'events':>7}{'driven':>8}{'held':>6}{'slip':>6}{'held %':>8}{'clicks':>7}")
for w in windows:
    d = w["held"] + w["slip"]
    if not w["events"]:
        continue
    pct = f"{100 * w['held'] / d:.0f}" if d else "-"
    print(f"{w['t']:8.1f}  {w['app']:<22}{w['events']:>7}{d:>8}{w['held']:>6}{w['slip']:>6}{pct:>8}{w['clicks']:>7}")

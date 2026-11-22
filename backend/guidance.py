"""Check management guidance against reported numbers.

All supported metrics are "higher is better", so guidance counts as met when
the actual figure reaches the lower bound (or the single target) minus a small
tolerance. Beating the upper end of a range still counts as met. Metrics marked
"other" stay pending, since they can't be checked automatically.
"""
from __future__ import annotations

import re
from typing import Dict, List, Optional, Tuple

from xbrl import pct_change

TOLERANCE = {"revenue_growth_yoy": 1.0, "pat_growth_yoy": 2.0,
             "ebitda_margin": 0.5, "revenue": 0.0}


def _by_period(quarters: List[Dict]) -> Dict[str, Dict]:
    return {q["period"]: q for q in quarters}


def _fy_totals(quarters: List[Dict], fy: int) -> Optional[Dict[str, float]]:
    qs = _by_period(quarters)
    rows = [qs.get(f"Q{i}FY{fy % 100:02d}") for i in range(1, 5)]
    if any(r is None or r.get("revenue") is None for r in rows):
        return None
    tot = {"revenue": sum(r["revenue"] for r in rows)}
    for k in ("ebitda", "pat"):
        vals = [r.get(k) for r in rows]
        tot[k] = sum(vals) if all(v is not None for v in vals) else None
    return tot


def _prev_quarter_label(label: str) -> str:
    """Same quarter one year earlier: Q2FY27 -> Q2FY26."""
    q, fy = label[:2], int(label[4:])
    return f"{q}FY{fy - 1:02d}"


def actual_value(metric: str, target_period: str, quarters: List[Dict]) -> Optional[float]:
    tp = target_period.strip().upper()
    if re.fullmatch(r"Q[1-4]FY\d{2}", tp):
        qs = _by_period(quarters)
        now, ago = qs.get(tp), qs.get(_prev_quarter_label(tp))
        if now is None:
            return None
        cur: Dict = now
        prev: Optional[Dict] = ago
    elif re.fullmatch(r"FY\d{2}", tp):
        fy = 2000 + int(tp[2:])
        cur = _fy_totals(quarters, fy)
        if cur is None:
            return None
        prev = _fy_totals(quarters, fy - 1)
    else:
        return None

    if metric == "revenue":
        return cur.get("revenue")
    if metric == "ebitda_margin":
        if cur.get("ebitda") is None or not cur.get("revenue"):
            return None
        return round(cur["ebitda"] / cur["revenue"] * 100, 2)
    if metric == "revenue_growth_yoy":
        return pct_change(cur.get("revenue"), (prev or {}).get("revenue"))
    if metric == "pat_growth_yoy":
        return pct_change(cur.get("pat"), (prev or {}).get("pat"))
    return None


def evaluate(item: Dict, quarters: List[Dict]) -> Tuple[str, Optional[float]]:
    """Return (status, actual). status in pending|met|missed."""
    metric = item.get("metric", "other")
    low, high = item.get("low"), item.get("high")
    target = low if low is not None else high
    if metric not in TOLERANCE or target is None:
        return "pending", None
    actual = actual_value(metric, item.get("targetPeriod", ""), quarters)
    if actual is None:
        return "pending", None
    return ("met" if actual >= target - TOLERANCE[metric] else "missed"), actual


def format_target(item: Dict) -> str:
    unit = " Cr" if item.get("metric") == "revenue" else "%"
    low, high = item.get("low"), item.get("high")
    if low is not None and high is not None and low != high:
        return f"{low:g}–{high:g}{unit}"
    if low is not None and high is None:
        return f"≥ {low:g}{unit}"
    v = low if low is not None else high
    return f"{v:g}{unit}" if v is not None else ""


def credibility(items: List[Dict]) -> Dict[str, int]:
    met = sum(1 for i in items if i.get("status") == "met")
    missed = sum(1 for i in items if i.get("status") == "missed")
    pending = sum(1 for i in items if i.get("status") == "pending")
    score = round(met / (met + missed) * 100) if (met + missed) else 0
    return {"score": score, "met": met, "missed": missed, "pending": pending}


_METRIC_LABEL = {"revenue_growth_yoy": "Revenue growth", "pat_growth_yoy": "Profit growth",
                 "ebitda_margin": "EBITDA margin", "revenue": "Revenue", "other": "Other"}


def _mid(item: Dict) -> Optional[float]:
    lo, hi = item.get("low"), item.get("high")
    if lo is not None and hi is not None:
        return (lo + hi) / 2
    return lo if lo is not None else hi


def diff(current: List[Dict], previous: List[Dict]) -> List[Dict]:
    """Compare this call's quantitative guidance with the previous call's.

    Matched by (metric, targetPeriod). Returns
    [{metric, label, targetPeriod, direction, before, now, statement}] where
    direction is raised | cut | reiterated | new | dropped. 'dropped' only
    for targets whose period hasn't been reported yet (still live).
    """
    def key(i):
        return (i.get("metric"), (i.get("targetPeriod") or "").upper().strip())

    prev = {key(i): i for i in previous if i.get("metric") != "other"}
    cur = {key(i): i for i in current if i.get("metric") != "other"}
    out = []
    for k, c in cur.items():
        p = prev.get(k)
        entry = {"metric": k[0], "label": _METRIC_LABEL.get(k[0], k[0]), "targetPeriod": k[1],
                 "now": format_target(c), "statement": c.get("statement", "")}
        if p is None:
            entry["direction"] = "new"
        else:
            a, b = _mid(p), _mid(c)
            entry["before"] = format_target(p)
            if a is None or b is None:
                entry["direction"] = "reiterated"
            else:
                tol = 0.25 if k[0] != "revenue" else abs(a) * 0.01
                entry["direction"] = "raised" if b > a + tol else ("cut" if b < a - tol else "reiterated")
        out.append(entry)
    for k, p in prev.items():
        if k not in cur and p.get("status", "pending") == "pending":
            out.append({"metric": k[0], "label": _METRIC_LABEL.get(k[0], k[0]), "targetPeriod": k[1],
                        "direction": "dropped", "before": format_target(p),
                        "statement": p.get("statement", "")})
    order = {"cut": 0, "raised": 1, "dropped": 2, "new": 3, "reiterated": 4}
    return sorted(out, key=lambda e: order[e["direction"]])


_TONE = {"positive": 1, "neutral": 0, "cautious": -1}


def call_info(concalls: List[Dict], items: List[Dict]) -> Dict:
    """Compact concall/guidance facts for the screener (companies/{sym}.callInfo).

    concalls: concall docs; items: guidance items. Returns
    {date, type, tone (1/0/-1), gDir (1 raised / 0 maintained / -1 cut),
     gRev, gPat, gMgn (guided % from the latest call), cred (met % if >= 2 checked)}.
    """
    calls = [c for c in concalls if c.get("kind", "earnings") in ("earnings", "analyst") and c.get("date")]
    out: Dict = {}
    if calls:
        last = max(calls, key=lambda c: c["date"])
        out["date"] = last["date"]
        out["type"] = last.get("callType")
        if last.get("tone") in _TONE:
            out["tone"] = _TONE[last["tone"]]
        dirs = {d.get("direction") for d in last.get("guidanceDiff") or []}
        if "cut" in dirs:
            out["gDir"] = -1
        elif "raised" in dirs:
            out["gDir"] = 1
        elif dirs & {"reiterated", "new"}:
            out["gDir"] = 0
        lid = last.get("id") or last.get("period")
        live = [i for i in items if i.get("status") != "superseded"]
        for metric, key in (("revenue_growth_yoy", "gRev"), ("pat_growth_yoy", "gPat"), ("ebitda_margin", "gMgn")):
            mine = [i for i in live if i.get("metric") == metric and (i.get("callId") or i.get("madeIn")) == lid]
            vals = [m for m in (_mid(i) for i in mine) if m is not None]
            if vals:
                out[key] = round(max(vals), 1)
    c = credibility([i for i in items if i.get("status") != "superseded"])
    if c["met"] + c["missed"] >= 2:
        out["cred"] = c["score"]
    return out

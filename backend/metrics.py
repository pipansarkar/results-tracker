"""Valuation and quality ratios from quarterly results + latest price.

TTM ("trailing twelve months") = sum of the latest 4 consecutive quarters.
All money in ₹ crore; shares in crore; prices in ₹.

Ratios are left out (None) when they'd be misleading: negative earnings
for P/E, non-positive growth for PEG, and debt/EV-based ratios for banks.
"""
from __future__ import annotations

import csv
import io
import zipfile
from datetime import date, timedelta
from typing import Dict, List, Optional


def _ttm(quarters: List[Dict], key: str, start: int) -> Optional[float]:
    """Sum of 4 consecutive quarters starting at index `start` (0 = latest)."""
    qs = quarters[start:start + 4]
    if len(qs) < 4:
        return None
    # Quarters must be consecutive (~3 months apart).
    for a, b in zip(qs, qs[1:]):
        gap = (date.fromisoformat(a["endDate"]) - date.fromisoformat(b["endDate"])).days
        if not 80 <= gap <= 100:
            return None
    vals = [q.get(key) for q in qs]
    if any(v is None for v in vals):
        return None
    return sum(vals)


def _pct(now: Optional[float], before: Optional[float]) -> Optional[float]:
    if now is None or before is None or before <= 0:
        return None
    return (now - before) / before * 100


def _r(v: Optional[float], nd: int = 2) -> Optional[float]:
    return None if v is None else round(v, nd)


def compute(quarters: List[Dict], price: Optional[float]) -> Dict:
    """quarters: newest first, as stored in companies/{symbol}."""
    if not quarters:
        return {}
    q0 = quarters[0]
    ago = next((q for q in quarters[1:] if q["period"][:2] == q0["period"][:2]), None)

    rev, pat = _ttm(quarters, "revenue", 0), _ttm(quarters, "pat", 0)
    ebitda, eps = _ttm(quarters, "ebitda", 0), _ttm(quarters, "eps", 0)
    pbt, fin = _ttm(quarters, "pbt", 0), _ttm(quarters, "financeCost", 0)
    rev_prev, pat_prev = _ttm(quarters, "revenue", 4), _ttm(quarters, "pat", 4)
    eps_prev = _ttm(quarters, "eps", 4)

    bs = next((q for q in quarters if q.get("equity")), {})
    bs_prev = next((q for q in quarters if q.get("equity") and q["endDate"] < bs.get("endDate", "")
                    and (date.fromisoformat(bs["endDate"]) - date.fromisoformat(q["endDate"])).days > 300), None) if bs else None
    shares = next((q["shares"] for q in quarters if q.get("shares")), None)
    bank = bool(bs.get("isBank"))
    equity, debt, cash = bs.get("equity"), bs.get("debt"), bs.get("cash")
    avg_equity = (equity + bs_prev["equity"]) / 2 if equity and bs_prev else equity

    m: Dict = {
        "q": q0["period"],
        "rev": _r(rev, 0), "pat": _r(pat, 0),
        "rg": _r(_pct(q0.get("revenue"), (ago or {}).get("revenue")), 1),   # latest qtr YoY
        "pg": _r(_pct(q0.get("pat"), (ago or {}).get("pat")), 1),
        "rgt": _r(_pct(rev, rev_prev), 1),                                 # TTM YoY
        "pgt": _r(_pct(pat, pat_prev), 1),
        "ebm": _r(ebitda / rev * 100 if ebitda is not None and rev else None, 1),
        "npm": _r(pat / rev * 100 if pat is not None and rev else None, 1),
        "eps": _r(eps),
        "roe": _r(pat / avg_equity * 100 if pat is not None and avg_equity and avg_equity > 0 else None, 1),
        "bank": bank or None,
    }
    if not bank:
        cap_employed = (equity or 0) + (debt or 0)
        m["roce"] = _r((pbt + fin) / cap_employed * 100 if pbt is not None and fin is not None
                       and equity and cap_employed > 0 else None, 1)
        m["de"] = _r(debt / equity if debt is not None and equity and equity > 0 else None)

    if price and shares:
        mcap = price * shares
        m["p"] = _r(price)
        m["mc"] = _r(mcap, 0)
        m["pe"] = _r(price / eps if eps and eps > 0 else None, 1)
        g = _pct(eps, eps_prev)
        m["peg"] = _r(m["pe"] / g if m["pe"] and g and g > 0 else None)
        m["pb"] = _r(mcap / equity if equity and equity > 0 else None)
        m["bv"] = _r(equity / shares if equity else None)
        if not bank and ebitda and ebitda > 0:
            m["ev"] = _r((mcap + (debt or 0) - (cash or 0)) / ebitda, 1)
    return {k: v for k, v in m.items() if v is not None}


# --------------------------------------------------------------- prices

BHAV_URL = "https://nsearchives.nseindia.com/content/cm/BhavCopy_NSE_CM_0_0_0_{d}_F_0000.csv.zip"


def latest_prices(nse, today: date, lookback: int = 7):
    """Closing prices from NSE's daily bhavcopy (one file for all stocks).
    Returns (trade_date_iso, {symbol: close}) for the latest available day."""
    for i in range(lookback):
        d = today - timedelta(days=i)
        if d.weekday() >= 5:
            continue
        try:
            raw = nse.download(BHAV_URL.format(d=d.strftime("%Y%m%d")))
            z = zipfile.ZipFile(io.BytesIO(raw))
        except Exception:
            continue
        text = z.read(z.namelist()[0]).decode("utf-8", errors="replace")
        prices = {}
        for r in csv.DictReader(io.StringIO(text)):
            if r.get("SctySrs") in ("EQ", "BE", "BZ") and r.get("ClsPric"):
                try:
                    prices[r["TckrSymb"]] = float(r["ClsPric"])
                except ValueError:
                    pass
        if prices:
            return d.isoformat(), prices
    return None, {}

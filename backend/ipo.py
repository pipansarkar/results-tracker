"""IPOs from NSE: open now, upcoming, and recently listed (with listing gain)."""
from __future__ import annotations

import logging
from datetime import date, timedelta
from typing import Callable, Dict, List, Optional

from nse import parse_nse_datetime

log = logging.getLogger(__name__)


def _f(v) -> Optional[float]:
    try:
        return float(str(v).replace(",", ""))
    except (TypeError, ValueError):
        return None


def _iso(s) -> Optional[str]:
    d = parse_nse_datetime((s or "").strip().title() if s else "")
    return d.date().isoformat() if d else None


def _clean(v) -> str:
    return " ".join(str(v or "").replace('"', "").split())


def _details(nse, symbol: str, series: str) -> Dict:
    """Issue info (title/value list) + category-wise subscription."""
    out: Dict = {"info": [], "subscription": []}
    try:
        d = nse.get_json("/api/ipo-detail", {"symbol": symbol, "series": series or "EQ"})
        for row in ((d.get("issueInfo") or {}).get("dataList") or []):
            t, v = row.get("title"), _clean(row.get("value"))
            if t and v and len(v) < 600:
                out["info"].append({"t": t, "v": v})
    except Exception as e:
        log.warning("ipo detail %s failed: %s", symbol, e)
    try:
        d = nse.get_json("/api/ipo-active-category", {"symbol": symbol})
        for row in (d.get("dataList") or [])[1:]:  # first row is the header
            times = _f(row.get("noOfTotalMeant"))
            if times is None and not row.get("noOfShareOffered"):
                continue
            out["subscription"].append({"category": _clean(row.get("category")), "times": times,
                                        "offered": _f(row.get("noOfShareOffered")),
                                        "bid": _f(row.get("noOfSharesBid"))})
        if d.get("updateTime"):
            out["subscriptionAsOf"] = d["updateTime"]
    except Exception as e:
        log.warning("ipo subscription %s failed: %s", symbol, e)
    return out


def fetch(nse, today: date, price_on: Callable[[str, date], Optional[float]]) -> Dict:
    """Snapshot for meta/ipos."""
    def base(r: Dict, status: str) -> Dict:
        return {
            "symbol": r.get("symbol"), "name": _clean(r.get("companyName") or r.get("company")),
            "status": status, "series": r.get("series") or r.get("securityType") or "EQ",
            "sme": (r.get("series") or r.get("securityType") or "").upper() == "SME",
            "open": _iso(r.get("issueStartDate") or r.get("ipoStartDate")),
            "close": _iso(r.get("issueEndDate") or r.get("ipoEndDate")),
            "priceBand": _clean(r.get("issuePrice") if status != "listed" else r.get("priceRange")),
            "issueSizeShares": _f(r.get("issueSize")),
        }

    out: Dict = {"open": [], "upcoming": [], "listed": []}
    for status, path, params in (("open", "/api/ipo-current-issue", None),
                                 ("upcoming", "/api/all-upcoming-issues", {"category": "ipo"})):
        try:
            rows = nse.get_json(path, params)
            rows = rows if isinstance(rows, list) else rows.get("data", [])
        except Exception as e:
            log.warning("%s IPOs failed: %s", status, e)
            rows = []
        seen = set()
        for r in rows:
            sym = r.get("symbol")
            if not sym or sym in seen:
                continue
            seen.add(sym)
            item = base(r, status)
            if status == "open":
                item["subscribedTimes"] = _f(r.get("noOfTime"))
            item.update(_details(nse, sym, item["series"]))
            out[status].append(item)
    try:
        rows = nse.get_json("/api/public-past-issues")
        rows = rows if isinstance(rows, list) else rows.get("data", [])
    except Exception as e:
        log.warning("past IPOs failed: %s", e)
        rows = []
    cutoff = (today - timedelta(days=45)).isoformat()
    for r in rows:
        # Only equity IPOs (main board and SME), not bonds / NCDs / REITs.
        if (r.get("securityType") or "").upper() not in ("EQ", "SME"):
            continue
        if (r.get("symbol") or "0")[0].isdigit():  # bond / NCD symbols, e.g. 13DCCL29A
            continue
        listed = _iso(r.get("listingDate"))
        if not listed or listed < cutoff:
            continue
        item = base(r, "listed")
        item["listingDate"] = listed
        issue = _f(r.get("issuePrice"))
        item["issuePrice"] = issue
        close = price_on(item["symbol"], date.fromisoformat(listed))
        now = price_on(item["symbol"], today)
        if issue and close:
            item["listingClose"] = close
            item["listingGain"] = round((close / issue - 1) * 100, 2)
        if issue and now:
            item["lastClose"] = now
            item["gainSinceIssue"] = round((now / issue - 1) * 100, 2)
        out["listed"].append(item)
    out["listed"].sort(key=lambda x: x["listingDate"], reverse=True)
    out["listed"] = out["listed"][:60]
    return out

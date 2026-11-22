"""Who's buying and selling: bulk & block deals, SAST (substantial
acquisition) disclosures and insider (PIT) trades, from NSE.

Every item is normalised to:
  {date, kind: bulk|block|sast|insider, who, side: buy|sell,
   qty, price, valueCr, holdingAfter, promoter, url}
"""
from __future__ import annotations

from datetime import date, datetime
from typing import Dict, List, Optional

from nse import nse_date, parse_nse_datetime


def _f(v) -> Optional[float]:
    try:
        return float(str(v).replace(",", ""))
    except (TypeError, ValueError):
        return None


def _iso(s) -> Optional[str]:
    d = parse_nse_datetime(s or "")
    return d.date().isoformat() if d else None


def bulk_block(nse) -> List[Dict]:
    """Latest trading day's bulk and block deals (NSE snapshot)."""
    d = nse.get_json("/api/snapshot-capital-market-largedeal")
    out = []
    for kind, key in (("bulk", "BULK_DEALS_DATA"), ("block", "BLOCK_DEALS_DATA")):
        for r in d.get(key) or []:
            qty, price = _f(r.get("qty")), _f(r.get("watp"))
            out.append({
                "symbol": r.get("symbol"), "date": _iso(r.get("date")), "kind": kind,
                "who": (r.get("clientName") or "").strip(),
                "side": "buy" if (r.get("buySell") or "").upper().startswith("B") else "sell",
                "qty": qty, "price": price,
                "valueCr": round(qty * price / 1e7, 2) if qty and price else None,
            })
    return out


def sast(nse, start: date, end: date) -> List[Dict]:
    """SAST Regulation 29 disclosures (crossing 5% / every 2% change after)."""
    rows = nse.get_json("/api/corporate-sast-reg29",
                        {"index": "equities", "from_date": nse_date(start), "to_date": nse_date(end)})
    rows = rows if isinstance(rows, list) else rows.get("data", [])
    out = []
    for r in rows:
        sale = (r.get("acqSaleType") or "").lower().startswith("sale")
        qty = _f(r.get("noOfShareSale") if sale else r.get("noOfShareAcq"))
        out.append({
            "symbol": r.get("symbol"),
            "date": _iso(r.get("timestamp") or r.get("time")),
            "kind": "sast", "who": (r.get("acquirerName") or "").strip(),
            "side": "sell" if sale else "buy", "qty": qty,
            "holdingAfter": _f(r.get("totAftShare")),
            "promoter": (r.get("promoterType") or "N").upper().startswith("Y"),
            "mode": r.get("acquisitionMode"), "url": r.get("attachement"),
        })
    return out


def insider(nse, start: date, end: date) -> List[Dict]:
    """Insider (PIT) trades. NSE's market-wide feed has been empty since
    early 2026; kept so data flows again if it returns."""
    d = nse.get_json("/api/corporates-pit",
                     {"index": "equities", "from_date": nse_date(start), "to_date": nse_date(end)})
    rows = d.get("data", []) if isinstance(d, dict) else d
    out = []
    for r in rows:
        buy_v, sell_v = _f(r.get("buyValue")) or 0, _f(r.get("sellValue")) or 0
        side = "buy" if buy_v >= sell_v else "sell"
        val = buy_v if side == "buy" else sell_v
        out.append({
            "symbol": r.get("symbol"), "date": _iso(r.get("date") or r.get("intimDt")),
            "kind": "insider", "who": (r.get("acqName") or "").strip(),
            "side": side, "qty": _f(r.get("secAcq")),
            "valueCr": round(val / 1e7, 2) if val else None,
            "holdingAfter": _f(r.get("afterAcqSharesPer")),
            "promoter": "promoter" in (r.get("personCategory") or "").lower(),
            "mode": r.get("acqMode"),
        })
    return out


def is_alert_worthy(d: Dict) -> bool:
    """Deals worth a push: promoter activity, or ≥ ₹5 Cr by value."""
    return bool(d.get("promoter")) or (d.get("valueCr") or 0) >= 5 or d["kind"] == "block"


def describe(d: Dict) -> str:
    who = d.get("who") or "Someone"
    verb = "bought" if d["side"] == "buy" else "sold"
    val = f" ₹{d['valueCr']:,.1f} Cr" if d.get("valueCr") else ""
    after = f" (now {d['holdingAfter']:.2f}%)" if d.get("holdingAfter") is not None else ""
    label = {"bulk": "bulk deal", "block": "block deal", "sast": "stake change",
             "insider": "insider trade"}[d["kind"]]
    prom = "Promoter " if d.get("promoter") else ""
    return f"{prom}{who} {verb}{val} in a {label}{after}"

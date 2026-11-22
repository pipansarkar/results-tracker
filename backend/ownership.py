"""Shareholding pattern (quarterly) from NSE SHP filings.

The master list gives filing dates and an XBRL file per quarter; the XBRL
has the full category split. Percentages are stored as % (0-100).
"""
from __future__ import annotations

import xml.etree.ElementTree as ET
from datetime import datetime
from typing import Dict, List, Optional

from xbrl import _local

# XBRL member -> our key
_MEMBERS = {
    "ShareholdingOfPromoterAndPromoterGroupMember": "promoter",
    "InstitutionsForeignMember": "fii",
    "InstitutionsDomesticMember": "dii",
    "MutualFundsOrUTIMember": "mf",
    "InsuranceCompaniesMember": "insurance",
    "ResidentIndividualShareholdersHoldingNominalShareCapitalUpToRsTwoLakhMember": "retailSmall",
    "ResidentIndividualShareholdersHoldingNominalShareCapitalInExcessOfRsTwoLakhMember": "retailLarge",
    "PublicShareholdingMember": "public",
}


def parse_shp(content: bytes) -> Dict[str, float]:
    """Category -> % holding, plus 'pledge' (% of promoter shares encumbered)
    when the filing reports it."""
    root = ET.fromstring(content)
    ctx_members: Dict[str, List[str]] = {}
    for el in root.iter():
        if _local(el.tag) == "context":
            ctx_members[el.get("id")] = [
                (m.text or "").split(":")[-1] for m in el.iter() if _local(m.tag) == "explicitMember"
            ]
    out: Dict[str, float] = {}
    pledge_pct = None
    any_encumbered = None
    for el in root:
        name = _local(el.tag)
        text = (el.text or "").strip()
        mem = ctx_members.get(el.get("contextRef") or "", [])
        if name == "ShareholdingAsAPercentageOfTotalNumberOfShares" and len(mem) == 1:
            key = _MEMBERS.get(mem[0])
            if key and text:
                try:
                    v = float(text)
                    # Newer filings store fractions (0.75); older ones
                    # store percentages (75). Normalise to percent.
                    out[key] = round(v * 100 if v <= 1.0 else v, 2)
                except ValueError:
                    pass
        elif name.startswith("WhetherAnySharesHeldByPromotersAreEncumbered") and text:
            any_encumbered = (any_encumbered or False) or text.lower() == "true"
        elif ("Encumbered" in name or "Pledged" in name) and "Percentage" in name and text \
                and "ShareholdingOfPromoterAndPromoterGroupMember" in mem:
            try:
                v = float(text)
                pledge_pct = (pledge_pct or 0) + (v * 100 if v <= 1 else v)
            except ValueError:
                pass
    if "retailSmall" in out or "retailLarge" in out:
        out["retail"] = round(out.pop("retailSmall", 0) + out.pop("retailLarge", 0), 2)
    if pledge_pct is not None:
        out["pledge"] = round(pledge_pct, 2)
    elif any_encumbered is False:
        out["pledge"] = 0.0
    if "promoter" in out and "public" in out:
        known = sum(out.get(k, 0) for k in ("fii", "dii", "retail"))
        out["others"] = round(max(out["public"] - known, 0), 2)
    return out


def _date(s: str) -> Optional[str]:
    for fmt in ("%d-%b-%Y", "%d-%B-%Y"):
        try:
            return datetime.strptime(s.strip().title(), fmt).date().isoformat()
        except (ValueError, AttributeError):
            continue
    return None


def history(nse, symbol: str, quarters: int = 6) -> List[Dict]:
    """Latest `quarters` shareholding patterns, newest first."""
    rows = nse.get_json("/api/corporate-share-holdings-master", {"index": "equities", "symbol": symbol})
    rows = rows if isinstance(rows, list) else rows.get("data", [])
    by_date: Dict[str, Dict] = {}
    for r in rows:
        d = _date(r.get("date") or "")
        if d and d not in by_date:  # first = latest revision
            by_date[d] = r
    out = []
    for d in sorted(by_date, reverse=True)[:quarters]:
        r = by_date[d]
        rec: Dict = {"date": d}
        url = r.get("xbrl") or ""
        if url.lower().endswith(".xml"):
            try:
                rec.update(parse_shp(nse.download(url)))
            except Exception:
                pass
        if "promoter" not in rec:  # fall back to master-list numbers
            try:
                rec["promoter"] = float(r.get("pr_and_prgrp") or "nan")
                rec["public"] = float(r.get("public_val") or "nan")
            except ValueError:
                pass
        rec = {k: v for k, v in rec.items() if v == v}  # drop NaN
        if len(rec) > 1:
            out.append(rec)
    return out


def latest_filings(nse, start, end) -> List[Dict]:
    """Market-wide SHP filings broadcast between start and end."""
    from nse import nse_date
    rows = nse.get_json("/api/corporate-share-holdings-master",
                        {"index": "equities", "from_date": nse_date(start), "to_date": nse_date(end)})
    return rows if isinstance(rows, list) else rows.get("data", [])


def changes(hist: List[Dict]) -> List[Dict]:
    """Notable quarter-on-quarter changes between the two latest patterns:
    [{type, text, severity}]."""
    if len(hist) < 2:
        return []
    now, prev = hist[0], hist[1]
    out = []

    def diff(k):
        if k in now and k in prev:
            return round(now[k] - prev[k], 2)
        return None

    d = diff("promoter")
    if d is not None and abs(d) >= 0.5:
        out.append({"type": "promoter_up" if d > 0 else "promoter_down",
                    "text": f"Promoter holding {'up' if d > 0 else 'down'} {abs(d):.2f}% to {now['promoter']:.2f}%",
                    "severity": "medium" if d < 0 else "low"})
    for k, label in (("fii", "FII"), ("dii", "DII"), ("mf", "Mutual fund")):
        d = diff(k)
        if d is not None and abs(d) >= 1:
            out.append({"type": f"{k}_{'up' if d > 0 else 'down'}",
                        "text": f"{label} holding {'up' if d > 0 else 'down'} {abs(d):.2f}% to {now[k]:.2f}%",
                        "severity": "low"})
    d = diff("pledge")
    if d is not None and d >= 1:
        out.append({"type": "pledge_up",
                    "text": f"Promoter pledge up {d:.2f}% to {now['pledge']:.2f}% of promoter shares",
                    "severity": "high"})
    return out

"""Parse quarterly numbers out of an NSE/BSE financial-results XBRL file.

The filings use the Ind AS "in-capmkt" taxonomy. Instead of hard-coding
context ids (they differ between filers) we read every context's period and
pick facts whose context:
  * has no dimensions (segment/scenario), and
  * covers ~3 months ending on the latest end date in the file.

All money values are converted from rupees to ₹ crore.
"""
from __future__ import annotations

import xml.etree.ElementTree as ET
from dataclasses import dataclass, asdict
from datetime import date, datetime
from typing import Dict, List, Optional, Tuple

CRORE = 1e7

# Candidate element names, first match wins. Banks and NBFCs use different
# line items, hence the fallbacks.
REVENUE = ["RevenueFromOperations", "InterestEarned", "Income", "TotalIncome"]
OTHER_INCOME = ["OtherIncome"]
PBT = ["ProfitBeforeTax", "ProfitLossBeforeTax",
       "ProfitLossFromOrdinaryActivitiesBeforeTax"]
FINANCE_COSTS = ["FinanceCosts", "InterestExpended"]
DEPRECIATION = ["DepreciationDepletionAndAmortisationExpense",
                "DepreciationAndAmortisationExpense"]
OPERATING_PROFIT = ["OperatingProfitBeforeProvisionAndContingencies"]
PAT_OWNERS = ["ProfitOrLossAttributableToOwnersOfParent",
              "ProfitLossAttributableToOwnersOfParent"]
PAT = ["ProfitLossForPeriod", "ProfitLossForThePeriod",
       "ProfitLossFromOrdinaryActivitiesAfterTax"]
EPS = ["BasicEarningsLossPerShareFromContinuingAndDiscontinuedOperations",
       "BasicEarningsLossPerShareFromContinuingOperations",
       "BasicEarningsPerShareAfterExtraordinaryItems",
       "BasicEarningsLossPerShare"]


@dataclass
class Quarter:
    period: str          # e.g. Q2FY27
    endDate: str         # ISO date
    revenue: Optional[float]
    ebitda: Optional[float]
    pat: Optional[float]
    eps: Optional[float]
    consolidated: bool

    def to_dict(self) -> Dict:
        return asdict(self)


def quarter_label(end: date) -> str:
    """Indian fiscal quarter label: Apr-Jun=Q1 ... Jan-Mar=Q4; FY ends in March."""
    q = {6: 1, 9: 2, 12: 3, 3: 4}.get(end.month)
    if q is None:
        raise ValueError(f"not a quarter end: {end}")
    fy = end.year if end.month == 3 else end.year + 1
    return f"Q{q}FY{fy % 100:02d}"


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _parse_date(s: str) -> date:
    return datetime.strptime(s.strip()[:10], "%Y-%m-%d").date()


def _contexts(root: ET.Element) -> Dict[str, Tuple[Optional[date], date, bool]]:
    """context id -> (start, end, has_dimensions)."""
    out = {}
    for ctx in root.iter():
        if _local(ctx.tag) != "context":
            continue
        cid = ctx.get("id")
        start = end = None
        has_dims = False
        for el in ctx.iter():
            name = _local(el.tag)
            if name == "startDate" and el.text:
                start = _parse_date(el.text)
            elif name in ("endDate", "instant") and el.text:
                end = _parse_date(el.text)
            elif name in ("segment", "scenario") and len(list(el)) > 0:
                has_dims = True
        if cid and end:
            out[cid] = (start, end, has_dims)
    return out


def _facts(root: ET.Element) -> Dict[Tuple[str, str], float]:
    """(local element name, context id) -> numeric value."""
    out = {}
    for el in root:
        ref = el.get("contextRef")
        if not ref or el.text is None:
            continue
        try:
            out[(_local(el.tag), ref)] = float(el.text.strip())
        except ValueError:
            continue
    return out


def _text_fact(root: ET.Element, names: List[str]) -> Optional[str]:
    for el in root:
        if _local(el.tag) in names and el.text:
            return el.text.strip()
    return None


def parse_xbrl(content: bytes) -> List[Quarter]:
    """Return quarters found in the filing (current quarter first, plus the
    year-ago and previous quarter when the filing includes them)."""
    root = ET.fromstring(content)
    ctxs = _contexts(root)
    facts = _facts(root)

    nature = (_text_fact(root, ["NatureOfReportStandaloneConsolidated"]) or "").lower()
    consolidated = "consolidated" in nature and "standalone" not in nature

    # Quarter-long, dimension-free contexts grouped by end date.
    by_end: Dict[date, List[str]] = {}
    for cid, (start, end, dims) in ctxs.items():
        if dims or start is None:
            continue
        days = (end - start).days
        if 85 <= days <= 95:
            by_end.setdefault(end, []).append(cid)

    quarters = []
    for end in sorted(by_end, reverse=True):
        cids = by_end[end]

        def pick(names: List[str]) -> Optional[float]:
            for n in names:
                for c in cids:
                    if (n, c) in facts:
                        return facts[(n, c)]
            return None

        revenue = pick(REVENUE)
        if revenue is None:
            continue
        pbt = pick(PBT)
        fin = pick(FINANCE_COSTS) or 0.0
        dep = pick(DEPRECIATION) or 0.0
        oth = pick(OTHER_INCOME) or 0.0
        op = pick(OPERATING_PROFIT)
        if op is not None:
            ebitda = op  # banks: operating profit before provisions
        elif pbt is not None:
            ebitda = pbt + fin + dep - oth
        else:
            ebitda = None
        pat = pick(PAT_OWNERS) if consolidated else None
        if pat is None:
            pat = pick(PAT)
        eps = pick(EPS)

        try:
            label = quarter_label(end)
        except ValueError:
            continue
        quarters.append(Quarter(
            period=label,
            endDate=end.isoformat(),
            revenue=_cr(revenue),
            ebitda=_cr(ebitda),
            pat=_cr(pat),
            eps=round(eps, 2) if eps is not None else None,
            consolidated=consolidated,
        ))
    return quarters


def _cr(v: Optional[float]) -> Optional[float]:
    return None if v is None else round(v / CRORE, 2)


def pct_change(now: Optional[float], before: Optional[float]) -> Optional[float]:
    if now is None or before is None or before == 0:
        return None
    return round((now - before) / abs(before) * 100, 2)


def merge_quarters(existing: List[Dict], new: List[Quarter], keep: int = 12) -> List[Dict]:
    """Upsert by period. A consolidated figure is never replaced by standalone."""
    by_period = {q["period"]: q for q in existing}
    for q in new:
        old = by_period.get(q.period)
        if old and old.get("consolidated") and not q.consolidated:
            continue
        by_period[q.period] = q.to_dict()
    out = sorted(by_period.values(), key=lambda q: q["endDate"], reverse=True)
    return out[:keep]

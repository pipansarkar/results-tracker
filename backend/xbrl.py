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
    # Detailed P&L (₹ crore), filled when the filing has the line item.
    otherIncome: Optional[float] = None
    totalIncome: Optional[float] = None
    materialCost: Optional[float] = None
    employeeCost: Optional[float] = None
    otherExpenses: Optional[float] = None
    totalExpenses: Optional[float] = None
    depreciation: Optional[float] = None
    financeCost: Optional[float] = None
    exceptional: Optional[float] = None
    pbt: Optional[float] = None
    tax: Optional[float] = None
    netProfit: Optional[float] = None   # incl. minority interest
    dilutedEps: Optional[float] = None
    # [{name, revenue, result}] for the quarter, when segments are reported.
    segments: Optional[List[Dict]] = None
    # Balance sheet at quarter end (₹ crore); companies file it half-yearly.
    equity: Optional[float] = None
    debt: Optional[float] = None
    cash: Optional[float] = None
    totalAssets: Optional[float] = None
    # Shares outstanding, in crore shares.
    shares: Optional[float] = None
    isBank: Optional[bool] = None
    # Detailed balance sheet lines (₹ Cr) at half-year / year end.
    bs: Optional[Dict] = None
    # Cash flow for the fiscal year-to-date (6 or 12 months), ₹ Cr.
    cf: Optional[Dict] = None
    # When the result was filed (ISO datetime) and the stock's move on it (%).
    filedAt: Optional[str] = None
    reaction: Optional[float] = None

    def to_dict(self) -> Dict:
        return {k: v for k, v in asdict(self).items() if v is not None or k in (
            "revenue", "ebitda", "pat", "eps")}


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


def _segments(root: ET.Element, end: date, facts: Dict[Tuple[str, str], float]) -> Optional[List[Dict]]:
    """Segment revenue/result for the quarter ending `end`. Segment names
    come from DescriptionOfReportableSegment facts in a context with the
    same ReportableSegments member."""
    member_of: Dict[str, str] = {}      # context id -> member
    quarter_ctx: Dict[str, str] = {}    # member -> context id for this quarter
    for ctx in root.iter():
        if _local(ctx.tag) != "context":
            continue
        cid = ctx.get("id")
        mem = start = stop = None
        for el in ctx.iter():
            n = _local(el.tag)
            if n == "explicitMember" and "ReportableSegments" in (el.get("dimension") or ""):
                mem = (el.text or "").strip()
            elif n == "startDate" and el.text:
                start = _parse_date(el.text)
            elif n == "endDate" and el.text:
                stop = _parse_date(el.text)
        if cid and mem:
            member_of[cid] = mem
            if start and stop == end and 85 <= (stop - start).days <= 95:
                quarter_ctx.setdefault(mem, cid)
    if not quarter_ctx:
        return None
    names: Dict[str, str] = {}
    for el in root:
        if _local(el.tag) == "DescriptionOfReportableSegment" and el.text:
            mem = member_of.get(el.get("contextRef") or "")
            if mem and mem not in names:
                names[mem] = el.text.strip()
    out = []
    for mem, cid in quarter_ctx.items():
        rev = facts.get(("SegmentRevenueFromOperations", cid), facts.get(("SegmentRevenue", cid)))
        res = facts.get(("SegmentProfitLossBeforeTaxAndFinanceCosts", cid))
        if not rev:
            continue
        label = names.get(mem) or mem.split(":")[-1].replace("Member", "")
        out.append({"name": label, "revenue": _cr(rev), "result": _cr(res)})
    out.sort(key=lambda x: -(x["revenue"] or 0))
    # Drop a lone "total"/single-segment report: not informative.
    return out if len(out) >= 2 else None


def _balance_sheet(ctxs, facts, end: date) -> Dict:
    """Instant (point-in-time), dimension-free facts at `end`."""
    cids = [cid for cid, (start, e, dims) in ctxs.items() if start is None and not dims and e == end]
    if not cids:
        return {}

    def get(n):
        for c in cids:
            if (n, c) in facts:
                return facts[(n, c)]
        return None

    def add(*names):
        vals = [get(n) for n in names]
        vals = [v for v in vals if v is not None]
        return sum(vals) if vals else None

    bank = get("Deposits") is not None
    if bank:
        equity = add("Capital", "ReservesAndSurplus")
        debt = get("Borrowings")
        cash = get("CashAndBalancesWithReserveBankOfIndia")
    else:
        equity = get("EquityAttributableToOwnersOfParent")
        if equity is None:
            equity = get("Equity")
        debt = add("BorrowingsCurrent", "BorrowingsNoncurrent")
        cash = add("CashAndCashEquivalents", "BankBalanceOtherThanCashAndCashEquivalents")
    out = {"equity": _cr(equity), "debt": _cr(debt), "cash": _cr(cash),
           "totalAssets": _cr(get("Assets")), "isBank": bank}
    if not equity:
        return {}
    if bank:
        detail = {
            "deposits": get("Deposits"), "advances": get("Advances"),
            "investments": get("Investments"), "borrowings": get("Borrowings"),
            "fixedAssets": get("FixedAssets"), "equity": equity,
            "otherLiabilities": get("OtherLiabilitiesAndProvisions"),
            "totalAssets": get("Assets"),
        }
    else:
        detail = {
            "fixedAssets": get("PropertyPlantAndEquipment"),
            "cwip": get("CapitalWorkInProgress"),
            "goodwill": get("Goodwill"),
            "investments": add("NoncurrentInvestments", "CurrentInvestments",
                               "InvestmentsAccountedForUsingEquityMethod"),
            "inventories": get("Inventories"),
            "receivables": add("TradeReceivablesCurrent", "TradeReceivablesNoncurrent"),
            "cash": cash,
            "totalAssets": get("Assets"),
            "equity": equity,
            "minority": get("NonControllingInterest"),
            "borrowingsLong": get("BorrowingsNoncurrent"),
            "borrowingsShort": get("BorrowingsCurrent"),
            "payables": add("TradePayablesCurrent", "TradePayablesNoncurrent"),
            "currentAssets": get("CurrentAssets"),
            "currentLiabilities": get("CurrentLiabilities"),
        }
    out["bs"] = {k: _cr(v) for k, v in detail.items() if v is not None}
    return out


def _cash_flow(ctxs, facts, end: date) -> Optional[Dict]:
    """Year-to-date cash flow ending at `end` (filed with half-year and
    full-year results). Indian FY starts 1 April."""
    fy_start = date(end.year if end.month >= 4 else end.year - 1, 4, 1)
    cids = [cid for cid, (start, e, dims) in ctxs.items()
            if start == fy_start and e == end and not dims]
    if not cids:
        return None

    def get(n):
        for c in cids:
            if (n, c) in facts:
                return facts[(n, c)]
        return None

    cfo = get("CashFlowsFromUsedInOperatingActivities")
    if cfo is None:
        return None
    capex = get("PurchaseOfPropertyPlantAndEquipmentClassifiedAsInvestingActivities")
    intangibles = get("PurchaseOfIntangibleAssetsClassifiedAsInvestingActivities")
    capex_total = (capex or 0) + (intangibles or 0) if (capex or intangibles) else None
    out = {
        "months": round((end - fy_start).days / 30.4),
        "cfo": cfo,
        "cfi": get("CashFlowsFromUsedInInvestingActivities"),
        "cff": get("CashFlowsFromUsedInFinancingActivities"),
        "capex": capex_total,
        "dividends": get("DividendsPaidClassifiedAsFinancingActivities"),
        "fcf": cfo - capex_total if capex_total is not None else None,
    }
    return {k: (v if k == "months" else _cr(v)) for k, v in out.items() if v is not None}


def _shares(ctxs, facts, end: date) -> Optional[float]:
    """Paid-up capital / face value, in crore shares."""
    paid = face = None
    for (n, c), v in facts.items():
        if c in ctxs and ctxs[c][1] == end and not ctxs[c][2]:
            if n == "PaidUpValueOfEquityShareCapital":
                paid = v
            elif n == "FaceValueOfEquityShareCapital":
                face = v
    if paid and face and face > 0:
        return round(paid / face / CRORE, 4)
    return None


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
        total_pat = pick(PAT)
        pat = pick(PAT_OWNERS) if consolidated else None
        # Some filers put 0 in "attributable to owners" (no minority
        # interest); fall back to total profit in that case.
        if pat is None or (pat == 0 and total_pat):
            pat = total_pat
        eps = pick(EPS)

        def total(names: List[str]) -> Optional[float]:
            vals = [pick([n]) for n in names]
            vals = [v for v in vals if v is not None]
            return sum(vals) if vals else None

        tax = pick(["TaxExpense"])
        if tax is None:
            tax = total(["CurrentTax", "DeferredTax"])
        detail = dict(
            otherIncome=_cr(pick(OTHER_INCOME)),
            totalIncome=_cr(pick(["Income", "TotalIncome"])),
            materialCost=_cr(total(["CostOfMaterialsConsumed", "PurchasesOfStockInTrade",
                                    "ChangesInInventoriesOfFinishedGoodsWorkInProgressAndStockInTrade"])),
            employeeCost=_cr(pick(["EmployeeBenefitExpense"])),
            otherExpenses=_cr(pick(["OtherExpenses"])),
            totalExpenses=_cr(pick(["Expenses", "TotalExpenses"])),
            depreciation=_cr(pick(DEPRECIATION)),
            financeCost=_cr(pick(FINANCE_COSTS)),
            exceptional=_cr(pick(["ExceptionalItemsBeforeTax", "ExceptionalItems"])),
            pbt=_cr(pbt),
            tax=_cr(tax),
            netProfit=_cr(pick(PAT)),
            dilutedEps=_round2(pick(["DilutedEarningsLossPerShareFromContinuingAndDiscontinuedOperations",
                                     "DilutedEarningsLossPerShareFromContinuingOperations",
                                     "DilutedEarningsLossPerShare"])),
            segments=_segments(root, end, facts),
            shares=_shares(ctxs, facts, end),
            cf=_cash_flow(ctxs, facts, end),
            **_balance_sheet(ctxs, facts, end),
        )

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
            eps=_round2(eps),
            consolidated=consolidated,
            **detail,
        ))
    return quarters


def _round2(v: Optional[float]) -> Optional[float]:
    return None if v is None else round(v, 2)


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
        new = q.to_dict()
        for k in ("filedAt", "reaction"):  # keep what we learned earlier
            if old and new.get(k) is None and old.get(k) is not None:
                new[k] = old[k]
        by_period[q.period] = new
    out = sorted(by_period.values(), key=lambda q: q["endDate"], reverse=True)
    return out[:keep]

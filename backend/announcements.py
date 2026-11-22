"""Classify NSE announcements and pull dates and times out of their text."""
from __future__ import annotations

import re
from datetime import date, datetime, timedelta
from typing import Optional

CONCALL_DESC = re.compile(r"analyst|investor meet|con\.? ?call|conference call|earnings call", re.I)
TRANSCRIPT = re.compile(r"transcript", re.I)
INTIMATION = re.compile(r"schedul|intimat|will be held|to be held|invite|participate", re.I)
RESULTS_PURPOSE = re.compile(r"financial results|quarterly results|audited|unaudited", re.I)

MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}

_DATE_PATTERNS = [
    # 25th November, 2026 / 25 Nov 2026
    re.compile(r"\b(\d{1,2})(?:st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+(\d{4})", re.I),
    # November 25, 2026
    re.compile(r"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})", re.I),
    # 25-11-2026 / 25/11/2026 / 25.11.2026
    re.compile(r"\b(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})\b"),
]
_TIME = re.compile(r"\b(\d{1,2})[:.](\d{2})\s*(a\.?m\.?|p\.?m\.?|hrs|hours|ist)?", re.I)


def is_transcript(desc: str, text: str) -> bool:
    return bool(TRANSCRIPT.search(text or "") or TRANSCRIPT.search(desc or "")) and \
        bool(CONCALL_DESC.search((desc or "") + " " + (text or "")))


def is_concall_intimation(desc: str, text: str) -> bool:
    blob = (desc or "") + " " + (text or "")
    return bool(CONCALL_DESC.search(blob)) and bool(INTIMATION.search(text or "")) \
        and not TRANSCRIPT.search(blob) and not re.search(r"audio|recording", blob, re.I)


_EARNINGS_CALL = re.compile(
    r"earnings?\s+(conference\s+)?call"
    r"|(conference|con\.?|concall|group)\s*call.{0,200}?(financial\s+)?(results|performance|quarter)"
    r"|(results|quarter|performance).{0,200}?(conference|con\.?)\s*call",
    re.I | re.S)


def is_earnings_call_text(body: str) -> bool:
    """True when an intimation is about a results/earnings call, not a generic
    investor conference or one-on-one meeting."""
    return bool(_EARNINGS_CALL.search(body or ""))


def meet_kind(body: str) -> str:
    """Short label for a non-earnings investor interaction."""
    b = body.lower()
    if "conference" in b:
        return "Investor conference"
    if "one on one" in b or "one-on-one" in b or "1:1" in b:
        return "One-on-one investor meetings"
    if "group" in b:
        return "Group investor meeting"
    if "site visit" in b or "plant visit" in b:
        return "Site visit"
    if "analyst" in b:
        return "Analyst meet"
    return "Investor meet"


def is_results_meeting(purpose: str) -> bool:
    return bool(RESULTS_PURPOSE.search(purpose or ""))


def find_date(text: str, not_before: Optional[date] = None,
              max_days_ahead: int = 60) -> Optional[date]:
    """First plausible date in the text, on or after `not_before` and at most
    `max_days_ahead` days after it (filters typos like 2826)."""
    found = []
    for i, pat in enumerate(_DATE_PATTERNS):
        for m in pat.finditer(text or ""):
            try:
                if i == 0:
                    d = date(int(m.group(3)), MONTHS[m.group(2).lower()[:3]], int(m.group(1)))
                elif i == 1:
                    d = date(int(m.group(3)), MONTHS[m.group(1).lower()[:3]], int(m.group(2)))
                else:
                    d = date(int(m.group(3)), int(m.group(2)), int(m.group(1)))
            except (ValueError, KeyError):
                continue
            found.append((m.start(), d))
    found.sort()
    for _, d in found:
        if not_before is None:
            return d
        if not_before <= d <= not_before + timedelta(days=max_days_ahead):
            return d
    return None


def find_time(text: str) -> Optional[str]:
    """'4:00 PM' -> '16:00'."""
    for m in _TIME.finditer(text or ""):
        h, mi, suffix = int(m.group(1)), int(m.group(2)), (m.group(3) or "").lower()
        if mi > 59 or h > 23:
            continue
        if suffix.startswith("p") and h < 12:
            h += 12
        elif suffix.startswith("a") and h == 12:
            h = 0
        elif not suffix and h < 8:
            h += 12  # "4.00" without am/pm almost always means afternoon
        return f"{h:02d}:{mi:02d}"
    return None


def latest_quarter_end_before(d: date) -> date:
    """Most recent quarter end strictly before d (calls happen after quarter end)."""
    y, m = d.year, d.month
    for _ in range(5):
        m -= 1
        if m == 0:
            y, m = y - 1, 12
        if m in (3, 6, 9, 12):
            import calendar
            end = date(y, m, calendar.monthrange(y, m)[1])
            if end < d:
                return end
    raise ValueError(d)


def parse_dt(s: Optional[str]) -> Optional[datetime]:
    from nse import parse_nse_datetime
    return parse_nse_datetime(s)

"""Free NSE data access (no official API, so we call the JSON endpoints the
nseindia.com website itself uses).

NSE needs browser-like headers and the cookies set by the home page. Calls are
rate limited to stay polite. These endpoints change from time to time; if a
call starts failing, open the matching page on nseindia.com with browser dev
tools and check the request it makes.
"""
from __future__ import annotations

import csv
import io
import logging
import time
from datetime import date, datetime
from typing import Any, Dict, List, Optional

import requests

log = logging.getLogger(__name__)

BASE = "https://www.nseindia.com"
EQUITY_CSV = "https://nsearchives.nseindia.com/content/equities/EQUITY_L.csv"
NIFTY500_CSV ="https://nsearchives.nseindia.com/content/indices/ind_nifty500list.csv"
HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0 Safari/537.36"
    ),
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": BASE + "/",
}


def nse_date(d: date) -> str:
    return d.strftime("%d-%m-%Y")


def parse_nse_datetime(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    for fmt in ("%d-%b-%Y %H:%M:%S", "%d-%b-%Y %H:%M", "%d-%b-%Y", "%d-%m-%Y"):
        try:
            return datetime.strptime(s.strip(), fmt)
        except ValueError:
            continue
    return None


class NseClient:
    def __init__(self, min_interval: float = 1.0):
        self.s = requests.Session()
        self.s.headers.update(HEADERS)
        self.min_interval = min_interval
        self._last = 0.0
        self._last_archive = 0.0
        self._primed = False

    def _wait(self) -> None:
        dt = time.time() - self._last
        if dt < self.min_interval:
            time.sleep(self.min_interval - dt)
        self._last = time.time()

    def _prime(self) -> None:
        if not self._primed:
            self._wait()
            self.s.get(BASE, timeout=20)
            self._primed = True

    def get_json(self, path: str, params: Optional[Dict[str, Any]] = None) -> Any:
        self._prime()
        for attempt in range(3):
            self._wait()
            r = self.s.get(BASE + path, params=params, timeout=30)
            if r.status_code == 401 or r.status_code == 403:
                # Cookies expired: re-prime and retry.
                self._primed = False
                self._prime()
                continue
            r.raise_for_status()
            return r.json()
        raise RuntimeError(f"NSE refused {path} (HTTP {r.status_code}). "
                           "NSE often blocks non-Indian cloud IPs; see README.")

    def download(self, url: str) -> bytes:
        self._prime()
        if "nsearchives" in url:
            # Static archive host: a lighter, separate rate limit.
            dt = time.time() - self._last_archive
            if dt < 0.3:
                time.sleep(0.3 - dt)
            self._last_archive = time.time()
        else:
            self._wait()
        r = self.s.get(url, timeout=60)
        r.raise_for_status()
        return r.content

    # ------------------------------------------------------------ endpoints

    def announcements(self, start: date, end: date,
                      symbol: Optional[str] = None) -> List[Dict[str, Any]]:
        params = {"index": "equities", "from_date": nse_date(start),
                  "to_date": nse_date(end)}
        if symbol:
            params["symbol"] = symbol
        data = self.get_json("/api/corporate-announcements", params)
        return data if isinstance(data, list) else data.get("data", [])

    def board_meetings(self, start: date, end: date) -> List[Dict[str, Any]]:
        params = {"index": "equities", "from_date": nse_date(start),
                  "to_date": nse_date(end)}
        data = self.get_json("/api/corporate-board-meetings", params)
        return data if isinstance(data, list) else data.get("data", [])

    def financial_results(self, start: Optional[date] = None, end: Optional[date] = None,
                          symbol: Optional[str] = None,
                          include_legacy: bool = False) -> List[Dict[str, Any]]:
        """Quarterly result filings, normalised to
        {symbol, xbrl, filingDate, consolidated, quarterEnd}.

        Since 2025 SEBI's "Integrated Filing (Financials)" carries quarterly
        results; older quarters are only in the legacy endpoint, so pass
        include_legacy=True for history backfills.
        """
        out = [self._norm_integrated(r) for r in self._integrated(start, end, symbol)]
        if include_legacy:
            params: Dict[str, Any] = {"index": "equities", "period": "Quarterly"}
            if start and end:
                params.update(from_date=nse_date(start), to_date=nse_date(end))
            if symbol:
                params["symbol"] = symbol
            data = self.get_json("/api/corporates-financial-results", params)
            rows = data if isinstance(data, list) else data.get("data", [])
            out += [{
                "symbol": r.get("symbol"),
                "xbrl": r.get("xbrl") or "",
                "filingDate": r.get("filingDate") or r.get("broadCastDate"),
                "consolidated": r.get("consolidated") == "Consolidated",
                "quarterEnd": r.get("toDate"),
            } for r in rows]
        return out

    def _integrated(self, start: Optional[date], end: Optional[date],
                    symbol: Optional[str], page_size: int = 200) -> List[Dict[str, Any]]:
        params: Dict[str, Any] = {"index": "equities", "type": "Integrated Filing- Financials",
                                  "size": page_size}
        if start and end:
            params.update(from_date=nse_date(start), to_date=nse_date(end))
        if symbol:
            params["symbol"] = symbol
        rows: List[Dict[str, Any]] = []
        page = 1  # NSE pages are 1-indexed
        while True:
            params["page"] = page
            data = self.get_json("/api/integrated-filing-results", params)
            batch = data.get("data", []) if isinstance(data, dict) else data
            rows += batch
            total = data.get("totalCount", 0) if isinstance(data, dict) else 0
            if not batch or len(rows) >= total or page >= 50:
                return rows
            page += 1

    @staticmethod
    def _norm_integrated(r: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "symbol": r.get("symbol"),
            "xbrl": r.get("xbrl") or "",
            "filingDate": r.get("broadcast_Date") or r.get("creation_Date"),
            "consolidated": r.get("consolidated") == "Consolidated",
            "quarterEnd": r.get("qe_Date"),
        }

    def all_equities(self) -> List[Dict[str, str]]:
        """Every NSE main-board equity (EQUITY_L.csv). No sector column there,
        so callers merge sectors from the Nifty 500 list."""
        text = self.download(EQUITY_CSV).decode("utf-8-sig", errors="replace")
        out = []
        for row in csv.DictReader(io.StringIO(text)):
            row = {k.strip(): (v or "").strip() for k, v in row.items() if k}
            if row.get("SERIES") not in ("EQ", "BE", "BZ"):
                continue
            out.append({"symbol": row["SYMBOL"], "name": row["NAME OF COMPANY"],
                        "sector": "", "isin": row.get("ISIN NUMBER", "")})
        return out

    def nifty500(self) -> List[Dict[str, str]]:
        text = self.download(NIFTY500_CSV).decode("utf-8-sig")
        out = []
        for row in csv.DictReader(io.StringIO(text)):
            out.append({
                "symbol": row["Symbol"].strip(),
                "name": row["Company Name"].strip(),
                "sector": row.get("Industry", "").strip(),
                "isin": row.get("ISIN Code", "").strip(),
            })
        return out

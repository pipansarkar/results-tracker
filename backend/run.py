"""Results & concall pipeline. Runs on GitHub Actions every 30 minutes and is
fully automatic. Every run:

  1. refreshes the list of all NSE stocks (weekly)
  2. picks up new quarterly results (last 2 days)
  3. backfills ~3 years of history for a batch of stocks not done yet
     (Nifty 500 first), so the whole market fills in over the first days
  4. updates the calendar: board meetings (past 60 / next 45 days), concall
     and investor-conference intimations, plus a slowly moving look-back that
     walks older announcements so past concalls fill in too
  5. summarises queued concall transcripts with Gemini (free tier)
  6. sends FCM topic pushes

Examples:
  python run.py --dry-run --symbols TCS,INFY     # writes JSON to ./out
  python run.py                                  # live: Firestore + push
  python run.py --morning                        # "today" alerts
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import logging
import os
import re
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).parent))

import announcements as ann  # noqa: E402
import deals as dl  # noqa: E402
import extract  # noqa: E402
import ipo  # noqa: E402
import ownership  # noqa: E402
import redflags  # noqa: E402
import guidance as gd  # noqa: E402
from notify import Notifier  # noqa: E402
from nse import NseClient, parse_nse_datetime  # noqa: E402
from store import FirestoreStore, LocalStore, Store  # noqa: E402
from xbrl import merge_quarters, parse_xbrl, pct_change, quarter_label  # noqa: E402

log = logging.getLogger("pipeline")
IST = timezone(timedelta(hours=5, minutes=30))
HERE = Path(__file__).parent
UNIVERSE_CSV = HERE / "companies.csv"
STATE = "pipeline_state/main"
SCHEMA = 5  # bump to re-parse all filings (5 = + BS/cash-flow detail, filing time, price reaction, shareholding)
MAX_PROCESSED = 8000

CAL_PAST_DAYS = 60        # calendar keeps / back-fills this many past days
CAL_FUTURE_DAYS = 45
UNIVERSE_REFRESH_DAYS = 7
# Track every NSE company with market cap of at least MIN_MCAP ₹ crore
# (refreshed weekly). TOP_N > 0 additionally caps the count.
MIN_MCAP = float(os.environ.get("MIN_MCAP", "500"))
TOP_N = int(os.environ.get("TOP_N", "0"))
# Every scheduled run spends up to this long loading history for stocks that
# don't have it yet, until the whole market is done. Fully automatic.
BACKFILL_MINUTES = float(os.environ.get("BACKFILL_MINUTES", "12"))
HISTORY_DAYS_PER_RUN = int(os.environ.get("HISTORY_DAYS_PER_RUN", "2"))
# Concall summaries: time budget per run (backlog uses Flash-Lite) and how
# many past quarters of earnings calls to keep per company.
TRANSCRIPT_DAYS = int(os.environ.get("TRANSCRIPT_DAYS", "400"))   # ~last 4 quarters
MAX_CALLS = int(os.environ.get("MAX_CALLS", "8"))                   # per company
MAX_DOCS = 2          # latest investor presentations / press releases per company
SUMMARY_VERSION = 3   # bump to regenerate all summaries in a new format
ENRICH_VERSION = 3    # bump to re-run per-company enrichment (calls, docs, dividends)
SUMMARY_MINUTES = float(os.environ.get("SUMMARY_MINUTES", "12"))


def _cap_class(rank: int) -> str:
    """SEBI/AMFI-style buckets by market-cap rank: 1-100 large, 101-250 mid,
    251-500 small, 501+ micro."""
    return "large" if rank <= 100 else "mid" if rank <= 250 else "small" if rank <= 500 else "micro"


def _doc_kind(desc: str, text: str) -> Optional[str]:
    blob = f"{desc} {text}".lower()
    if "investor presentation" in blob:
        return "presentation"
    if desc.strip().lower() == "press release" or "press release" in (desc or "").lower():
        return "press_release"
    return None


def _pkey(label: str):
    """Sort key for quarter labels: Q2FY27 -> (27, 2)."""
    try:
        return (int(label[4:]), int(label[1]))
    except (ValueError, IndexError):
        return (0, 0)


def now_ist() -> datetime:
    return datetime.now(IST)


def week_id(d: date) -> str:
    """Calendar docs are one per week, keyed by the Monday: calendar/2026-11-16."""
    return (d - timedelta(days=d.weekday())).isoformat()


def load_csv_universe() -> Dict[str, Dict[str, str]]:
    with open(UNIVERSE_CSV, newline="", encoding="utf-8") as f:
        return {r["symbol"]: dict(r, n500="1") for r in csv.DictReader(f)}


def _hash(obj) -> str:
    return hashlib.sha1(json.dumps(obj, sort_keys=True, default=str).encode()).hexdigest()[:16]


class Pipeline:
    def __init__(self, store: Store, nse: NseClient, notifier: Notifier,
                 universe: Dict[str, Dict[str, str]], max_summaries: int):
        self.store = store
        self.nse = nse
        self.notify = notifier
        self.universe = universe
        self.max_summaries = max_summaries
        self.state = store.get(STATE) or {}
        if self.state.get("schema") != SCHEMA:
            # New fields: reload history for every stock once.
            self.state["processed"] = [k for k in self.state.get("processed", []) if not k.startswith("res:")]
            self.state["backfilled"] = []
            self.state["schema"] = SCHEMA
        if self.state.get("trReset") != 1:
            # Transcripts dropped while the Gemini model was unavailable:
            # forget them so the announcement history walk queues them again
            # (existing summaries are skipped, so nothing is redone).
            self.state["processed"] = [k for k in self.state.get("processed", []) if not k.startswith("tr:")]
            self.state["historyCursor"] = None
            self.state["trReset"] = 1
        self.processed = set(self.state.get("processed", []))
        self.queue: List[Dict] = []  # legacy; transcripts now live in transcripts/{sym}
        self.backfilled = set(self.state.get("backfilled", []))
        self.today = now_ist().date()
        # Calendar events collected during this run, keyed by week id.
        self._cal: Dict[str, List[Dict]] = {}
        # Company announcements (news) collected during this run, by symbol.
        self._news: Dict[str, List[Dict]] = {}
        # Transcripts found this run, per symbol (merged into transcripts/{sym}).
        self._new_transcripts: Dict[str, List[Dict]] = {}
        self._orders: List[Dict] = []
        # Deals, ownership changes and red flags per symbol (activity/{sym}).
        self._activity: Dict[str, List[Dict]] = {}
        self._market_deals: List[Dict] = []
        # Daily NSE closing prices, cached per date for this run.
        self._bhav: Dict[str, Optional[Dict[str, float]]] = {}
        self.counters = self.state.setdefault("counters", {}).setdefault(self.today.isoformat(), {})
        for d in [d for d in self.state["counters"] if d < (self.today - timedelta(days=3)).isoformat()]:
            del self.state["counters"][d]

    # ----------------------------------------------------------------- state

    def save_state(self) -> None:
        self.state["processed"] = list(self.processed)[-MAX_PROCESSED:]

        self.state["backfilled"] = sorted(self.backfilled)
        self.state["lastRun"] = now_ist().isoformat()
        self.store.set(STATE, self.state)

    # -------------------------------------------------------------- universe

    def refresh_universe(self, force: bool = False) -> None:
        """Weekly: every NSE company with market cap ≥ MIN_MCAP (₹500 Cr by
        default), with names, sectors and the Nifty 500 flag. Automatic."""
        last = self.state.get("universeRefreshed")
        fresh = last and date.fromisoformat(last) > self.today - timedelta(days=UNIVERSE_REFRESH_DAYS)
        rule = f"{MIN_MCAP}/{TOP_N}/cap1"
        if not force and fresh and self.state.get("universeRule") == rule:
            return
        try:
            eq = {r["symbol"]: r for r in self.nse.all_equities()}
            n500 = {r["symbol"]: r for r in self.nse.nifty500()}
            caps = self.nse.market_caps()
        except Exception as e:
            log.warning("universe refresh failed, keeping current list: %s", e)
            return
        ranked = sorted((s for s in caps if s in eq and caps[s] >= MIN_MCAP), key=lambda s: -caps[s])
        if TOP_N > 0:
            ranked = ranked[:TOP_N]
        if len(ranked) < 500:  # sanity check before replacing
            log.warning("universe refresh: only %d ranked stocks, keeping current list", len(ranked))
            return
        uni = {}
        for rank, s in enumerate(ranked, 1):
            extra = n500.get(s, {})
            uni[s] = {"symbol": s, "name": extra.get("name") or eq[s]["name"],
                      "sector": extra.get("sector") or self.state.get("aiSectors", {}).get(s, ""),
                      "n500": "1" if s in n500 else "",
                      "mcap": round(caps[s]), "cap": _cap_class(rank)}
        self.universe = uni
        self.state["universeRefreshed"] = self.today.isoformat()
        self.state["universeRule"] = rule
        # Only the tracked universe matters for history loading.
        self.backfilled &= set(uni)
        log.info("universe: %d companies with market cap ≥ ₹%.0f Cr, %d in Nifty 500",
                 len(uni), MIN_MCAP, sum(1 for s in uni if uni[s]["n500"]))

    def sync_company_list(self) -> None:
        items = [{"symbol": s, "name": r["name"], "sector": r.get("sector", ""),
                  **({"n500": True} if r.get("n500") else {}),
                  **({"mcap": r["mcap"]} if r.get("mcap") else {}),
                  **({"cap": r["cap"]} if r.get("cap") else {})}
                 for s, r in sorted(self.universe.items())]
        h = _hash(items)
        if self.state.get("universeHash") != h:
            self.store.set("meta/companies", {"items": items, "updatedAt": now_ist().isoformat()})
            self.state["universeHash"] = h
            log.info("wrote meta/companies (%d companies)", len(items))

    # --------------------------------------------------------------- results

    def process_results(self, days: int) -> None:
        filings = self.nse.financial_results(self.today - timedelta(days=days), self.today)
        log.info("%d new result filings to check", len(filings))
        self._process_filings(filings, announce=True)
        # A company that just reported should never show a single quarter:
        # load its history right away if that hasn't happened yet.
        fresh = sorted({f.get("symbol") for f in filings
                        if f.get("symbol") in self.universe and f.get("symbol") not in self.backfilled})
        if fresh:
            self.backfill(fresh)

    def backfill(self, symbols: Optional[List[str]] = None, minutes: float = BACKFILL_MINUTES,
                 refresh_ratios_every: int = 0) -> None:
        """~3 years of results + shareholding history for stocks that don't
        have it yet, Nifty 500 first, for up to `minutes` per run."""
        import time as _t
        deadline = _t.time() + minutes * 60
        if symbols is None:
            todo = [s for s in self.universe if s not in self.backfilled]
            todo.sort(key=lambda s: -float(self.universe[s].get("mcap") or 0))
            symbols = todo
        done = 0
        for s in symbols:
            if _t.time() > deadline:
                break
            done += 1
            try:
                filings = self.nse.financial_results(symbol=s, include_legacy=True)
            except Exception as e:
                log.warning("history for %s failed: %s", s, e)
                continue
            self._process_filings(self._one_per_quarter(filings), announce=False)
            try:
                hist = ownership.history(self.nse, s)
                if hist:
                    self.store.set(f"companies/{s}", {"holding": hist}, merge=True)
            except Exception as e:
                log.warning("shareholding for %s failed: %s", s, e)
            self.enrich(s)
            self.backfilled.add(s)
            if len(self.backfilled) % 25 == 0:
                self.save_state()  # long backfills never lose progress
            if refresh_ratios_every and len(self.backfilled) % refresh_ratios_every == 0:
                try:
                    self.process_screener(force=True)
                except Exception as e:
                    log.warning("screener refresh failed: %s", e)
        if done:
            log.info("backfilled %d stocks (%d/%d done)", done, len(self.backfilled), len(self.universe))

    @staticmethod
    def _one_per_quarter(filings: List[Dict], keep: int = 12) -> List[Dict]:
        """Per quarter end keep one filing: consolidated preferred, latest filed."""
        best: Dict[date, Dict] = {}
        for f in filings:
            if not (f.get("xbrl") or "").lower().endswith(".xml"):
                continue
            qe = parse_nse_datetime(f.get("quarterEnd"))
            if not qe:
                continue
            key = qe.date()
            rank = (bool(f.get("consolidated")), parse_nse_datetime(f.get("filingDate")) or datetime.min)
            cur = best.get(key)
            if cur is None or rank > cur[0]:
                best[key] = (rank, f)
        chosen = sorted(best.items(), reverse=True)[:keep]
        return [f for _, (_, f) in chosen]

    def _process_filings(self, filings: List[Dict], announce: bool) -> None:
        # Oldest day first so revisions win; within a day consolidated first,
        # so the feed and push use consolidated numbers.
        def order(f):
            dt = parse_nse_datetime(f.get("filingDate")) or datetime.min
            return (dt.date(), not f.get("consolidated"), dt)

        for f in sorted(filings, key=order):
            sym = f.get("symbol")
            url = f.get("xbrl") or ""
            if sym not in self.universe or not url.lower().endswith(".xml"):
                continue
            key = "res:" + url
            if key in self.processed:
                continue
            try:
                quarters = parse_xbrl(self.nse.download(url))
            except Exception as e:
                log.warning("XBRL %s failed: %s", url, e)
                continue
            self.processed.add(key)
            if quarters:
                filed = parse_nse_datetime(f.get("filingDate"))
                if filed:
                    quarters[0].filedAt = filed.isoformat()
                    quarters[0].reaction = self.reaction(sym, filed)
                    if quarters[0].reaction is None and filed.date() >= self.today - timedelta(days=5):
                        pend = self.state.setdefault("reactionsPending", [])
                        if not any(p["symbol"] == sym and p["period"] == quarters[0].period for p in pend):
                            pend.append({"symbol": sym, "period": quarters[0].period, "filedAt": filed.isoformat()})
                self._update_company(sym, quarters, filed, announce)

    def _update_company(self, sym: str, quarters, filed: Optional[datetime], announce: bool) -> None:
        info = self.universe[sym]
        path = f"companies/{sym}"
        doc = self.store.get(path) or {}
        before = {q["period"]: bool(q.get("consolidated")) for q in doc.get("quarters", [])}
        merged = merge_quarters(doc.get("quarters", []), quarters)
        doc.update({"symbol": sym, "name": info["name"], "sector": info.get("sector", ""),
                    "quarters": merged, "updatedAt": now_ist().isoformat()})

        # Re-check pending guidance now that new numbers exist.
        items = self.store.list(f"{path}/guidance") if doc.get("credibility") is not None or announce else []
        for gid, item in items:
            if item.get("status", "pending") != "pending":
                continue
            status, actual = gd.evaluate(item, merged)
            if status != "pending":
                unit = " Cr" if item.get("metric") == "revenue" else "%"
                item.update(status=status, actual=f"{actual:g}{unit}")
                self.store.set(f"{path}/guidance/{gid}", item)
        if items:
            doc["credibility"] = gd.credibility([i for _, i in items])
        self.store.set(path, doc)

        # Results event on the calendar (past or present).
        filed_q = quarters[0]
        by_p = {q["period"]: q for q in merged}
        this_q = by_p.get(filed_q.period, filed_q.to_dict())
        ago = by_p.get(gd._prev_quarter_label(filed_q.period))
        rev_yoy = pct_change(this_q.get("revenue"), (ago or {}).get("revenue"))
        pat_yoy = pct_change(this_q.get("pat"), (ago or {}).get("pat"))
        if filed and filed.date() >= self.today - timedelta(days=CAL_PAST_DAYS):
            note = filed_q.period + (f" · Revenue {rev_yoy:+.1f}% YoY" if rev_yoy is not None else "")
            self.add_event(filed.date(), {"symbol": sym, "type": "results", "time": filed.strftime("%H:%M"),
                                          "note": note, "period": filed_q.period, "done": True})

        latest = merged[0]
        is_new = latest["period"] not in before
        upgraded = not is_new and latest.get("consolidated") and not before[latest["period"]]
        recent = filed is not None and filed.date() >= self.today - timedelta(days=1)
        if not (announce and recent and (is_new or upgraded) and latest["period"] == filed_q.period):
            return
        self._add_to_feed(sym, info["name"], latest, rev_yoy, pat_yoy, filed)
        if not is_new:
            return  # already pushed for the standalone filing
        body = f"Revenue ₹{latest.get('revenue') or 0:,.0f} Cr"
        if rev_yoy is not None:
            body += f" ({rev_yoy:+.1f}% YoY)"
        if latest.get("pat") is not None:
            body += f", profit ₹{latest['pat']:,.0f} Cr"
            if pat_yoy is not None:
                body += f" ({pat_yoy:+.1f}%)"
        self.notify.send(sym, f"{info['name']} {latest['period']} results out", body, {"type": "results"})

    @staticmethod
    def story(quarters: List[Dict]) -> List[str]:
        """Plain-English badges for the latest quarter (newest first list)."""
        if not quarters:
            return []
        q, hist = quarters[0], quarters[:12]
        out = []
        for key, label in (("revenue", "revenue"), ("pat", "profit")):
            vals = [x.get(key) for x in hist if x.get(key) is not None]
            if q.get(key) is not None and len(vals) >= 6:
                if q[key] >= max(vals):
                    out.append(f"Record {label}")
                elif q[key] <= min(vals):
                    out.append(f"Lowest {label} in {len(vals)} quarters")
        def margin(x):
            return x["ebitda"] / x["revenue"] * 100 if x.get("ebitda") is not None and x.get("revenue") else None
        ago = next((x for x in quarters[1:] if x["period"][:2] == q["period"][:2]), None)
        if ago and margin(q) is not None and margin(ago) is not None:
            d = (margin(q) - margin(ago)) * 100
            if abs(d) >= 100:
                out.append(f"Margin {'up' if d > 0 else 'down'} {abs(d):.0f} bps")
        if q.get("pat") is not None and ago and ago.get("pat") is not None:
            if q["pat"] > 0 >= ago["pat"]:
                out.append("Back to profit")
            elif q["pat"] < 0 <= ago["pat"]:
                out.append("Swung to loss")
        return out[:3]

    def _add_to_feed(self, sym, name, q, rev_yoy, pat_yoy, filed: datetime) -> None:
        today_id = self.today.isoformat()
        feed = self.store.get("feed/today") or {}
        if feed.get("date") != today_id:
            feed = {"date": today_id, "items": []}
        feed["items"] = [i for i in feed["items"] if i["symbol"] != sym]
        feed["items"].append({
            "symbol": sym, "name": name, "period": q["period"],
            "revenue": q.get("revenue"), "pat": q.get("pat"),
            "revenueYoY": rev_yoy, "patYoY": pat_yoy,
            "announcedAt": filed.isoformat(),
            "story": self.story((self.store.get(f"companies/{sym}") or {}).get("quarters", [])),
        })
        self.store.set("feed/today", feed)

    # ------------------------------------------------------ price reaction

    def _prices(self, d: date) -> Optional[Dict[str, float]]:
        import metrics
        k = d.isoformat()
        if k not in self._bhav:
            prices = None
            if d.weekday() < 5 and d <= self.today:
                try:
                    _, prices = metrics.latest_prices(self.nse, d, lookback=1)
                except Exception:
                    prices = None
            self._bhav[k] = prices or None
        return self._bhav[k]

    def reaction(self, sym: str, filed: datetime) -> Optional[float]:
        """% move of the stock on the first session that could react to the
        result: same day if filed before 15:30, else the next trading day,
        versus the previous trading day's close."""
        event = filed.date() if (filed.hour, filed.minute) < (15, 30) else filed.date() + timedelta(days=1)
        ev_day = None
        for i in range(7):
            d = event + timedelta(days=i)
            if d > self.today:
                return None
            p = self._prices(d)
            if p and sym in p:
                ev_day, ev_price = d, p[sym]
                break
        if ev_day is None:
            return None
        for i in range(1, 8):
            p = self._prices(ev_day - timedelta(days=i))
            if p and sym in p and p[sym]:
                return round((ev_price / p[sym] - 1) * 100, 2)
        return None

    def process_pending_reactions(self) -> None:
        pend = self.state.get("reactionsPending", [])
        keep = []
        for item in pend:
            filed = datetime.fromisoformat(item["filedAt"])
            r = self.reaction(item["symbol"], filed)
            if r is None:
                if filed.date() >= self.today - timedelta(days=10):
                    keep.append(item)
                continue
            path = f"companies/{item['symbol']}"
            doc = self.store.get(path) or {}
            for q in doc.get("quarters", []):
                if q["period"] == item["period"]:
                    q["reaction"] = r
            if doc:
                self.store.set(path, {"quarters": doc["quarters"]}, merge=True)
            feed = self.store.get("feed/today") or {}
            changed = False
            for f in feed.get("items", []):
                if f["symbol"] == item["symbol"] and f.get("period") == item["period"]:
                    f["reaction"] = r
                    changed = True
            if changed:
                self.store.set("feed/today", feed)
        self.state["reactionsPending"] = keep

    # -------------------------------------------------- orders / ratings / mgmt

    _MGMT = re.compile(r"change in (director|key managerial|management|auditor|senior management|kmp)"
                       r"|appointment of|re-?appointment|resignation of|cessation", re.I)
    _ROLE = re.compile(r"director|chief|ceo|cfo|coo|cto|managing|chairman|company secretary|"
                       r"auditor|key managerial|president|head", re.I)

    def _pdf(self, url: str, limit: int = 8000) -> str:
        if not url.lower().endswith(".pdf"):
            return ""
        try:
            from summarize import pdf_text
            return pdf_text(self.nse.download(url))[:limit]
        except Exception:
            return ""

    def _ttm_revenue(self, sym: str) -> Optional[float]:
        doc = self.store.get(f"companies/{sym}") or {}
        qs = doc.get("quarters", [])[:4]
        if len(qs) == 4 and all(q.get("revenue") for q in qs):
            return sum(q["revenue"] for q in qs)
        return None

    def _special_filing(self, sym: str, a: Dict, desc: str, text: str, url: str, filed: date) -> None:
        """Order wins, credit ratings and management changes."""
        key = "sp:" + (url or str(a.get("seq_id", "")) or _hash([sym, desc, text]))
        if key in self.processed:
            return
        low = f"{desc} {text}".lower()
        name = self.universe[sym]["name"]
        recent = filed >= self.today - timedelta(days=2)
        if "bagging" in low or "receiving of order" in low or "letter of award" in low or \
                re.search(r"\b(order|contract)s?\b.{0,40}\b(received|bagged|secured|won|awarded)", low):
            self.processed.add(key)
            info = extract.order(text + "\n" + self._pdf(url), name)
            rev = self._ttm_revenue(sym)
            pct = round(info["valueCr"] / rev * 100, 2) if info.get("valueCr") and rev else None
            item = {"kind": "order", "date": filed.isoformat(), "valueCr": info.get("valueCr"),
                    "pctRevenue": pct, "who": info.get("client"), "text": info.get("description"),
                    "detail": info.get("executionPeriod"), "url": url or None}
            self.add_activity(sym, item)
            self._orders.append({"symbol": sym, "name": name, **{k: v for k, v in item.items() if v is not None}})
            if recent and ((pct or 0) >= 2 or (info.get("valueCr") or 0) >= 250):
                v = f"₹{info['valueCr']:,.0f} Cr" if info.get("valueCr") else "New order"
                self.notify.send(sym, f"{name}: order win {v}",
                                 (f"{pct:.1f}% of annual revenue · " if pct else "") + (info.get("description") or ""),
                                 {"type": "order"})
            return
        if "credit rating" in low or re.search(r"\b(crisil|icra|care ratings|india ratings|acuite)\b", low):
            self.processed.add(key)
            info = extract.rating(text + "\n" + self._pdf(url), name)
            item = {"kind": "rating", "date": filed.isoformat(), "who": info.get("agency"),
                    "text": info.get("rating"), "detail": info.get("instrument"),
                    "side": info.get("action"), "outlook": info.get("outlook"),
                    "previous": info.get("previousRating"), "url": url or None}
            self.add_activity(sym, item)
            if recent and info.get("action") in ("upgrade", "downgrade"):
                self.notify.send(sym, f"{name}: credit rating {info['action']}",
                                 f"{info.get('agency') or ''} {info.get('rating') or ''} "
                                 f"{('(' + info['outlook'] + ')') if info.get('outlook') else ''}".strip(),
                                 {"type": "rating"})
            return
        if self._MGMT.search(low) and self._ROLE.search(low):
            self.processed.add(key)
            detail = " ".join(text.split())[:300] or desc
            pdf = self._pdf(url, 3000) if len(detail) < 120 else ""
            if pdf:
                detail = " ".join(pdf.split())[:400]
            change = "exit" if re.search(r"resign|cessation|step(s|ped)? down|retire", low) else "appointment"
            self.add_activity(sym, {"kind": "mgmt", "date": filed.isoformat(), "side": change,
                                    "text": desc.strip() or "Management change", "detail": detail,
                                    "url": url or None})

    def flush_orders(self) -> None:
        if not self._orders:
            return
        doc = self.store.get("orders/latest") or {}
        cutoff = (self.today - timedelta(days=30)).isoformat()
        seen = {(i["symbol"], i.get("date"), i.get("valueCr"), i.get("text")) for i in doc.get("items", [])}
        items = [i for i in doc.get("items", []) if (i.get("date") or "") >= cutoff]
        items += [i for i in self._orders if (i["symbol"], i.get("date"), i.get("valueCr"), i.get("text")) not in seen]
        items.sort(key=lambda i: (i.get("date") or "", i.get("valueCr") or 0), reverse=True)
        self.store.set("orders/latest", {"items": items[:400]})
        log.info("orders: %d new", len(self._orders))
        self._orders = []

    # ---------------------------------------------------------- dividends

    _DIV = re.compile(r"dividend[^0-9]*?(?:rs\.?|re\.?|₹|inr)\s*([\d.]+)", re.I)

    def dividends(self, sym: str) -> None:
        """3 years of dividends and corporate actions -> companies/{sym}."""
        from nse import nse_date
        try:
            rows = self.nse.get_json("/api/corporates-corporateActions", {
                "index": "equities", "symbol": sym,
                "from_date": nse_date(self.today - timedelta(days=3 * 365 + 30)),
                "to_date": nse_date(self.today + timedelta(days=60))})
        except Exception as e:
            log.warning("corporate actions for %s failed: %s", sym, e)
            return
        rows = rows if isinstance(rows, list) else rows.get("data", [])
        divs, actions = [], []
        for r in rows:
            ex = parse_nse_datetime(r.get("exDate"))
            subj = (r.get("subject") or "").strip()
            if not ex or not subj:
                continue
            actions.append({"exDate": ex.date().isoformat(), "subject": subj})
            for m in self._DIV.finditer(subj):
                try:
                    divs.append({"exDate": ex.date().isoformat(), "amount": float(m.group(1)),
                                 "kind": "interim" if "interim" in subj.lower() else
                                 "special" if "special" in subj.lower() else "final"})
                except ValueError:
                    pass
        divs.sort(key=lambda d: d["exDate"], reverse=True)
        actions.sort(key=lambda d: d["exDate"], reverse=True)
        self.store.set(f"companies/{sym}", {"dividends": divs, "corpActions": actions[:30]}, merge=True)

    def enrich(self, sym: str) -> None:
        """Per-company extras: calls & documents index, dividends."""
        self.index_transcripts(sym)
        self.dividends(sym)
        done = self.state.setdefault("enriched", {})
        done[sym] = ENRICH_VERSION

    def enrich_remaining(self, minutes: float) -> None:
        import time as _t
        deadline = _t.time() + minutes * 60
        done = self.state.setdefault("enriched", {})
        todo = sorted((s for s in self.universe if done.get(s) != ENRICH_VERSION),
                      key=lambda s: -float(self.universe[s].get("mcap") or 0))
        n = 0
        for s in todo:
            if _t.time() > deadline:
                break
            self.enrich(s)
            n += 1
        if n:
            log.info("enriched %d companies (%d/%d)", n,
                     sum(1 for s in self.universe if done.get(s) == ENRICH_VERSION), len(self.universe))

    # ----------------------------------------------------------------- IPOs

    def process_ipos(self) -> None:
        def price_on(sym: str, d: date) -> Optional[float]:
            for i in range(0, 5):
                p = self._prices(d - timedelta(days=i))
                if p and sym in p:
                    return p[sym]
            return None
        try:
            data = ipo.fetch(self.nse, self.today, price_on)
        except Exception as e:
            log.warning("IPOs failed: %s", e)
            return
        data["updatedAt"] = now_ist().isoformat()
        self.store.set("meta/ipos", data)
        log.info("ipos: %d open, %d upcoming, %d recently listed",
                 len(data["open"]), len(data["upcoming"]), len(data["listed"]))

    # ------------------------------------------------------- weekly report

    def process_weekly(self) -> None:
        now = now_ist()
        if now.weekday() != 6 or now.hour < 10 or self.state.get("weeklyDate") == self.today.isoformat():
            return
        self.state["weeklyDate"] = self.today.isoformat()
        self.notify.send_topic("digest", "Your weekly report is ready",
                               "Results, concalls, orders, deals and red flags for your watchlists this week.",
                               {"type": "weekly"})

    # ------------------------------------------------------------- activity

    def add_activity(self, sym: str, item: Dict) -> None:
        self._activity.setdefault(sym, []).append({k: v for k, v in item.items() if v is not None})

    def flush_activity(self, keep: int = 60) -> None:
        def key(i):
            return (i.get("kind"), i.get("date"), i.get("who"), i.get("side"), i.get("qty"),
                    i.get("text"), i.get("valueCr"))
        n = 0
        for sym, items in self._activity.items():
            doc = self.store.get(f"activity/{sym}") or {}
            existing = doc.get("items", [])
            seen = {key(i) for i in existing}
            new = [i for i in items if key(i) not in seen and not seen.add(key(i))]
            if not new:
                continue
            merged = sorted(existing + new, key=lambda i: i.get("date") or "", reverse=True)[:keep]
            self.store.set(f"activity/{sym}", {"symbol": sym, "items": merged})
            n += 1
        if self._market_deals:
            doc = self.store.get("deals/latest") or {}
            cutoff = (self.today - timedelta(days=4)).isoformat()
            allk = {key(i) for i in doc.get("items", [])}
            merged = [i for i in doc.get("items", []) if (i.get("date") or "") >= cutoff]
            merged += [i for i in self._market_deals if key(i) not in allk]
            merged.sort(key=lambda i: (i.get("date") or "", i.get("valueCr") or 0), reverse=True)
            self.store.set("deals/latest", {"items": merged[:500]})
        log.info("activity: updated %d companies", n)
        self._activity, self._market_deals = {}, []

    def process_deals(self, days: int) -> None:
        items: List[Dict] = []
        for name, fn in (("bulk/block", lambda: dl.bulk_block(self.nse)),
                         ("sast", lambda: dl.sast(self.nse, self.today - timedelta(days=days), self.today)),
                         ("insider", lambda: dl.insider(self.nse, self.today - timedelta(days=days), self.today))):
            try:
                items += fn()
            except Exception as e:
                log.warning("%s deals failed: %s", name, e)
        # Same party buying AND selling the same stock on the same day is
        # intraday trading, not a stake change: keep it, but don't alert.
        sides: Dict[tuple, set] = {}
        for d in items:
            sides.setdefault((d.get("symbol"), d.get("who"), d.get("date")), set()).add(d.get("side"))
        n = 0
        for d in items:
            if len(sides.get((d.get("symbol"), d.get("who"), d.get("date")), ())) > 1:
                d["intraday"] = True
            sym = d.pop("symbol", None)
            if sym not in self.universe:
                continue
            k = "deal:" + _hash([sym, d.get("kind"), d.get("date"), d.get("who"), d.get("side"), d.get("qty")])
            if k in self.processed:
                continue
            self.processed.add(k)
            self.add_activity(sym, d)
            self._market_deals.append({"symbol": sym, "name": self.universe[sym]["name"], **d})
            n += 1
            if dl.is_alert_worthy(d) and not d.get("intraday") \
                    and (d.get("date") or "") >= (self.today - timedelta(days=2)).isoformat():
                self.notify.send(sym, f"{self.universe[sym]['name']}: {d['kind']} deal", dl.describe(d),
                                 {"type": "deal"})
        log.info("deals: %d new", n)

    def process_shareholding(self, days: int) -> None:
        try:
            rows = ownership.latest_filings(self.nse, self.today - timedelta(days=days + 1), self.today)
        except Exception as e:
            log.warning("shareholding feed failed: %s", e)
            return
        n = 0
        for r in rows:
            sym = r.get("symbol")
            k = "shp:" + str(r.get("recordId"))
            if sym not in self.universe or k in self.processed:
                continue
            self.processed.add(k)
            try:
                hist = ownership.history(self.nse, sym)
            except Exception as e:
                log.warning("shareholding %s failed: %s", sym, e)
                continue
            if not hist:
                continue
            self.store.set(f"companies/{sym}", {"holding": hist}, merge=True)
            n += 1
            for ch in ownership.changes(hist):
                self.add_activity(sym, {"kind": "holding", "date": self.today.isoformat(), **ch})
                if ch["severity"] in ("high", "medium"):
                    self.notify.send(sym, f"{self.universe[sym]['name']}: shareholding change", ch["text"],
                                     {"type": "holding"})
        log.info("shareholding: %d companies updated", n)

    def process_corporate_actions(self) -> None:
        """Dividends, bonus, splits, buybacks, rights (once a day)."""
        if self.state.get("corpActionsDate") == self.today.isoformat():
            return
        from nse import nse_date
        try:
            rows = self.nse.get_json("/api/corporates-corporateActions", {
                "index": "equities",
                "from_date": nse_date(self.today - timedelta(days=CAL_PAST_DAYS)),
                "to_date": nse_date(self.today + timedelta(days=CAL_FUTURE_DAYS))})
        except Exception as e:
            log.warning("corporate actions failed: %s", e)
            return
        rows = rows if isinstance(rows, list) else rows.get("data", [])
        n = 0
        for r in rows:
            sym = r.get("symbol")
            ex = parse_nse_datetime(r.get("exDate"))
            if sym not in self.universe or not ex or (r.get("series") or "EQ") not in ("EQ", "BE"):
                continue
            self.add_event(ex.date(), {"symbol": sym, "type": "corp_action",
                                       "note": (r.get("subject") or "Corporate action").strip()})
            n += 1
        self.state["corpActionsDate"] = self.today.isoformat()
        log.info("corporate actions: %d", n)

    def process_ai_config(self) -> None:
        """Once a day: publish the Gemini model names the app's Ask AI should
        use (meta/config), so the app never calls a retired model."""
        if self.state.get("aiConfigDate") == self.today.isoformat() or not os.environ.get("GEMINI_API_KEY"):
            return
        try:
            from google import genai
            import summarize
            client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])
            cfg = {"aiModel": summarize.pick_model(client), "updatedAt": now_ist().isoformat()}
            try:
                cfg["aiModelLite"] = summarize.pick_model(client, lite=True)
            except Exception:
                pass
            self.store.set("meta/config", cfg, merge=True)
            self.state["aiConfigDate"] = self.today.isoformat()
            log.info("ai config: %s", cfg)
        except Exception as e:
            log.warning("ai config failed: %s", e)

    def process_digest(self) -> None:
        """Evening summary push to everyone (topic 'digest'), once a day."""
        now = now_ist()
        if (now.hour, now.minute) < (20, 30) or self.state.get("digestDate") == self.today.isoformat():
            return
        feed = self.store.get("feed/today") or {}
        items = feed.get("items", []) if feed.get("date") == self.today.isoformat() else []
        c = self.counters
        if not items and not c.get("summaries") and not c.get("flags"):
            self.state["digestDate"] = self.today.isoformat()
            return
        parts = []
        if items:
            parts.append(f"{len(items)} companies reported")
            best = max((i for i in items if i.get("patYoY") is not None), key=lambda i: i["patYoY"], default=None)
            if best:
                parts.append(f"top profit growth: {best['name']} {best['patYoY']:+.0f}%")
        if c.get("summaries"):
            parts.append(f"{c['summaries']} concall summaries")
        if c.get("flags"):
            parts.append(f"{c['flags']} red flags")
        self.notify.send_topic("digest", "Today in results", " · ".join(parts), {"type": "digest"})
        self.state["digestDate"] = self.today.isoformat()

    # -------------------------------------------------------------- calendar

    def add_event(self, d: date, e: Dict) -> None:
        if not (self.today - timedelta(days=CAL_PAST_DAYS) <= d <= self.today + timedelta(days=CAL_FUTURE_DAYS + 30)):
            return
        e = {k: v for k, v in e.items() if v is not None}
        e["date"] = d.isoformat()
        e.setdefault("name", self.universe.get(e["symbol"], {}).get("name", e["symbol"]))
        self._cal.setdefault(week_id(d), []).append(e)

    def flush_calendar(self) -> None:
        """Merge this run's events into the weekly docs; write only on change."""
        hashes = self.state.setdefault("calendarHashes", {})
        for wk, new in self._cal.items():
            doc = self.store.get(f"calendar/{wk}") or {}
            events = doc.get("events", [])
            index = {(x["symbol"], x["type"], x["date"]): x for x in events}
            for e in new:
                k = (e["symbol"], e["type"], e["date"])
                if k in index:
                    index[k].update(e)  # e.g. add period/summary flag later
                else:
                    # A concall found via its transcript may duplicate an intimation a day apart.
                    events.append(e)
                    index[k] = e
            events.sort(key=lambda x: (x["date"], x.get("time") or "99", x["symbol"]))
            h = _hash(events)
            if hashes.get(wk) != h:
                self.store.set(f"calendar/{wk}", {"week": wk, "events": events})
                hashes[wk] = h
        cutoff = week_id(self.today - timedelta(days=CAL_PAST_DAYS + 14))
        for wk in [w for w in hashes if w < cutoff]:
            del hashes[wk]
        log.info("calendar: updated %d week docs", len(self._cal))
        self._cal = {}

    def process_board_meetings(self) -> None:
        try:
            meetings = self.nse.board_meetings(self.today - timedelta(days=CAL_PAST_DAYS),
                                               self.today + timedelta(days=CAL_FUTURE_DAYS))
        except Exception as e:
            log.warning("board meetings failed: %s", e)
            return
        n = 0
        for m in meetings:
            sym = m.get("bm_symbol")
            if sym not in self.universe or not ann.is_results_meeting(
                    (m.get("bm_purpose") or "") + " " + (m.get("bm_desc") or "")):
                continue
            d = parse_nse_datetime(m.get("bm_date"))
            if d:
                past = d.date() < self.today
                self.add_event(d.date(), {"symbol": sym, "type": "results",
                                          "note": "Board meeting: financial results" if not past else None})
                n += 1
        log.info("board meetings: %d results meetings", n)

    def process_announcements(self, days: int, history: bool = True) -> None:
        """Recent window every run, plus HISTORY_DAYS_PER_RUN older days so the
        past 60 days of concalls / investor meets fill in automatically."""
        windows: List[Tuple[date, date]] = [(self.today - timedelta(days=days), self.today)]
        if history:
            cursor = date.fromisoformat(self.state.get("historyCursor") or (self.today - timedelta(days=days)).isoformat())
            oldest = self.today - timedelta(days=CAL_PAST_DAYS)
            if cursor > oldest:
                start = max(oldest, cursor - timedelta(days=HISTORY_DAYS_PER_RUN))
                windows.append((start, cursor - timedelta(days=1)))
                self.state["historyCursor"] = start.isoformat()
        for start, end in windows:
            if end < start:
                continue
            try:
                items = self.nse.announcements(start, end)
            except Exception as e:
                log.warning("announcements %s..%s failed: %s", start, end, e)
                continue
            self._handle_announcements(items)
            log.info("announcements %s..%s: %d items, %d transcripts queued", start, end, len(items), len(self.queue))

    def _handle_announcements(self, items: List[Dict]) -> None:
        from summarize import pdf_text

        for a in items:
            sym = a.get("symbol")
            if sym not in self.universe:
                continue
            desc, text, url = a.get("desc") or "", a.get("attchmntText") or "", a.get("attchmntFile") or ""
            filed_dt = parse_nse_datetime(a.get("an_dt") or a.get("sort_date")) or now_ist().replace(tzinfo=None)
            filed = filed_dt.date()
            flag = redflags.classify(desc, text)
            if desc or text:
                self._news.setdefault(sym, []).append({
                    "date": filed_dt.isoformat(), "title": desc.strip() or "Announcement",
                    "text": " ".join(text.split())[:300], "url": url or None,
                    **({"flag": flag["label"], "severity": flag["severity"]} if flag else {}),
                })
            if flag:
                fk = "flag:" + (url or str(a.get("seq_id", "")) or _hash([sym, desc, text]))
                if fk not in self.processed:
                    self.processed.add(fk)
                    self.add_activity(sym, {"kind": "flag", "date": filed.isoformat(), "type": flag["type"],
                                            "severity": flag["severity"], "text": flag["label"],
                                            "detail": " ".join(text.split())[:240], "url": url or None})
                    if filed >= self.today - timedelta(days=2):
                        self.counters["flags"] = self.counters.get("flags", 0) + 1
                        if flag["severity"] == "high":
                            self.notify.send(sym, f"⚠ {self.universe[sym]['name']}: {flag['label']}",
                                             " ".join(text.split())[:150] or desc, {"type": "flag"})
            self._special_filing(sym, a, desc, text, url, filed)
            if ann.is_transcript(desc, text) and url.lower().endswith(".pdf"):
                self._new_transcripts.setdefault(sym, []).append({"url": url, "filed": filed.isoformat()})
            elif url.lower().endswith(".pdf") and (dk := _doc_kind(desc, text)):
                self._new_transcripts.setdefault(sym, []).append(
                    {"url": url, "filed": filed.isoformat(), "doc": dk})
            elif ann.is_concall_intimation(desc, text):
                key = "int:" + (url or str(a.get("seq_id", "")))
                if key in self.processed:
                    continue
                body = text
                if url.lower().endswith(".pdf"):
                    try:
                        body = text + "\n" + pdf_text(self.nse.download(url))[:6000]
                    except Exception as e:
                        log.warning("intimation %s failed: %s", url, e)
                        continue
                self.processed.add(key)
                earnings = ann.is_earnings_call_text(body)
                d = ann.find_date(body, not_before=filed)
                if not d:
                    continue
                low = body.lower()
                tm = ann.find_time(body[low.find("time"):] if "time" in low else body)
                self.add_event(d, {
                    "symbol": sym,
                    "type": "concall" if earnings else "investor_meet",
                    "time": tm,
                    "note": "Earnings call" if earnings else ann.meet_kind(body),
                    "url": url or None,
                })

    def flush_news(self, keep: int = 40) -> None:
        """news/{symbol}: the company's latest NSE announcements (official news)."""
        n = 0
        for sym, items in self._news.items():
            doc = self.store.get(f"news/{sym}") or {}
            seen = {(i["date"], i["title"]) for i in doc.get("items", [])}
            new = []
            for i in items:
                k = (i["date"], i["title"])
                if k not in seen:
                    seen.add(k)
                    new.append(i)
            if not new:
                continue
            merged = sorted(doc.get("items", []) + new, key=lambda i: i["date"], reverse=True)[:keep]
            self.store.set(f"news/{sym}", {"symbol": sym, "items": merged})
            n += 1
        log.info("news: updated %d companies", n)
        self._news = {}

    # -------------------------------------------------------------- screener

    def process_screener(self, force: bool = False, chunk: int = 400) -> None:
        """Ratios for every stock -> screener/{n} docs (compact keys, ~400
        stocks each, to stay under Firestore's 1 MB document limit).
        Runs once per new trading day, or when forced (after a full load)."""
        import metrics

        trade_date, prices = metrics.latest_prices(self.nse, self.today)
        if not force and (not trade_date or self.state.get("screenerPriceDate") == trade_date):
            return
        companies = dict(self.store.list("companies"))
        rows = []
        backfill_ci = 0
        for sym, info in sorted(self.universe.items()):
            doc = companies.get(sym) or {}
            m = metrics.compute(doc.get("quarters", []), prices.get(sym), doc.get("dividends"), self.today)
            if not m and sym not in prices:
                continue
            if sym in prices and "p" not in m:
                m["p"] = round(prices[sym], 2)
            ci = doc.get("callInfo")
            if ci is None and "credibility" in doc and backfill_ci < 300:
                backfill_ci += 1  # companies summarised before callInfo existed
                try:
                    ci = self._update_call_info(sym)
                except Exception as e:
                    log.warning("callInfo %s failed: %s", sym, e)
            for src, key in (("gRev", "gr"), ("gPat", "gp"), ("gMgn", "gm"), ("gDir", "gd"),
                             ("tone", "tn"), ("cred", "cr")):
                if (ci or {}).get(src) is not None:
                    m[key] = ci[src]
            if (ci or {}).get("date"):
                try:
                    m["lc"] = (self.today - date.fromisoformat(ci["date"][:10])).days
                except ValueError:
                    pass
            rows.append({"s": sym, **m})
        old_chunks = self.state.get("screenerChunks", 0)
        n = 0
        for n, i in enumerate(range(0, len(rows), chunk)):
            self.store.set(f"screener/{n}", {"asOf": trade_date, "items": rows[i:i + chunk]})
        n_chunks = (len(rows) + chunk - 1) // chunk
        for extra in range(n_chunks, old_chunks):
            self.store.set(f"screener/{extra}", {"asOf": trade_date, "items": []})
        self.state["screenerChunks"] = n_chunks
        self.state["screenerPriceDate"] = trade_date
        log.info("screener: %d stocks, prices of %s, %d docs", len(rows), trade_date, n_chunks)
        try:
            self._season(rows, companies)
        except Exception as e:
            log.warning("season stats failed: %s", e)
        try:
            self._saved_screens(rows)
        except Exception as e:
            log.warning("saved screens failed: %s", e)

    def _update_call_info(self, sym: str, items: Optional[List[Dict]] = None) -> Dict:
        """Refresh companies/{sym}.callInfo (latest call tone, guidance, credibility)."""
        calls = [c for _, c in self.store.list(f"companies/{sym}/concalls") if c.get("v", 1) >= 2]
        if items is None:
            items = [x for _, x in self.store.list(f"companies/{sym}/guidance")]
        info = gd.call_info(calls, items)
        self.store.set(f"companies/{sym}", {"callInfo": info}, merge=True)
        if info.get("date") and self.state.setdefault("profiled", {}).get(sym) != info["date"]:
            q = self.state.setdefault("profileQueue", [])
            if sym not in q:
                q.append(sym)  # rewrite "future potential" from the new call
        return info

    def process_profiles(self, minutes: float = 4) -> None:
        """'About', 'future potential' and sector for every company (Gemini
        Flash-Lite, 8 companies per request). Biggest companies first; a
        company is redone when a newer concall has been summarised."""
        import company_profile as cp
        import time as _t
        from summarize import QuotaExceeded

        if not os.environ.get("GEMINI_API_KEY"):
            return
        done = self.state.setdefault("profiled", {})
        queue = [s for s in self.state.get("profileQueue", []) if s in self.universe]
        fresh = sorted((s for s in self.universe if s not in done and s not in queue),
                       key=lambda s: -(self.universe[s].get("mcap") or 0))
        sectors = sorted({u["sector"] for u in self.universe.values() if u.get("sector")}) or [
            "Financial Services", "Information Technology", "Healthcare", "FMCG", "Capital Goods",
            "Automobile and Auto Components", "Chemicals", "Construction", "Power", "Realty",
            "Metals & Mining", "Oil Gas & Consumable Fuels", "Consumer Durables", "Services",
            "Telecommunication", "Textiles", "Media Entertainment & Publication", "Consumer Services",
            "Construction Materials", "Diversified", "Forest Materials"]
        deadline = _t.time() + minutes * 60
        n = 0
        todo = queue + fresh
        while todo and _t.time() < deadline:
            batch, todo = todo[:cp.BATCH], todo[cp.BATCH:]
            items, call_dates = [], {}
            for sym in batch:
                u = self.universe[sym]
                notes = ""
                if sym in queue:
                    calls = [c for _, c in self.store.list(f"companies/{sym}/concalls")
                             if c.get("v", 1) >= 2 and c.get("kind", "earnings") in ("earnings", "analyst")]
                    if calls:
                        last = max(calls, key=lambda c: c.get("date") or "")
                        notes, call_dates[sym] = cp.concall_notes(last), last.get("date") or ""
                items.append({"symbol": sym, "name": u["name"], "sector": u.get("sector"), "notes": notes})
            try:
                got = cp.describe(items, sectors)
            except QuotaExceeded as e:
                log.warning("profiles paused (quota): %s", str(e)[:120])
                break
            except Exception as e:
                log.warning("profile batch failed: %s", e)
                continue
            for sym in batch:
                prof = got.get(sym)
                if not prof:
                    continue
                sector = self.universe[sym].get("sector") or prof["sector"]
                if not self.universe[sym].get("sector") and prof["sector"]:
                    self.universe[sym]["sector"] = prof["sector"]
                    self.state.setdefault("aiSectors", {})[sym] = prof["sector"]
                prof.update(v=cp.VERSION, at=self.today.isoformat(),
                            basis="concall" if call_dates.get(sym) else "general")
                self.store.set(f"companies/{sym}", {"profile": prof, "sector": sector}, merge=True)
                done[sym] = call_dates.get(sym, "")
                if sym in self.state.get("profileQueue", []):
                    self.state["profileQueue"].remove(sym)
                n += 1
        if n:
            log.info("profiles: %d written, %d still to do", n,
                     len([s for s in self.universe if s not in done]) + len(self.state.get("profileQueue", [])))

    def _saved_screens(self, rows: List[Dict]) -> None:
        """Users' saved screens (screens/{id}): push 'screen_{id}' when a
        stock newly qualifies. First evaluation only records members."""
        screens = self.store.list("screens")
        by_sym = {r["s"]: r for r in rows}
        pushes = 0
        for sid, sc in screens[:2000]:
            filters = sc.get("filters") or {}
            sector, n500, caps = sc.get("sector"), sc.get("n500"), set(sc.get("caps") or [])

            def ok(sym, r):
                info = self.universe.get(sym, {})
                if sector and info.get("sector") != sector:
                    return False
                if n500 and not info.get("n500"):
                    return False
                if caps and info.get("cap") not in caps:
                    return False
                for k, rng in filters.items():
                    v = r.get(k)
                    if v is None:
                        return False
                    lo, hi = (rng + [None, None])[:2] if isinstance(rng, list) else (None, None)
                    if lo is not None and v < lo or hi is not None and v > hi:
                        return False
                return True

            members = sorted(s for s, r in by_sym.items() if ok(s, r))
            before = sc.get("members")
            if before is not None:
                new = [s for s in members if s not in set(before)]
                if new:
                    names = ", ".join(self.universe.get(s, {}).get("name", s) for s in new[:3])
                    more = f" and {len(new) - 3} more" if len(new) > 3 else ""
                    self.notify.send_topic(f"screen_{sid}", f"New in your screen '{sc.get('name', '')}'",
                                           names + more, {"type": "screen", "screen": sid})
                    pushes += 1
            self.store.set(f"screens/{sid}", {"members": members[:500], "count": len(members),
                                              "checkedAt": now_ist().isoformat()}, merge=True)
        if screens:
            log.info("saved screens: %d checked, %d alerts", len(screens), pushes)

    def _season(self, rows: List[Dict], companies: Dict[str, Dict]) -> None:
        """Results-season scoreboard -> meta/season."""
        from statistics import median
        counts: Dict[str, int] = {}
        for r in rows:
            if r.get("q"):
                counts[r["q"]] = counts.get(r["q"], 0) + 1
        live = [q for q, n in counts.items() if n >= 50]
        if not live:
            return
        season = max(live, key=_pkey)
        cur = [r for r in rows if r.get("q") == season]

        def med(vals):
            vals = [v for v in vals if v is not None]
            return round(median(vals), 1) if vals else None

        def share(vals):
            vals = [v for v in vals if v is not None]
            return round(sum(1 for v in vals if v > 0) / len(vals) * 100) if vals else None

        sectors: Dict[str, List[Dict]] = {}
        for r in cur:
            sec = self.universe.get(r["s"], {}).get("sector") or ""
            if sec:
                sectors.setdefault(sec, []).append(r)
        sector_rows = sorted([
            {"sector": sec, "n": len(v), "rg": med(x.get("rg") for x in v),
             "pg": med(x.get("pg") for x in v), "ebm": med(x.get("ebm") for x in v)}
            for sec, v in sectors.items() if len(v) >= 3
        ], key=lambda x: -(x["pg"] if x["pg"] is not None else -999))

        def reaction(sym):
            for q in (companies.get(sym) or {}).get("quarters", [])[:1]:
                if q.get("period") == season:
                    return q.get("reaction")
            return None

        sizable = [r for r in cur if (r.get("mc") or 0) >= 1000 and r.get("pg") is not None]
        movers = [dict(s=r["s"], r=reaction(r["s"]), pg=r.get("pg")) for r in cur]
        movers = [m for m in movers if m["r"] is not None]
        pick = lambda r: {"s": r["s"], "rg": r.get("rg"), "pg": r.get("pg"), "mc": r.get("mc")}
        self.store.set("meta/season", {
            "season": season, "updatedAt": now_ist().isoformat(),
            "reported": len(cur), "total": len(self.universe),
            "revGrewPct": share(r.get("rg") for r in cur), "profitGrewPct": share(r.get("pg") for r in cur),
            "medianRevGrowth": med(r.get("rg") for r in cur), "medianProfitGrowth": med(r.get("pg") for r in cur),
            "sectors": sector_rows,
            "topProfit": [pick(r) for r in sorted(sizable, key=lambda r: -r["pg"])[:15]],
            "worstProfit": [pick(r) for r in sorted(sizable, key=lambda r: r["pg"])[:15]],
            "bestReaction": sorted(movers, key=lambda m: -m["r"])[:10],
            "worstReaction": sorted(movers, key=lambda m: m["r"])[:10],
        })
        log.info("season %s: %d reported", season, len(cur))

    # ----------------------------------------------------------- transcripts

    # Transcript index: transcripts/{sym} = {items: [{url, filed, period, done}]}
    # One earnings-call transcript per quarter, last TRANSCRIPT_QUARTERS
    # quarters. state["trPending"][sym] = {"n": pending, "latest": bool}.

    @staticmethod
    def _classify_call(filed: date) -> Tuple[str, str]:
        """(period, kind). The first transcript within ~75 days of a quarter end
        is that quarter's earnings call; others are analyst/investor calls."""
        qend = ann.latest_quarter_end_before(filed)
        kind = "earnings" if (filed - qend).days <= 75 else "analyst"
        return quarter_label(qend), kind

    def _merge_transcripts(self, sym: str, found: List[Dict]) -> None:
        path = f"transcripts/{sym}"
        doc = self.store.get(path) or {}
        by_url: Dict[str, Dict] = {i["url"]: i for i in doc.get("items", [])}
        # Investor presentations / press releases: keep the latest few.
        for f in [f for f in found if f.get("doc")]:
            if f["url"] in by_url:
                continue
            filed = date.fromisoformat(f["filed"][:10])
            period = quarter_label(ann.latest_quarter_end_before(filed))
            tag = "pres" if f["doc"] == "presentation" else "pr"
            by_url[f["url"]] = {"id": f"{period}-{tag}-{filed.strftime('%m%d')}", "period": period,
                                "kind": f["doc"], "url": f["url"], "filed": f["filed"][:10], "done": False}
        found = [f for f in found if not f.get("doc")]
        earnings_periods = {i["period"] for i in by_url.values() if i.get("kind") == "earnings"}
        cutoff = (self.today - timedelta(days=TRANSCRIPT_DAYS)).isoformat()
        for f in sorted(found, key=lambda x: x["filed"]):
            if f["url"] in by_url or f["filed"][:10] < cutoff:
                continue
            filed = date.fromisoformat(f["filed"][:10])
            period, kind = self._classify_call(filed)
            if kind == "earnings" and period in earnings_periods:
                kind = "analyst"  # a second call in the same results window
            if kind == "earnings":
                earnings_periods.add(period)
            cid = period if kind == "earnings" else f"{period}-{filed.strftime('%m%d')}"
            by_url[f["url"]] = {"id": cid, "period": period, "kind": kind, "url": f["url"],
                                "filed": f["filed"][:10], "done": False}
        calls = sorted((i for i in by_url.values() if i.get("kind") in ("earnings", "analyst")),
                       key=lambda i: i["filed"], reverse=True)[:MAX_CALLS]
        docs = []
        for kind in ("presentation", "press_release"):
            docs += sorted((i for i in by_url.values() if i.get("kind") == kind),
                           key=lambda i: i["filed"], reverse=True)[:MAX_DOCS]
        items = sorted(calls + docs, key=lambda i: i["filed"], reverse=True)
        if items != doc.get("items"):
            self.store.set(path, {"symbol": sym, "items": items})
        self._set_pending(sym, items)

    def _set_pending(self, sym: str, items: List[Dict]) -> None:
        pend = self.state.setdefault("trPending", {})
        n = sum(1 for i in items if not i.get("done"))
        if n:
            pend[sym] = {"n": n, "latest": bool(items) and not items[0].get("done")}
        else:
            pend.pop(sym, None)

    def index_transcripts(self, sym: str) -> None:
        """Find a company's earnings-call transcripts for the last ~5 quarters."""
        try:
            items = self.nse.announcements(self.today - timedelta(days=480), self.today, symbol=sym)
        except Exception as e:
            log.warning("transcript history for %s failed: %s", sym, e)
            return
        found = []
        for a in items:
            desc, text, url = a.get("desc") or "", a.get("attchmntText") or "", a.get("attchmntFile") or ""
            filed = parse_nse_datetime(a.get("an_dt") or a.get("sort_date"))
            if not filed or not url.lower().endswith(".pdf"):
                continue
            if ann.is_transcript(desc, text):
                found.append({"url": url, "filed": filed.date().isoformat()})
            elif (dk := _doc_kind(desc, text)):
                found.append({"url": url, "filed": filed.date().isoformat(), "doc": dk})
        self._merge_transcripts(sym, found)
        self.state.setdefault("trIndexed", [])
        if sym not in self.state["trIndexed"]:
            self.state["trIndexed"].append(sym)

    def index_remaining_transcripts(self, minutes: float) -> None:
        """Companies whose results history loaded before transcript indexing
        existed: index them too (time-boxed, biggest first)."""
        import time as _t
        deadline = _t.time() + minutes * 60
        done = set(self.state.get("trIndexed", []))
        todo = sorted((s for s in self.universe if s not in done),
                      key=lambda s: -float(self.universe[s].get("mcap") or 0))
        n = 0
        for s in todo:
            if _t.time() > deadline:
                break
            self.index_transcripts(s)
            n += 1
        if n:
            log.info("transcripts indexed for %d more companies (%d/%d)", n,
                     len(self.state.get("trIndexed", [])), len(self.universe))

    def flush_transcripts(self) -> None:
        # One-time migration of the old flat queue into the per-company index.
        old = self.state.pop("transcriptQueue", None) or []
        for q in old:
            self._new_transcripts.setdefault(q["symbol"], []).append({"url": q["url"], "filed": q["filed"]})
        for sym, found in self._new_transcripts.items():
            if sym in self.universe:
                self._merge_transcripts(sym, found)
        self._new_transcripts = {}
        pend = self.state.get("trPending", {})
        for sym in [s for s in pend if s not in self.universe]:
            del pend[sym]

    def process_transcripts(self) -> None:
        """Summarise pending transcripts: every company's latest call first
        (biggest companies first), then earlier quarters. Time-boxed."""
        from summarize import QuotaExceeded, pdf_text, summarise
        import time as _t

        self.flush_transcripts()
        deadline = _t.time() + SUMMARY_MINUTES * 60
        done = failures_in_a_row = 0
        pend = self.state.setdefault("trPending", {})

        def order():
            return sorted(pend, key=lambda s: (not pend[s].get("latest"),
                                               -float(self.universe.get(s, {}).get("mcap") or 0)))

        while pend and done < self.max_summaries and failures_in_a_row < 5 and _t.time() < deadline:
            sym = order()[0]
            tdoc = self.store.get(f"transcripts/{sym}") or {"items": []}
            items = tdoc.get("items", [])
            item = next((i for i in items if not i.get("done")), None)  # newest pending first
            if item is None:
                pend.pop(sym, None)
                continue
            period, url = item["period"], item["url"]
            cid, kind = item.get("id", period), item.get("kind", "earnings")
            filed = date.fromisoformat(item["filed"])
            path = f"companies/{sym}/concalls/{cid}"
            existing = self.store.get(path)
            if existing and existing.get("v", 1) >= SUMMARY_VERSION:
                item["done"] = True
                self.store.set(f"transcripts/{sym}", tdoc)
                self._set_pending(sym, items)
                continue
            company = self.store.get(f"companies/{sym}") or {}
            all_docs = [c for _, c in self.store.list(f"companies/{sym}/concalls") if c.get("v", 1) >= 2]
            is_doc = kind in ("presentation", "press_release")
            # Calls are compared with calls; documents with documents of the same kind.
            all_calls = [c for c in all_docs if (c.get("kind") == kind) if is_doc] if is_doc else \
                [c for c in all_docs if c.get("kind", "earnings") in ("earnings", "analyst")]
            earlier = [c for c in all_calls if (c.get("date") or "") < item["filed"]]
            prev = max(earlier, key=lambda c: c.get("date") or "") if earlier else None
            try:
                text = pdf_text(self.nse.download(url))
                if len(text) < 2000:
                    raise ValueError("transcript text too short (scanned PDF?)")
                label = {"earnings": period, "analyst": f"{period} (analyst / investor call)",
                         "presentation": f"{period} investor presentation",
                         "press_release": f"{period} press release"}.get(kind, period)
                result = summarise(text, name=self.universe[sym]["name"], symbol=sym, period=label,
                                   doc="call" if not is_doc else kind,
                                   previous=prev, lite=filed < self.today - timedelta(days=3))
            except QuotaExceeded:
                log.warning("Gemini quota reached; %d companies still have pending transcripts", len(pend))
                break
            except Exception as e:
                log.warning("transcript %s failed: %s", url, e)
                failures_in_a_row += 1
                item["tries"] = item.get("tries", 0) + 1
                if item["tries"] >= 3:
                    item["done"] = True  # give up on unreadable transcripts
                self.store.set(f"transcripts/{sym}", tdoc)
                self._set_pending(sym, items)
                continue

            call_date = filed
            try:
                if result.get("callDate"):
                    cd = date.fromisoformat(result["callDate"][:10])
                    if filed - timedelta(days=20) <= cd <= filed:
                        call_date = cd
            except ValueError:
                pass
            if is_doc:
                result["guidanceItems"] = []
            for g in result.get("guidanceItems", []):
                g.update(madeIn=period, callId=cid, target=gd.format_target(g))
            guidance_all = self.store.list(f"companies/{sym}/guidance")
            prev_id = (prev or {}).get("id") or (prev or {}).get("period")
            prev_guidance = [x for _, x in guidance_all
                             if prev and (x.get("callId") or x.get("madeIn")) == prev_id]
            gdiff = gd.diff(result.get("guidanceItems", []), prev_guidance) if prev else []
            doc = {
                "v": SUMMARY_VERSION, "id": cid, "kind": kind, "period": period,
                "callType": ("investor_presentation" if kind == "presentation" else
                             "press_release" if kind == "press_release" else
                             result.get("callType") or ("earnings_call" if kind == "earnings" else "analyst_meet")),
                "date": call_date.isoformat(), "filed": item["filed"], "transcriptUrl": url,
                "tone": result.get("tone", "neutral"), "toneChange": result.get("toneChange") or None,
                "summary": result.get("summary", {}), "model": _model_name(),
                "changes": result.get("changes") if prev else None,
                "previousPeriod": (prev.get("id") or prev.get("period")) if prev else None,
                "guidanceDiff": gdiff,
            }
            self.store.set(path, doc)
            for gid, gx in guidance_all:  # replace this call's guidance items
                if (gx.get("callId") or gx.get("madeIn")) == cid and gx.get("status") != "superseded":
                    self.store.set(f"companies/{sym}/guidance/{gid}", {"madeIn": period, "metric": "other",
                                                                     "statement": "", "status": "superseded"})
            for i, g in enumerate(result.get("guidanceItems", [])):
                status, actual = gd.evaluate(g, company.get("quarters", []))
                g["status"] = status
                if actual is not None:
                    g["actual"] = f"{actual:g}"
                self.store.set(f"companies/{sym}/guidance/{cid}-{i}", g)
            all_g = [x for _, x in self.store.list(f"companies/{sym}/guidance") if x.get("status") != "superseded"]
            if company:
                self.store.set(f"companies/{sym}", {"credibility": gd.credibility(all_g)}, merge=True)

            # An older call was added after a newer one: refresh the newer
            # call's "what changed" and guidance diff against this one.
            later = [c for c in all_calls if (c.get("date") or "") > doc["date"]]
            if later:
                nxt = min(later, key=lambda c: c.get("date") or "")
                prev_of_next = next((c for c in all_calls
                                     if (c.get("id") or c.get("period")) == nxt.get("previousPeriod")), None)
                if prev_of_next is None or (prev_of_next.get("date") or "") < doc["date"]:
                    self._recompare(sym, doc, nxt, all_g)
            if company:
                self._update_call_info(sym, all_g)

            if filed >= self.today - timedelta(days=60):
                self.add_event(call_date, {"symbol": sym, "type": "concall", "period": cid,
                                           "hasSummary": True,
                                           "note": f"{period} {'earnings' if kind == 'earnings' else 'analyst / investor'} call · summary ready"})
            item["done"] = True
            self.store.set(f"transcripts/{sym}", tdoc)
            self._set_pending(sym, items)
            done += 1
            failures_in_a_row = 0
            n_flags = len(((result.get("summary") or {}).get("en") or {}).get("redFlags", []))
            cuts = [g for g in gdiff if g["direction"] in ("cut", "dropped")]
            if filed >= self.today - timedelta(days=2):
                self.counters["summaries"] = self.counters.get("summaries", 0) + 1
                body = "Detailed summary, guidance and Q&A" + (f" · {n_flags} red flags" if n_flags else "")
                if cuts:
                    c0 = cuts[0]
                    body = (f"Guidance {c0['direction']}: {c0['label']} {c0['targetPeriod']} "
                            f"{c0.get('before', '')} → {c0.get('now', 'withdrawn')}. ") + body
                self.notify.send(sym, f"{self.universe[sym]['name']} {period} "
                                      f"{'concall' if kind == 'earnings' else 'analyst call'} summary ready",
                                 body, {"type": "concall", "period": cid})
            log.info("%s %s concall summarised", sym, cid)
        log.info("concalls: %d summarised this run; %d companies still pending", done, len(pend))

    def _recompare(self, sym: str, prev_doc: Dict, nxt: Dict, guidance: List[Dict]) -> None:
        from summarize import QuotaExceeded, compare
        pid, nid = prev_doc.get("id") or prev_doc["period"], nxt.get("id") or nxt["period"]
        prev_items = [g for g in guidance if (g.get("callId") or g.get("madeIn")) == pid]
        cur_items = [g for g in guidance if (g.get("callId") or g.get("madeIn")) == nid]
        update = {"previousPeriod": pid, "guidanceDiff": gd.diff(cur_items, prev_items)}
        try:
            ch = compare(prev_doc, nxt, name=self.universe[sym]["name"], symbol=sym)
            if ch:
                update["changes"] = ch
        except QuotaExceeded:
            pass
        self.store.set(f"companies/{sym}/concalls/{nid}", update, merge=True)

    # --------------------------------------------------------------- morning

    def morning_alerts(self) -> None:
        if self.state.get("morningDate") == self.today.isoformat():
            return
        self.state["morningDate"] = self.today.isoformat()
        doc = self.store.get(f"calendar/{week_id(self.today)}") or {}
        for e in doc.get("events", []):
            if e.get("date") != self.today.isoformat() or e.get("done") or e.get("symbol") not in self.universe:
                continue
            when = f" at {e['time']}" if e.get("time") else ""
            if e["type"] == "concall":
                self.notify.send(e["symbol"], f"{e['name']} concall today{when}",
                                 "Summary will appear in the app once the transcript is filed.",
                                 {"type": "concall_today"})
            elif e["type"] == "investor_meet":
                self.notify.send(e["symbol"], f"{e['name']} investor meet today{when}",
                                 e.get("note") or "Analyst / investor conference", {"type": "investor_meet"})
            else:
                self.notify.send(e["symbol"], f"{e['name']} results expected today",
                                 "Board meeting to approve quarterly results.", {"type": "results_today"})


def _model_name() -> str:
    import summarize
    return summarize._resolved or summarize.MODEL or "gemini"


def load_universe(store: Store) -> Dict[str, Dict[str, str]]:
    doc = store.get("meta/companies")
    if doc and doc.get("items"):
        return {i["symbol"]: {"symbol": i["symbol"], "name": i["name"], "sector": i.get("sector", ""),
                              "n500": "1" if i.get("n500") else "", "mcap": i.get("mcap"),
                              "cap": i.get("cap")}
                for i in doc["items"]}
    return load_csv_universe()


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--dry-run", action="store_true", help="write JSON to ./out, no push")
    p.add_argument("--out", default=str(HERE / "out"))
    p.add_argument("--symbols", help="comma-separated NSE symbols to limit the run")
    p.add_argument("--days", type=int, default=2, help="look-back window for new filings")
    p.add_argument("--backfill", action="store_true", help="backfill history for --symbols now")
    p.add_argument("--backfill-all", action="store_true",
                   help="one-off: load history for every remaining stock in this run")
    p.add_argument("--morning", action="store_true", help="send today's alerts")
    p.add_argument("--refresh-universe", action="store_true", help="force refresh of the NSE stock list")
    p.add_argument("--max-summaries", type=int, default=int(os.environ.get("MAX_SUMMARIES", "25")))
    p.add_argument("--skip-transcripts", action="store_true")
    p.add_argument("--no-history", action="store_true", help="skip the automatic backfill steps")
    args = p.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("pypdf").setLevel(logging.ERROR)  # font-encoding noise
    store: Store = LocalStore(args.out) if args.dry_run else FirestoreStore()
    nse = NseClient()
    universe = load_universe(store)
    symbols = [s.strip().upper() for s in args.symbols.split(",")] if args.symbols else None
    pipe = Pipeline(store, nse, Notifier(dry_run=args.dry_run), universe, args.max_summaries)

    if args.morning:
        pipe.morning_alerts()
        pipe.save_state()
        return
    try:
        if not symbols:
            pipe.refresh_universe(force=args.refresh_universe)
            pipe.sync_company_list()
        else:
            pipe.universe = {s: universe.get(s, {"symbol": s, "name": s, "sector": ""}) for s in symbols}
        pipe.process_results(args.days)
        pipe.process_deals(args.days)
        pipe.process_shareholding(args.days)
        if args.backfill and symbols:
            pipe.backfill(symbols, minutes=600)
        elif args.backfill_all:
            pipe.backfill(minutes=330, refresh_ratios_every=400)
            pipe.save_state()
            pipe.process_screener(force=True)
        elif not args.no_history and not symbols:
            # Automatic: every scheduled run loads more history until done,
            # and refreshes ratios as big batches land.
            before = len(pipe.backfilled)
            pipe.backfill()
            pipe.enrich_remaining(minutes=10)
            if len(pipe.backfilled) // 300 > before // 300:
                pipe.state["screenerPriceDate"] = None  # force a ratios refresh
        pipe.process_board_meetings()
        pipe.process_announcements(args.days, history=not args.no_history and not symbols)
        if not symbols:
            pipe.process_corporate_actions()
        pipe.flush_calendar()
        pipe.flush_news()
        pipe.flush_activity()
        pipe.flush_orders()
        if not symbols:
            pipe.process_ipos()
        pipe.process_pending_reactions()
        if not args.skip_transcripts:
            pipe.process_transcripts()
            pipe.flush_calendar()
        if not symbols:
            try:
                pipe.process_profiles(float(os.environ.get("PROFILE_MINUTES", "4")))
                pipe.sync_company_list()  # sectors filled in by profiles
            except Exception as e:
                log.warning("profiles failed: %s", e)
        if not symbols:
            try:  # after summaries, so the day's concall/guidance filters are current
                first = pipe.state.get("screenerV") != 3  # one-off rebuild adding guidance fields
                pipe.process_screener(force=first)
                pipe.state["screenerV"] = 3
            except Exception as e:  # ratios must never block results/summaries
                log.warning("screener failed: %s", e)
        if not symbols:
            pipe.process_digest()
            pipe.process_weekly()
            now = now_ist()
            if (now.hour, now.minute) >= (7, 50):
                pipe.morning_alerts()  # once a day: concalls / results today
    finally:
        pipe.save_state()


if __name__ == "__main__":
    main()

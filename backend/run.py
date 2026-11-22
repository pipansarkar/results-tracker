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
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).parent))

import announcements as ann  # noqa: E402
import deals as dl  # noqa: E402
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
# Every scheduled run spends up to this long loading history for stocks that
# don't have it yet, until the whole market is done. Fully automatic.
BACKFILL_MINUTES = float(os.environ.get("BACKFILL_MINUTES", "12"))
HISTORY_DAYS_PER_RUN = int(os.environ.get("HISTORY_DAYS_PER_RUN", "2"))


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
        self.queue: List[Dict] = self.state.get("transcriptQueue", [])
        self.backfilled = set(self.state.get("backfilled", []))
        self.today = now_ist().date()
        # Calendar events collected during this run, keyed by week id.
        self._cal: Dict[str, List[Dict]] = {}
        # Company announcements (news) collected during this run, by symbol.
        self._news: Dict[str, List[Dict]] = {}
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
        self.state["transcriptQueue"] = self.queue
        self.state["backfilled"] = sorted(self.backfilled)
        self.state["lastRun"] = now_ist().isoformat()
        self.store.set(STATE, self.state)

    # -------------------------------------------------------------- universe

    def refresh_universe(self, force: bool = False) -> None:
        """Weekly: all NSE equities, sectors and Nifty 500 flag merged in."""
        last = self.state.get("universeRefreshed")
        if not force and last and date.fromisoformat(last) > self.today - timedelta(days=UNIVERSE_REFRESH_DAYS):
            return
        try:
            eq = self.nse.all_equities()
            n500 = {r["symbol"]: r for r in self.nse.nifty500()}
        except Exception as e:
            log.warning("universe refresh failed, keeping current list: %s", e)
            return
        uni = {}
        for r in eq:
            s = r["symbol"]
            extra = n500.get(s, {})
            uni[s] = {"symbol": s, "name": extra.get("name") or r["name"],
                      "sector": extra.get("sector", ""), "n500": "1" if s in n500 else ""}
        if len(uni) > 1000:  # sanity check before replacing
            self.universe = uni
            self.state["universeRefreshed"] = self.today.isoformat()
            log.info("universe: %d NSE stocks (%d in Nifty 500)", len(uni), len(n500))

    def sync_company_list(self) -> None:
        items = [{"symbol": s, "name": r["name"], "sector": r.get("sector", ""),
                  **({"n500": True} if r.get("n500") else {})}
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
            todo.sort(key=lambda s: (not self.universe[s].get("n500"), s))
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

    # ------------------------------------------------------------- activity

    def add_activity(self, sym: str, item: Dict) -> None:
        self._activity.setdefault(sym, []).append({k: v for k, v in item.items() if v is not None})

    def flush_activity(self, keep: int = 60) -> None:
        def key(i):
            return (i.get("kind"), i.get("date"), i.get("who"), i.get("side"), i.get("qty"), i.get("text"))
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
            if ann.is_transcript(desc, text) and url.lower().endswith(".pdf"):
                key = "tr:" + url
                if key not in self.processed and not any(q["url"] == url for q in self.queue):
                    self.queue.append({"symbol": sym, "url": url, "filed": filed.isoformat(),
                                       "n500": bool(self.universe[sym].get("n500"))})
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

    def process_screener(self, force: bool = False, chunk: int = 600) -> None:
        """Ratios for every stock -> screener/{n} docs (compact keys, ~600
        stocks each, to stay under Firestore's 1 MB document limit).
        Runs once per new trading day, or when forced (after a full load)."""
        import metrics

        trade_date, prices = metrics.latest_prices(self.nse, self.today)
        if not force and (not trade_date or self.state.get("screenerPriceDate") == trade_date):
            return
        companies = dict(self.store.list("companies"))
        rows = []
        for sym, info in sorted(self.universe.items()):
            doc = companies.get(sym) or {}
            m = metrics.compute(doc.get("quarters", []), prices.get(sym))
            if not m and sym not in prices:
                continue
            if sym in prices and "p" not in m:
                m["p"] = round(prices[sym], 2)
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

    def process_transcripts(self) -> None:
        from summarize import QuotaExceeded, pdf_text, summarise

        # Nifty 500 first, newest first.
        self.queue.sort(key=lambda q: q["filed"], reverse=True)
        self.queue.sort(key=lambda q: not q.get("n500"))  # stable: keeps newest-first within groups
        done = 0
        failures_in_a_row = 0
        while self.queue and done < self.max_summaries and failures_in_a_row < 5:
            item = self.queue[0]
            sym, url = item["symbol"], item["url"]
            if sym not in self.universe:
                self.queue.pop(0)
                continue
            filed = date.fromisoformat(item["filed"])
            company = self.store.get(f"companies/{sym}") or {}
            period = next((q["period"] for q in company.get("quarters", [])
                           if q["endDate"] < filed.isoformat()), None) \
                or quarter_label(ann.latest_quarter_end_before(filed))
            path = f"companies/{sym}/concalls/{period}"
            if self.store.get(path):
                self.queue.pop(0)
                self.processed.add("tr:" + url)
                continue
            try:
                text = pdf_text(self.nse.download(url))
                if len(text) < 2000:
                    raise ValueError("transcript text too short (scanned PDF?)")
                earlier = [c for _, c in self.store.list(f"companies/{sym}/concalls")
                           if _pkey(c.get("period", "")) < _pkey(period)]
                prev = max(earlier, key=lambda c: _pkey(c["period"])) if earlier else None
                result = summarise(text, name=self.universe[sym]["name"], symbol=sym,
                                   period=period, previous=prev)
            except QuotaExceeded:
                log.warning("Gemini quota reached; %d transcripts left for next run", len(self.queue))
                break
            except Exception as e:
                log.warning("transcript %s failed: %s", url, e)
                failures_in_a_row += 1
                item["tries"] = item.get("tries", 0) + 1
                self.queue.pop(0)
                if item["tries"] < 3:
                    self.queue.append(item)
                else:
                    self.processed.add("tr:" + url)
                continue

            call_date = filed
            try:
                if result.get("callDate"):
                    cd = date.fromisoformat(result["callDate"][:10])
                    if filed - timedelta(days=20) <= cd <= filed:
                        call_date = cd
            except ValueError:
                pass
            for g in result.get("guidanceItems", []):
                g.update(madeIn=period, target=gd.format_target(g))
            prev_guidance = [x for _, x in self.store.list(f"companies/{sym}/guidance")
                             if prev and x.get("madeIn") == prev.get("period")]
            gdiff = gd.diff(result.get("guidanceItems", []), prev_guidance) if prev else []
            self.store.set(path, {
                "period": period, "date": call_date.isoformat(), "transcriptUrl": url,
                "tone": result.get("tone", "neutral"), "toneChange": result.get("toneChange") or None,
                "summary": result.get("summary", {}), "model": _model_name(),
                "changes": result.get("changes") or None,
                "previousPeriod": prev.get("period") if prev else None,
                "guidanceDiff": gdiff,
            })
            for i, g in enumerate(result.get("guidanceItems", [])):
                status, actual = gd.evaluate(g, company.get("quarters", []))
                g["status"] = status
                if actual is not None:
                    g["actual"] = f"{actual:g}"
                self.store.set(f"companies/{sym}/guidance/{period}-{i}", g)
            all_g = [x for _, x in self.store.list(f"companies/{sym}/guidance")]
            if company:
                self.store.set(f"companies/{sym}", {"credibility": gd.credibility(all_g)}, merge=True)
            self.add_event(call_date, {"symbol": sym, "type": "concall", "period": period,
                                       "hasSummary": True, "note": f"{period} earnings call · summary ready"})

            self.queue.pop(0)
            self.processed.add("tr:" + url)
            done += 1
            failures_in_a_row = 0
            n_flags = len(((result.get("summary") or {}).get("en") or {}).get("redFlags", []))
            cuts = [g for g in gdiff if g["direction"] in ("cut", "dropped")]
            if filed >= self.today - timedelta(days=2):
                self.counters["summaries"] = self.counters.get("summaries", 0) + 1
                body = "Key points, guidance and Q&A" + (f" · {n_flags} red flags" if n_flags else "")
                if cuts:
                    c0 = cuts[0]
                    body = (f"Guidance {c0['direction']}: {c0['label']} {c0['targetPeriod']} "
                            f"{c0.get('before', '')} → {c0.get('now', 'withdrawn')}. ") + body
                self.notify.send(sym, f"{self.universe[sym]['name']} {period} concall summary ready",
                                 body, {"type": "concall", "period": period})
            log.info("%s %s concall summarised", sym, period)

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
                              "n500": "1" if i.get("n500") else ""} for i in doc["items"]}
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
            if len(pipe.backfilled) // 300 > before // 300:
                pipe.state["screenerPriceDate"] = None  # force a ratios refresh
        pipe.process_board_meetings()
        pipe.process_announcements(args.days, history=not args.no_history and not symbols)
        if not symbols:
            pipe.process_corporate_actions()
        pipe.flush_calendar()
        pipe.flush_news()
        pipe.flush_activity()
        pipe.process_pending_reactions()
        if not symbols:
            try:
                pipe.process_screener()
            except Exception as e:  # ratios must never block results/summaries
                log.warning("screener failed: %s", e)
        if not args.skip_transcripts:
            pipe.process_transcripts()
            pipe.flush_calendar()
        if not symbols:
            pipe.process_digest()
            now = now_ist()
            if (now.hour, now.minute) >= (7, 50):
                pipe.morning_alerts()  # once a day: concalls / results today
    finally:
        pipe.save_state()


if __name__ == "__main__":
    main()

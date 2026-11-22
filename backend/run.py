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
MAX_PROCESSED = 8000

CAL_PAST_DAYS = 60        # calendar keeps / back-fills this many past days
CAL_FUTURE_DAYS = 45
UNIVERSE_REFRESH_DAYS = 7
BACKFILL_PER_RUN = int(os.environ.get("BACKFILL_PER_RUN", "15"))
HISTORY_DAYS_PER_RUN = int(os.environ.get("HISTORY_DAYS_PER_RUN", "2"))
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")


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
        self.processed = set(self.state.get("processed", []))
        self.queue: List[Dict] = self.state.get("transcriptQueue", [])
        self.backfilled = set(self.state.get("backfilled", []))
        self.today = now_ist().date()
        # Calendar events collected during this run, keyed by week id.
        self._cal: Dict[str, List[Dict]] = {}

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

    def backfill(self, symbols: Optional[List[str]] = None, limit: int = BACKFILL_PER_RUN) -> None:
        """~3 years of quarterly history, a batch of stocks per run."""
        if symbols is None:
            todo = [s for s in self.universe if s not in self.backfilled]
            todo.sort(key=lambda s: (not self.universe[s].get("n500"), s))
            symbols = todo[:limit]
        for s in symbols:
            try:
                filings = self.nse.financial_results(symbol=s, include_legacy=True)
            except Exception as e:
                log.warning("history for %s failed: %s", s, e)
                continue
            self._process_filings(self._one_per_quarter(filings), announce=False)
            self.backfilled.add(s)
        if symbols:
            log.info("backfilled %d stocks (%d/%d done)", len(symbols), len(self.backfilled), len(self.universe))

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
            cursor = date.fromisoformat(self.state.get("historyCursor", (self.today - timedelta(days=days)).isoformat()))
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
            filed = (parse_nse_datetime(a.get("an_dt") or a.get("sort_date")) or now_ist()).date()
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

    # ----------------------------------------------------------- transcripts

    def process_transcripts(self) -> None:
        from summarize import QuotaExceeded, pdf_text, summarise

        # Nifty 500 first, newest first.
        self.queue.sort(key=lambda q: q["filed"], reverse=True)
        self.queue.sort(key=lambda q: not q.get("n500"))  # stable: keeps newest-first within groups
        done = 0
        while self.queue and done < self.max_summaries:
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
                prev_calls = sorted(self.store.list(f"companies/{sym}/concalls"), reverse=True)
                prev = prev_calls[0][1] if prev_calls else None
                result = summarise(text, name=self.universe[sym]["name"], symbol=sym,
                                   period=period, previous=prev)
            except QuotaExceeded:
                log.warning("Gemini quota reached; %d transcripts left for next run", len(self.queue))
                break
            except Exception as e:
                log.warning("transcript %s failed: %s", url, e)
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
            self.store.set(path, {
                "period": period, "date": call_date.isoformat(), "transcriptUrl": url,
                "tone": result.get("tone", "neutral"), "toneChange": result.get("toneChange") or None,
                "summary": result.get("summary", {}), "model": GEMINI_MODEL,
            })
            for i, g in enumerate(result.get("guidanceItems", [])):
                g.update(madeIn=period, target=gd.format_target(g))
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
            n_flags = len(((result.get("summary") or {}).get("en") or {}).get("redFlags", []))
            if filed >= self.today - timedelta(days=2):
                self.notify.send(sym, f"{self.universe[sym]['name']} {period} concall summary ready",
                                 "Key points, guidance and Q&A" + (f" · {n_flags} red flags" if n_flags else ""),
                                 {"type": "concall", "period": period})
            log.info("%s %s concall summarised", sym, period)

    # --------------------------------------------------------------- morning

    def morning_alerts(self) -> None:
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
    p.add_argument("--morning", action="store_true", help="send today's alerts")
    p.add_argument("--refresh-universe", action="store_true", help="force refresh of the NSE stock list")
    p.add_argument("--max-summaries", type=int, default=int(os.environ.get("MAX_SUMMARIES", "8")))
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
        return
    try:
        if not symbols:
            pipe.refresh_universe(force=args.refresh_universe)
            pipe.sync_company_list()
        else:
            pipe.universe = {s: universe.get(s, {"symbol": s, "name": s, "sector": ""}) for s in symbols}
        pipe.process_results(args.days)
        if args.backfill and symbols:
            pipe.backfill(symbols)
        elif not args.no_history and not symbols:
            pipe.backfill()
        pipe.process_board_meetings()
        pipe.process_announcements(args.days, history=not args.no_history and not symbols)
        pipe.flush_calendar()
        if not args.skip_transcripts:
            pipe.process_transcripts()
            pipe.flush_calendar()
    finally:
        pipe.save_state()


if __name__ == "__main__":
    main()

import sys
from datetime import date, datetime, timedelta
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))

import announcements as ann  # noqa: E402
import guidance as gd  # noqa: E402
from notify import Notifier, topic_for  # noqa: E402
from store import LocalStore  # noqa: E402
from xbrl import Quarter, merge_quarters, parse_xbrl, pct_change, quarter_label  # noqa: E402

FIX = Path(__file__).parent / "fixtures"


# ------------------------------------------------------------------- xbrl

def test_parse_xbrl_picks_quarter_contexts_and_converts_to_crore():
    qs = parse_xbrl((FIX / "sample_results.xml").read_bytes())
    assert [q.period for q in qs] == ["Q2FY27", "Q2FY26"]
    cur, ago = qs
    assert cur.consolidated is True
    assert cur.revenue == 1200.0
    # EBITDA = PBT + finance + D&A - other income = 200 + 10 + 30 - 20
    assert cur.ebitda == 220.0
    assert cur.otherIncome == 20.0 and cur.financeCost == 10.0 and cur.pbt == 200.0
    assert cur.pat == 145.0  # attributable to owners, not total PAT
    assert cur.eps == 12.35 or cur.eps == 12.34  # float rounding
    assert ago.revenue == 1000.0
    assert pct_change(cur.revenue, ago.revenue) == 20.0


@pytest.mark.parametrize("d,label", [
    (date(2026, 6, 30), "Q1FY27"), (date(2026, 9, 30), "Q2FY27"),
    (date(2026, 12, 31), "Q3FY27"), (date(2027, 3, 31), "Q4FY27"),
])
def test_quarter_label(d, label):
    assert quarter_label(d) == label


def test_merge_keeps_consolidated_over_standalone():
    existing = [{"period": "Q2FY27", "endDate": "2026-09-30", "revenue": 100, "consolidated": True}]
    new = [Quarter("Q2FY27", "2026-09-30", 90, None, None, None, consolidated=False),
           Quarter("Q1FY27", "2026-06-30", 80, None, None, None, consolidated=False)]
    out = merge_quarters(existing, new)
    assert [q["period"] for q in out] == ["Q2FY27", "Q1FY27"]
    assert out[0]["revenue"] == 100


def test_pct_change_edge_cases():
    assert pct_change(None, 1) is None
    assert pct_change(1, 0) is None
    assert pct_change(-50, -100) == 50.0


# -------------------------------------------------------------- guidance

def _quarters():
    # FY26 and FY27 quarters: FY27 revenue 20% higher, margin 20%.
    qs = []
    for fy, rev in ((26, 100.0), (27, 120.0)):
        for qn, end in ((1, "06-30"), (2, "09-30"), (3, "12-31"), (4, "03-31")):
            year = 2000 + fy if qn == 4 else 2000 + fy - 1
            qs.append({"period": f"Q{qn}FY{fy}", "endDate": f"{year}-{end}",
                       "revenue": rev, "ebitda": rev * 0.2, "pat": rev * 0.1})
    return sorted(qs, key=lambda q: q["endDate"], reverse=True)


def test_guidance_quarter_and_full_year():
    qs = _quarters()
    assert gd.evaluate({"metric": "revenue_growth_yoy", "low": 18, "targetPeriod": "Q2FY27"}, qs) == ("met", 20.0)
    assert gd.evaluate({"metric": "revenue_growth_yoy", "low": 25, "high": 28, "targetPeriod": "FY27"}, qs) == ("missed", 20.0)
    assert gd.evaluate({"metric": "ebitda_margin", "low": 20.3, "targetPeriod": "FY27"}, qs)[0] == "met"  # tolerance
    assert gd.evaluate({"metric": "ebitda_margin", "low": 20, "targetPeriod": "Q1FY28"}, qs) == ("pending", None)
    assert gd.evaluate({"metric": "other", "targetPeriod": "FY27"}, qs) == ("pending", None)


def test_credibility_and_target_format():
    items = [{"status": "met"}, {"status": "met"}, {"status": "missed"}, {"status": "pending"}]
    assert gd.credibility(items) == {"score": 67, "met": 2, "missed": 1, "pending": 1}
    assert gd.format_target({"metric": "ebitda_margin", "low": 15, "high": 18}) == "15–18%"
    assert gd.format_target({"metric": "revenue_growth_yoy", "low": 20, "high": None}) == "≥ 20%"


# --------------------------------------------------------- announcements

def test_classify_announcements():
    desc = "Analysts/Institutional Investor Meet/Con. Call Updates"
    assert ann.is_transcript(desc, "Transcript of the earnings conference call held on Nov 12, 2026")
    assert not ann.is_concall_intimation(desc, "Transcript of the earnings conference call")
    assert ann.is_concall_intimation(desc, "Intimation of earnings call scheduled on 25th November, 2026 at 4:00 PM IST")
    assert not ann.is_concall_intimation(desc, "Audio recording of the earnings call")


@pytest.mark.parametrize("text,expected", [
    ("call scheduled on 25th November, 2026 at 4:00 PM", date(2026, 11, 25)),
    ("call on November 25, 2026", date(2026, 11, 25)),
    ("meeting on 25-11-2026", date(2026, 11, 25)),
    ("letter dated 1st Nov 2026; call on 3rd December 2026", date(2026, 12, 3)),
    ("call on 29th October, 2826", None),
])
def test_find_date(text, expected):
    assert ann.find_date(text, not_before=date(2026, 11, 21)) == expected


@pytest.mark.parametrize("text,expected", [
    ("at 4:00 PM IST", "16:00"), ("at 11.30 a.m.", "11:30"), ("at 16:30 hrs", "16:30"), ("at 4.00", "16:00"),
])
def test_find_time(text, expected):
    assert ann.find_time(text) == expected


def test_latest_quarter_end_before():
    assert ann.latest_quarter_end_before(date(2026, 11, 21)) == date(2026, 9, 30)
    assert ann.latest_quarter_end_before(date(2027, 1, 20)) == date(2026, 12, 31)


# ----------------------------------------------------------- misc / store

def test_topic_matches_flutter():
    assert topic_for("M&M") == "stock_M_M"
    assert topic_for("BAJAJ-AUTO") == "stock_BAJAJ-AUTO"


def test_local_store_roundtrip(tmp_path):
    s = LocalStore(str(tmp_path))
    s.set("companies/M&M", {"a": 1})
    s.set("companies/M&M", {"b": 2}, merge=True)
    assert s.get("companies/M&M") == {"a": 1, "b": 2}
    s.set("companies/TCS/guidance/x", {"status": "met"})
    assert s.list("companies/TCS/guidance") == [("x", {"status": "met"})]


def test_pipeline_results_flow_with_fake_nse(tmp_path):
    import run

    xml = (FIX / "sample_results.xml").read_bytes()
    now = run.now_ist()
    today = now.date()
    past = today - timedelta(days=10)
    future = today + timedelta(days=5)
    desc = "Analysts/Institutional Investor Meet/Con. Call Updates"

    class FakeNse:
        def financial_results(self, *a, **k):
            return [{"symbol": "TEST", "xbrl": "https://x/test.xml", "consolidated": True,
                     "quarterEnd": "30-Sep-2026", "filingDate": now.strftime("%d-%b-%Y %H:%M")}]

        def download(self, url):
            return xml

        def board_meetings(self, *a):
            return [{"bm_symbol": "TEST", "bm_purpose": "Financial Results",
                     "bm_date": future.strftime("%d-%b-%Y")}]

        def announcements(self, *a, **k):
            return [
                {"symbol": "TEST", "desc": desc, "seq_id": "1", "attchmntFile": "",
                 "an_dt": past.strftime("%d-%b-%Y 10:00:00"),
                 "attchmntText": "Intimation: Earnings conference call to discuss results scheduled on "
                                 + (past + timedelta(days=2)).strftime("%d %B %Y") + " at 4:00 PM"},
                {"symbol": "TEST", "desc": desc, "seq_id": "2", "attchmntFile": "",
                 "an_dt": now.strftime("%d-%b-%Y 10:00:00"),
                 "attchmntText": "Intimation of schedule: will participate in Investor Conference on "
                                 + future.strftime("%d %B %Y") + " at 11:00 AM"},
            ]

    store = LocalStore(str(tmp_path))
    store.set("companies/TEST/guidance/g1",
              {"metric": "revenue_growth_yoy", "low": 15, "targetPeriod": "Q2FY27", "status": "pending"})
    notifier = Notifier(dry_run=True)
    uni = {"TEST": {"symbol": "TEST", "name": "Test Ltd", "sector": "X", "n500": "1"}}
    pipe = run.Pipeline(store, FakeNse(), notifier, dict(uni), 0)
    pipe.process_results(days=1)
    pipe.backfill()  # same filing again: already processed, must be a no-op
    pipe.process_board_meetings()
    pipe.process_announcements(days=2)
    pipe.flush_calendar()
    pipe.flush_news()
    pipe.save_state()

    news = store.get("news/TEST")["items"]
    assert len(news) == 2 and news[0]["title"].startswith("Analysts")
    doc = store.get("companies/TEST")
    assert doc["quarters"][0]["period"] == "Q2FY27"
    assert doc["credibility"]["met"] == 1
    assert store.get("companies/TEST/guidance/g1")["status"] == "met"
    assert store.get("feed/today")["items"][0]["revenueYoY"] == 20.0
    assert notifier.sent and notifier.sent[0][0] == "stock_TEST"
    assert "TEST" in store.get("pipeline_state/main")["backfilled"]

    def events(d):
        wk = store.get(f"calendar/{run.week_id(d)}") or {"events": []}
        return {(e["type"], e["date"]) for e in wk["events"]}

    assert ("results", today.isoformat()) in events(today)              # reported today
    assert ("results", future.isoformat()) in events(future)            # upcoming board meeting
    assert ("investor_meet", future.isoformat()) in events(future)      # investor conference
    call = past + timedelta(days=2)
    assert ("concall", call.isoformat()) in events(call)                # past concall

    # Second run is idempotent: no duplicate push, no duplicate events.
    pipe2 = run.Pipeline(store, FakeNse(), Notifier(dry_run=True), dict(uni), 0)
    pipe2.process_results(days=1)
    pipe2.process_board_meetings()
    pipe2.flush_calendar()
    assert pipe2.notify.sent == []
    wk = store.get(f"calendar/{run.week_id(future)}")["events"]
    assert len([e for e in wk if e["type"] == "results" and e["date"] == future.isoformat()]) == 1


def test_one_per_quarter_prefers_consolidated():
    import run
    fs = [
        {"symbol": "A", "xbrl": "s.xml", "consolidated": False, "quarterEnd": "30-Sep-2026", "filingDate": "08-Oct-2026 10:00"},
        {"symbol": "A", "xbrl": "c.xml", "consolidated": True, "quarterEnd": "30-Sep-2026", "filingDate": "08-Oct-2026 09:00"},
        {"symbol": "A", "xbrl": "-", "consolidated": True, "quarterEnd": "30-Jun-2026", "filingDate": "08-Jul-2026 09:00"},
    ]
    assert [f["xbrl"] for f in run.Pipeline._one_per_quarter(fs)] == ["c.xml"]


def test_week_id_is_monday():
    import run
    assert run.week_id(date(2026, 11, 21)) == "2026-11-16"
    assert run.week_id(date(2026, 11, 16)) == "2026-11-16"


@pytest.mark.parametrize("body,expected", [
    ("we will host an Earnings Conference Call on November 27, 2026 at 4:00 PM to discuss results", True),
    ("Conference Call to discuss the financial results for the quarter ended September 30, 2026", True),
    ("will be participating in the below scheduled Investor Conference", False),
    ("interacting with Institutional Investors as per details below: One on One meeting", False),
])
def test_is_earnings_call_text(body, expected):
    assert ann.is_earnings_call_text(body) is expected


def test_pick_model_prefers_newest_stable_flash():
    import summarize

    class M:
        def __init__(self, name, actions=("generateContent",)):
            self.name, self.supported_actions = "models/" + name, list(actions)

    class Client:
        class models:
            @staticmethod
            def list():
                return [M("gemini-2.5-flash"), M("gemini-3.8-flash"), M("gemini-3.8-flash-lite"),
                        M("gemini-4.0-flash-preview"), M("gemini-3.8-pro"),
                        M("text-embedding-004", ("embedContent",)), M("gemini-3.10-flash-tts")]

    assert summarize.pick_model(Client) == "gemini-3.8-flash"
    assert summarize.pick_model(Client, lite=True) == "gemini-3.8-flash-lite"


def test_zero_owners_profit_falls_back_to_total():
    xml = (FIX / "sample_results.xml").read_text().replace(
        '<in-capmkt:ProfitOrLossAttributableToOwnersOfParent contextRef="OneD" unitRef="INR" decimals="-5">1450000000',
        '<in-capmkt:ProfitOrLossAttributableToOwnersOfParent contextRef="OneD" unitRef="INR" decimals="-5">0')
    cur = parse_xbrl(xml.encode())[0]
    assert cur.pat == 150.0  # total profit, not 0


def test_metrics_ratios():
    import metrics
    qs = []
    # 8 quarters, newest first; EPS 10/qtr now vs 8/qtr a year earlier.
    ends = ["2026-09-30", "2026-06-30", "2026-03-31", "2025-12-31",
            "2025-09-30", "2025-06-30", "2025-03-31", "2024-12-31"]
    labels = ["Q2FY27", "Q1FY27", "Q4FY26", "Q3FY26", "Q2FY26", "Q1FY26", "Q4FY25", "Q3FY25"]
    for i, (e, l) in enumerate(zip(ends, labels)):
        new = i < 4
        qs.append({"period": l, "endDate": e, "revenue": 1000 if new else 800,
                   "ebitda": 200 if new else 150, "pat": 100 if new else 80,
                   "eps": 10 if new else 8, "pbt": 130 if new else 100, "financeCost": 10,
                   **({"equity": 2000, "debt": 500, "cash": 100, "shares": 10, "isBank": False} if i == 0 else {})})
    m = metrics.compute(qs, price=800)
    assert m["eps"] == 40 and m["pe"] == 20.0          # 800 / 40
    assert m["peg"] == 0.8                              # 20 / 25% EPS growth
    assert m["mc"] == 8000 and m["pb"] == 4.0           # 800 * 10 Cr shares; 8000/2000
    assert m["roe"] == 20.0                              # 400 / 2000
    assert m["roce"] == 22.4                             # (520 + 40) / 2500
    assert m["de"] == 0.25 and m["bv"] == 200.0
    assert m["ev"] == 10.5                               # (8000 + 500 - 100) / 800
    assert m["rg"] == 25.0 and m["rgt"] == 25.0 and m["ebm"] == 20.0
    # Loss-making: no P/E or PEG
    loss = [dict(q, eps=-1) for q in qs]
    m2 = metrics.compute(loss, price=800)
    assert "pe" not in m2 and "peg" not in m2


def test_guidance_diff():
    prev = [
        {"metric": "revenue_growth_yoy", "low": 12, "high": 14, "targetPeriod": "FY27", "status": "pending"},
        {"metric": "ebitda_margin", "low": 20, "high": None, "targetPeriod": "FY27", "status": "pending"},
        {"metric": "pat_growth_yoy", "low": 15, "high": None, "targetPeriod": "FY27", "status": "pending"},
        {"metric": "revenue", "low": 5000, "high": None, "targetPeriod": "Q1FY27", "status": "met"},
    ]
    cur = [
        {"metric": "revenue_growth_yoy", "low": 9, "high": 11, "targetPeriod": "FY27"},   # cut
        {"metric": "ebitda_margin", "low": 20, "high": None, "targetPeriod": "fy27"},     # reiterated
        {"metric": "ebitda_margin", "low": 22, "high": None, "targetPeriod": "FY28"},     # new
    ]
    d = {(e["metric"], e["targetPeriod"]): e["direction"] for e in gd.diff(cur, prev)}
    assert d[("revenue_growth_yoy", "FY27")] == "cut"
    assert d[("ebitda_margin", "FY27")] == "reiterated"
    assert d[("ebitda_margin", "FY28")] == "new"
    assert d[("pat_growth_yoy", "FY27")] == "dropped"       # live target no longer mentioned
    assert ("revenue", "Q1FY27") not in d                     # already resolved: not "dropped"
    first = gd.diff(cur, prev)[0]
    assert first["direction"] == "cut" and first["before"] == "12–14%" and first["now"] == "9–11%"


def test_shp_parse_and_changes(tmp_path):
    import ownership
    xml = """<x:xbrl xmlns:x="http://www.xbrl.org/2003/instance" xmlns:d="http://xbrl.org/2006/xbrldi" xmlns:c="http://example/c">
    <x:context id="P"><x:entity><x:segment><d:explicitMember dimension="c:A">c:ShareholdingOfPromoterAndPromoterGroupMember</d:explicitMember></x:segment></x:entity></x:context>
    <x:context id="F"><x:entity><x:segment><d:explicitMember dimension="c:A">c:InstitutionsForeignMember</d:explicitMember></x:segment></x:entity></x:context>
    <x:context id="D"><x:entity><x:segment><d:explicitMember dimension="c:A">c:InstitutionsDomesticMember</d:explicitMember></x:segment></x:entity></x:context>
    <x:context id="U"><x:entity><x:segment><d:explicitMember dimension="c:A">c:PublicShareholdingMember</d:explicitMember></x:segment></x:entity></x:context>
    <x:context id="N"><x:entity/></x:context>
    <c:ShareholdingAsAPercentageOfTotalNumberOfShares contextRef="P">0.55</c:ShareholdingAsAPercentageOfTotalNumberOfShares>
    <c:ShareholdingAsAPercentageOfTotalNumberOfShares contextRef="F">0.2</c:ShareholdingAsAPercentageOfTotalNumberOfShares>
    <c:ShareholdingAsAPercentageOfTotalNumberOfShares contextRef="D">0.1</c:ShareholdingAsAPercentageOfTotalNumberOfShares>
    <c:ShareholdingAsAPercentageOfTotalNumberOfShares contextRef="U">0.45</c:ShareholdingAsAPercentageOfTotalNumberOfShares>
    <c:WhetherAnySharesHeldByPromotersAreEncumberedUnderPledged contextRef="N">false</c:WhetherAnySharesHeldByPromotersAreEncumberedUnderPledged>
    </x:xbrl>"""
    r = ownership.parse_shp(xml.encode())
    assert r["promoter"] == 55.0 and r["fii"] == 20.0 and r["dii"] == 10.0 and r["pledge"] == 0.0
    ch = ownership.changes([dict(r, promoter=53.0, pledge=4.0), r])
    types = {c["type"] for c in ch}
    assert "promoter_down" in types and "pledge_up" in types


def test_redflags():
    import redflags
    assert redflags.classify("", "Resignation of Statutory Auditor")["type"] == "auditor_exit"
    assert redflags.classify("", "CRISIL downgraded the credit rating to BBB")["type"] == "rating_down"
    assert redflags.classify("Outcome of Board Meeting", "Approved results") is None


def test_shp_older_filings_store_percentages():
    import ownership
    xml = """<x:xbrl xmlns:x="http://www.xbrl.org/2003/instance" xmlns:d="http://xbrl.org/2006/xbrldi" xmlns:c="http://example/c">
    <x:context id="P"><x:entity><x:segment><d:explicitMember dimension="c:A">c:ShareholdingOfPromoterAndPromoterGroupMember</d:explicitMember></x:segment></x:entity></x:context>
    <c:ShareholdingAsAPercentageOfTotalNumberOfShares contextRef="P">75</c:ShareholdingAsAPercentageOfTotalNumberOfShares>
    </x:xbrl>"""
    assert ownership.parse_shp(xml.encode())["promoter"] == 75.0

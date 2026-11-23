"""Concall transcript -> structured summary using the Gemini API free tier.

Get a free key at https://aistudio.google.com/apikey and set GEMINI_API_KEY.
The free tier has per-minute and per-day request limits; check the current
numbers at https://ai.google.dev/gemini-api/docs/rate-limits. The pipeline
handles the limit by stopping and leaving the rest in the queue for the next
run. Set GEMINI_MODEL to change the model.
"""
from __future__ import annotations

import io
import json
import logging
import re
import os
import time
from typing import Any, Dict, List, Optional

# Empty = pick the newest Flash model this key can use (Google retires
# model names over time). Set GEMINI_MODEL to pin one.
log = logging.getLogger(__name__)
MODEL = os.environ.get("GEMINI_MODEL", "")
_resolved: Optional[str] = None
_lite: Optional[str] = None  # Flash-Lite model name ("" = unavailable)
MAX_CHARS = int(os.environ.get("TRANSCRIPT_MAX_CHARS", "150000"))


class QuotaExceeded(Exception):
    """Stop summarising for this run; queued transcripts stay queued."""


def _version_key(name: str):
    nums = [int(x) for x in re.findall(r"\d+", name.split("/")[-1])]
    return nums


def pick_model(client, lite: bool = False) -> str:
    """Newest stable 'flash' model (not preview/tts/image) that supports
    generateContent, from the key's own model list. lite=True picks the
    newest Flash-Lite instead (fallback when Flash is overloaded)."""
    names = []
    for m in client.models.list():
        name = (m.name or "").split("/")[-1]
        actions = getattr(m, "supported_actions", None) or []
        if "flash" not in name or (actions and "generateContent" not in actions):
            continue
        if re.search(r"preview|exp|tts|image|audio|live|thinking", name):
            continue
        if ("lite" in name) != lite:
            continue
        names.append(name)
    if not names:
        raise QuotaExceeded("no usable Gemini Flash model found for this key")
    return max(names, key=_version_key)


def resolved_model(client) -> str:
    global _resolved
    if _resolved is None:
        _resolved = MODEL or pick_model(client)
    return _resolved


def pdf_text(content: bytes) -> str:
    logging.getLogger("pypdf").setLevel(logging.ERROR)
    from pypdf import PdfReader
    reader = PdfReader(io.BytesIO(content))
    return "\n".join((p.extract_text() or "") for p in reader.pages)


_STR_LIST = {"type": "ARRAY", "items": {"type": "STRING"}}

# Detailed, English-only summary (version 2).
_SUMMARY = {
    "type": "OBJECT",
    "properties": {
        "overview": {"type": "STRING"},
        "highlights": _STR_LIST,
        "financials": _STR_LIST,
        "segments": {"type": "ARRAY", "items": {
            "type": "OBJECT",
            "properties": {"name": {"type": "STRING"}, "commentary": {"type": "STRING"}},
            "required": ["name", "commentary"],
        }},
        "outlook": _STR_LIST,
        "margins": _STR_LIST,
        "capex": _STR_LIST,
        "balanceSheet": _STR_LIST,
        "guidance": _STR_LIST,
        "qa": {"type": "ARRAY", "items": {
            "type": "OBJECT",
            "properties": {"q": {"type": "STRING"}, "a": {"type": "STRING"},
                           "analyst": {"type": "STRING", "nullable": True}},
            "required": ["q", "a"],
        }},
        "risks": _STR_LIST,
        "redFlags": _STR_LIST,
        "quotes": _STR_LIST,
        "orderBook": {
            "type": "OBJECT",
            "nullable": True,
            "properties": {
                "valueCr": {"type": "NUMBER", "nullable": True},
                "asOf": {"type": "STRING", "nullable": True},
                "bookToBill": {"type": "NUMBER", "nullable": True},
                "inflowsCr": {"type": "NUMBER", "nullable": True},
                "executionYears": {"type": "NUMBER", "nullable": True},
                "commentary": _STR_LIST,
            },
        },
        "promises": {"type": "ARRAY", "items": {
            "type": "OBJECT",
            "properties": {
                "item": {"type": "STRING"},
                "target": {"type": "STRING", "nullable": True},
                "status": {"type": "STRING", "enum": ["new", "on_track", "delayed", "completed", "dropped"]},
                "note": {"type": "STRING", "nullable": True},
            },
            "required": ["item", "status"],
        }},
    },
    "required": ["overview", "highlights", "financials", "outlook", "guidance", "risks", "redFlags"],
}

_CHANGES = {
    "type": "OBJECT",
    "properties": {
        "summary": {"type": "STRING"},
        "newTopics": _STR_LIST,
        "droppedTopics": _STR_LIST,
        "guidanceShifts": _STR_LIST,
        "toneShift": {"type": "STRING"},
    },
    "required": ["summary", "newTopics", "droppedTopics", "guidanceShifts"],
}

_GUIDANCE_ITEMS = {"type": "ARRAY", "items": {
    "type": "OBJECT",
    "properties": {
        "statement": {"type": "STRING"},
        "metric": {"type": "STRING", "enum": [
            "revenue_growth_yoy", "pat_growth_yoy", "ebitda_margin", "revenue", "other"]},
        "low": {"type": "NUMBER", "nullable": True},
        "high": {"type": "NUMBER", "nullable": True},
        "targetPeriod": {"type": "STRING"},
    },
    "required": ["statement", "metric", "targetPeriod"],
}}

SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "callDate": {"type": "STRING", "nullable": True},
        "callType": {"type": "STRING", "enum": [
            "earnings_call", "analyst_meet", "investor_call", "investor_conference", "agm", "other"]},
        "tone": {"type": "STRING", "enum": ["positive", "neutral", "cautious"]},
        "toneChange": {"type": "STRING"},
        "summary": _SUMMARY,
        "changes": _CHANGES,
        "guidanceItems": _GUIDANCE_ITEMS,
    },
    "required": ["tone", "summary", "guidanceItems"],
}

PROMPT = """You are a senior equity research analyst writing a DETAILED summary of an
Indian listed company's {doc} for serious retail investors.

Company: {name} ({symbol}). Quarter: {period}.
{previous}
Write in English. Facts only, from the transcript; no buy/sell views or price
targets. Use ₹ crore and exact numbers, growth rates and margins wherever the
call gives them. Be specific: name products, geographies, clients, plants.

summary:
- overview: 5-7 sentences: the quarter in context, what drove it, management's
  overall message.
- highlights: 8-12 key takeaways.
- financials: every financial number discussed (revenue, EBITDA, margins, PAT,
  growth YoY/QoQ, order book, volumes, realisations, ARPU, NIM, GNPA, etc.).
- segments: one entry per business segment / vertical / geography discussed,
  with 2-4 sentences of commentary each (empty list if none).
- outlook: demand environment, industry trends, pipeline, order inflows.
- margins: costs, pricing, raw materials, wage hikes, operating leverage.
- capex: capacity expansion, new plants, investments, acquisitions, timelines.
- balanceSheet: debt, cash, working capital, receivables, capital allocation,
  dividends/buybacks.
- guidance: every forward-looking statement, with numbers and periods.
- qa: the 10-15 most important analyst questions and management's answers,
  each answer 2-4 sentences. analyst = the analyst's firm if stated.
- risks: risks and headwinds management or analysts raised.
- redFlags: real concerns only (auditor issues, rising receivables/debt, weak
  demand, repeated excuses, evasive answers, guidance cuts, key exits). Empty
  list if none.
- quotes: 3-5 short notable direct quotes from management.
- orderBook: if the company discusses an order book / backlog / pipeline: valueCr
  (₹ crore), asOf, bookToBill (order book ÷ trailing revenue, if given or
  computable), inflowsCr (order inflows in the period), executionYears, and
  commentary (mix, large orders, execution). null if not discussed.
- promises: concrete commitments with timelines (capacity, plants, launches,
  capex, debt reduction, deliveries). status vs the PREVIOUS CALL if given:
  new, on_track, delayed (with note on the new timeline), completed, dropped
  (promised before, not mentioned or abandoned now).
tone: overall management tone. toneChange: one line vs the previous call if
given, else "".
changes: compare with the PREVIOUS CALL section if given (otherwise empty
lists and summary "First call tracked"). summary: 2-3 lines on what changed.
newTopics; droppedTopics (stressed last time, not mentioned or avoided now);
guidanceShifts (raised / cut / reiterated / withdrawn, with numbers); toneShift.
callDate: the date of the call as YYYY-MM-DD if stated, else null.
callType: earnings_call (discussing quarterly/annual results), analyst_meet
(analyst / institutional investor meet, site or plant visit, analyst day),
investor_call (other group call with investors), investor_conference (a
broker-hosted conference), agm (annual general meeting), or other.
guidanceItems: only quantitative guidance checkable against reported results.
targetPeriod is a quarter like "Q3FY27" or fiscal year like "FY27" (Indian FY
ends March). low/high in % for growth/margin metrics or ₹ crore for revenue.
"about 15%" -> low=15, high=15. "15-18%" -> 15, 18. "at least 20%" -> 20, null.

Transcript:
---
{transcript}
---"""

COMPARE_PROMPT = """Compare two earnings calls of {name} ({symbol}) and say what changed in
{period} versus {prev_period}. Facts only, English, specific, with numbers.
summary: 2-3 lines. newTopics: themes in {period} not discussed in {prev_period}.
droppedTopics: themes stressed in {prev_period} but missing or avoided in
{period}. guidanceShifts: each guidance raised / cut / reiterated / withdrawn
with before -> after numbers. toneShift: one line.

{prev_period} CALL:
{prev}

{period} CALL:
{cur}"""


def _brief(s: Dict[str, Any]) -> str:
    """Compact text version of a stored English summary (for comparisons)."""
    en = (s.get("summary") or {}).get("en") or {}
    parts = [f"Tone: {s.get('tone')}", f"Overview: {en.get('overview', '')}"]
    if en.get("orderBook"):
        parts.append(f"Order book: {en['orderBook']}")
    if en.get("promises"):
        parts.append("Promises: " + " | ".join(f"{p.get('item')} ({p.get('target')})" for p in en["promises"][:12]))
    for k in ("highlights", "financials", "outlook", "margins", "capex", "guidance", "risks"):
        if en.get(k):
            parts.append(f"{k}: " + " | ".join(en[k][:12]))
    if en.get("qa"):
        parts.append("Q&A: " + " | ".join(x.get("q", "") for x in en["qa"][:12]))
    return "\n".join(parts)


DOC_NAMES = {
    "call": "earnings conference call / analyst or investor call transcript",
    "presentation": "investor presentation (slides; no Q&A, leave qa empty)",
    "press_release": "results press release (no Q&A, leave qa empty)",
}


def summarise(text: str, *, name: str, symbol: str, period: str,
              previous: Optional[Dict[str, Any]] = None,
              api_key: Optional[str] = None, lite: bool = False,
              doc: str = "call") -> Dict[str, Any]:
    """lite=True uses Flash-Lite (faster, larger free quota) - used for the
    backlog of older calls; fresh calls use the full Flash model."""
    from google import genai
    from google.genai import types

    key = api_key or os.environ.get("GEMINI_API_KEY")
    if not key:
        # Treated like a quota stop: transcripts stay queued until a key exists.
        raise QuotaExceeded("GEMINI_API_KEY is not set")
    prev = ""
    if previous:
        prev = f"PREVIOUS CALL ({previous.get('period')}):\n{_brief(previous)}\n"

    client = genai.Client(api_key=key)
    prompt = PROMPT.format(doc=DOC_NAMES.get(doc, DOC_NAMES["call"]), name=name, symbol=symbol, period=period,
                           previous=prev, transcript=text[:MAX_CHARS])
    global _lite
    if lite and not MODEL:
        if _lite is None:
            try:
                _lite = pick_model(client, lite=True)
            except QuotaExceeded:
                _lite = ""
        model = _lite or resolved_model(client)
    else:
        model = resolved_model(client)
    tried_lite = lite
    for attempt in range(5):
        try:
            resp = client.models.generate_content(
                model=model,
                contents=prompt,
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                    response_schema=SCHEMA,
                    temperature=0.2,
                ),
            )
            out = json.loads(resp.text)
            out["summary"] = {"en": out.get("summary") or {}}
            return out
        except json.JSONDecodeError:
            if attempt >= 2:
                raise
        except Exception as e:  # SDK raises its own error classes
            msg = str(e)
            if "429" in msg or "RESOURCE_EXHAUSTED" in msg:
                if "PerDay" in msg or attempt >= 2:
                    raise QuotaExceeded(msg[:300]) from e
                time.sleep(30 * (attempt + 1))  # per-minute limit: wait and retry
                continue
            if "503" in msg or "UNAVAILABLE" in msg or "500" in msg or "INTERNAL" in msg:
                # Google overloaded: back off, then try Flash-Lite once.
                if attempt >= 1 and not tried_lite and not MODEL:
                    try:
                        global _resolved
                        model = pick_model(client, lite=True)
                        _resolved = model  # stay on Lite for the rest of this run
                        tried_lite = True
                        log.info("Gemini busy; falling back to %s", model)
                        continue
                    except QuotaExceeded:
                        pass
                if attempt >= 4:
                    raise QuotaExceeded("Gemini overloaded: " + msg[:200]) from e
                time.sleep(15 * (attempt + 1))
                continue
            if "404" in msg or "NOT_FOUND" in msg or "API_KEY_INVALID" in msg or "PERMISSION_DENIED" in msg:
                # Model/key problem, not this transcript's fault: stop the batch.
                raise QuotaExceeded(msg[:300]) from e
            raise
    raise RuntimeError("unreachable")


def compare(prev: Dict[str, Any], cur: Dict[str, Any], *, name: str, symbol: str,
            api_key: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """'What changed' between two stored summaries (small, cheap call on
    Flash-Lite). Used when an older call is added after a newer one."""
    from google import genai
    from google.genai import types

    key = api_key or os.environ.get("GEMINI_API_KEY")
    if not key:
        return None
    client = genai.Client(api_key=key)
    global _lite
    if _lite is None:
        try:
            _lite = pick_model(client, lite=True)
        except QuotaExceeded:
            _lite = ""
    prompt = COMPARE_PROMPT.format(name=name, symbol=symbol, period=cur.get("period"),
                                   prev_period=prev.get("period"), prev=_brief(prev), cur=_brief(cur))
    try:
        resp = client.models.generate_content(
            model=_lite or resolved_model(client), contents=prompt,
            config=types.GenerateContentConfig(response_mime_type="application/json",
                                               response_schema=_CHANGES, temperature=0.2))
        return json.loads(resp.text)
    except Exception as e:
        msg = str(e)
        if "429" in msg or "RESOURCE_EXHAUSTED" in msg:
            raise QuotaExceeded(msg[:200]) from e
        log.warning("compare failed for %s: %s", symbol, e)
        return None


# ------------------------------------------------------------ full Q&A

QA_SCHEMA = {"type": "ARRAY", "items": {
    "type": "OBJECT",
    "properties": {
        "analyst": {"type": "STRING", "nullable": True},
        "firm": {"type": "STRING", "nullable": True},
        "topic": {"type": "STRING"},
        "q": {"type": "STRING"},
        "a": {"type": "STRING"},
        "answeredBy": {"type": "STRING", "nullable": True},
    },
    "required": ["topic", "q", "a"],
}}

QA_PROMPT = """Below is {part} of the earnings/analyst call transcript of {name} ({symbol}), {period}.

List EVERY question asked by analysts/investors in this text, in the order asked.
Do not skip, merge or shorten the list: follow-up questions are separate entries.
If one person asks several questions in one turn, make one entry per question.
Ignore the operator, opening remarks and anything that is not a question.
- analyst: the person's name; firm: their company (null if not stated).
- topic: 1-3 words (e.g. "Margins", "Order book", "Capex", "Demand").
- q: the question in full in 1-3 clear sentences, keeping every number.
- a: management's answer in detail (3-6 sentences): all numbers, timelines,
  reasons and caveats they gave. If they declined to answer, say so.
- answeredBy: the management person who answered (name and/or role), if clear.
English only. Facts from the transcript only.

TRANSCRIPT ({part}):
{text}
"""

_QA_START = re.compile(r"question[- ]and[- ]answer|q\s*&\s*a session|first question|open the floor|"
                       r"open (?:the )?(?:line|call) for questions", re.I)


def qa_chunks(text: str, size: int = 45000) -> List[str]:
    """The Q&A part of a transcript, split at line breaks into ~size-char chunks."""
    m = _QA_START.search(text, len(text) // 8)  # skip mentions in the opening agenda
    body = text[m.start():] if m else text
    chunks, cur = [], ""
    for line in body.splitlines(keepends=True):
        if len(cur) + len(line) > size and cur:
            chunks.append(cur)
            cur = ""
        cur += line
    if cur.strip():
        chunks.append(cur)
    return chunks


def full_qa(text: str, *, name: str, symbol: str, period: str,
            api_key: Optional[str] = None) -> List[Dict[str, Any]]:
    """Every question and answer of a call (Flash-Lite, chunked)."""
    from google import genai
    from google.genai import types

    key = api_key or os.environ.get("GEMINI_API_KEY")
    if not key:
        raise QuotaExceeded("GEMINI_API_KEY is not set")
    client = genai.Client(api_key=key)
    global _lite
    if _lite is None:
        try:
            _lite = pick_model(client, lite=True)
        except QuotaExceeded:
            _lite = ""
    model = _lite or resolved_model(client)
    chunks = qa_chunks(text[:MAX_CHARS * 2])
    out: List[Dict[str, Any]] = []
    for i, chunk in enumerate(chunks):
        part = "the Q&A session" if len(chunks) == 1 else f"part {i + 1} of {len(chunks)} of the Q&A session"
        prompt = QA_PROMPT.format(part=part, name=name, symbol=symbol, period=period, text=chunk)
        for attempt in range(4):
            try:
                resp = client.models.generate_content(
                    model=model, contents=prompt,
                    config=types.GenerateContentConfig(
                        response_mime_type="application/json", response_schema=QA_SCHEMA,
                        temperature=0.1, max_output_tokens=32768))
                rows = json.loads(resp.text)
                break
            except json.JSONDecodeError:
                if attempt >= 1:
                    raise
            except Exception as e:
                msg = str(e)
                if "429" in msg or "RESOURCE_EXHAUSTED" in msg:
                    if "PerDay" in msg or attempt >= 2:
                        raise QuotaExceeded(msg[:300]) from e
                    time.sleep(30 * (attempt + 1))
                    continue
                if any(x in msg for x in ("503", "UNAVAILABLE", "500", "INTERNAL")) and attempt < 3:
                    time.sleep(10 * (attempt + 1))
                    continue
                raise
        else:
            raise RuntimeError("Q&A extraction failed")
        for r in rows:
            if (r.get("q") or "").strip():
                out.append({k: (r.get(k) or "").strip() or None
                            for k in ("analyst", "firm", "topic", "q", "a", "answeredBy")})
    return out

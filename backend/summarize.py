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
from typing import Any, Dict, Optional

# Empty = pick the newest Flash model this key can use (Google retires
# model names over time). Set GEMINI_MODEL to pin one.
log = logging.getLogger(__name__)
MODEL = os.environ.get("GEMINI_MODEL", "")
_resolved: Optional[str] = None
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
    },
    "required": ["overview", "highlights", "financials", "outlook", "guidance", "qa", "risks", "redFlags"],
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
Indian listed company's earnings conference call for serious retail investors.

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
    for k in ("highlights", "financials", "outlook", "margins", "capex", "guidance", "risks"):
        if en.get(k):
            parts.append(f"{k}: " + " | ".join(en[k][:12]))
    if en.get("qa"):
        parts.append("Q&A: " + " | ".join(x.get("q", "") for x in en["qa"][:12]))
    return "\n".join(parts)


def summarise(text: str, *, name: str, symbol: str, period: str,
              previous: Optional[Dict[str, Any]] = None,
              api_key: Optional[str] = None, lite: bool = False) -> Dict[str, Any]:
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
    prompt = PROMPT.format(name=name, symbol=symbol, period=period,
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

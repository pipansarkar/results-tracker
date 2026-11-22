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


_LANG = {
    "type": "OBJECT",
    "properties": {
        "highlights": {"type": "ARRAY", "items": {"type": "STRING"}},
        "guidance": {"type": "ARRAY", "items": {"type": "STRING"}},
        "qa": {"type": "ARRAY", "items": {
            "type": "OBJECT",
            "properties": {"q": {"type": "STRING"}, "a": {"type": "STRING"}},
            "required": ["q", "a"],
        }},
        "redFlags": {"type": "ARRAY", "items": {"type": "STRING"}},
    },
    "required": ["highlights", "guidance", "qa", "redFlags"],
}

SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "callDate": {"type": "STRING", "nullable": True},
        "tone": {"type": "STRING", "enum": ["positive", "neutral", "cautious"]},
        "toneChange": {"type": "STRING"},
        "summary": {
            "type": "OBJECT",
            "properties": {"en": _LANG, "bn": _LANG, "hi": _LANG},
            "required": ["en", "bn", "hi"],
        },
        "changes": {
            "type": "OBJECT",
            "properties": {
                "summary": {"type": "STRING"},
                "newTopics": {"type": "ARRAY", "items": {"type": "STRING"}},
                "droppedTopics": {"type": "ARRAY", "items": {"type": "STRING"}},
                "guidanceShifts": {"type": "ARRAY", "items": {"type": "STRING"}},
                "toneShift": {"type": "STRING"},
                "bn": {"type": "STRING"},
                "hi": {"type": "STRING"},
            },
            "required": ["summary", "newTopics", "droppedTopics", "guidanceShifts"],
        },
        "guidanceItems": {"type": "ARRAY", "items": {
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
        }},
    },
    "required": ["tone", "summary", "guidanceItems"],
}

PROMPT = """You are an equity research assistant summarising an Indian listed company's
earnings conference call transcript for retail investors.

Company: {name} ({symbol}). Quarter: {period}.
{previous}
Rules:
- Facts only, taken from the transcript. No buy/sell views, no price targets.
- Numbers in ₹ crore where possible. Keep each bullet under 30 words.
- highlights: 5-8 key points (growth drivers, margins, segments, order book, capex).
- guidance: every forward-looking statement by management, with numbers when given.
- qa: the 5-8 most important analyst questions and management's answers, condensed.
- redFlags: real concerns only (auditor issues, rising receivables or debt, weak demand,
  repeated excuses, evasive answers, guidance cuts, key exits). Empty list if none.
- changes: compare with the PREVIOUS CALL section if given (otherwise use
  empty lists and summary "First call tracked"). summary: 1-2 lines on what
  changed. newTopics: themes discussed now that weren't last time.
  droppedTopics: themes management stressed last time but didn't mention or
  skipped now (these can be quiet red flags). guidanceShifts: each guidance
  raised, cut, reiterated or withdrawn vs last call, with numbers.
  toneShift: one line. bn/hi: the summary line in Bengali and Hindi.
- callDate: the date the call was held, as YYYY-MM-DD, if stated; otherwise null.
- tone: overall management tone. toneChange: one line comparing with the previous call
  if provided, otherwise "".
- summary.bn and summary.hi: faithful Bengali and Hindi translations of summary.en,
  in simple everyday language. Keep company names, numbers and units as-is.
- guidanceItems: only quantitative guidance that can be checked against reported results.
  targetPeriod is a quarter label like "Q3FY27" or a fiscal year like "FY27" (Indian FY
  ends in March). low/high are numbers in % for growth/margin metrics or ₹ crore for
  revenue. "about 15%" -> low=15, high=15. "15-18%" -> low=15, high=18.
  "at least 20%" -> low=20, high=null.

Transcript:
---
{transcript}
---"""


def summarise(text: str, *, name: str, symbol: str, period: str,
              previous: Optional[Dict[str, Any]] = None,
              api_key: Optional[str] = None) -> Dict[str, Any]:
    from google import genai
    from google.genai import types

    key = api_key or os.environ.get("GEMINI_API_KEY")
    if not key:
        # Treated like a quota stop: transcripts stay queued until a key exists.
        raise QuotaExceeded("GEMINI_API_KEY is not set")
    prev = ""
    if previous:
        en = (previous.get("summary") or {}).get("en") or {}
        prev = ("PREVIOUS CALL ({p}), tone: {t}\nKey points: {h}\nGuidance: {g}\n"
                "Analyst questions: {q}\n".format(
                    p=previous.get("period"), t=previous.get("tone"),
                    h=" | ".join(en.get("highlights", [])[:8]),
                    g=" | ".join(en.get("guidance", [])[:8]),
                    q=" | ".join(x.get("q", "") for x in en.get("qa", [])[:8])))

    client = genai.Client(api_key=key)
    prompt = PROMPT.format(name=name, symbol=symbol, period=period,
                           previous=prev, transcript=text[:MAX_CHARS])
    model = resolved_model(client)
    tried_lite = False
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
            return json.loads(resp.text)
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

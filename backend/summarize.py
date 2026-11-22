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
import os
import time
from typing import Any, Dict, Optional

MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
MAX_CHARS = int(os.environ.get("TRANSCRIPT_MAX_CHARS", "150000"))


class QuotaExceeded(Exception):
    pass


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
        raise RuntimeError("GEMINI_API_KEY is not set")
    prev = ""
    if previous:
        en = (previous.get("summary") or {}).get("en") or {}
        prev = ("Previous call ({p}) tone: {t}. Its guidance was: {g}\n".format(
            p=previous.get("period"), t=previous.get("tone"),
            g="; ".join(en.get("guidance", [])[:6])))

    client = genai.Client(api_key=key)
    prompt = PROMPT.format(name=name, symbol=symbol, period=period,
                           previous=prev, transcript=text[:MAX_CHARS])
    for attempt in range(3):
        try:
            resp = client.models.generate_content(
                model=MODEL,
                contents=prompt,
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                    response_schema=SCHEMA,
                    temperature=0.2,
                ),
            )
            return json.loads(resp.text)
        except json.JSONDecodeError:
            if attempt == 2:
                raise
        except Exception as e:  # SDK raises its own error classes
            msg = str(e)
            if "429" in msg or "RESOURCE_EXHAUSTED" in msg:
                if "PerDay" in msg or attempt == 2:
                    raise QuotaExceeded(msg) from e
                time.sleep(30 * (attempt + 1))  # per-minute limit: wait and retry
                continue
            raise
    raise RuntimeError("unreachable")

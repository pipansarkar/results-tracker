"""Pull structured details out of short filings: order wins and credit
ratings. Uses Gemini Flash-Lite (a small, cheap request) with a regex
fallback so nothing breaks when the quota is used up."""
from __future__ import annotations

import json
import os
import re
from typing import Dict, Optional

_AMOUNT = re.compile(
    r"(?:₹|rs\.?|inr|rupees)\s*([\d,]+(?:\.\d+)?)\s*(crores?|cr\.?|lakhs?|lacs?|million|mn|billion|bn)?"
    r"|([\d,]+(?:\.\d+)?)\s*(crores?|cr\.?)\b",
    re.I)
_UNIT_TO_CR = {"crore": 1, "crores": 1, "cr": 1, "cr.": 1, "lakh": 0.01, "lakhs": 0.01, "lac": 0.01,
               "lacs": 0.01, "million": 0.1, "mn": 0.1, "billion": 100, "bn": 100}


def amounts_cr(text: str):
    """All rupee amounts in the text, in ₹ crore."""
    out = []
    for m in _AMOUNT.finditer(text or ""):
        num = m.group(1) or m.group(3)
        unit = (m.group(2) or m.group(4) or "").lower().rstrip(".")
        try:
            v = float(num.replace(",", ""))
        except ValueError:
            continue
        if unit:
            out.append(v * _UNIT_TO_CR.get(unit, _UNIT_TO_CR.get(unit + ".", 1)))
        elif v >= 1e6:  # bare rupees
            out.append(v / 1e7)
    return out


_AGENCY = re.compile(r"\b(CRISIL|ICRA|CARE|India Ratings|Ind-Ra|Acuit[eé]|Brickwork|Infomerics|S&P|Moody'?s|Fitch)\b", re.I)
_RATING = re.compile(r"\b((?:CRISIL|ICRA|CARE|IND|ACUITE|BWR|IVR)\s*)?(AAA|AA[+-]?|A[+-]?|BBB[+-]?|BB[+-]?|B[+-]?|C|D|A1\+?|A2\+?|A3\+?|A4\+?)(?=[\s/(),.;]|$)")


def _regex_order(text: str) -> Dict:
    vals = [v for v in amounts_cr(text) if 0.05 <= v <= 500000]
    return {"valueCr": round(max(vals), 2) if vals else None}


def _regex_rating(text: str) -> Dict:
    t = text or ""
    low = t.lower()
    action = ("upgrade" if "upgrad" in low else "downgrade" if "downgrad" in low
              else "reaffirmed" if "reaffirm" in low else "assigned" if "assign" in low
              else "revised" if "revis" in low else None)
    ag = _AGENCY.search(t)
    rt = _RATING.search(t)
    outlook = next((o for o in ("Positive", "Stable", "Negative", "Developing", "Watch")
                    if o.lower() in low), None)
    return {"agency": ag.group(1) if ag else None,
            "rating": (rt.group(0).strip() if rt else None),
            "outlook": outlook, "action": action}


_ORDER_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "valueCr": {"type": "NUMBER", "nullable": True},
        "client": {"type": "STRING", "nullable": True},
        "description": {"type": "STRING"},
        "executionPeriod": {"type": "STRING", "nullable": True},
        "domestic": {"type": "BOOLEAN", "nullable": True},
    },
    "required": ["description"],
}
_RATING_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "agency": {"type": "STRING", "nullable": True},
        "instrument": {"type": "STRING", "nullable": True},
        "rating": {"type": "STRING", "nullable": True},
        "previousRating": {"type": "STRING", "nullable": True},
        "outlook": {"type": "STRING", "nullable": True},
        "action": {"type": "STRING", "enum": ["upgrade", "downgrade", "reaffirmed", "assigned",
                                               "outlook_change", "withdrawn", "other"]},
    },
    "required": ["action"],
}


def _ai(prompt: str, schema: Dict) -> Optional[Dict]:
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        return None
    try:
        from google import genai
        from google.genai import types
        import summarize
        client = genai.Client(api_key=key)
        if summarize._lite is None:
            try:
                summarize._lite = summarize.pick_model(client, lite=True)
            except summarize.QuotaExceeded:
                summarize._lite = ""
        model = summarize._lite or summarize.resolved_model(client)
        resp = client.models.generate_content(
            model=model, contents=prompt,
            config=types.GenerateContentConfig(response_mime_type="application/json",
                                               response_schema=schema, temperature=0))
        return json.loads(resp.text)
    except Exception:
        return None


def order(text: str, company: str) -> Dict:
    """{valueCr, client, description, executionPeriod, domestic}."""
    text = (text or "")[:8000]
    ai = _ai(f"From this stock-exchange filing by {company} about an order/contract win, extract: "
             "valueCr = total order value in ₹ crore (convert lakh/million/billion; null if not "
             "stated), client, a one-line description of the work, executionPeriod, and "
             f"domestic (true/false/null).\n\nFiling:\n{text}", _ORDER_SCHEMA)
    out = _regex_order(text)
    if ai:
        out.update({k: v for k, v in ai.items() if v not in (None, "")})
    return out


def rating(text: str, company: str) -> Dict:
    """{agency, instrument, rating, previousRating, outlook, action}."""
    text = (text or "")[:8000]
    ai = _ai(f"From this stock-exchange filing by {company} about a credit rating, extract the "
             "agency, the instrument (e.g. long-term bank facilities, NCDs, commercial paper), "
             "the rating (e.g. 'CRISIL AA+'), previousRating if stated, outlook, and the action. "
             f"For several instruments, use the main long-term one.\n\nFiling:\n{text}", _RATING_SCHEMA)
    out = _regex_rating(text)
    if ai:
        out.update({k: v for k, v in ai.items() if v not in (None, "")})
    return out

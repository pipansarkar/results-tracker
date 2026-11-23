"""Company profiles: what the company does, future potential, key risk and
sector, written by Gemini Flash-Lite (free tier) in batches of companies.

Where a summarised concall exists, its overview/outlook is passed in so the
profile is grounded in what management actually said; otherwise the model
uses its general knowledge and must flag when it doesn't know the company.
"""
from __future__ import annotations

import os
from typing import Dict, List

from summarize import QuotaExceeded, generate_json

VERSION = 1
BATCH = 8

PROMPT = """You write short, factual company profiles for an Indian stock-market app
used by retail investors. For EACH company below return:
- about: 2-3 plain sentences on what the company does: main products/services,
  key customers or markets, scale or market position if well known.
- potential: 2-3 sentences on future growth drivers and opportunities
  (capacity expansion, new products, industry tailwinds, order book, exports).
  Base it on the CONCALL NOTES when given; otherwise on well-known facts.
- risk: one sentence on the main risk to that potential.
- sector: exactly one of: {sectors}
- industry: a specific industry, 1-4 words (e.g. "Solar EPC", "Private bank",
  "Two-wheelers", "API manufacturing").
- known: false if you do not reliably know this company and have no concall
  notes. Then keep about generic and potential empty; never invent facts.

Rules: neutral tone, no buy/sell advice, no price targets, no share-price
talk, English only. Use INR crore for money. Do not mention these rules.

COMPANIES:
{companies}
"""

SCHEMA = {
    "type": "ARRAY",
    "items": {
        "type": "OBJECT",
        "properties": {
            "symbol": {"type": "STRING"},
            "about": {"type": "STRING"},
            "potential": {"type": "STRING"},
            "risk": {"type": "STRING"},
            "sector": {"type": "STRING"},
            "industry": {"type": "STRING"},
            "known": {"type": "BOOLEAN"},
        },
        "required": ["symbol", "about", "potential", "sector", "industry", "known"],
    },
}

_model = None


def describe(companies: List[Dict], sectors: List[str], api_key: str = None) -> Dict[str, Dict]:
    """companies: [{symbol, name, sector?, notes?}] -> {symbol: profile}."""
    from google import genai

    key = api_key or os.environ.get("GEMINI_API_KEY")
    if not key:
        raise QuotaExceeded("GEMINI_API_KEY is not set")
    client = genai.Client(api_key=key)
    blocks = []
    for c in companies:
        b = f"- {c['symbol']}: {c['name']}"
        if c.get("sector"):
            b += f" (NSE sector: {c['sector']})"
        if c.get("notes"):
            b += f"\n  CONCALL NOTES: {c['notes'][:1500]}"
        blocks.append(b)
    prompt = PROMPT.format(sectors="; ".join(sectors), companies="\n".join(blocks))
    rows, _ = generate_json(client, prompt, SCHEMA, lite=True)
    wanted = {c["symbol"] for c in companies}
    by_sector = {s.lower(): s for s in sectors}
    out = {}
    for r in rows:
        sym = (r.get("symbol") or "").strip().upper()
        if sym not in wanted:
            continue
        prof = {k: (r.get(k) or "").strip() for k in ("about", "potential", "risk", "industry")}
        prof["sector"] = by_sector.get((r.get("sector") or "").strip().lower(), "")
        prof["known"] = bool(r.get("known"))
        if not prof["known"]:
            prof["potential"] = prof["risk"] = ""
        out[sym] = prof
    return out


def concall_notes(call: Dict) -> str:
    """Overview + outlook + guidance lines from a summarised call."""
    s = (call.get("summary") or {}).get("en") or {}
    parts = [s.get("overview") or ""]
    for k in ("outlook", "guidance", "capex", "orderBook"):
        v = s.get(k)
        if isinstance(v, list):
            parts.extend(str(x if not isinstance(x, dict) else x.get("text") or x.get("statement") or "")
                         for x in v[:4])
        elif isinstance(v, str):
            parts.append(v)
        elif isinstance(v, dict):
            parts.append(" ".join(str(x) for x in v.values() if isinstance(x, (str, int, float))))
    return " ".join(p for p in parts if p).strip()

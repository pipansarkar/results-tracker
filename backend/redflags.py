"""Red flags from company announcements.

Each rule: (type, severity, label, pattern). Matched against the
announcement category + text. High severity triggers a push.
"""
from __future__ import annotations

import re
from typing import Dict, Optional

_RULES = [
    ("auditor_exit", "high", "Auditor resigned",
     r"resign\w*.{0,60}(statutory )?auditor|auditor.{0,60}resign"),
    ("kmp_exit", "high", "Top management exit",
     r"(resign\w*|cessation|step(s|ped)? down).{0,80}(chief financial officer|\bcfo\b|chief executive|\bceo\b|managing director|whole[- ]time director)"),
    ("rating_down", "high", "Credit rating downgrade",
     r"(credit )?rating.{0,120}(downgrad|revised (to|from).{0,40}negative|watch with negative implications)|downgrad.{0,60}rating"),
    ("default", "high", "Default / delayed payment",
     r"\bdefault\w*\b.{0,60}(payment|interest|principal|loan|debenture|ncd)|delay in (payment|servicing) of"),
    ("fraud", "high", "Fraud / forensic audit",
     r"forensic audit|\bfraud\b"),
    ("pledge", "medium", "Promoter shares pledged",
     r"creation of (pledge|encumbrance)|encumbrance.{0,40}(created|creation)|invocation of pledge|pledge.{0,30}invok"),
    ("regulator", "medium", "Regulatory action",
     r"\bsebi\b.{0,80}(order|penalty|show[- ]cause|adjudicat)|show[- ]cause notice|penalty (of|imposed)"),
    ("results_delay", "medium", "Results delayed",
     r"(delay|postpone\w*).{0,60}(financial results|board meeting)"),
    ("company_secretary_exit", "low", "Company secretary exit",
     r"(resign\w*|cessation).{0,60}company secretary"),
    ("tax_demand", "low", "Tax demand / notice",
     r"(gst|income[- ]tax|tax).{0,40}(demand|notice|order)"),
    ("litigation", "low", "Litigation",
     r"(winding up|insolvency|nclt).{0,60}(petition|application|admit)"),
]
_COMPILED = [(t, s, l, re.compile(p, re.I | re.S)) for t, s, l, p in _RULES]


def classify(desc: str, text: str) -> Optional[Dict]:
    """First matching rule, or None. Rules are ordered by severity."""
    blob = f"{desc or ''} . {text or ''}"
    for t, sev, label, pat in _COMPILED:
        if pat.search(blob):
            return {"type": t, "severity": sev, "label": label}
    return None

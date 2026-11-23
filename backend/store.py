"""Storage: Firestore (free Spark plan) or a local JSON folder for --dry-run.

Paths use Firestore style: "companies/TCS", "companies/TCS/concalls/Q2FY27".
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Dict, List, Optional, Tuple


class Store:
    # Operations this run (Firestore's free plan: 50k reads, 20k writes a day).
    reads = 0
    writes = 0

    def get(self, path: str) -> Optional[Dict]:
        raise NotImplementedError

    def set(self, path: str, data: Dict, merge: bool = False) -> None:
        raise NotImplementedError

    def list(self, collection: str) -> List[Tuple[str, Dict]]:
        raise NotImplementedError


class LocalStore(Store):
    """Writes each document to <root>/<path>.json, so you can inspect the output."""

    def __init__(self, root: str):
        self.root = Path(root)

    def _file(self, path: str) -> Path:
        safe = "/".join(p.replace("&", "_and_") for p in path.split("/"))
        return self.root / f"{safe}.json"

    def get(self, path: str) -> Optional[Dict]:
        f = self._file(path)
        return json.loads(f.read_text()) if f.exists() else None

    def set(self, path: str, data: Dict, merge: bool = False) -> None:
        self.writes += 1
        f = self._file(path)
        f.parent.mkdir(parents=True, exist_ok=True)
        if merge and f.exists():
            data = {**json.loads(f.read_text()), **data}
        f.write_text(json.dumps(data, indent=2, ensure_ascii=False, default=str))

    def list(self, collection: str) -> List[Tuple[str, Dict]]:
        d = self._file(collection).with_suffix("")
        if not d.is_dir():
            return []
        return [(f.stem, json.loads(f.read_text())) for f in sorted(d.glob("*.json"))]


class FirestoreStore(Store):
    """Credentials: FIREBASE_SERVICE_ACCOUNT (the JSON text, as used in GitHub
    Actions) or GOOGLE_APPLICATION_CREDENTIALS (path to the JSON file)."""

    def __init__(self):
        import firebase_admin
        from firebase_admin import credentials, firestore

        if not firebase_admin._apps:
            raw = os.environ.get("FIREBASE_SERVICE_ACCOUNT")
            cred = (credentials.Certificate(json.loads(raw)) if raw
                    else credentials.ApplicationDefault())
            firebase_admin.initialize_app(cred)
        self.db = firestore.client()

    def get(self, path: str) -> Optional[Dict]:
        self.reads += 1
        snap = self.db.document(path).get()
        return snap.to_dict() if snap.exists else None

    def set(self, path: str, data: Dict, merge: bool = False) -> None:
        self.writes += 1
        self.db.document(path).set(data, merge=merge)

    def list(self, collection: str) -> List[Tuple[str, Dict]]:
        out = [(d.id, d.to_dict()) for d in self.db.collection(collection).stream()]
        self.reads += max(1, len(out))
        return out

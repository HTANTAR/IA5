"""Memoria vectorial simple y local (sin dependencias compiladas): JSON + numpy para similitud coseno.
Guarda hechos aprendidos para que los agentes los puedan recordar en conversaciones futuras."""
from __future__ import annotations
import json
import threading
import time
import uuid
from pathlib import Path
import numpy as np
from core.embeddings import embed

STORE_PATH = Path(__file__).resolve().parent.parent / "memory_store" / "facts.json"
STORE_PATH.parent.mkdir(exist_ok=True)

_lock = threading.Lock()


def _load() -> list[dict]:
    if not STORE_PATH.exists():
        return []
    with open(STORE_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def _save(entries: list[dict]) -> None:
    with open(STORE_PATH, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=2)


def remember(text: str, topic: str = "", source: str = "") -> None:
    """Guarda un hecho/fragmento de texto en la memoria, con su embedding."""
    vector = embed(text)
    entry = {
        "id": str(uuid.uuid4()),
        "text": text,
        "topic": topic,
        "source": source,
        "created_at": time.time(),
        "embedding": vector,
    }
    with _lock:
        entries = _load()
        entries.append(entry)
        _save(entries)


def recall(query: str, top_k: int = 4, min_similarity: float = 0.5) -> list[dict]:
    """Devuelve los hechos guardados mas relevantes para la consulta."""
    with _lock:
        entries = _load()
    if not entries:
        return []

    query_vec = np.array(embed(query))
    query_norm = np.linalg.norm(query_vec)
    if query_norm == 0:
        return []

    scored = []
    for entry in entries:
        vec = np.array(entry["embedding"])
        denom = (np.linalg.norm(vec) * query_norm)
        similarity = float(np.dot(vec, query_vec) / denom) if denom else 0.0
        if similarity >= min_similarity:
            scored.append((similarity, entry))

    scored.sort(key=lambda x: x[0], reverse=True)
    return [
        {"text": e["text"], "topic": e["topic"], "source": e["source"], "similarity": round(s, 3)}
        for s, e in scored[:top_k]
    ]


def stats() -> dict:
    with _lock:
        entries = _load()
    return {"total_facts": len(entries)}

"""Embeddings de texto usando Ollama (modelo nomic-embed-text), 100% local."""
from __future__ import annotations
import requests
from core.config import CONFIG

MODEL = "nomic-embed-text"


def embed(text: str) -> list[float]:
    url = f"{CONFIG['ollama']['host']}/api/embeddings"
    resp = requests.post(url, json={"model": MODEL, "prompt": text}, timeout=60)
    resp.raise_for_status()
    return resp.json()["embedding"]

"""Configuracion central: que proveedor de LLM usa cada agente."""
import os
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_FILE = ROOT / "config.json"

DEFAULTS = {
    # proveedor por agente: "ollama" (local, gratis siempre) o "gemini" (nube, gratis con limite)
    "providers": {
        "orchestrator": "gemini_or_ollama",
        "code_agent": "ollama",
        "text_agent": "ollama",
        "browser_agent": "ollama",
    },
    "ollama": {
        "host": "http://localhost:11434",
        "model_general": "llama3.1:latest",
        "model_code": "qwen2.5-coder:7b",
    },
    "gemini": {
        "model": "gemini-2.5-flash",
    },
    "voice": {
        "enabled": True,
        "edge_tts_voice": "es-AR-ElenaNeural",
    },
}


def load_config() -> dict:
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            user_cfg = json.load(f)
        merged = {**DEFAULTS, **user_cfg}
        return merged
    return DEFAULTS


def gemini_api_key() -> str | None:
    return os.environ.get("GEMINI_API_KEY")


CONFIG = load_config()

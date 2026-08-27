"""Voz: convierte texto a audio y lo reproduce, usando Edge TTS (voces neuronales, gratis)."""
from __future__ import annotations
import asyncio
import re
import tempfile
from pathlib import Path
import edge_tts
from playsound import playsound
from core.config import CONFIG

_TEMP_DIR = Path(tempfile.gettempdir()) / "ia_local_voice"
_TEMP_DIR.mkdir(exist_ok=True)

_CODE_BLOCK_RE = re.compile(r"```.*?```", re.DOTALL)


def _clean_for_speech(text: str) -> str:
    text = _CODE_BLOCK_RE.sub(" código omitido. ", text)
    return text.strip()


async def _synthesize(text: str, voice: str, out_path: Path) -> None:
    communicate = edge_tts.Communicate(text, voice)
    await communicate.save(str(out_path))


async def synthesize_bytes(text: str) -> bytes:
    """Genera el audio en memoria (mp3), sin tocar disco. Pensado para servirlo por HTTP."""
    clean = _clean_for_speech(text)
    if not clean:
        return b""
    voice_name = CONFIG["voice"]["edge_tts_voice"]
    communicate = edge_tts.Communicate(clean, voice_name)
    chunks = bytearray()
    async for chunk in communicate.stream():
        if chunk["type"] == "audio":
            chunks.extend(chunk["data"])
    return bytes(chunks)


def is_enabled() -> bool:
    return bool(CONFIG["voice"]["enabled"])


def set_enabled(value: bool) -> bool:
    CONFIG["voice"]["enabled"] = bool(value)
    return CONFIG["voice"]["enabled"]


def speak(text: str) -> None:
    """Sintetiza y reproduce el texto. Pensado para llamarse en un hilo aparte (bloquea mientras suena)."""
    if not is_enabled():
        return
    clean = _clean_for_speech(text)
    if not clean:
        return
    out_path = _TEMP_DIR / "reply.mp3"
    voice = CONFIG["voice"]["edge_tts_voice"]
    try:
        asyncio.run(_synthesize(clean, voice, out_path))
        playsound(str(out_path))
    except Exception:
        pass

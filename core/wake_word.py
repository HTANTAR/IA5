"""Modo 'escucha permanente': graba en ventanas cortas de forma continua y solo actua
cuando detecta la palabra de activacion. Todo el procesamiento es local (nada sale de la PC)."""
from __future__ import annotations
import threading
import unicodedata
import numpy as np
import sounddevice as sd
from core.stt import SAMPLE_RATE, is_silent, transcribe_confident

WAKE_WORD = "esclava"
WINDOW_SECONDS = 4
MAX_EDIT_DISTANCE = 2  # tolerancia a errores de transcripcion de Whisper sobre la palabra de activacion

_state = {"running": False}


_PUNCT = " ,.:;!¡¿?\"'"


def _normalize(text: str) -> str:
    nfkd = unicodedata.normalize("NFKD", text.lower())
    return "".join(c for c in nfkd if not unicodedata.combining(c))


def _normalize_word(word: str) -> str:
    return _normalize(word).strip(_PUNCT)


def _levenshtein(a: str, b: str) -> int:
    if len(a) < len(b):
        a, b = b, a
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def _find_command(text: str) -> str | None:
    """Busca la palabra de activacion de forma aproximada (Whisper suele transcribirla mal,
    p.ej. 'esclaro', 'es clara', 'le clava') y devuelve lo que sigue, o None si no aparece."""
    wake_norm = _normalize(WAKE_WORD)
    orig_words = text.split()
    norm_words = [_normalize_word(w) for w in orig_words]

    candidates = [(i, i + 1, w) for i, w in enumerate(norm_words)]
    candidates += [(i, i + 2, norm_words[i] + norm_words[i + 1]) for i in range(len(norm_words) - 1)]

    best_end, best_dist = None, MAX_EDIT_DISTANCE + 1
    for start, end, combined in candidates:
        dist = _levenshtein(combined, wake_norm)
        if dist < best_dist:
            best_dist, best_end = dist, end

    if best_end is None:
        return None
    return " ".join(orig_words[best_end:]).strip(_PUNCT)


def _record_window(seconds: float) -> np.ndarray:
    audio = sd.rec(int(seconds * SAMPLE_RATE), samplerate=SAMPLE_RATE, channels=1, dtype="float32")
    sd.wait()
    return audio.flatten()


def _loop(on_command) -> None:
    while _state["running"]:
        audio = _record_window(WINDOW_SECONDS)
        if not _state["running"]:
            break

        rms = float(np.sqrt(np.mean(audio ** 2))) if audio.size else 0.0
        if is_silent(audio):
            print(f"[wake_word] ventana silenciosa (rms={rms:.4f})", flush=True)
            continue

        text = transcribe_confident(audio)
        print(f"[wake_word] rms={rms:.4f} escuchado: {text!r}", flush=True)
        if not text:
            continue

        command = _find_command(text)
        if command is None:
            continue

        print(f"[wake_word] palabra de activacion detectada, comando: {command!r}", flush=True)
        if command:
            on_command(command)


def start(on_command) -> bool:
    if _state["running"]:
        return False
    _state["running"] = True
    threading.Thread(target=_loop, args=(on_command,), daemon=True).start()
    return True


def stop() -> bool:
    was_running = _state["running"]
    _state["running"] = False
    return was_running


def is_running() -> bool:
    return _state["running"]

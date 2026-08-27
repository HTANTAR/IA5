"""Reconocimiento de voz local (speech-to-text) con faster-whisper. Push-to-talk:
record_start() arranca a grabar del microfono, record_stop() corta y transcribe."""
from __future__ import annotations
import threading
import numpy as np
import sounddevice as sd
from faster_whisper import WhisperModel

SAMPLE_RATE = 16000
SILENCE_RMS_THRESHOLD = 0.012  # por debajo de esto se considera que no se dijo nada
NO_SPEECH_PROB_THRESHOLD = 0.5  # confianza del propio modelo de que el segmento es habla real
MIN_AUDIO_SECONDS = 0.6

_model: WhisperModel | None = None
_model_lock = threading.Lock()

_state = {"stream": None, "chunks": [], "lock": threading.Lock()}


def _get_model() -> WhisperModel:
    global _model
    with _model_lock:
        if _model is None:
            _model = WhisperModel("base", device="cpu", compute_type="int8")
        return _model


def is_silent(audio: np.ndarray) -> bool:
    if audio.size < SAMPLE_RATE * MIN_AUDIO_SECONDS:
        return True
    rms = float(np.sqrt(np.mean(audio ** 2))) if audio.size else 0.0
    return rms < SILENCE_RMS_THRESHOLD


def transcribe_confident(audio: np.ndarray) -> str:
    """Transcribe y descarta segmentos donde el modelo no esta seguro de que sea habla real
    (evita alucinar frases a partir de ruido de fondo o silencio)."""
    model = _get_model()
    segments, _info = model.transcribe(
        audio,
        language="es",
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 400},
    )
    confident = [seg.text.strip() for seg in segments if seg.no_speech_prob < NO_SPEECH_PROB_THRESHOLD]
    return " ".join(confident).strip()


def _callback(indata, frames, time_info, status):
    with _state["lock"]:
        _state["chunks"].append(indata.copy())


def record_start() -> None:
    with _state["lock"]:
        _state["chunks"] = []
    stream = sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
        callback=_callback,
    )
    stream.start()
    _state["stream"] = stream


def record_stop() -> str:
    stream = _state["stream"]
    if stream is None:
        return ""
    stream.stop()
    stream.close()
    _state["stream"] = None

    with _state["lock"]:
        chunks = _state["chunks"]
        _state["chunks"] = []

    if not chunks:
        return ""
    audio = np.concatenate(chunks, axis=0).flatten()

    if is_silent(audio):
        return ""

    return transcribe_confident(audio)

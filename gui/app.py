"""Backend FastAPI: expone el orquestador a la interfaz grafica."""
from __future__ import annotations
import json
import queue
from pathlib import Path
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, Response, StreamingResponse
from pydantic import BaseModel

from agents import orchestrator, meta_agent
from core import voice, stt, wake_word

app = FastAPI()

STATIC_DIR = Path(__file__).resolve().parent / "static"

SESSION_HISTORY: list[dict] = []
MAX_HISTORY_MESSAGES = 20
WAKE_EVENTS: "queue.Queue[dict]" = queue.Queue()


class ChatRequest(BaseModel):
    message: str


class VoiceRequest(BaseModel):
    enabled: bool


class TTSRequest(BaseModel):
    text: str


def _process_message(message: str) -> dict:
    result = orchestrator.handle(message, SESSION_HISTORY)
    SESSION_HISTORY.append({"role": "user", "content": message})
    SESSION_HISTORY.append({"role": "assistant", "content": result["reply"]})
    del SESSION_HISTORY[: max(0, len(SESSION_HISTORY) - MAX_HISTORY_MESSAGES)]
    return result


def _on_wake_command(command: str) -> None:
    WAKE_EVENTS.put({"type": "user", "text": command})
    result = _process_message(command)
    WAKE_EVENTS.put({"type": "assistant", "agent": result["agent"], "text": result["reply"]})


@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")


@app.post("/api/chat")
def api_chat(req: ChatRequest):
    return _process_message(req.message)


@app.post("/api/reset")
def api_reset():
    SESSION_HISTORY.clear()
    return {"ok": True}


@app.get("/api/voice")
def api_voice_get():
    return {"enabled": voice.is_enabled()}


@app.post("/api/voice")
def api_voice_set(req: VoiceRequest):
    return {"enabled": voice.set_enabled(req.enabled)}


@app.post("/api/tts")
async def api_tts(req: TTSRequest):
    audio = await voice.synthesize_bytes(req.text)
    return Response(content=audio, media_type="audio/mpeg")


@app.post("/api/listen/start")
def api_listen_start():
    stt.record_start()
    return {"ok": True}


@app.post("/api/listen/stop")
def api_listen_stop():
    text = stt.record_stop()
    return {"text": text}


@app.post("/api/wake/start")
def api_wake_start():
    wake_word.start(_on_wake_command)
    return {"listening": wake_word.is_running(), "wake_word": wake_word.WAKE_WORD}


@app.post("/api/wake/stop")
def api_wake_stop():
    wake_word.stop()
    return {"listening": wake_word.is_running()}


@app.get("/api/wake/status")
def api_wake_status():
    return {"listening": wake_word.is_running(), "wake_word": wake_word.WAKE_WORD}


@app.get("/api/wake/stream")
def api_wake_stream():
    def event_gen():
        while True:
            event = WAKE_EVENTS.get()
            yield f"data: {json.dumps(event, ensure_ascii=False)}\n\n"

    return StreamingResponse(event_gen(), media_type="text/event-stream")


@app.get("/api/proposals")
def api_proposals():
    return {"proposals": meta_agent.list_pending()}


app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

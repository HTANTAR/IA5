"""Cliente unificado de LLM: habla con Ollama (local) o Gemini (nube, tier gratis)."""
from __future__ import annotations
import json
import re
import truststore
truststore.inject_into_ssl()  # usa el almacen de certificados de Windows (evita SSL errors con AV/proxies locales)

import requests
from core.config import CONFIG, gemini_api_key


class LLMError(RuntimeError):
    pass


def _extract_json_objects(text: str) -> list[dict]:
    """Busca objetos JSON balanceados en un texto (con o sin fences ```json)."""
    objects = []
    i = 0
    while i < len(text):
        if text[i] == "{":
            depth = 0
            start = i
            in_string = False
            escape = False
            j = i
            while j < len(text):
                ch = text[j]
                if in_string:
                    if escape:
                        escape = False
                    elif ch == "\\":
                        escape = True
                    elif ch == '"':
                        in_string = False
                else:
                    if ch == '"':
                        in_string = True
                    elif ch == "{":
                        depth += 1
                    elif ch == "}":
                        depth -= 1
                        if depth == 0:
                            j += 1
                            break
                j += 1
            candidate = text[start:j]
            try:
                objects.append(json.loads(candidate))
            except json.JSONDecodeError:
                pass
            i = j if j > i else i + 1
        else:
            i += 1
    return objects


def _fallback_tool_calls(content: str, valid_names: set[str]) -> list[dict]:
    """Si el modelo no devolvio tool_calls estructurados, intenta parsearlos del texto plano.
    Solo reconoce objetos cuyo nombre coincide con una herramienta ofrecida en este pedido."""
    calls = []
    for obj in _extract_json_objects(content):
        name = obj.get("name")
        args = obj.get("arguments", obj.get("parameters", {}))
        if name in valid_names and isinstance(args, dict):
            calls.append({"function": {"name": name, "arguments": args}})
    return calls


def chat_ollama(messages: list[dict], model: str, tools: list[dict] | None = None) -> dict:
    url = f"{CONFIG['ollama']['host']}/api/chat"
    payload = {"model": model, "messages": messages, "stream": False}
    if tools:
        payload["tools"] = tools
    resp = requests.post(url, json=payload, timeout=300)
    if resp.status_code != 200:
        raise LLMError(f"Ollama error {resp.status_code}: {resp.text}")
    data = resp.json()
    msg = data.get("message", {})
    content = msg.get("content", "")
    tool_calls = msg.get("tool_calls", [])

    if tools and not tool_calls and content.strip():
        valid_names = {t["function"]["name"] for t in tools}
        fallback = _fallback_tool_calls(content, valid_names)
        if fallback:
            return {"content": "", "tool_calls": fallback}

    return {"content": content, "tool_calls": tool_calls}


def chat_gemini(messages: list[dict], tools: list[dict] | None = None) -> dict:
    key = gemini_api_key()
    if not key:
        raise LLMError("GEMINI_API_KEY no configurada")
    model = CONFIG["gemini"]["model"]
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"

    system_parts = [m["content"] for m in messages if m["role"] == "system"]
    contents = []
    for m in messages:
        if m["role"] == "system":
            continue
        role = "model" if m["role"] == "assistant" else "user"
        contents.append({"role": role, "parts": [{"text": m["content"]}]})

    payload: dict = {"contents": contents}
    if system_parts:
        payload["systemInstruction"] = {"parts": [{"text": "\n".join(system_parts)}]}

    resp = requests.post(url, json=payload, timeout=120)
    if resp.status_code != 200:
        raise LLMError(f"Gemini error {resp.status_code}: {resp.text}")
    data = resp.json()
    try:
        text = data["candidates"][0]["content"]["parts"][0]["text"]
    except (KeyError, IndexError):
        text = ""
    return {"content": text, "tool_calls": []}


def chat(messages: list[dict], agent: str = "orchestrator", tools: list[dict] | None = None) -> dict:
    """Punto de entrada unico. Elige proveedor segun config, con fallback a Ollama si falla la nube."""
    provider = CONFIG["providers"].get(agent, "ollama")

    if provider == "gemini_or_ollama":
        if gemini_api_key():
            try:
                return chat_gemini(messages, tools=tools)
            except LLMError:
                pass
        return chat_ollama(messages, model=CONFIG["ollama"]["model_general"], tools=tools)

    if provider == "gemini":
        return chat_gemini(messages, tools=tools)

    model = CONFIG["ollama"]["model_code"] if agent == "code_agent" else CONFIG["ollama"]["model_general"]
    return chat_ollama(messages, model=model, tools=tools)

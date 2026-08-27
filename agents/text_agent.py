"""Agente que inspecciona y analiza texto proporcionado por el usuario."""
from core.llm_client import chat

SYSTEM_PROMPT = """Sos un agente especializado en analizar texto. Dado un texto, según lo que
pida el usuario podés: resumir, detectar tono/sentimiento, encontrar inconsistencias o errores,
extraer datos clave, identificar entidades, o evaluar la calidad de la escritura.
Respondé en español, de forma clara y estructurada (usa listas cuando ayude)."""


def run(user_message: str, history: list[dict] | None = None) -> str:
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    messages += history or []
    messages.append({"role": "user", "content": user_message})
    result = chat(messages, agent="text_agent")
    return result["content"]

"""Agente orquestador: decide que agente especializado atiende cada mensaje."""
from __future__ import annotations
from core.llm_client import chat
from core import memory
from agents import code_agent, text_agent, browser_agent, learning_agent, meta_agent

ROUTER_PROMPT = """Clasificá el siguiente mensaje del usuario en UNA sola palabra, sin explicar nada mas:
- "codigo" si pide crear, revisar, corregir, ejecutar o explicar código/programación/archivos de un proyecto.
- "texto" si pide analizar, resumir, corregir o inspeccionar un texto que él te da.
- "navegador" si pide abrir una página, buscar algo en internet, o buscar/reproducir/controlar música o video.
- "aprender" SOLO si el mensaje usa explícitamente palabras como "aprendé", "investigá" o "averiguá"
  pidiendo estudiar un tema para el futuro. Una pregunta normal que busca una respuesta ahora NO es esto.
- "general" para cualquier otra cosa: charla, preguntas generales o fácticas (aunque requieran saber
  algo de internet), pedidos que no encajan arriba.

Mensaje: {message}

Respondé solo con: codigo, texto, navegador, aprender o general."""

GENERAL_SYSTEM_PROMPT = """Sos la orquestadora de un sistema de IA local con varios agentes
especializados (código, análisis de texto, navegador, y aprendizaje). Respondé de forma amigable,
cercana y breve en español. Si el pedido requiere código, análisis de texto o navegación, ya se
deriva automáticamente al agente correspondiente, así que en 'general' solo charlás, respondés
preguntas simples o coordinás.
Si se te da una sección "Recordá esto de tu memoria", son datos que vos misma aprendiste antes
investigando en internet: usalos si son relevantes para la respuesta, pero no los repitas si no vienen al caso."""


WEATHER_KEYWORDS = ("clima", "temperatura", "grados", "llueve", "lluvia", "pronóstico", "pronostico")
SYSTEM_INFO_KEYWORDS = ("rendimiento", "performance", "uso de cpu", "uso del cpu", "memoria ram", "espacio en disco")
CREATE_AGENT_KEYWORDS = (
    "crea un agente", "creá un agente", "crear un agente", "nuevo agente",
    "necesito un agente", "hace falta un agente", "armá un agente", "arma un agente",
)


def classify(message: str) -> str:
    lowered = message.lower()
    if any(kw in lowered for kw in CREATE_AGENT_KEYWORDS):
        return "crear_agente"
    if any(kw in lowered for kw in WEATHER_KEYWORDS) or any(kw in lowered for kw in SYSTEM_INFO_KEYWORDS):
        return "navegador"

    result = chat(
        [{"role": "user", "content": ROUTER_PROMPT.format(message=message)}],
        agent="orchestrator",
    )
    label = result["content"].strip().lower()
    if "codigo" in label or "código" in label:
        return "codigo"
    if "texto" in label:
        return "texto"
    if "navegador" in label:
        return "navegador"
    if "aprender" in label:
        return "aprender"
    return "general"


TOPIC_PROMPT = """Convertí este pedido en una consulta corta de búsqueda (2 a 6 palabras), sin verbos
como "aprender" o "investigar", solo el tema. No repitas la oración completa. No expliques nada.

Ejemplo:
Pedido: "Aprendé sobre el planeta Marte"
Consulta: planeta Marte

Pedido: "{message}"
Consulta:"""


def _extract_topic(user_message: str) -> str:
    result = chat(
        [{"role": "user", "content": TOPIC_PROMPT.format(message=user_message)}],
        agent="orchestrator",
    )
    topic = result["content"].strip().strip('"').split("\n")[0].strip()
    return topic or user_message


def handle(user_message: str, history: list[dict] | None = None) -> dict:
    intent = classify(user_message)

    if intent == "codigo":
        reply = code_agent.run(user_message, history)
    elif intent == "texto":
        reply = text_agent.run(user_message, history)
    elif intent == "navegador":
        reply = browser_agent.run(user_message, history)
    elif intent == "aprender":
        topic = _extract_topic(user_message)
        reply = learning_agent.learn_about(topic)
    elif intent == "crear_agente":
        reply = meta_agent.propose_agent(user_message)
    else:
        messages = [{"role": "system", "content": GENERAL_SYSTEM_PROMPT}]
        messages += history or []

        recalled = memory.recall(user_message, top_k=3)
        if recalled:
            context = "\n".join(f"- {f['text']}" for f in recalled)
            messages.append({"role": "system", "content": f"Recordá esto de tu memoria:\n{context}"})

        messages.append({"role": "user", "content": user_message})
        reply = chat(messages, agent="orchestrator")["content"]

    return {"agent": intent, "reply": reply}

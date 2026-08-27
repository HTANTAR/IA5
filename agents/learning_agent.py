"""Agente de auto-aprendizaje: investiga un tema en internet, extrae hechos clave
y los guarda en la memoria local para usarlos en conversaciones futuras."""
from __future__ import annotations
from core.llm_client import chat
from core import web_research, memory

SUMMARY_PROMPT = """Leé el siguiente contenido extraído de una página web sobre "{topic}"
y extraé entre 3 y 6 datos concretos y verificables (hechos, no opiniones), uno por línea,
sin numerar, en español, cada uno una oración corta y autocontenida (que se entienda sin
el resto del contexto).

Contenido:
{content}"""


def learn_about(topic: str, max_sources: int = 3) -> str:
    links = web_research.search_links(topic, max_results=max_sources)
    if not links:
        return f"No encontré resultados en internet sobre '{topic}'."

    learned_count = 0
    sources_used = []
    for link in links:
        page_text = web_research.fetch_page_text(link["url"])
        if not page_text:
            continue

        result = chat(
            [{"role": "user", "content": SUMMARY_PROMPT.format(topic=topic, content=page_text)}],
            agent="orchestrator",
        )
        raw_lines = [line.strip("-•0123456789. ").strip() for line in result["content"].splitlines() if line.strip()]
        facts = [line for line in raw_lines if len(line) > 15 and not line.endswith(":")]

        for fact in facts:
            memory.remember(fact, topic=topic, source=link["url"])
            learned_count += 1
        if facts:
            sources_used.append(link["url"])

    if learned_count == 0:
        return f"Busqué sobre '{topic}' pero no pude extraer datos confiables de las páginas encontradas."

    fuentes = "\n".join(f"- {s}" for s in sources_used)
    return f"Aprendí {learned_count} datos nuevos sobre '{topic}'. Fuentes:\n{fuentes}"


def recall(query: str) -> str:
    facts = memory.recall(query)
    if not facts:
        return "No tengo nada guardado sobre eso todavía."
    lines = [f"- {f['text']} (fuente: {f['source']})" for f in facts]
    return "Esto es lo que recuerdo:\n" + "\n".join(lines)

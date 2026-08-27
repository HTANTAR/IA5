"""Agente de computer-use: controla un navegador real para buscar, navegar y reproducir música/video.
Alcance acotado a nivel navegador (sin acceso a archivos ni al sistema)."""
from __future__ import annotations
import json
import unicodedata
from urllib.parse import urlparse
from core.llm_client import chat
from core.browser_tools import TOOL_SCHEMAS, TOOL_FUNCTIONS

_PLAY_FILLER_WORDS = {
    "podes", "puedes", "podrias", "abrime", "abrir", "abre", "abri", "youtube",
    "poner", "pon", "pone", "ponerme", "ponme", "reproducir", "reproduce", "reproduci",
    "buscar", "buscame", "porfavor", "porfa", "favor", "dale", "che", "vamos", "y",
}


def _normalize(text: str) -> str:
    nfkd = unicodedata.normalize("NFKD", text.lower())
    return "".join(c for c in nfkd if not unicodedata.combining(c))


def _extract_play_query(message: str) -> str:
    """Heurística de respaldo: si el modelo intentó abrir YouTube en blanco en vez de buscar,
    reconstruye el término de búsqueda a partir del pedido original del usuario."""
    kept = [w for w in message.split() if _normalize(w).strip(",.!¿?¡\"'") not in _PLAY_FILLER_WORDS]
    query = " ".join(kept).strip(" ,.!¿?¡\"'")
    return query or message


def _is_bare_youtube_url(url: str) -> bool:
    parsed = urlparse(url if "://" in url else f"https://{url}")
    host = parsed.netloc.lower()
    if "youtube.com" not in host and "youtu.be" not in host:
        return False
    return parsed.path in ("", "/") and not parsed.query

SYSTEM_PROMPT = """Sos un agente que controla un navegador web real para el usuario.
Podés abrir páginas, buscar en la web, buscar y reproducir música/videos en YouTube,
hacer click en elementos por su texto, escribir texto y controlar la reproducción con teclas.

Para pedidos de clima/temperatura: usá SIEMPRE get_weather (no hace falta abrir el navegador para esto).
Para pedidos de rendimiento/performance de la PC (CPU, RAM, disco, GPU): usá SIEMPRE get_system_info.
Para pedidos de música o video: usá directamente search_youtube_and_play con la búsqueda.
Para controlar la reproducción ya iniciada: usá press_key con 'k' o espacio (play/pausa),
'm' (mute), ArrowUp/ArrowDown (volumen).
Para otras preguntas que requieren info de internet: usá search_web y leé los resultados con get_text.

REGLA CRÍTICA: nunca inventes datos (temperaturas, fechas, precios, hechos) que no vengan literalmente
del resultado de una herramienta. Si una herramienta falla o no tenés la información, decile al usuario
que no la pudiste obtener — jamás completes el hueco con un valor inventado que suene plausible.

REGLA CRÍTICA: en tu respuesta final SIEMPRE repetí el dato concreto que te devolvió la herramienta
(la temperatura, el resultado, el texto encontrado, etc). Nunca respondas solo "ya lo hice" o "usé tal
función" sin decir el contenido real — el usuario no ve lo que devuelven las herramientas, solo tu respuesta.

No pidas contraseñas ni datos de pago, y no completes formularios de login por tu cuenta:
si el navegador te pide iniciar sesión, avisale al usuario en vez de intentarlo vos.
Respondé siempre en español, breve, contando qué hiciste."""

MAX_TOOL_ITERATIONS = 6

# Herramientas cuyo resultado ya es una respuesta lista para el usuario: se devuelve tal cual,
# sin pasar de nuevo por el modelo, porque el modelo local a veces "olvida" repetir el dato
# o inventa que algo funcionó cuando no.
SELF_SUFFICIENT_TOOLS = {"get_weather", "get_system_info", "search_youtube_and_play"}


def run(user_message: str, history: list[dict] | None = None) -> str:
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    messages += history or []
    messages.append({"role": "user", "content": user_message})

    for _ in range(MAX_TOOL_ITERATIONS):
        result = chat(messages, agent="browser_agent", tools=TOOL_SCHEMAS)
        tool_calls = result.get("tool_calls") or []

        if not tool_calls:
            return result["content"]

        messages.append({"role": "assistant", "content": result["content"], "tool_calls": tool_calls})

        for call in tool_calls:
            fn_name = call["function"]["name"]
            raw_args = call["function"].get("arguments", {})
            args = raw_args if isinstance(raw_args, dict) else json.loads(raw_args)

            # Red de seguridad: si el modelo intenta "abrir youtube" en blanco en vez de buscar
            # algo puntual, lo mas probable es que la intencion real sea reproducir una cancion/video.
            if fn_name == "open_url" and _is_bare_youtube_url(args.get("url", "")):
                fn_name = "search_youtube_and_play"
                args = {"query": _extract_play_query(user_message)}

            fn = TOOL_FUNCTIONS.get(fn_name)
            if fn is None:
                output = f"Herramienta desconocida: {fn_name}"
            else:
                try:
                    output = fn(**args)
                except Exception as exc:  # noqa: BLE001
                    output = f"Error ejecutando {fn_name}: {exc}"

            if fn_name in SELF_SUFFICIENT_TOOLS and isinstance(output, str) and output:
                return output

            messages.append({
                "role": "tool",
                "content": output if isinstance(output, str) else json.dumps(output, ensure_ascii=False),
            })

    return "Llegué al límite de pasos navegando. Podés pedirme que continúe."

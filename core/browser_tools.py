"""Definicion de herramientas de navegador expuestas al LLM (formato compatible con Ollama/OpenAI)."""
from core import browser
from core import web_research
from core import system_info

TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "get_system_info",
            "description": "Devuelve el uso REAL actual de CPU, RAM, disco y GPU de la PC. Usar siempre "
                           "esta herramienta para pedidos de rendimiento/performance de la computadora, "
                           "en vez de recomendar herramientas externas o adivinar.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Devuelve el clima ACTUAL real de una ubicación (temperatura, sensación térmica, "
                           "humedad). Usar SIEMPRE esta herramienta para pedidos de clima/temperatura, en vez "
                           "de adivinar o de abrir el navegador. No hace falta abrir ninguna página para esto.",
            "parameters": {
                "type": "object",
                "properties": {"location": {"type": "string", "description": "Ciudad o localidad, ej: 'Burzaco, Buenos Aires'"}},
                "required": ["location"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "open_url",
            "description": "Abre una URL en el navegador",
            "parameters": {
                "type": "object",
                "properties": {"url": {"type": "string"}},
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_web",
            "description": "Busca una consulta en DuckDuckGo y devuelve el texto de resultados",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string"}},
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_youtube_and_play",
            "description": "Busca una canción/video en YouTube y reproduce el primer resultado. Usar esto para pedidos de música.",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string"}},
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "click_text",
            "description": "Hace click en el primer elemento de la página que contenga ese texto visible",
            "parameters": {
                "type": "object",
                "properties": {"text": {"type": "string"}},
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "type_text",
            "description": "Escribe texto donde esté el foco actual del navegador (por ejemplo un buscador)",
            "parameters": {
                "type": "object",
                "properties": {"text": {"type": "string"}},
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "press_key",
            "description": "Presiona una tecla en el navegador. Útil para controlar reproducción de YouTube: "
                           "'k' o espacio = play/pausa, 'm' = mute, ArrowUp/ArrowDown = volumen, 'f' = pantalla completa.",
            "parameters": {
                "type": "object",
                "properties": {"key": {"type": "string"}},
                "required": ["key"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_text",
            "description": "Devuelve el texto visible de la página actual, para leer resultados o confirmar estado",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "go_back",
            "description": "Vuelve a la página anterior en el navegador",
            "parameters": {"type": "object", "properties": {}},
        },
    },
]

TOOL_FUNCTIONS = {
    "get_system_info": system_info.get_system_info,
    "get_weather": web_research.get_weather,
    "open_url": browser.open_url,
    "search_web": browser.search_web,
    "search_youtube_and_play": browser.search_youtube_and_play,
    "click_text": browser.click_text,
    "type_text": browser.type_text,
    "press_key": browser.press_key,
    "get_text": browser.get_text,
    "go_back": browser.go_back,
}

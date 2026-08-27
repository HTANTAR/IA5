"""Agente de codigo: escribe, analiza y ejecuta codigo dentro de workspace/."""
from __future__ import annotations
import json
from core.llm_client import chat
from core.tools import TOOL_SCHEMAS, TOOL_FUNCTIONS

SYSTEM_PROMPT = """Sos un agente de programacion. Podes leer, escribir y ejecutar archivos
dentro de la carpeta workspace del proyecto usando las herramientas disponibles.
Cuando el usuario pida crear, analizar o implementar codigo:
1. Si necesitas ver archivos existentes, usa read_file o list_dir primero.
2. Escribi el codigo con write_file.
3. Si es razonable, corre el codigo o los tests con run_command para verificar que funciona.
4. Respondé siempre en español, de forma breve, explicando qué hiciste y el resultado.
No inventes que algo funciona sin haberlo corrido si tenés la herramienta para probarlo."""

MAX_TOOL_ITERATIONS = 8


def run(user_message: str, history: list[dict] | None = None) -> str:
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    messages += history or []
    messages.append({"role": "user", "content": user_message})

    for _ in range(MAX_TOOL_ITERATIONS):
        result = chat(messages, agent="code_agent", tools=TOOL_SCHEMAS)
        tool_calls = result.get("tool_calls") or []

        if not tool_calls:
            return result["content"]

        messages.append({"role": "assistant", "content": result["content"], "tool_calls": tool_calls})

        for call in tool_calls:
            fn_name = call["function"]["name"]
            raw_args = call["function"].get("arguments", {})
            args = raw_args if isinstance(raw_args, dict) else json.loads(raw_args)
            fn = TOOL_FUNCTIONS.get(fn_name)
            if fn is None:
                output = f"Herramienta desconocida: {fn_name}"
            else:
                try:
                    output = fn(**args)
                except Exception as exc:  # noqa: BLE001
                    output = f"Error ejecutando {fn_name}: {exc}"
            messages.append({
                "role": "tool",
                "content": json.dumps(output, ensure_ascii=False) if not isinstance(output, str) else output,
            })

    return "Llegué al límite de pasos intentando resolver esto. Podés pedirme que continúe."

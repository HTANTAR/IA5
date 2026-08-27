"""Meta-agente: cuando falta una capacidad, redacta un agente nuevo dentro de una carpeta
de prueba aislada (sandbox/pending_review/). Nunca lo integra a la app real por su cuenta:
el modelo local se equivoca seguido incluso en tareas mas simples que esta (lo vimos varias
veces hoy con clima, rutas y musica), asi que pasar a produccion requiere revision humana/de Claude."""
from __future__ import annotations
import json
import re
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

from core.llm_client import chat
from core.sandbox_tools import make_tools

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SANDBOX_ROOT = PROJECT_ROOT / "sandbox" / "pending_review"

SYSTEM_PROMPT = """Sos el modulo que redacta agentes nuevos para un sistema de IA local, dentro de una
carpeta de prueba aislada. Tu unica tarea es escribir un archivo agent_code.py que:
- defina una funcion run(message: str, history: list[dict] | None = None) -> str
- pueda hacer 'from core.llm_client import chat' para usar el modelo de lenguaje local
  (chat(messages, agent="general") devuelve {"content": str, "tool_calls": [...]})
- resuelva el pedido del usuario de la forma mas simple posible

IMPORTANTE: no describas el código en texto. Tu PRIMER mensaje tiene que ser directamente una
llamada a la herramienta write_file("agent_code.py", <código>) — no expliques qué harías, hacelo.
El sistema prueba el archivo automáticamente después. Recién cuando ya lo hayas escrito con
write_file, respondé con una descripción corta (1-2 frases) de qué hace el agente."""

MAX_ITERATIONS = 6


def _slugify(text: str) -> str:
    nfkd = unicodedata.normalize("NFKD", text.lower())
    ascii_text = "".join(c for c in nfkd if not unicodedata.combining(c))
    slug = re.sub(r"[^a-z0-9]+", "_", ascii_text).strip("_")
    return slug[:40] or "agente"


def _smoke_test(sandbox_dir: Path) -> dict:
    """Corre el agente recien redactado en un subproceso aparte (no en el proceso de la app real)
    con un mensaje de prueba, solo para ver si al menos no explota al importarlo/correrlo."""
    code = (
        "import sys; "
        f"sys.path.insert(0, r'{PROJECT_ROOT}'); "
        f"sys.path.insert(0, r'{sandbox_dir}'); "
        "import agent_code; "
        "print(agent_code.run('mensaje de prueba', []))"
    )
    try:
        result = subprocess.run(
            [sys.executable, "-c", code],
            cwd=str(PROJECT_ROOT), capture_output=True, text=True, timeout=45,
        )
        return {"returncode": result.returncode, "stdout": result.stdout[-2000:], "stderr": result.stderr[-2000:]}
    except subprocess.TimeoutExpired:
        return {"returncode": -1, "stdout": "", "stderr": "Timeout probando el agente"}


def propose_agent(request: str) -> str:
    slug = _slugify(request)
    folder_name = f"{time.strftime('%Y%m%d_%H%M%S')}_{slug}"
    sandbox_dir = SANDBOX_ROOT / folder_name
    schemas, functions = make_tools(sandbox_dir)

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"Necesito un agente que resuelva esto: {request}"},
    ]

    description = ""
    for _ in range(MAX_ITERATIONS):
        result = chat(messages, agent="meta_agent", tools=schemas)
        tool_calls = result.get("tool_calls") or []
        if not tool_calls:
            description = result["content"]
            break
        messages.append({"role": "assistant", "content": result["content"], "tool_calls": tool_calls})
        for call in tool_calls:
            fn_name = call["function"]["name"]
            raw_args = call["function"].get("arguments", {})
            args = raw_args if isinstance(raw_args, dict) else json.loads(raw_args)
            fn = functions.get(fn_name)
            output = fn(**args) if fn else f"Herramienta desconocida: {fn_name}"
            messages.append({
                "role": "tool",
                "content": output if isinstance(output, str) else json.dumps(output, ensure_ascii=False),
            })

    agent_file = sandbox_dir / "agent_code.py"
    if not agent_file.exists():
        return "No pude generar un boceto de agente para ese pedido. Probá describirlo de otra forma."

    test = _smoke_test(sandbox_dir)
    proposal = {
        "request": request,
        "slug": slug,
        "description": description,
        "created_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "test_passed": test["returncode"] == 0,
        "test_stdout": test["stdout"],
        "test_stderr": test["stderr"],
    }
    (sandbox_dir / "proposal.json").write_text(json.dumps(proposal, ensure_ascii=False, indent=2), encoding="utf-8")

    status = "pasó la prueba básica" if proposal["test_passed"] else "TIENE ERRORES en la prueba básica"
    return (
        f"Armé un boceto de agente para \"{request}\" en sandbox/pending_review/{folder_name}/ ({status}). "
        f"{description}\n\n"
        f"No lo activé en la app real: no tengo forma de garantizar que funcione bien sin que alguien lo revise "
        f"(el modelo local se equivoca seguido, incluso en cosas más simples). Para ponerlo en producción, "
        f"mostrame esa carpeta en una conversación conmigo (Claude) y lo reviso e integro si está bien."
    )


def list_pending() -> list[dict]:
    if not SANDBOX_ROOT.exists():
        return []
    proposals = []
    for folder in sorted(SANDBOX_ROOT.iterdir(), reverse=True):
        proposal_file = folder / "proposal.json"
        if proposal_file.exists():
            data = json.loads(proposal_file.read_text(encoding="utf-8"))
            data["folder"] = folder.name
            proposals.append(data)
    return proposals

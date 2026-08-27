"""Herramientas del agente de codigo. Todo queda confinado a la carpeta workspace/."""
from __future__ import annotations
import subprocess
from pathlib import Path

WORKSPACE = (Path(__file__).resolve().parent.parent / "workspace").resolve()
WORKSPACE.mkdir(exist_ok=True)


class ToolError(RuntimeError):
    pass


def _safe_path(relative_path: str) -> Path:
    candidate = (WORKSPACE / relative_path).resolve()
    if WORKSPACE not in candidate.parents and candidate != WORKSPACE:
        raise ToolError(f"Ruta fuera del workspace no permitida: {relative_path}")
    return candidate


def read_file(relative_path: str) -> str:
    path = _safe_path(relative_path)
    if not path.exists():
        raise ToolError(f"No existe: {relative_path}")
    return path.read_text(encoding="utf-8", errors="replace")


def write_file(relative_path: str, content: str) -> str:
    path = _safe_path(relative_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return f"Escrito: {relative_path} ({len(content)} bytes)"


def list_dir(relative_path: str = ".") -> list[str]:
    path = _safe_path(relative_path)
    if not path.exists():
        raise ToolError(f"No existe: {relative_path}")
    return sorted(p.name + ("/" if p.is_dir() else "") for p in path.iterdir())


def run_command(command: str, timeout: int = 60) -> dict:
    """Ejecuta un comando dentro de workspace/. Sin acceso a nada fuera de esa carpeta por convencion,
    aunque el propio comando podria intentarlo: usar solo con codigo que vos mismo revisaste."""
    try:
        result = subprocess.run(
            command,
            shell=True,
            cwd=str(WORKSPACE),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return {
            "stdout": result.stdout[-8000:],
            "stderr": result.stderr[-4000:],
            "returncode": result.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"stdout": "", "stderr": f"Timeout tras {timeout}s", "returncode": -1}


TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Lee un archivo dentro del workspace del proyecto",
            "parameters": {
                "type": "object",
                "properties": {"relative_path": {"type": "string"}},
                "required": ["relative_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Crea o sobreescribe un archivo dentro del workspace",
            "parameters": {
                "type": "object",
                "properties": {
                    "relative_path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["relative_path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_dir",
            "description": "Lista archivos y carpetas dentro del workspace",
            "parameters": {
                "type": "object",
                "properties": {"relative_path": {"type": "string"}},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Ejecuta un comando de shell dentro del workspace (python, node, npm, pytest, etc)",
            "parameters": {
                "type": "object",
                "properties": {"command": {"type": "string"}},
                "required": ["command"],
            },
        },
    },
]

TOOL_FUNCTIONS = {
    "read_file": read_file,
    "write_file": write_file,
    "list_dir": list_dir,
    "run_command": run_command,
}

"""Herramientas de archivo/ejecucion iguales a core.tools pero con raiz configurable: se usan para que
el meta-agente redacte y pruebe agentes nuevos en una carpeta aislada, sin tocar el resto del proyecto."""
from __future__ import annotations
import subprocess
from pathlib import Path


class ToolError(RuntimeError):
    pass


def make_tools(root: Path):
    root = root.resolve()
    root.mkdir(parents=True, exist_ok=True)

    def _safe_path(relative_path: str) -> Path:
        candidate = (root / relative_path).resolve()
        if root not in candidate.parents and candidate != root:
            raise ToolError(f"Ruta fuera de la carpeta de trabajo no permitida: {relative_path}")
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
            return []
        return sorted(p.name + ("/" if p.is_dir() else "") for p in path.iterdir())

    def run_command(command: str, timeout: int = 30) -> dict:
        try:
            result = subprocess.run(
                command, shell=True, cwd=str(root),
                capture_output=True, text=True, timeout=timeout,
            )
            return {"stdout": result.stdout[-4000:], "stderr": result.stderr[-2000:], "returncode": result.returncode}
        except subprocess.TimeoutExpired:
            return {"stdout": "", "stderr": f"Timeout tras {timeout}s", "returncode": -1}

    schemas = [
        {"type": "function", "function": {
            "name": "read_file", "description": "Lee un archivo dentro de esta carpeta de trabajo aislada",
            "parameters": {"type": "object", "properties": {"relative_path": {"type": "string"}}, "required": ["relative_path"]},
        }},
        {"type": "function", "function": {
            "name": "write_file", "description": "Crea o sobreescribe un archivo dentro de esta carpeta de trabajo aislada",
            "parameters": {"type": "object", "properties": {
                "relative_path": {"type": "string"}, "content": {"type": "string"}}, "required": ["relative_path", "content"]},
        }},
        {"type": "function", "function": {
            "name": "list_dir", "description": "Lista archivos dentro de esta carpeta de trabajo aislada",
            "parameters": {"type": "object", "properties": {"relative_path": {"type": "string"}}},
        }},
        {"type": "function", "function": {
            "name": "run_command", "description": "Ejecuta un comando dentro de esta carpeta de trabajo aislada (ej: python para probar el codigo)",
            "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]},
        }},
    ]
    functions = {"read_file": read_file, "write_file": write_file, "list_dir": list_dir, "run_command": run_command}
    return schemas, functions

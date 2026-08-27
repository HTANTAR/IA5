"""Informacion real del sistema (CPU, RAM, disco, GPU) para responder sobre rendimiento sin inventar datos."""
from __future__ import annotations
import subprocess
import psutil


def _gpu_info() -> str:
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            util, mem_used, mem_total, temp = [p.strip() for p in result.stdout.strip().split(",")]
            return f"GPU al {util}% de uso, {mem_used}/{mem_total} MB de VRAM, {temp}°C."
    except Exception:
        pass
    return "No pude leer datos de la GPU (nvidia-smi no disponible)."


def get_system_info() -> str:
    cpu_percent = psutil.cpu_percent(interval=0.5)
    ram = psutil.virtual_memory()
    disk = psutil.disk_usage("C:\\")

    ram_used_gb = ram.used / (1024 ** 3)
    ram_total_gb = ram.total / (1024 ** 3)
    disk_free_gb = disk.free / (1024 ** 3)
    disk_total_gb = disk.total / (1024 ** 3)

    return (
        f"CPU al {cpu_percent}% de uso. "
        f"RAM: {ram_used_gb:.1f} de {ram_total_gb:.1f} GB usados ({ram.percent}%). "
        f"Disco C: {disk_free_gb:.1f} GB libres de {disk_total_gb:.1f} GB. "
        f"{_gpu_info()}"
    )

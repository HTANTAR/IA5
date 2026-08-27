"""Investigacion web liviana (sin navegador) para alimentar la memoria: busca, lee y resume."""
from __future__ import annotations
import truststore
truststore.inject_into_ssl()  # usa el almacen de certificados de Windows (evita SSL errors con AV/proxies locales)

import requests
from bs4 import BeautifulSoup

HEADERS = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) IA-Local-Research/1.0"}


def search_links(query: str, max_results: int = 3) -> list[dict]:
    resp = requests.post(
        "https://html.duckduckgo.com/html/",
        data={"q": query},
        headers=HEADERS,
        timeout=20,
    )
    soup = BeautifulSoup(resp.text, "lxml")
    results = []
    for link in soup.select("a.result__a")[:max_results]:
        href = link.get("href")
        title = link.get_text(strip=True)
        if href:
            results.append({"title": title, "url": href})
    return results


def fetch_page_text(url: str, max_chars: int = 3000) -> str:
    try:
        resp = requests.get(url, headers=HEADERS, timeout=15)
        soup = BeautifulSoup(resp.text, "lxml")
        for tag in soup(["script", "style", "nav", "footer", "header"]):
            tag.decompose()
        text = " ".join(soup.get_text(separator=" ").split())
        return text[:max_chars]
    except Exception:
        return ""


def get_weather(location: str) -> str:
    """Clima actual real (no inventado) via wttr.in, sin necesidad de abrir un navegador."""
    try:
        resp = requests.get(
            f"https://wttr.in/{location}",
            params={"format": "j1", "lang": "es"},
            headers=HEADERS,
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json()
        current = data["current_condition"][0]
        temp_c = current["temp_C"]
        feels_like = current["FeelsLikeC"]
        humidity = current["humidity"]
        desc_list = current.get("lang_es") or current.get("weatherDesc") or []
        desc = desc_list[0]["value"] if desc_list else ""
        return (
            f"En {location} ahora mismo: {temp_c}°C (sensación térmica {feels_like}°C), "
            f"{desc}, humedad {humidity}%."
        )
    except Exception:
        return f"No pude obtener el clima real de '{location}' en este momento. No inventes un valor: decile al usuario que no lo pudiste consultar."

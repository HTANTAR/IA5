"""Control del navegador para el agente de computer-use.
Usa la API sincrona de Playwright, siempre desde un unico hilo dedicado (ThreadPoolExecutor
de 1 worker), porque los objetos de Playwright son afines al hilo que los creo."""
from __future__ import annotations
from concurrent.futures import ThreadPoolExecutor
from playwright.sync_api import sync_playwright

_executor = ThreadPoolExecutor(max_workers=1)
_state: dict = {"playwright": None, "browser": None, "page": None}


def _ensure_page():
    if _state["page"] is None:
        _state["playwright"] = sync_playwright().start()
        _state["browser"] = _state["playwright"].chromium.launch(headless=False, channel="msedge")
        _state["page"] = _state["browser"].new_page()
    return _state["page"]


def _open_url(url: str) -> str:
    page = _ensure_page()
    if not url.startswith("http"):
        url = "https://" + url
    page.goto(url, wait_until="domcontentloaded", timeout=30000)
    return f"Abrí: {page.url}"


def _search_web(query: str) -> str:
    page = _ensure_page()
    page.goto(f"https://duckduckgo.com/html/?q={query}", wait_until="domcontentloaded", timeout=30000)
    return _get_text()


def _search_youtube_and_play(query: str) -> str:
    page = _ensure_page()
    page.goto(f"https://www.youtube.com/results?search_query={query}", wait_until="domcontentloaded", timeout=30000)
    page.wait_for_selector("a#video-title", timeout=15000)
    first = page.query_selector("a#video-title")
    if first is None:
        return "No encontré resultados en YouTube."
    title = (first.get_attribute("title") or first.inner_text() or "").strip()
    first.click()
    page.wait_for_timeout(2500)
    return f"Reproduciendo en YouTube: {title}"


def _click_text(text: str) -> str:
    page = _ensure_page()
    locator = page.get_by_text(text, exact=False).first
    locator.click(timeout=10000)
    return f"Hice click en: {text}"


def _type_text(text: str) -> str:
    page = _ensure_page()
    page.keyboard.type(text)
    return f"Escribí: {text}"


def _press_key(key: str) -> str:
    page = _ensure_page()
    page.keyboard.press(key)
    return f"Tecla presionada: {key}"


def _get_text() -> str:
    page = _ensure_page()
    text = page.inner_text("body")
    return text[:4000]


def _go_back() -> str:
    page = _ensure_page()
    page.go_back()
    return "Volví a la página anterior"


def _current_url() -> str:
    page = _ensure_page()
    return page.url


def _run(fn, *args, **kwargs):
    return _executor.submit(fn, *args, **kwargs).result(timeout=60)


def open_url(url: str) -> str:
    return _run(_open_url, url)


def search_web(query: str) -> str:
    return _run(_search_web, query)


def search_youtube_and_play(query: str) -> str:
    return _run(_search_youtube_and_play, query)


def click_text(text: str) -> str:
    return _run(_click_text, text)


def type_text(text: str) -> str:
    return _run(_type_text, text)


def press_key(key: str) -> str:
    return _run(_press_key, key)


def get_text() -> str:
    return _run(_get_text)


def go_back() -> str:
    return _run(_go_back)


def current_url() -> str:
    return _run(_current_url)

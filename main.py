"""Punto de entrada: levanta el backend local y abre la ventana de la app."""
import threading
import time
import uvicorn
import webview

from gui.app import app

HOST = "127.0.0.1"
PORT = 8731


def run_server():
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")


if __name__ == "__main__":
    server_thread = threading.Thread(target=run_server, daemon=True)
    server_thread.start()
    time.sleep(1)

    webview.create_window("IA Local", f"http://{HOST}:{PORT}", width=1000, height=740, min_size=(700, 500))
    webview.start()

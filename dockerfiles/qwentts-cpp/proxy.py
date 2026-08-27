#!/usr/bin/env python3
"""Proxy that manages tts-server lifecycle and rewrites requests for compatibility."""

import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

BACKEND_PORT = int(os.environ.get("TTS_BACKEND_PORT", "8081"))
BACKEND = f"http://127.0.0.1:{BACKEND_PORT}"
DEFAULT_INSTRUCT = os.environ.get("TTS_DEFAULT_INSTRUCT", "")
IDLE_TIMEOUT = int(os.environ.get("TTS_IDLE_TIMEOUT_SECONDS", "0"))
SUPPORTED_FORMATS = {"pcm", "wav"}

_lock = threading.Lock()
_process = None
_last_activity = 0.0


def _is_running():
    return _process is not None and _process.poll() is None


def _start_backend():
    global _process, _last_activity
    if _is_running():
        return
    print("[proxy] starting tts-server", flush=True)
    env = os.environ.copy()
    env["PORT"] = str(BACKEND_PORT)
    _process = subprocess.Popen(["./entrypoint.sh"], env=env, cwd="/app")
    for _ in range(120):
        try:
            urlopen(f"{BACKEND}/health", timeout=2)
            print("[proxy] tts-server ready", flush=True)
            _last_activity = time.monotonic()
            return
        except (URLError, OSError):
            time.sleep(1)
    print("[proxy] tts-server failed to start", flush=True)


def _stop_backend():
    global _process
    if not _is_running():
        _process = None
        return
    print("[proxy] stopping tts-server (idle timeout)", flush=True)
    proc = _process
    if proc is None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    _process = None
    print("[proxy] tts-server stopped", flush=True)


class ProxyHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            status = "ready" if _is_running() else "idle"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": status}).encode())
            return
        self._start_if_needed()
        self._proxy()

    def do_POST(self):
        global _last_activity
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        if self.path == "/v1/audio/speech" and body:
            data = json.loads(body)
            if data.get("response_format", "wav") not in SUPPORTED_FORMATS:
                data["response_format"] = "wav"
            if DEFAULT_INSTRUCT and "instruct" not in data:
                data["instruct"] = DEFAULT_INSTRUCT
            body = json.dumps(data).encode()

        self._start_if_needed()
        _last_activity = time.monotonic()
        self._proxy(body)

    def _start_if_needed(self):
        with _lock:
            if not _is_running():
                _start_backend()

    def _proxy(self, body=None):
        url = BACKEND + self.path
        headers = {k: v for k, v in self.headers.items() if k.lower() != "host"}
        if body:
            headers["Content-Length"] = str(len(body))

        try:
            req = Request(url, data=body, headers=headers, method=self.command)
            with urlopen(req, timeout=300) as resp:
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() not in ("transfer-encoding",):
                        self.send_header(k, v)
                self.end_headers()
                while chunk := resp.read(8192):
                    self.wfile.write(chunk)
        except HTTPError as e:
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(e.read())
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[proxy] {fmt % args}\n")


def _idle_watchdog():
    while True:
        time.sleep(30)
        if not _is_running():
            continue
        idle = time.monotonic() - _last_activity
        if idle >= IDLE_TIMEOUT:
            with _lock:
                _stop_backend()


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    port = int(os.environ.get("PROXY_PORT", "8080"))
    lazy = os.environ.get("TTS_LAZY_LOAD", "true").lower() == "true"

    if not lazy:
        _start_backend()

    if IDLE_TIMEOUT > 0:
        threading.Thread(target=_idle_watchdog, daemon=True).start()
        print(f"[proxy] idle timeout: {IDLE_TIMEOUT}s", flush=True)

    server = ThreadedHTTPServer(("0.0.0.0", port), ProxyHandler)
    print(f"[proxy] listening on 0.0.0.0:{port}, lazy_load={lazy}", flush=True)

    def _shutdown(sig, frame):
        _stop_backend()
        sys.exit(0)
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    server.serve_forever()

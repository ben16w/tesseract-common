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
DEFAULT_INSTRUCT = os.environ.get("TTS_DEFAULT_INSTRUCTIONS", "")
IDLE_TIMEOUT = int(os.environ.get("TTS_IDLE_TIMEOUT_SECONDS", "0"))
MAX_NEW_TOKENS = int(os.environ.get("TTS_MAX_NEW_TOKENS", "4096"))

CONTENT_TYPES = {
    "wav": "audio/wav",
    "mp3": "audio/mpeg",
    "opus": "audio/opus",
    "aac": "audio/aac",
    "flac": "audio/flac",
    "pcm": "audio/pcm",
}
FFMPEG_ARGS = {
    "mp3": ["-f", "mp3", "-codec:a", "libmp3lame", "-q:a", "2"],
    "opus": ["-f", "opus", "-codec:a", "libopus"],
    "aac": ["-f", "adts", "-codec:a", "aac"],
    "flac": ["-f", "flac", "-codec:a", "flac"],
}


def _log(msg):
    sys.stderr.write(f"[proxy] {msg}\n")
    sys.stderr.flush()


def _convert_audio(wav_data: bytes, fmt: str) -> bytes:
    """Convert WAV to the requested format using ffmpeg."""
    if fmt in ("wav", "pcm"):
        return wav_data
    args = FFMPEG_ARGS.get(fmt)
    if not args:
        return wav_data
    proc = subprocess.run(
        ["ffmpeg", "-i", "pipe:0", "-y"] + args + ["pipe:1"],
        input=wav_data, capture_output=True,
    )
    if proc.returncode != 0:
        _log(f"ffmpeg error: {proc.stderr.decode()[:200]}")
        raise RuntimeError(f"ffmpeg failed: {proc.stderr.decode()[:200]}")
    _log(f"converted wav ({len(wav_data)} bytes) -> {fmt} ({len(proc.stdout)} bytes)")
    return proc.stdout

_lock = threading.Lock()
_process = None
_last_activity = 0.0
_active_requests = 0


def _is_running():
    return _process is not None and _process.poll() is None


def _start_backend():
    global _process, _last_activity
    if _is_running():
        return
    _log("starting tts-server")
    env = os.environ.copy()
    env["PORT"] = str(BACKEND_PORT)
    _process = subprocess.Popen(
        ["./entrypoint.sh"], env=env, cwd="/app",
        start_new_session=True,
    )
    for _ in range(120):
        try:
            urlopen(f"{BACKEND}/health", timeout=2)
            _log("tts-server ready")
            _last_activity = time.monotonic()
            return
        except (URLError, OSError):
            time.sleep(1)
    _log("tts-server failed to start")


def _stop_backend():
    global _process
    if not _is_running():
        _process = None
        return
    _log("stopping tts-server (idle timeout)")
    proc = _process
    if proc is None:
        return
    pgid = os.getpgid(proc.pid)
    os.killpg(pgid, signal.SIGTERM)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(pgid, signal.SIGKILL)
        proc.wait()
    _process = None
    _log("tts-server stopped")


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
        global _last_activity, _active_requests
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        if self.path == "/v1/audio/speech" and body:
            data = json.loads(body)
            requested_format = data.get("response_format", "wav")
            is_streaming = data.get("stream", False)
            voice = data.get("voice", "?")
            text_len = len(data.get("input", ""))
            _log(f"speech request: voice={voice} format={requested_format} text={text_len} chars stream={is_streaming}")
            if is_streaming:
                # Streaming only supports pcm passthrough
                data["response_format"] = "pcm"
                requested_format = None
            else:
                data["response_format"] = "wav"
            if DEFAULT_INSTRUCT and "instructions" not in data:
                data["instructions"] = DEFAULT_INSTRUCT
            if "max_new_tokens" not in data:
                data["max_new_tokens"] = MAX_NEW_TOKENS
            body = json.dumps(data).encode()
        else:
            requested_format = None

        self._start_if_needed()
        _active_requests += 1
        try:
            if requested_format and requested_format != "wav":
                self._proxy_and_convert(body, requested_format)
            else:
                self._proxy(body)
        finally:
            _active_requests -= 1
            _last_activity = time.monotonic()

    def _start_if_needed(self):
        with _lock:
            if not _is_running():
                _start_backend()

    def _proxy_and_convert(self, body, fmt):
        """Fetch WAV from backend, convert to requested format, send to client."""
        url = BACKEND + self.path
        headers = {k: v for k, v in self.headers.items() if k.lower() != "host"}
        if body:
            headers["Content-Length"] = str(len(body))
        try:
            req = Request(url, data=body, headers=headers, method=self.command)
            with urlopen(req, timeout=300) as resp:
                wav_data = resp.read()
            converted = _convert_audio(wav_data, fmt)
            content_type = CONTENT_TYPES.get(fmt, "application/octet-stream")
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(converted)))
            self.end_headers()
            self.wfile.write(converted)
        except HTTPError as e:
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(e.read())
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(e).encode())

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
        _log(fmt % args)


def _idle_watchdog():
    while True:
        time.sleep(30)
        if not _is_running() or _active_requests > 0:
            continue
        idle = time.monotonic() - _last_activity
        if idle >= IDLE_TIMEOUT:
            with _lock:
                if _active_requests > 0:
                    continue
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
        _log(f"idle timeout: {IDLE_TIMEOUT}s")

    server = ThreadedHTTPServer(("0.0.0.0", port), ProxyHandler)
    _log(f"listening on 0.0.0.0:{port}, lazy_load={lazy}")

    def _shutdown(sig, frame):
        _stop_backend()
        sys.exit(0)
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    server.serve_forever()

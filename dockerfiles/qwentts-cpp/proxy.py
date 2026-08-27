#!/usr/bin/env python3
"""Proxy that sits in front of tts-server, rewriting requests for compatibility."""

import json
import os
import subprocess
import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import HTTPError

BACKEND = os.environ.get("TTS_BACKEND_URL", "http://127.0.0.1:8081")
DEFAULT_INSTRUCT = os.environ.get("TTS_DEFAULT_INSTRUCT", "")
SUPPORTED_FORMATS = {"pcm", "wav"}


class ProxyHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self._proxy()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        if self.path == "/v1/audio/speech" and body:
            data = json.loads(body)
            if data.get("response_format", "wav") not in SUPPORTED_FORMATS:
                data["response_format"] = "wav"
            if DEFAULT_INSTRUCT and "instruct" not in data:
                data["instruct"] = DEFAULT_INSTRUCT
            body = json.dumps(data).encode()

        self._proxy(body)

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


if __name__ == "__main__":
    port = int(os.environ.get("PROXY_PORT", "8080"))
    server = HTTPServer(("0.0.0.0", port), ProxyHandler)
    print(f"[proxy] listening on 0.0.0.0:{port}, backend={BACKEND}", flush=True)
    server.serve_forever()

#!/usr/bin/env python3
"""Checks scripts/send_test_webhook.py against a local server.

Swift tests cover payload encoding, branch names, opt-in, retries, PR matching,
and the .screenclip merge guard. This script only checks the webhook helper.
"""
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "send_test_webhook.py"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self.server.requests.append((self.headers.get("Authorization"), self.headers.get("Content-Type"), body))
        status = self.server.status
        payload = b"accepted" if status < 300 else b"rejected"
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        return


def run(url, authorization, include_authorization=True):
    env = os.environ.copy()
    env.pop("SCREENCLIP_WEBHOOK_URL", None)
    env.pop("SCREENCLIP_AUTHORIZATION", None)
    if url is not None:
        env["SCREENCLIP_WEBHOOK_URL"] = url
    if include_authorization:
        env["SCREENCLIP_AUTHORIZATION"] = authorization
    return subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.requests = []
    server.status = 204
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_address[1]}/hook"
    try:
        missing = run(None, "", include_authorization=False)
        assert missing.returncode == 2, missing.stderr
        assert "SCREENCLIP_WEBHOOK_URL" in missing.stderr

        ok = run(url, "Bearer custom value")
        assert ok.returncode == 0, ok.stdout + ok.stderr
        assert "HTTP 204" in ok.stdout
        authorization, content_type, body = server.requests[-1]
        assert authorization == "Bearer custom value"
        assert content_type.startswith("application/json")
        assert json.loads(body) == {"schema": "screenclip.external.v1.test"}

        server.status = 401
        denied = run(url, "Token raw")
        assert denied.returncode == 1, denied.stdout
        assert "HTTP 401" in denied.stdout
        assert "rejected" in denied.stdout
        assert server.requests[-1][0] == "Token raw"
    finally:
        server.shutdown()
    print("external assistant webhook script tests passed")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Read-only Codex handshake probe. Never prints credentials or account identity."""
import argparse
import json
import selectors
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--codex", required=True)
args = parser.parse_args()
process = subprocess.Popen([args.codex, "app-server", "--listen", "stdio://"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)

def request(number, method, params):
    process.stdin.write(json.dumps({"id": number, "method": method, "params": params}) + "\n")
    process.stdin.flush()
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if not selector.select(timeout=0.5):
            if process.poll() is not None:
                raise RuntimeError(f"Codex exited with {process.returncode}")
            continue
        line = process.stdout.readline()
        if not line:
            raise RuntimeError("Codex closed stdout")
        message = json.loads(line)
        if message.get("id") == number:
            if "error" in message:
                raise RuntimeError(message["error"].get("message", "RPC error"))
            return message.get("result", {})
    raise TimeoutError(f"Timed out during {method}")

try:
    result = request(1, "initialize", {"clientInfo": {"name": "screenclip_probe", "title": "ScreenClip Probe", "version": "0.1.0"}})
    print("initialize: OK")
    process.stdin.write(json.dumps({"method": "initialized", "params": {}}) + "\n")
    process.stdin.flush()
    account = request(2, "account/read", {"refreshToken": False})
    print("account: " + str((account.get("account") or {}).get("type", "signed out")))
    models = request(3, "model/list", {})
    print("models: " + ", ".join(str(m.get("id")) for m in models.get("data", [])[:8]))
finally:
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
    selector.close()

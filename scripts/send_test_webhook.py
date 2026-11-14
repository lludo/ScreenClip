#!/usr/bin/env python3
"""POST a screenclip.external.v1.test payload.

The assistant panel gives a ready-made Authorization header value. This script
sends that value verbatim and does not add a scheme such as "Bearer".

Environment:
  SCREENCLIP_WEBHOOK_URL     webhook URL
  SCREENCLIP_AUTHORIZATION   full Authorization header value
"""
import json
import os
import sys
import urllib.error
import urllib.request

SCHEMA = "screenclip.external.v1.test"


def main() -> int:
    url = os.environ.get("SCREENCLIP_WEBHOOK_URL", "").strip()
    # Keep internal spaces. Only a surrounding newline from the environment is removed.
    authorization = os.environ.get("SCREENCLIP_AUTHORIZATION", "").strip()
    if not url:
        print("Set SCREENCLIP_WEBHOOK_URL.", file=sys.stderr)
        return 2
    body = json.dumps({"schema": SCHEMA}, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(url, data=body, method="POST")
    request.add_header("Content-Type", "application/json")
    if authorization:
        request.add_header("Authorization", authorization)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read().decode("utf-8", "replace")
            print(f"HTTP {response.status}")
            if payload:
                print(payload[:2000])
            return 0 if 200 <= response.status < 300 else 1
    except urllib.error.HTTPError as error:
        payload = error.read().decode("utf-8", "replace")
        print(f"HTTP {error.code}")
        if payload:
            print(payload[:2000])
        return 1
    except urllib.error.URLError as error:
        print(f"Could not reach the webhook. {error.reason}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import os
import sys
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location("screenclip_plugin", Path(__file__).resolve().parents[1] / "plugins/screenclip/server.py")
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)

class PluginTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        plugin.ROOT = Path(self.directory.name).resolve()
        (plugin.ROOT / "assets").mkdir()
        self.id = str(uuid.uuid4())
        self.asset = plugin.ROOT / "assets/approved.png"
        self.asset.write_bytes(b"approved")
        self.issue = {"id": self.id, "title": "Test", "status": "needsYou", "captures": [{"id": "capture", "note": "test", "context": {}, "imagePath": str(self.asset), "originalPath": "/private/original.png"}]}
        self.save()
    def save(self):
        with sqlite3.connect(plugin.ROOT / "screenclip.sqlite") as db:
            db.execute("CREATE TABLE IF NOT EXISTS state(id INTEGER PRIMARY KEY,payload BLOB)")
            db.execute("INSERT OR REPLACE INTO state VALUES(1,?)", (json.dumps({"issues": [self.issue], "projects": [], "settings": {"secret": "not for plugins"}}).encode(),))
    def test_approved_only(self):
        result = plugin.call("get_issue", {"issue_id": self.id, "include_images": True})
        self.assertEqual(result["content"][1]["data"], "YXBwcm92ZWQ=")
        self.assertNotIn("original", result["content"][0]["text"])
        self.assertNotIn("secret", result["content"][0]["text"])
    def test_refuses_outside_asset_path(self):
        self.issue["captures"][0]["imagePath"] = str(plugin.ROOT / "screenclip.sqlite")
        self.save()
        with self.assertRaises(ValueError):
            plugin.call("get_issue", {"issue_id": self.id, "include_images": True})
    def test_filter_and_unknown_issue(self):
        self.assertEqual(json.loads(plugin.call("list_issues", {"status": "merged"})["content"][0]["text"]), [])
        with self.assertRaises(ValueError):
            plugin.call("get_issue", {"issue_id": str(uuid.uuid4())})
    def test_stdio_handshake_and_tool_discovery(self):
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_issue", "arguments": {"issue_id": self.id}}}
        ]
        result = subprocess.run([sys.executable, spec.origin], input="\n".join(map(json.dumps, requests))+"\n", capture_output=True, text=True, check=True, env={**os.environ, "SCREENCLIP_DATA_DIR": str(plugin.ROOT)})
        messages = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(messages), 3)
        self.assertEqual(messages[0]["result"]["serverInfo"]["name"], "screenclip")
        self.assertEqual(len(messages[1]["result"]["tools"]), 2)
        self.assertEqual(json.loads(messages[2]["result"]["content"][0]["text"])["id"], self.id)

if __name__ == "__main__":
    unittest.main()

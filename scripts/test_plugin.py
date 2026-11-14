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
    def test_report_number_lookup_and_listing(self):
        self.issue["reportNumber"] = 234
        self.issue["archived"] = True
        self.save()
        for reference in ["#234", "234", " #234 "]:
            found = json.loads(plugin.call("get_issue", {"issue_id": reference})["content"][0]["text"])
            self.assertEqual(found["id"], self.id)
            self.assertEqual(found["reportNumber"], 234)
        with self.assertRaises(ValueError):
            plugin.call("get_issue", {"issue_id": "#23"})
        self.issue["archived"] = False
        self.save()
        listed = json.loads(plugin.call("list_issues", {})["content"][0]["text"])
        self.assertEqual(listed[0]["reportNumber"], 234)
    def test_agent_defaults_to_codex_for_older_issues(self):
        listed = json.loads(plugin.call("list_issues", {})["content"][0]["text"])
        self.assertEqual(listed[0]["agent"], "codex")
        self.issue["agent"] = "claude"
        self.save()
        found = json.loads(plugin.call("get_issue", {"issue_id": self.id})["content"][0]["text"])
        self.assertEqual(found["agent"], "claude")
    def test_text_only_context_is_returned_with_legacy_default(self):
        found = json.loads(plugin.call("get_issue", {"issue_id": self.id})["content"][0]["text"])
        self.assertEqual(found["contextNotes"], [])
        notes = [{"id": "note", "date": 123, "text": "Details added after filing"}]
        self.issue["contextNotes"] = notes
        self.save()
        found = json.loads(plugin.call("get_issue", {"issue_id": self.id})["content"][0]["text"])
        self.assertEqual(found["contextNotes"], notes)
    def test_claude_code_plugin_manifests(self):
        root = Path(__file__).resolve().parents[1]
        manifest = json.loads((root / "plugins/screenclip/.claude-plugin/plugin.json").read_text())
        self.assertEqual(manifest["name"], "screenclip")
        servers = json.loads((root / "plugins/screenclip/.mcp.json").read_text())["mcpServers"]
        self.assertEqual(servers["screenclip"]["args"], ["${CLAUDE_PLUGIN_ROOT}/server.py"])
        market = json.loads((root / ".claude-plugin/marketplace.json").read_text())
        self.assertEqual(market["plugins"][0]["source"], "./plugins/screenclip")
        self.assertTrue((root / "plugins/screenclip/skills/fix-report/SKILL.md").is_file())
    def test_invalid_arguments_return_errors_instead_of_crashing(self):
        with self.assertRaises(plugin.InvalidParams):
            plugin.call("get_issue", {"issue_id": 5})
        with self.assertRaises(plugin.InvalidParams):
            plugin.call("get_issue", "not an object")
        with self.assertRaises(plugin.InvalidParams):
            plugin.call("get_issue", {"issue_id": "not-a-uuid"})
        self.issue["captures"] = None
        self.save()
        found = json.loads(plugin.call("get_issue", {"issue_id": self.id})["content"][0]["text"])
        self.assertEqual(found["captures"], [])
    def test_malformed_requests_get_a_response(self):
        requests = [
            '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": null}',
            '{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "get_issue", "arguments": {"issue_id": 5}}}',
            '{"jsonrpc": "2.0", "id": 3, "method": "initialize", "params": {"protocolVersion": "2099-01-01"}}',
            'not json',
            '{"jsonrpc": "2.0", "id": 4, "method": "nope"}',
        ]
        result = subprocess.run([sys.executable, spec.origin], input="\n".join(requests)+"\n", capture_output=True, text=True, check=True, env={**os.environ, "SCREENCLIP_DATA_DIR": str(plugin.ROOT)})
        messages = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([m.get("id") for m in messages], [1, 2, 3, None, 4])
        self.assertEqual(messages[0]["error"]["code"], -32602)
        self.assertEqual(messages[1]["error"]["code"], -32602)
        self.assertEqual(messages[2]["result"]["protocolVersion"], "2024-11-05")
        self.assertEqual(messages[3]["error"]["code"], -32700)
        self.assertEqual(messages[4]["error"]["code"], -32601)
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

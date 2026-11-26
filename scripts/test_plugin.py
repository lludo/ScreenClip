#!/usr/bin/env python3
import importlib.util
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sqlite3
import subprocess
import os
import sys
import tempfile
import threading
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
    def test_diagnostics_are_listed_and_returned_only_when_asked(self):
        folder = plugin.ROOT / "diagnostics/abc"
        folder.mkdir(parents=True)
        (folder / "logs.txt").write_text("12:00 info [app] tapped checkout")
        self.issue["captures"][0]["diagnostics"] = {"folder": str(folder), "files": [{"name": "logs.txt", "summary": "1 line", "bytes": 32}, {"name": "../../screenclip.sqlite", "summary": "x", "bytes": 1}]}
        self.save()
        plain = plugin.call("get_issue", {"issue_id": self.id})["content"]
        self.assertEqual(len(plain), 1)
        listed = json.loads(plain[0]["text"])["captures"][0]["diagnostics"]
        self.assertEqual(listed[0], {"name": "logs.txt", "summary": "1 line", "bytes": 32})
        self.assertNotIn(str(folder), plain[0]["text"])
        full = plugin.call("get_issue", {"issue_id": self.id, "include_diagnostics": True})["content"]
        self.assertEqual(len(full), 2)
        self.assertIn("tapped checkout", full[1]["text"])
        self.issue["captures"][0]["diagnostics"]["folder"] = str(plugin.ROOT / "assets")
        self.save()
        with self.assertRaises(ValueError):
            plugin.call("get_issue", {"issue_id": self.id, "include_diagnostics": True})
    def test_text_capture_with_images_requested(self):
        self.issue["captures"].insert(0, {"id": "note", "note": "Text only", "context": {}})
        self.save()
        content = plugin.call("get_issue", {"issue_id": self.id, "include_images": True})["content"]
        self.assertEqual([item["type"] for item in content], ["text", "image"])
        self.assertEqual(json.loads(content[0]["text"])["captures"][0]["note"], "Text only")
    def test_images_require_an_explicit_boolean(self):
        for value in ["false", "true", 0, 1, [], {}, None]:
            with self.subTest(value=value), self.assertRaises(plugin.InvalidParams):
                plugin.call("get_issue", {"issue_id": self.id, "include_images": value})
        for arguments in [{"issue_id": self.id}, {"issue_id": self.id, "include_images": False}]:
            result = plugin.call("get_issue", arguments)
            self.assertTrue(all(item["type"] == "text" for item in result["content"]))
    def test_empty_mistyped_arguments_are_not_silently_replaced(self):
        for arguments in [False, 0, "", [], None]:
            with self.subTest(arguments=arguments), self.assertRaises(plugin.InvalidParams):
                plugin.handle({"method": "tools/call", "params": {"name": "list_issues", "arguments": arguments}})
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
    def test_listing_hides_finished_reports_and_is_limited(self):
        self.issue["status"] = "merged"
        self.save()
        self.assertEqual(json.loads(plugin.call("list_issues", {})["content"][0]["text"]), [])
        self.assertEqual(len(json.loads(plugin.call("list_issues", {"include_closed": True})["content"][0]["text"])), 1)
        self.assertEqual(len(json.loads(plugin.call("list_issues", {"status": "merged"})["content"][0]["text"])), 1)
        base = dict(self.issue)
        issues = [base | {"id": str(uuid.uuid4()), "status": "needsYou", "updatedAt": n} for n in range(5)]
        with sqlite3.connect(plugin.ROOT / "screenclip.sqlite") as db:
            db.execute("INSERT OR REPLACE INTO state VALUES(1,?)", (json.dumps({"issues": issues, "projects": []}).encode(),))
        result = plugin.call("list_issues", {"limit": 2})
        listed = json.loads(result["content"][0]["text"])
        self.assertEqual([i["id"] for i in listed], [issues[4]["id"], issues[3]["id"]])
        self.assertIn("Showing 2 of 5", result["content"][1]["text"])
        with self.assertRaises(plugin.InvalidParams):
            plugin.call("list_issues", {"limit": 0})
    def test_issue_returns_recent_activity_only(self):
        self.issue["activities"] = [{"text": f"step {n}"} for n in range(30)]
        self.save()
        found = json.loads(plugin.call("get_issue", {"issue_id": self.id})["content"][0]["text"])
        self.assertEqual(found["activityCount"], 30)
        self.assertEqual([a["text"] for a in found["activities"]], [f"step {n}" for n in range(10, 30)])
        found = json.loads(plugin.call("get_issue", {"issue_id": self.id, "activity_limit": 0})["content"][0]["text"])
        self.assertEqual(found["activities"], [])
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
    def save_state(self, projects, issues):
        with sqlite3.connect(plugin.ROOT / "screenclip.sqlite") as db:
            db.execute("INSERT OR REPLACE INTO state VALUES(1,?)", (json.dumps({"issues": issues, "projects": projects}).encode(),))
    def make_projects(self):
        self.app_repo = plugin.ROOT / "repos/App"
        (self.app_repo / ".git/worktrees/feature").mkdir(parents=True)
        (self.app_repo / "Sources").mkdir()
        (self.app_repo / ".git/worktrees/feature/commondir").write_text("../..\n")
        self.linked = plugin.ROOT / "repos/App-feature"
        self.linked.mkdir()
        (self.linked / ".git").write_text(f"gitdir: {self.app_repo}/.git/worktrees/feature\n")
        self.own_worktree = plugin.ROOT / "worktrees/abc"
        (self.own_worktree / "Sources").mkdir(parents=True)
        app, site = str(uuid.uuid4()), str(uuid.uuid4())
        projects = [{"id": app, "name": "App", "path": str(self.app_repo)}, {"id": site, "name": "Site", "path": str(plugin.ROOT / "repos/Site")}]
        def issue(n, status, project, **extra):
            return {"id": str(uuid.uuid4()), "reportNumber": n, "title": f"Report {n}", "status": status, "projectID": project, "updatedAt": n} | extra
        issues = [issue(1, "queued", app), issue(2, "working", app, worktreePath=str(self.own_worktree)), issue(3, "needsYou", app), issue(4, "failed", site),
                  issue(5, "merged", app), issue(6, "draft", None), issue(7, "needsYou", app, archived=True)]
        self.save_state(projects, issues)
    def test_task_summary_groups_statuses_per_project(self):
        self.make_projects()
        summary = json.loads(plugin.call("task_summary", {"project": "app"})["content"][0]["text"])
        self.assertEqual(summary["project"], "App")
        self.assertEqual(summary["counts"], {"open": 1, "in_progress": 1, "blocked": 1, "done": 1})
        self.assertEqual([b["reportNumber"] for b in summary["blocked"]], [3])
        everything = json.loads(plugin.call("task_summary", {})["content"][0]["text"])
        self.assertEqual(everything["counts"], {"open": 2, "in_progress": 1, "blocked": 2, "done": 1})
        self.assertEqual([(b["reportNumber"], b["project"]) for b in everything["blocked"]], [(4, "Site"), (3, "App")])
    def test_project_matches_repository_worktrees_and_subfolders(self):
        self.make_projects()
        for path in [self.app_repo, self.app_repo / "Sources", self.linked, self.own_worktree / "Sources"]:
            with self.subTest(path=path):
                summary = json.loads(plugin.call("task_summary", {"project": str(path)})["content"][0]["text"])
                self.assertEqual(summary["project"], "App")
        with self.assertRaisesRegex(ValueError, "No ScreenClip project matches"):
            plugin.call("task_summary", {"project": str(plugin.ROOT / "elsewhere")})
        with self.assertRaisesRegex(ValueError, "Known projects: App, Site"):
            plugin.call("list_issues", {"project": "Nope"})
        result = plugin.handle({"method": "tools/call", "params": {"name": "list_issues", "arguments": {"project": "Nope"}}})
        self.assertTrue(result["isError"])
        with self.assertRaises(plugin.InvalidParams):
            plugin.call("list_issues", {"project": ""})
    def test_list_issues_by_group_and_project(self):
        self.make_projects()
        def numbers(arguments):
            return [i["reportNumber"] for i in json.loads(plugin.call("list_issues", arguments)["content"][0]["text"])]
        self.assertEqual(numbers({"status": "blocked"}), [4, 3])
        self.assertEqual(numbers({"status": "blocked", "project": "App"}), [3])
        self.assertEqual(numbers({"status": "in_progress", "project": "App"}), [2])
        self.assertEqual(numbers({"status": "done"}), [5])
        self.assertEqual(numbers({"status": "queued"}), [1])
        self.assertEqual(numbers({"project": "App"}), [3, 2, 1])
        listed = json.loads(plugin.call("list_issues", {"status": "failed"})["content"][0]["text"])
        self.assertEqual((listed[0]["project"], listed[0]["group"]), ("Site", "blocked"))
        with self.assertRaises(plugin.InvalidParams):
            plugin.call("list_issues", {"status": "stuck"})
    def test_list_projects_counts(self):
        self.make_projects()
        result = json.loads(plugin.call("list_projects", {})["content"][0]["text"])
        self.assertEqual([(p["name"], p["counts"]["blocked"]) for p in result["projects"]], [("App", 1), ("Site", 1)])
        self.assertEqual(result["withoutProject"]["open"], 1)
    def test_nested_project_and_relative_paths(self):
        outer, inner = plugin.ROOT / "repos/Mono", plugin.ROOT / "repos/Mono/website"
        (inner / "src").mkdir(parents=True)
        (outer / ".git").mkdir()
        projects = [{"id": "outer", "name": "Mono", "path": str(outer)}, {"id": "inner", "name": "Web", "path": str(inner)}, {"id": "blank", "name": "Blank", "path": ""}]
        self.save_state(projects, [])
        def project(reference):
            return json.loads(plugin.call("task_summary", {"project": reference})["content"][0]["text"])["project"]
        self.assertEqual(project(str(inner / "src")), "Web")
        self.assertEqual(project(str(outer)), "Mono")
        cwd = os.getcwd()
        self.addCleanup(os.chdir, cwd)
        os.chdir(inner / "src")
        self.assertEqual(project("."), "Web")
        self.assertEqual(project("../.."), "Mono")
    def test_new_statuses_and_blocked_cap(self):
        issues = [{"id": str(uuid.uuid4()), "reportNumber": n, "title": "t", "status": "needsYou", "updatedAt": n} for n in range(25)]
        issues.append({"id": str(uuid.uuid4()), "reportNumber": 99, "title": "t", "status": "paused", "updatedAt": 99})
        self.save_state([], issues)
        summary = json.loads(plugin.call("task_summary", {})["content"][0]["text"])
        self.assertEqual(summary["counts"]["other"], 1)
        self.assertEqual(sum(summary["counts"].values()), 26)
        self.assertEqual(len(summary["blocked"]), 20)
        self.assertIn("20 of 25", summary["note"])
        listed = json.loads(plugin.call("list_issues", {"status": "paused"})["content"][0]["text"])
        self.assertEqual([i["reportNumber"] for i in listed], [99])
    def proposal_files(self):
        folder = plugin.ROOT / "proposals"
        return sorted(folder.glob("*.json")) if folder.is_dir() else []
    def test_close_issue_writes_a_close_request_with_evidence(self):
        self.issue["reportNumber"] = 12
        self.save()
        database = (plugin.ROOT / "screenclip.sqlite").read_bytes()
        with self.assertRaises(plugin.InvalidParams):
            plugin.call("close_issue", {"issue_id": "#12", "summary": "Fixed it."})
        with self.assertRaises(plugin.InvalidParams):
            plugin.call("close_issue", {"issue_id": "#12", "summary": "Fixed.", "commit": "nothex!"})
        with self.assertRaises(plugin.InvalidParams):
            plugin.call("close_issue", {"issue_id": "#99", "summary": "Fixed.", "commit": "abcdef1"})
        result = json.loads(plugin.call("close_issue", {"issue_id": "#12", "summary": "Landed in my own PR.", "pull_request": "https://github.com/o/r/pull/7"})["content"][0]["text"])
        self.assertEqual(result["status"], "closing")
        self.assertEqual((plugin.ROOT / "screenclip.sqlite").read_bytes(), database)
        files = list((plugin.ROOT / "closures").glob("*.json"))
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
        request = json.loads(files[0].read_text())
        self.assertEqual((request["issueID"], request["resolution"], request["pullRequest"]), (self.id, "done", "https://github.com/o/r/pull/7"))
        canceled = json.loads(plugin.call("close_issue", {"issue_id": self.id, "resolution": "canceled", "summary": "Duplicate of #11."})["content"][0]["text"])
        self.assertEqual(canceled["resolution"], "canceled")
        self.issue["status"] = "merged"
        self.save()
        unchanged = json.loads(plugin.call("close_issue", {"issue_id": "#12", "summary": "Again.", "commit": "abcdef1"})["content"][0]["text"])
        self.assertEqual(unchanged["status"], "unchanged")
    def test_proposing_settings_writes_only_a_proposal_file(self):
        repo = plugin.ROOT / "repos/App"
        (repo / ".git").mkdir(parents=True)
        project_id = str(uuid.uuid4()).upper()
        self.save_state([{"id": project_id, "name": "App", "path": str(repo), "baseBranch": "main", "validationCommand": ""}], [])
        database = (plugin.ROOT / "screenclip.sqlite").read_bytes()
        plugin.CLIENT["name"] = "claude-code"
        self.addCleanup(plugin.CLIENT.update, {"name": None})
        result = json.loads(plugin.call("propose_project_settings", {"project": str(repo), "validation_command": "  make test  ", "reason": "Runs the tests."})["content"][0]["text"])
        self.assertEqual(result["status"], "pending")
        self.assertEqual((plugin.ROOT / "screenclip.sqlite").read_bytes(), database)
        files = self.proposal_files()
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
        proposal = json.loads(files[0].read_text())
        self.assertEqual(files[0].stem, proposal["id"])
        self.assertEqual((proposal["projectID"], proposal["changes"], proposal["reason"], proposal["proposer"]), (project_id, {"validationCommand": "make test"}, "Runs the tests.", "claude-code"))
        listed = json.loads(plugin.call("list_projects", {})["content"][0]["text"])["projects"][0]
        self.assertEqual((listed["hasValidationCommand"], listed["settingsProposalPending"]), (False, True))
        # Projects saved before the screenshot setting commit screenshots.
        self.assertTrue(listed["commitsScreenshots"])
        self.assertNotIn("validationCommand", listed)
        # A newer proposal for the same project replaces the waiting one.
        plugin.call("propose_project_settings", {"project": "App", "validation_command": "make check", "base_branch": "develop"})
        files = self.proposal_files()
        self.assertEqual(len(files), 1)
        self.assertEqual(json.loads(files[0].read_text())["changes"], {"validationCommand": "make check", "baseBranch": "develop"})
    def test_overlapping_proposals_leave_one_decision_for_the_tester(self):
        self.make_projects()
        start = threading.Barrier(8)
        def send(index):
            start.wait(timeout=5)
            result = plugin.call("propose_project_settings", {"project": "App", "validation_command": f"make check-{index}"})
            return json.loads(result["content"][0]["text"])["proposalID"]
        with ThreadPoolExecutor(max_workers=8) as writers:
            ids = list(writers.map(send, range(8)))
        files = self.proposal_files()
        self.assertEqual(len(files), 1)
        self.assertIn(files[0].stem, ids)

    def test_invalid_git_branch_names_are_refused(self):
        self.make_projects()
        for branch in ["-main", "topic/.hidden", "topic.lock/wip", "HEAD"]:
            with self.subTest(branch=branch), self.assertRaises(plugin.InvalidParams):
                plugin.call("propose_project_settings", {"project": "App", "base_branch": branch})
        self.assertEqual(self.proposal_files(), [])

    def test_proposals_that_change_nothing_or_are_invalid_are_refused(self):
        self.save_state([{"id": "p", "name": "App", "path": "/nowhere", "baseBranch": "main", "validationCommand": "make test"}], [])
        unchanged = json.loads(plugin.call("propose_project_settings", {"project": "App", "validation_command": "make test"})["content"][0]["text"])
        self.assertEqual(unchanged["status"], "unchanged")
        for arguments in [{"project": "App"}, {"project": "App", "validation_command": "   "}, {"project": "App", "validation_command": 5}, {"project": "App", "validation_command": "x" * 4001}, {"project": "App", "base_branch": "bad branch"}, {"project": "App", "base_branch": "../main"}, {"project": "App", "validation_command": "a\x00b"}, {"validation_command": "make"}]:
            with self.subTest(arguments=arguments), self.assertRaises(plugin.InvalidParams):
                plugin.call("propose_project_settings", arguments)
        with self.assertRaises(ValueError):
            plugin.call("propose_project_settings", {"project": "Unknown", "validation_command": "make"})
        self.assertEqual(self.proposal_files(), [])
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
        self.assertEqual({t["name"] for t in messages[1]["result"]["tools"]}, {"task_summary", "list_issues", "get_issue", "list_projects", "propose_project_settings", "close_issue"})
        tools = {t["name"]: t for t in messages[1]["result"]["tools"]}
        self.assertFalse(tools["propose_project_settings"]["annotations"]["readOnlyHint"])
        self.assertTrue(all(t["annotations"]["readOnlyHint"] for name, t in tools.items() if name not in {"propose_project_settings", "close_issue"}))
        self.assertFalse(tools["close_issue"]["annotations"]["readOnlyHint"])
        self.assertEqual(json.loads(messages[2]["result"]["content"][0]["text"])["id"], self.id)

if __name__ == "__main__":
    unittest.main()

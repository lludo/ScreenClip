#!/usr/bin/env python3
"""Regressions for the read-only local queue review command."""
import argparse
import contextlib
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import review_queue


class QueueReviewTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.args = argparse.Namespace(
            project=None, include_archived=False, search=None, status=None,
            check_worktrees=False, data_dir=self.root)
        self.state = {"projects": [], "issues": [
            {"id": "one", "reportNumber": 23, "title": "First", "status": "verified"},
            {"id": "two", "reportNumber": 234, "title": "Second", "status": "merged"},
            {"id": "three", "title": "Third", "status": "working", "archived": True},
        ]}

    def test_snapshot_does_not_change_database(self):
        database = self.root / "screenclip.sqlite"
        with sqlite3.connect(database) as connection:
            connection.execute("CREATE TABLE state (id INTEGER, payload BLOB)")
            connection.execute("INSERT INTO state VALUES (1, ?)", (json.dumps(self.state).encode(),))
        before = database.read_bytes()
        self.assertEqual(review_queue.snapshot(self.root), self.state)
        self.assertEqual(database.read_bytes(), before)
        self.assertEqual(list(self.root.iterdir()), [database])

    def test_archive_candidates_require_a_finished_status(self):
        self.args.include_archived = True
        result = review_queue.review(self.state, self.args)
        self.assertEqual(result["archiveCandidates"], ["one"])
        self.assertEqual(result["archivedCount"], 1)
        self.assertFalse(result["reports"][1]["archiveCandidate"])

    def test_report_number_search_is_exact_with_or_without_hash(self):
        for query in ("23", "#23", " #23 "):
            self.args.search = query
            reports = review_queue.review(self.state, self.args)["reports"]
            self.assertEqual([report["id"] for report in reports], ["one"])

    def test_text_only_context_is_searchable_and_visible_in_details(self):
        self.state["issues"][0]["contextNotes"] = [
            {"text": "Details added after filing", "date": 123, "id": "note"}]
        self.args.search = "AFTER FILING"
        result = review_queue.review(self.state, self.args)
        self.assertEqual([report["id"] for report in result["reports"]], ["one"])
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            review_queue.print_review(result, details=True)
        self.assertIn("Feedback: Details added after filing", output.getvalue())

    def test_project_blockers_and_claude_session_output(self):
        self.state["projects"] = [{"id": "project", "name": "Test", "path": str(self.root)}]
        self.state["issues"][0].update({"agent": "claude", "threadID": "claude-session"})
        with patch.object(review_queue, "git_result", side_effect=[(2, ""), (0, ".git")]):
            result = review_queue.review(self.state, self.args)
        self.assertEqual(len(result["projectChecks"][0]["blockers"]), 2)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            review_queue.print_review(result, details=True)
        self.assertIn("Claude Code session: claude-session", output.getvalue())
        self.assertNotIn("codex://threads/claude-session", output.getvalue())


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Review ScreenClip's local queue without starting work or changing its database."""
import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys


GROUPS = (
    ("Needs attention", {"needsProject", "needsYou", "failed"}),
    ("In progress", {"working", "prOpen"}),
    ("Queued", {"queued"}),
    ("To retest", {"merged"}),
    ("Finished / archive candidates", {"verified", "canceled"}),
    ("Drafts", {"draft"}),
)


def snapshot(root):
    database = root / "screenclip.sqlite"
    if not database.is_file():
        raise ValueError(f"No ScreenClip queue at {database}")
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
        row = connection.execute("SELECT payload FROM state WHERE id=1").fetchone()
    return json.loads(row[0]) if row else {"projects": [], "issues": []}


def git_result(path, *arguments):
    try:
        result = subprocess.run(
            ["/usr/bin/git", "-C", path, *arguments],
            capture_output=True, text=True, timeout=10,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
        )
        return result.returncode, result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None, ""


def updated_at(value):
    if not isinstance(value, (int, float)):
        return None
    # Swift's default Codable Date uses seconds since 2001-01-01.
    return (datetime(2001, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=value)).isoformat()


def searchable(issue):
    values = [issue.get(key) or "" for key in ("id", "title", "resultSummary", "lastError")]
    values.append(str(issue.get("reportNumber") or ""))
    values.extend(capture.get("note", "") for capture in issue.get("captures", []))
    values.extend(activity.get("text", "") for activity in issue.get("activities", []))
    for question in issue.get("questions", []):
        values.extend([question.get("title", ""), question.get("reply") or ""])
    return "\n".join(values).casefold()


def review(state, args):
    projects = state.get("projects", [])
    if args.project:
        projects = [project for project in projects if args.project.casefold() in
                    (project["id"].casefold(), project["name"].casefold())]
        if not projects:
            raise ValueError(f"No project named {args.project!r}; use its exact name or UUID")
    project_ids = {project["id"] for project in projects}
    checks = []
    for project in projects:
        code, output = git_result(project["path"], "remote", "get-url", "origin")
        # Failed Git commands may mean either no remote or an inaccessible checkout.
        if code != 0:
            repository_code, _ = git_result(project["path"], "rev-parse", "--git-dir")
        else:
            repository_code = 0
        blockers = []
        if not project.get("validationCommand", "").strip():
            blockers.append("No project validation command; publication is blocked")
        if repository_code != 0:
            blockers.append("Cannot inspect the project's Git repository")
        elif code != 0 or not output.strip():
            blockers.append("No origin remote; the PR/merge workflow cannot finish")
        checks.append({"id": project["id"], "name": project["name"], "blockers": blockers})

    names = {project["id"]: project["name"] for project in projects}
    reports = []
    for issue in state.get("issues", []):
        if args.project and issue.get("projectID") not in project_ids:
            continue
        if not args.include_archived and issue.get("archived", False):
            continue
        if args.search:
            query = args.search.strip()
            digits = query.removeprefix("#")
            if digits.isascii() and digits.isdecimal() and int(digits) > 0:
                if issue.get("reportNumber") != int(digits):
                    continue
            elif query.casefold() not in searchable(issue):
                continue
        if args.status and issue.get("status") not in args.status:
            continue
        report = {key: issue.get(key) for key in (
            "id", "reportNumber", "title", "status", "agent", "threadID", "prURL",
            "revision", "coveredRevision", "resultSummary", "lastError",
        )}
        report.update({
            "project": names.get(issue.get("projectID"), "Unassigned"),
            "archived": bool(issue.get("archived")),
            "updatedAt": updated_at(issue.get("updatedAt")),
            "notes": [capture.get("note", "") for capture in issue.get("captures", [])],
            "pendingQuestions": [question.get("title", "") for question in
                                 issue.get("questions", []) if question.get("reply") is None],
            "latestActivity": [activity.get("text", "") for activity in
                               issue.get("activities", [])[-3:]],
            # A completed agent turn or a merged fix awaiting retest is not verified.
            "archiveCandidate": not issue.get("archived") and
                                issue.get("status") in {"verified", "canceled"},
        })
        if args.check_worktrees and issue.get("worktreePath"):
            code, output = git_result(issue["worktreePath"], "status", "--porcelain=v1", "-z")
            report["worktreeHasChanges"] = bool(output) if code == 0 else None
        reports.append(report)
    return {
        "observedAt": datetime.now(timezone.utc).isoformat(),
        "source": str(args.data_dir / "screenclip.sqlite"),
        "processingPaused": bool(state.get("settings", {}).get("paused")),
        "counts": dict(Counter(report["status"] for report in reports)),
        "archivedCount": sum(report["archived"] for report in reports),
        "archiveCandidates": [report["id"] for report in reports if report["archiveCandidate"]],
        "projectChecks": checks,
        "reports": reports,
    }


def print_review(result, details):
    print(f"ScreenClip queue — {result['observedAt']}")
    print(f"{len(result['reports'])} matching reports; processing " +
          ("paused" if result["processingPaused"] else "enabled"))
    print("Stored statuses; check the linked Codex chat before taking over an existing job.")
    for project in result["projectChecks"]:
        for blocker in project["blockers"]:
            print(f"Project {project['name']}: {blocker}")
    assigned = set()
    for heading, statuses in (*GROUPS, ("Other statuses", set())):
        reports = [report for report in result["reports"] if not report["archived"] and
                   (report["status"] in statuses if statuses else report["id"] not in assigned)]
        if not reports:
            continue
        print(f"\n{heading} ({len(reports)})")
        for report in reports:
            assigned.add(report["id"])
            print_report(report, details)
    archived = [report for report in result["reports"] if report["archived"]]
    if archived:
        print(f"\nArchived ({len(archived)})")
        for report in archived:
            print_report(report, details)
    print(f"\n{len(result['archiveCandidates'])} finished reports eligible for archive. "
          "Merged reports stay under To retest until verified.")


def print_report(report, details):
    reference = f"#{report['reportNumber']}" if report.get("reportNumber") else report["id"][:8]
    title = " ".join(report["title"].split())
    print(f"  {reference} [{report['status']}] {title}")
    for question in report["pendingQuestions"]:
        print(f"    Needs input: {' '.join(question.split())}")
    if report["lastError"]:
        print(f"    Last recorded error: {' '.join(report['lastError'].split())}")
    if "worktreeHasChanges" in report:
        value = {True: "uncommitted changes", False: "clean", None: "unavailable"}[
            report["worktreeHasChanges"]]
        print(f"    Worktree: {value}")
    if details:
        for note in report["notes"]:
            if note.strip():
                print(f"    Feedback: {' '.join(note.split())}")
        if report["resultSummary"]:
            print(f"    Agent result (not merge verification): {report['resultSummary']}")
        for activity in report["latestActivity"]:
            print(f"    Activity: {' '.join(activity.split())}")
        if report["threadID"]:
            if report.get("agent") == "claude":
                print(f"    Claude Code session: {report['threadID']}")
            else:
                print(f"    Chat: codex://threads/{report['threadID']}")
        if report["prURL"]:
            print(f"    PR: {report['prURL']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=Path(os.environ.get(
        "SCREENCLIP_DATA_DIR", str(Path.home() / "Library/Application Support/ScreenClip"))))
    parser.add_argument("--project", help="Exact project name or UUID")
    parser.add_argument("--status", action="append", help="Stored status; repeat to select several")
    parser.add_argument("--search", help="Search report numbers, feedback, results, and conversation text")
    parser.add_argument("--include-archived", action="store_true")
    parser.add_argument("--check-worktrees", action="store_true", help="Also run read-only git status")
    parser.add_argument("--details", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    args.data_dir = args.data_dir.expanduser().resolve()
    try:
        result = review(snapshot(args.data_dir), args)
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"ScreenClip review: {error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print_review(result, args.details)
    return 0


if __name__ == "__main__":
    sys.exit(main())

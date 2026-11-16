#!/usr/bin/env python3
"""Ask the running ScreenClip app to reconcile or continue a report by its number.

The app stays the only writer of the queue: this reads the queue read-only to find the report,
then opens `screenclip://issues/<uuid>/<action>`. The app applies the same conditions as the
Reconcile chat and Continue buttons, so an action that is not currently offered does nothing.
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

import review_queue

ACTIONS = ("open", "reconcile", "continue", "resume")


def find(snapshot, number):
    for issue in snapshot.get("issues", []):
        if issue.get("reportNumber") == number:
            return issue
    raise ValueError(f"No report #{number} in this queue")


def link(issue, action):
    base = "screenclip://issues/" + issue["id"]
    return base if action == "open" else base + "/" + action


def describe(issue):
    last = (issue.get("activities") or [{}])[-1].get("text", "")
    waiting = sum(1 for q in issue.get("questions", []) if q.get("reply") is None)
    return f"#{issue.get('reportNumber')} {issue.get('status')} · {waiting} unanswered · {last[:120]}"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("number", type=int, help="report number, as shown in the queue")
    parser.add_argument("action", choices=ACTIONS, help="resume = reconcile, then continue")
    parser.add_argument("--data-dir", type=Path, default=Path(os.environ.get(
        "SCREENCLIP_DATA_DIR", str(Path.home() / "Library/Application Support/ScreenClip"))))
    parser.add_argument("--wait", type=float, default=8, help="seconds to wait before reporting")
    args = parser.parse_args(argv)
    root = args.data_dir.expanduser().resolve()
    try:
        issue = find(review_queue.snapshot(root), args.number)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    print("before:", describe(issue))
    # -g: act in the background without bringing ScreenClip forward.
    flags = [] if args.action == "open" else ["-g"]
    subprocess.run(["/usr/bin/open", *flags, link(issue, args.action)], check=True)
    if args.action != "open":
        time.sleep(max(0, args.wait))
        print("after: ", describe(find(review_queue.snapshot(root), args.number)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Create an explicitly named private, disposable GitHub fixture for the native end-to-end run."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--repository", required=True, help="OWNER/screenclip-integration-NAME")
parser.add_argument("--destination", required=True)
args = parser.parse_args()
owner, separator, name = args.repository.partition("/")
if not separator or not name.startswith("screenclip-integration-"):
    parser.error("Use a dedicated OWNER/screenclip-integration-* repository")
destination = Path(args.destination).resolve()
if destination.exists():
    parser.error("Choose a new destination directory")

def run(*command, cwd=None):
    return subprocess.run(command, cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()

run("gh", "repo", "create", args.repository, "--private", "--description", "Disposable private fixture for ScreenClip capture-to-PR-to-merge verification")
run("gh", "repo", "clone", args.repository, str(destination))
files = {
    "style.css": ".purchase-button { width: 80px; padding: 12px; }\n",
    "index.html": '<!doctype html><link rel="stylesheet" href="style.css"><button class="purchase-button">Complete purchase</button>\n',
    "test_layout.py": '''from pathlib import Path
import re
import unittest

class LayoutTest(unittest.TestCase):
    def test_purchase_button_has_room_for_its_label(self):
        css = Path("style.css").read_text()
        self.assertRegex(css, r"width:\\s*240px")

if __name__ == "__main__":
    unittest.main()
''',
    ".gitignore": "__pycache__/\n",
    ".github/workflows/check.yml": """name: Fixture checks
on: [pull_request]
jobs:
  layout:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: python3 -m unittest
""",
    "README.md": "# ScreenClip integration fixture\n\nSynthetic UI bug used to verify the native issue worker, isolated edits, checks, PR creation, and automatic merge. Contains no user screenshots or project data.\n"
}
for filename, contents in files.items():
    target = destination / filename
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(contents)
run("git", "checkout", "-b", "main", cwd=destination)
run("git", "add", "--all", cwd=destination)
run("git", "commit", "-m", "Add synthetic purchase-button regression fixture", cwd=destination)
run("git", "push", "-u", "origin", "main", cwd=destination)
print(f"Created private fixture https://github.com/{args.repository}")
print(f"Local checkout: {destination}")

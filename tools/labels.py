"""Read .github/labels.yml and push it to GitHub through the gh command.

The label set lives in the repository rather than only in the web interface, so
that it can be reviewed in a pull request and restored after somebody deletes
one by accident. This is a small hand written parser rather than a yaml
dependency, because the file has exactly three keys per entry and adding a
package to the default install for that would be a poor trade.

Without --apply it validates the file and prints what would change, which is
what a checker should do by default.

Run: python3 -m tools.labels [--apply]
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

FILE = Path(".github/labels.yml")
ENTRY = re.compile(
    r"^- name: (?P<name>.+)\n  color: \"(?P<color>[0-9A-Fa-f]{6})\"\n  description: (?P<description>.+)$",
    re.MULTILINE,
)
FAMILIES = ("kind/", "area/", "priority/", "status/")


def parse(text: str) -> list[dict[str, str]]:
    return [match.groupdict() for match in ENTRY.finditer(text)]


def validate(labels: list[dict[str, str]]) -> list[str]:
    problems: list[str] = []
    seen: set[str] = set()

    for label in labels:
        name = label["name"]
        if name in seen:
            problems.append(f"{name}: listed twice")
        seen.add(name)

        if len(label["description"]) > 100:
            problems.append(f"{name}: description is longer than the 100 characters GitHub stores")

        if "/" in name and not name.startswith(FAMILIES):
            problems.append(f"{name}: uses a family that is not one of {', '.join(FAMILIES)}")

    for family in FAMILIES:
        if not any(label["name"].startswith(family) for label in labels):
            problems.append(f"no labels in the {family} family")

    return problems


def apply(labels: list[dict[str, str]]) -> int:
    failed = 0
    for label in labels:
        result = subprocess.run(
            [
                "gh",
                "label",
                "create",
                label["name"],
                "--color",
                label["color"],
                "--description",
                label["description"],
                "--force",
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            failed += 1
            print(f"{label['name']}: {result.stderr.strip()}")
    return failed


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)

    if not FILE.exists():
        print(f"labels: {FILE} is missing")
        return 1

    labels = parse(FILE.read_text(encoding="utf-8"))
    problems = validate(labels)

    for problem in problems:
        print(problem)

    if problems:
        print(f"labels: {len(labels)} labels, {len(problems)} problems")
        return 1

    if "--apply" not in argv:
        print(f"labels: {len(labels)} labels, valid, pass --apply to push them")
        return 0

    failed = apply(labels)
    print(f"labels: pushed {len(labels) - failed} of {len(labels)}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

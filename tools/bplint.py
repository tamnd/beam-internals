"""The blueprint shape, checked.

A blueprint is what somebody implements from when they have not read the lesson
it came from. So the sections have to all be there, and the text is not allowed
to lean on the lesson. The rule that matters most is the last one: a blueprint
that says "as we saw above" is a summary, and summaries rot into wrongness
because nobody reads them adversarially.

Run: python3 -m tools.bplint
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path("blueprints")

SECTIONS = [
    "1. Scope",
    "2. Data structures",
    "3. Algorithms",
    "4. Invariants, ordering guarantees and yield points",
    "5. Edge cases and error behaviour",
    "6. Observable surface",
    "7. Conformance",
    "8. Porting notes",
    "9. Provenance",
]

HEADER_FIELDS = ["Status", "Applies to", "Lesson", "Depends on", "Conformance"]
STATUSES = {"draft", "reviewed", "stable"}

# A blueprint names its lesson once, in the header, and never again.
BACKREF = re.compile(
    r"\b(as we saw|as we did|recall that|in this chapter|in the chapter|"
    r"earlier in the lesson|the lesson above|see the chapter)\b",
    re.IGNORECASE,
)
LESSON_LINK = re.compile(r"\]\(\.\./?lessons/")

YIELD_MARKER = re.compile(r"\[yield\]")
NOT_GUARANTEED = re.compile(r"not guaranteed", re.IGNORECASE)


def check(path: Path) -> list[str]:
    problems: list[str] = []
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    head = "\n".join(lines[:12])

    for field in HEADER_FIELDS:
        if f"{field}:" not in head:
            problems.append(f"{path}: header is missing {field}")

    status = re.search(r"^Status:\s*(\w+)", head, re.MULTILINE)
    if status and status.group(1) not in STATUSES:
        problems.append(f"{path}: status {status.group(1)!r} is not one of {sorted(STATUSES)}")

    for index, section in enumerate(SECTIONS):
        if f"## {section}" not in text:
            problems.append(f"{path}: missing section {index + 1}, {section}")

    body_start = text.find("## 1. Scope")
    body = text[body_start:] if body_start >= 0 else text

    for line in body.splitlines():
        if BACKREF.search(line):
            problems.append(f"{path}: refers back to its lesson: {line.strip()[:80]}")
        if LESSON_LINK.search(line):
            problems.append(f"{path}: links into lessons/, which a blueprint may not do")

    if "## 4." in text:
        section4 = text.split("## 4.", 1)[1].split("## 5.", 1)[0]
        if "ORD-" in section4 and not NOT_GUARANTEED.search(section4):
            problems.append(
                f"{path}: section 4 states an ordering guarantee with no boundary. "
                "Every guarantee needs at least one line saying what is not guaranteed."
            )

    if "## 3." in text and "## 4." in text:
        section3 = text.split("## 3.", 1)[1].split("## 4.", 1)[0]
        section4 = text.split("## 4.", 1)[1].split("## 5.", 1)[0]
        if YIELD_MARKER.search(section3) and "yield point" not in section4.lower():
            problems.append(f"{path}: section 3 marks a yield and section 4 does not list it")

    return problems


def main() -> int:
    files = sorted(p for p in ROOT.rglob("*.md") if p.name != "NOTATION.md")
    problems: list[str] = []
    for path in files:
        problems.extend(check(path))

    for problem in problems:
        print(problem)

    print(f"bplint: {len(files)} blueprints, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())

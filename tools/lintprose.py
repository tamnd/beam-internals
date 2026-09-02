"""House style rules for the prose in this repository, as a script.

The rules are in CONTRIBUTING.md. They live here as well so that nobody has to
remember them and no reviewer has to spend attention on them. Standard library
only, so it runs in under a second and a prose change gets an answer straight
away.

Run: python3 -m tools.lintprose [path ...]
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

SKIP_DIRS = {
    ".git",
    ".venv",
    "node_modules",
    "_build",
    "site/_build",
    "otp",
    "__pycache__",
    ".pytest_cache",
    ".ruff_cache",
    ".mypy_cache",
}

# corpora/ is not skipped. Only markdown is checked, and the recorded output in
# there is not markdown, so the only thing this reaches is the prose explaining
# a corpus, which is prose like any other.

# Words that tell a reader the problem is them, plus one that is simply untrue.
# "it turns out" did not turn out. Somebody decided, and there is a commit.
BANNED = [
    r"\bsimply\b",
    r"\bjust\b",
    r"\bobviously\b",
    r"\bof course\b",
    r"\btrivially\b",
    r"\bas you would expect\b",
    r"\bit turns out\b",
    r"\bnote that\b",
    r"\bwe will explore\b",
]

# A citation into the Erlang/OTP tree has to carry the tag it was read at. A
# line number with no version is noise within a year.
CITATION = re.compile(r"\b((?:erts|lib|system|make)/[\w./+-]+\.(?:c|h|erl|hrl|tab|md|names|types|tla)):(\d+)")
TAGGED = re.compile(r"@OTP-\d")

# Colour and position carry no information for a reader who cannot see the
# figure. Name the thing instead.
POSITIONAL = re.compile(
    r"\b(shown in (red|green|blue|orange)|the (box|line|panel) on the (left|right))\b",
    re.IGNORECASE,
)

RULE_LINE = re.compile(r"^\s*(-{3,}|\*{3,}|_{3,})\s*$")
INTERNAL_LINK = re.compile(r"\[[^\]]*\]\((?!https?:|mailto:|#)([^)#\s]+)")

CONTINUES = re.compile(r"[a-z,;]$")
STARTS_LOWER = re.compile(r"^[a-z]")
STRUCTURAL = re.compile(r"^\s*(\||[-*+>]\s|\d+\.\s|#|<!--|\[)")


@dataclass
class Problem:
    path: Path
    line: int
    rule: str
    text: str


def strip_code(line: str) -> str:
    """Blank out inline code so that identifiers do not trip the word rules."""
    return re.sub(r"`[^`]*`", lambda m: " " * len(m.group(0)), line)


def check(path: Path) -> list[Problem]:
    problems: list[Problem] = []
    lines = path.read_text(encoding="utf-8").splitlines()
    in_fence = False
    allow_next = False

    for number, raw in enumerate(lines, start=1):
        if raw.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        if "lintprose: allow" in raw:
            allow_next = True
            continue
        allowed = allow_next
        allow_next = False

        if raw != raw.rstrip():
            problems.append(Problem(path, number, "trailing-whitespace", raw.rstrip()))

        if "—" in raw:
            problems.append(Problem(path, number, "em-dash", raw.strip()))
        if " – " in raw:  # noqa: RUF001, the en dash is the thing being detected
            problems.append(Problem(path, number, "en-dash-as-punctuation", raw.strip()))

        if RULE_LINE.match(raw) and number != 1:
            problems.append(Problem(path, number, "horizontal-rule", raw.strip()))

        prose = strip_code(raw)

        if not allowed:
            for pattern in BANNED:
                if re.search(pattern, prose, re.IGNORECASE):
                    problems.append(Problem(path, number, f"banned-word {pattern}", raw.strip()))

        if POSITIONAL.search(prose):
            problems.append(Problem(path, number, "positional-reference", raw.strip()))

        for match in CITATION.finditer(raw):
            tail = raw[match.end() : match.end() + 16]
            if not TAGGED.match(tail):
                problems.append(Problem(path, number, "citation-without-tag", match.group(0)))

        for match in INTERNAL_LINK.finditer(raw):
            target = (path.parent / match.group(1)).resolve()
            if not target.exists():
                problems.append(Problem(path, number, "dead-internal-link", match.group(1)))

        if number < len(lines) and not allowed:
            nxt = lines[number]
            if (
                prose.strip()
                and not STRUCTURAL.match(raw)
                and not STRUCTURAL.match(nxt)
                and CONTINUES.search(prose.rstrip())
                and STARTS_LOWER.match(nxt.strip())
            ):
                problems.append(Problem(path, number, "sentence-wrapped-across-lines", raw.strip()))

    return problems


def targets(argv: list[str]) -> list[Path]:
    roots = [Path(a) for a in argv] or [Path(".")]
    found: list[Path] = []
    for root in roots:
        if root.is_file():
            found.append(root)
            continue
        for path in sorted(root.rglob("*.md")):
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            found.append(path)
    return found


def main(argv: list[str] | None = None) -> int:
    problems: list[Problem] = []
    files = targets(list(sys.argv[1:] if argv is None else argv))
    for path in files:
        problems.extend(check(path))

    for problem in problems:
        print(f"{problem.path}:{problem.line}: {problem.rule}: {problem.text[:110]}")

    print(f"lintprose: {len(files)} files, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Every citation into the Erlang/OTP tree, checked against the pinned tree.

A citation names a file, a line and the tag it was read at. This resolves the
file in the submodule, checks the line exists, and reports anything pointing at
a file the emulator generates rather than at the table it was generated from.

When the submodule is not checked out, the citations are still parsed and their
shape is checked, and the resolution step says it was skipped. That is so a
prose only change does not need three hundred megabytes of Erlang source. Pass
--strict to turn a missing submodule into a failure, which is what the job that
does check it out uses.

Run: python3 -m tools.refcheck [--strict] [path ...]
"""

from __future__ import annotations

import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

CITATION = re.compile(
    r"\b((?:erts|lib|system|make)/[\w./+-]+\.(?:c|h|cpp|hpp|erl|hrl|tab|md|names|types|tla|pl))"
    r":(\d+)(?:-(\d+))?@(OTP-[\w.]+)"
)

SKIP_DIRS = {".git", ".venv", "node_modules", "_build", "otp", "__pycache__"}


@dataclass
class Citation:
    source: Path
    line: int
    path: str
    start: int
    end: int
    tag: str


def load_config(root: Path) -> dict:
    with (root / "refcheck.toml").open("rb") as handle:
        return tomllib.load(handle)


def collect(roots: list[Path]) -> list[Citation]:
    found: list[Citation] = []
    for root in roots:
        files = [root] if root.is_file() else sorted(root.rglob("*.md"))
        for path in files:
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            for number, text in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                for match in CITATION.finditer(text):
                    start = int(match.group(2))
                    end = int(match.group(3)) if match.group(3) else start
                    found.append(Citation(path, number, match.group(1), start, end, match.group(4)))
    return found


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    strict = "--strict" in argv
    argv = [a for a in argv if a != "--strict"]

    root = Path(".")
    config = load_config(root)
    pin = config["pin"]
    rules = config["rules"]

    citations = collect([Path(a) for a in argv] or [root])
    problems: list[str] = []

    tree = root / pin["submodule"]
    resolvable = (tree / "erts").is_dir()

    if strict and not resolvable:
        problems.append(
            f"{pin['submodule']} is not checked out, so nothing was resolved. "
            "Run with submodules, or drop --strict."
        )

    for cite in citations:
        where = f"{cite.source}:{cite.line}"

        if cite.tag != pin["tag"]:
            problems.append(f"{where}: cites {cite.tag}, the pin is {pin['tag']}")

        if cite.path in rules["generated"]:
            problems.append(f"{where}: {cite.path} is generated, cite the table it comes from instead")

        span = cite.end - cite.start + 1
        if span > rules["max_span"]:
            problems.append(f"{where}: spans {span} lines, the limit is {rules['max_span']}")

        if resolvable:
            target = tree / cite.path
            if not target.exists():
                problems.append(f"{where}: {cite.path} does not exist at {pin['tag']}")
                continue
            count = len(target.read_text(encoding="utf-8", errors="replace").splitlines())
            if cite.end > count:
                problems.append(f"{where}: {cite.path} has {count} lines, the citation points at {cite.end}")

    for problem in problems:
        print(problem)

    state = "resolved against the pinned tree" if resolvable else "shape only, submodule not checked out"
    print(f"refcheck: {len(citations)} citations at {pin['tag']}, {state}, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())

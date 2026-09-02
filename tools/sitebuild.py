"""Stage the book into the site directory and generate its navigation.

MkDocs can only see what is under its docs directory, so the lessons and the
blueprints get copied in. The originals are the committed ones. The navigation
is generated from what is on disk rather than hand written, so a lesson cannot
be added and left as a page nobody can reach.

Run: python3 -m tools.sitebuild [--check]
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

SITE = Path("site")
DOCS = SITE / "docs"

TOP = [
    ("index.md", Path("README.md"), "Home"),
    ("layout.md", Path("LAYOUT.md"), "Layout"),
    ("contributing.md", Path("CONTRIBUTING.md"), "Contributing"),
    ("notation.md", Path("blueprints/NOTATION.md"), "Blueprint notation"),
]


def collect() -> tuple[list[Path], list[Path]]:
    lessons = sorted(Path("lessons").rglob("lesson.livemd"))
    blueprints = sorted(p for p in Path("blueprints").rglob("BP-*.md") if p.name != "NOTATION.md")
    return lessons, blueprints


def navigation(lessons: list[Path], blueprints: list[Path]) -> str:
    lines = ["", "nav:"]
    for name, _, title in TOP:
        lines.append(f"  - {title}: {name}")

    if lessons:
        lines.append("  - Lessons:")
        for path in lessons:
            lines.append(f"      - {path.parent.name}: lessons/{path.parent.name}.md")

    if blueprints:
        lines.append("  - Blueprints:")
        for path in blueprints:
            lines.append(f"      - {path.stem}: blueprints/{path.stem}.md")

    return "\n".join(lines) + "\n"


def build(check: bool) -> int:
    lessons, blueprints = collect()
    config = (SITE / "mkdocs.base.yml").read_text(encoding="utf-8") + navigation(lessons, blueprints)

    target = SITE / "mkdocs.yml"
    if check:
        if not target.exists() or target.read_text(encoding="utf-8") != config:
            print("sitebuild: navigation is out of date, run `just site-stage`")
            return 1
        print(f"sitebuild: {len(lessons)} lessons, {len(blueprints)} blueprints, up to date")
        return 0

    DOCS.mkdir(parents=True, exist_ok=True)
    for name, source, _ in TOP:
        shutil.copyfile(source, DOCS / name)

    if lessons:
        out = DOCS / "lessons"
        out.mkdir(exist_ok=True)
        for path in lessons:
            shutil.copyfile(path, out / f"{path.parent.name}.md")

    if blueprints:
        out = DOCS / "blueprints"
        out.mkdir(exist_ok=True)
        for path in blueprints:
            shutil.copyfile(path, out / f"{path.stem}.md")

    target.write_text(config, encoding="utf-8")
    print(f"sitebuild: staged {len(TOP)} pages, {len(lessons)} lessons, {len(blueprints)} blueprints")
    return 0


if __name__ == "__main__":
    raise SystemExit(build("--check" in sys.argv[1:]))

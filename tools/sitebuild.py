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

from tools import node

SITE = Path("site")
DOCS = SITE / "docs"

# `corpus.md` is here because the bottom rung of the degradation ladder points
# at it. A badge that sends a reader to a page the site does not publish is the
# failure the ladder exists to prevent, so the page is staged whether or not the
# Node is up.
TOP = [
    ("index.md", Path("README.md"), "Home"),
    ("layout.md", Path("LAYOUT.md"), "Layout"),
    ("corpus.md", Path("corpora/README.md"), "Corpus"),
    ("contributing.md", Path("CONTRIBUTING.md"), "Contributing"),
    ("notation.md", Path("blueprints/NOTATION.md"), "Blueprint notation"),
]


def collect() -> tuple[list[Path], list[Path]]:
    lessons = sorted(Path("lessons").rglob("lesson.livemd"))
    blueprints = sorted(p for p in Path("blueprints").rglob("BP-*.md") if p.name != "NOTATION.md")
    return lessons, blueprints


def stage_assets(lesson: Path, target: Path) -> None:
    """Copy a lesson's attached files in alongside its page.

    `files/` is Livebook's own name for the things a notebook refers to, and a
    notebook writes them as `files/x.svg`. Keeping that name and staging the
    page as `lessons/<id>/index.md` rather than as a flat `lessons/<id>.md`
    means the same relative path resolves in Livebook Desktop and on the
    published site. The alternative is rewriting image paths on the way in,
    which would leave the page and the notebook holding different text, and the
    whole reason for choosing this format is that they hold the same text.
    """
    source = lesson / "files"
    if not source.is_dir():
        return
    shutil.copytree(source, target / "files", dirs_exist_ok=True)


def with_badge(text: str, lesson: str, ladder: node.Ladder) -> str:
    """The lesson page, with the Node badge under its title.

    The badge is added here rather than written into `lesson.livemd`, because
    the notebook has to open in Livebook Desktop with no site and no repository
    anywhere near it. A button pointing at a hosted sandbox means nothing there.
    The staged page is the copy that gets a badge, and it gets whichever badge
    the ladder is standing on today.
    """
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line.startswith("# "):
            head = lines[: index + 1]
            tail = lines[index + 1 :]
            return "\n".join([*head, "", node.badge(ladder, lesson).rstrip("\n"), *tail]) + "\n"
    raise node.Broken(f"{lesson} has no title line, so there is nowhere to put the badge")


def navigation(lessons: list[Path], blueprints: list[Path]) -> str:
    lines = ["", "nav:"]
    for name, _, title in TOP:
        lines.append(f"  - {title}: {name}")

    if lessons:
        lines.append("  - Lessons:")
        for path in lessons:
            lines.append(f"      - {path.parent.name}: lessons/{path.parent.name}/index.md")

    if blueprints:
        lines.append("  - Blueprints:")
        for path in blueprints:
            lines.append(f"      - {path.stem}: blueprints/{path.stem}.md")

    return "\n".join(lines) + "\n"


def build(check: bool) -> int:
    lessons, blueprints = collect()
    config = (SITE / "mkdocs.base.yml").read_text(encoding="utf-8") + navigation(lessons, blueprints)
    ladder = node.read()

    target = SITE / "mkdocs.yml"
    if check:
        if not target.exists() or target.read_text(encoding="utf-8") != config:
            print("sitebuild: navigation is out of date, run `just site-stage`")
            return 1
        print(
            f"sitebuild: {len(lessons)} lessons, {len(blueprints)} blueprints, "
            f"badge on rung {ladder.standing_on}, up to date"
        )
        return 0

    DOCS.mkdir(parents=True, exist_ok=True)
    for name, source, _ in TOP:
        shutil.copyfile(source, DOCS / name)

    if lessons:
        out = DOCS / "lessons"
        out.mkdir(exist_ok=True)
        for path in lessons:
            page = out / path.parent.name
            page.mkdir(exist_ok=True)
            text = path.read_text(encoding="utf-8")
            (page / "index.md").write_text(with_badge(text, path.parent.name, ladder), encoding="utf-8")
            stage_assets(path.parent, page)

    if blueprints:
        out = DOCS / "blueprints"
        out.mkdir(exist_ok=True)
        for path in blueprints:
            shutil.copyfile(path, out / f"{path.stem}.md")

    target.write_text(config, encoding="utf-8")
    print(
        f"sitebuild: staged {len(TOP)} pages, {len(lessons)} lessons, {len(blueprints)} blueprints, "
        f"badge on rung {ladder.standing_on}, {ladder.current.name}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(build("--check" in sys.argv[1:]))

"""The degradation ladder for the Node, and the badge it puts on every lesson.

The Node is the hosted sandbox a reader opens from a lesson page. It costs
money, it runs code anonymous people type, and it will be down sometimes. So
the way it gets worse is written down in `node/ladder.toml` as four rungs, and
the badge on every staged lesson page is generated from whichever rung the Node
is standing on rather than written by hand.

Generating it is the point. A ladder that lives in a design document is a
paragraph nobody can test. A ladder that renders the badge means every rung has
to produce something a reader can act on, and a rung that would leave a reader
staring at a dead link fails here instead of in production.

The bottom rung is the one that matters most. Rung 4 is the Node being gone,
and the promise attached to it is that the reader loses interactivity and loses
no information. That promise is only worth making because every lesson carries
its own recorded output, so `tests/test_node.py` checks it by reading the pages
rather than by believing this paragraph.

Run:
  python3 -m tools.node            the ladder, and the badge for each rung
  python3 -m tools.node --check    the file is well formed and the links resolve
"""

from __future__ import annotations

import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

LADDER = Path("node/ladder.toml")

# Every field a rung has to carry. A rung missing one of these is a rung that
# renders half a badge, so it is caught here rather than by a reader.
FIELDS = [
    "number",
    "name",
    "title",
    "badge",
    "target",
    "tone",
    "session_minutes",
    "extensions",
    "note",
    "entered_when",
    "costs_the_reader",
]

# What a badge can point at. `node` is a session on the hosted sandbox, and
# `corpus` is a page of this book, which is the only target that works when
# there is nothing hosted at all.
TARGETS = {"node", "corpus"}

# The admonition styles this renders into, which are the ones the site theme
# already has. A rung asking for anything else would render as plain text.
TONES = {"success", "info", "warning", "danger"}


class Broken(Exception):
    pass


@dataclass(frozen=True)
class Rung:
    number: int
    name: str
    title: str
    badge: str
    target: str
    tone: str
    session_minutes: int
    extensions: int
    note: str
    entered_when: str
    costs_the_reader: str

    @property
    def opens_a_session(self) -> bool:
        return self.session_minutes > 0


@dataclass(frozen=True)
class Ladder:
    node_url: str
    corpus_page: str
    rungs: list[Rung]
    standing_on: int
    since: str
    why: str

    @property
    def current(self) -> Rung:
        return self.rung(self.standing_on)

    def rung(self, number: int) -> Rung:
        for one in self.rungs:
            if one.number == number:
                return one
        raise Broken(f"there is no rung {number} on this ladder")


def read(path: Path = LADDER) -> Ladder:
    if not path.exists():
        raise Broken(f"{path} is not there, and the badge on every lesson comes out of it")
    raw = tomllib.loads(path.read_text(encoding="utf-8"))

    if "current" not in raw:
        raise Broken(f"{path} has no [current], so nothing says which rung the Node is on")
    current = raw["current"]
    for field in ("rung", "since", "why"):
        if field not in current:
            raise Broken(f"{path} [current] has no {field}")

    rungs = []
    for entry in raw.get("rung", []):
        missing = [field for field in FIELDS if field not in entry]
        if missing:
            where = entry.get("number", "with no number")
            raise Broken(f"{path} rung {where} is missing {', '.join(missing)}")
        rungs.append(Rung(**{field: entry[field] for field in FIELDS}))

    return Ladder(
        node_url=raw.get("node_url", "").rstrip("/"),
        corpus_page=raw.get("corpus_page", ""),
        rungs=rungs,
        standing_on=current["rung"],
        since=current["since"],
        why=" ".join(current["why"].split()),
    )


def problems(ladder: Ladder) -> list[str]:
    """Everything that can be wrong with a ladder, in the order it gets read.

    Most of these are shapes rather than opinions. The two that are opinions are
    that the ladder only ever gets worse as it goes down, and that the bottom
    rung asks for nothing hosted, because a bottom rung that still needs a
    server is not a floor.
    """
    found: list[str] = []
    numbers = [rung.number for rung in ladder.rungs]

    if numbers != list(range(1, len(numbers) + 1)):
        found.append(f"the rungs are numbered {numbers}, and a ladder is 1 upwards with no gaps")
        return found
    if len(numbers) < 2:
        found.append("a ladder with one rung is not a ladder")
        return found

    for rung in ladder.rungs:
        if rung.target not in TARGETS:
            known = " or ".join(sorted(TARGETS))
            found.append(f"rung {rung.number} points at {rung.target!r}, which is not {known}")
        if rung.tone not in TONES:
            found.append(f"rung {rung.number} asks for the {rung.tone!r} style, which the site does not have")
        if rung.session_minutes < 0 or rung.extensions < 0:
            found.append(f"rung {rung.number} has a negative session or extension count")
        if rung.target == "node" and not rung.opens_a_session:
            found.append(f"rung {rung.number} opens a session of no minutes, which is a dead badge")
        if rung.target == "corpus" and rung.opens_a_session:
            found.append(f"rung {rung.number} sends the reader to the corpus and claims a session as well")

    for above, below in zip(ladder.rungs, ladder.rungs[1:], strict=False):
        if below.session_minutes > above.session_minutes:
            found.append(
                f"rung {below.number} offers more minutes than rung {above.number}, so the ladder "
                f"goes up as it goes down"
            )
        if below.extensions > above.extensions:
            found.append(f"rung {below.number} offers more extensions than rung {above.number}")

    bottom = ladder.rungs[-1]
    if bottom.target != "corpus":
        found.append(
            f"the bottom rung points at {bottom.target!r}, and a floor that still "
            f"needs a server is not a floor"
        )

    badges = [rung.badge for rung in ladder.rungs]
    if len(set(badges)) != len(badges):
        found.append("two rungs use the same words on the badge, so a reader cannot tell them apart")

    if ladder.standing_on not in numbers:
        found.append(f"the Node is said to be on rung {ladder.standing_on}, which is not on the ladder")
    if not ladder.why:
        found.append("the current rung has no reason written against it")

    if not ladder.corpus_page:
        found.append("no corpus_page, so the bottom rung has nowhere to send anybody")
    if any(rung.target == "node" for rung in ladder.rungs) and not ladder.node_url:
        found.append("rungs open sessions and no node_url says where")

    return found


def link(ladder: Ladder, rung: Rung, lesson: str, depth: int = 2) -> str:
    """Where the badge goes, from a staged lesson page.

    `depth` is how far the page sits under the docs directory, because the
    corpus link is relative. A staged lesson is `lessons/<id>/index.md`, so two.
    Passing it in rather than hard coding it keeps this usable from a test that
    renders into a directory of its own.
    """
    if rung.target == "node":
        return f"{ladder.node_url}/{lesson}"
    return "../" * depth + ladder.corpus_page


def badge(ladder: Ladder, lesson: str, rung: Rung | None = None, depth: int = 2) -> str:
    """The block that goes at the top of a lesson page, as markdown.

    An admonition rather than a bare button, because a badge on its own answers
    what to click and not what happens when you do. The reader who meets rung 3
    should be told the session is short before it ends early.
    """
    rung = rung or ladder.current
    style = " .md-button--primary" if rung.opens_a_session else ""
    return "\n".join(
        [
            f'!!! {rung.tone} "{rung.title}"',
            "",
            f"    {rung.note}",
            "",
            f"    [{rung.badge}]({link(ladder, rung, lesson, depth)})" + "{ .md-button" + style + " }",
            "",
        ]
    )


def describe(ladder: Ladder) -> str:
    lines = [
        f"the Node is on rung {ladder.standing_on}, {ladder.current.name}, since {ladder.since}",
        "",
        f"  {ladder.why}",
        "",
    ]
    for rung in ladder.rungs:
        here = " <- here" if rung.number == ladder.standing_on else ""
        session = f"{rung.session_minutes} minutes" if rung.opens_a_session else "no session"
        lines += [
            f"{rung.number}. {rung.name}, {session}, {rung.extensions} extension(s){here}",
            f"     entered when   {rung.entered_when}",
            f"     costs a reader {rung.costs_the_reader}",
            f"     badge says     {rung.badge}",
            "",
        ]
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    try:
        ladder = read()
    except Broken as broken:
        print(f"node: {broken}")
        return 1

    found = problems(ladder)
    for problem in found:
        print(f"node: {problem}")
    if found:
        return 1

    if "--check" in argv:
        print(f"node: {len(ladder.rungs)} rungs, standing on {ladder.standing_on}, {ladder.current.name}")
        return 0

    print(describe(ladder))
    print("the badge each rung puts on a lesson page, here for t07")
    print()
    for rung in ladder.rungs:
        print(badge(ladder, "t07", rung))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

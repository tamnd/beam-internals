"""Run every cell of every lesson and compare what came out against the recording.

A lesson makes a promise on every page: run this and you will see that. The only
way to keep the promise is to run it, so this pulls the cells out of the
notebook, runs them in order in one session, and compares the output against the
files in the lesson's `expected/` directory.

Two halves. The bookkeeping half needs no Erlang and is what `just check` runs:
every elixir cell is accounted for in `meta.toml`, every deterministic cell has a
recording, and the output shown to a reader inside the lesson matches that
recording. The running half needs a release on the path and is the part that
finds out whether any of it is still true.

Not every cell can be compared. A banner prints the build in front of you and a
timing cell prints wall clock times, so `meta.toml` splits the cells into the
ones whose output is the same everywhere and the ones that are run only to catch
the day one of them stops compiling.

Run:
  python3 -m tools.bake              every lesson, run and compare
  python3 -m tools.bake t07 m02      only these
  python3 -m tools.bake --offline    the half that needs no Erlang
  python3 -m tools.bake --write      run and rewrite the recordings
"""

from __future__ import annotations

import argparse
import difflib
import re
import subprocess
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path

LESSONS = Path("lessons")
RUNNER = Path("tools/bake.exs")

MARKER = re.compile(r"^<!--\s*cell:\s*(.+?)\s*-->$")
FENCE = re.compile(r"^```(\w*)\s*$")

# A marker whose name starts with this is a listing rather than a cell. The
# lessons print code they want read and not run, and without a way to say so the
# only options are a cell the baker skips silently or a cell it fails on.
NOT_A_CELL = "none"


class Broken(Exception):
    pass


@dataclass
class Cell:
    name: str
    code: str
    line: int
    # The output block the lesson shows underneath the cell, and where it sits,
    # so that `--write` can bring it forward along with the recording.
    shown: str | None
    span: tuple[int, int] | None


def parse(path: Path) -> list[Cell]:
    """Every elixir cell in a notebook, in the order Livebook would run them."""
    lines = path.read_text(encoding="utf-8").splitlines()
    cells: list[Cell] = []
    pending: str | None = None
    index = 0

    while index < len(lines):
        line = lines[index]

        marker = MARKER.match(line)
        if marker:
            pending = marker.group(1)
            index += 1
            continue

        fence = FENCE.match(line)
        if not fence:
            if line.strip():
                pending = None
            index += 1
            continue

        close = index + 1
        while close < len(lines) and not FENCE.match(lines[close]):
            close += 1
        if close == len(lines):
            raise Broken(f"{path}:{index + 1} a fence that never closes")

        if fence.group(1) != "elixir":
            pending = None
            index = close + 1
            continue

        if pending is None:
            raise Broken(
                f"{path}:{index + 1} an elixir block with no cell marker above it. "
                f"Livebook will run it and the baker will not, which is the worst of "
                f"both. Put `<!-- cell: name -->` above it, or `<!-- cell: none, "
                f"a listing -->` if it is there to be read rather than run."
            )

        code = "\n".join(lines[index + 1 : close]) + "\n"
        shown, span = following_block(lines, close + 1)

        if not pending.startswith(NOT_A_CELL):
            cells.append(Cell(pending, code, index + 1, shown, span))

        pending = None
        index = close + 1

    return cells


def following_block(lines: list[str], start: int) -> tuple[str | None, tuple[int, int] | None]:
    """The unlabelled fence right after a cell, which is the output the lesson shows.

    Only an unlabelled fence counts. A cell followed straight away by another
    elixir block is a cell whose output the lesson chose not to print, which is
    what both boss fights do so that the answer is not sitting on the page.
    """
    index = start
    while index < len(lines) and not lines[index].strip():
        index += 1
    if index >= len(lines) or lines[index] != "```":
        return None, None

    close = index + 1
    while close < len(lines) and lines[close] != "```":
        close += 1
    if close == len(lines):
        return None, None

    return "\n".join(lines[index + 1 : close]) + "\n", (index + 1, close)


def lessons(wanted: list[str]) -> list[Path]:
    found = sorted(p.parent for p in LESSONS.rglob("lesson.livemd"))
    if not wanted:
        return found
    by_id = {p.name: p for p in found}
    missing = [name for name in wanted if name not in by_id]
    if missing:
        raise Broken(f"no such lesson: {', '.join(missing)}")
    return [by_id[name] for name in wanted]


def bookkeeping(lesson: Path, cells: list[Cell]) -> list[str]:
    """Everything that can be checked without running a single line of Elixir."""
    problems: list[str] = []
    meta = tomllib.loads((lesson / "meta.toml").read_text(encoding="utf-8"))
    bake = meta.get("bake")
    if bake is None:
        return [f"{lesson.name}: meta.toml has no [bake] section, so nothing knows what to compare"]

    deterministic = bake.get("deterministic", [])
    not_compared = bake.get("not_compared", [])

    seen: set[str] = set()
    for cell in cells:
        if cell.name in seen:
            problems.append(f"{lesson.name}: two cells called {cell.name}, so one recording has two owners")
        seen.add(cell.name)

    both = set(deterministic) & set(not_compared)
    for name in sorted(both):
        problems.append(f"{lesson.name}: {name} is listed as deterministic and as not compared")

    listed = set(deterministic) | set(not_compared)
    for name in sorted(seen - listed):
        problems.append(f"{lesson.name}: cell {name} is in the notebook and in neither list in meta.toml")
    for name in sorted(listed - seen):
        problems.append(f"{lesson.name}: meta.toml lists {name} and the notebook has no such cell")

    recordings = {p.stem for p in (lesson / "expected").glob("*.txt")}
    for name in sorted(set(deterministic) - recordings):
        problems.append(f"{lesson.name}: {name} is deterministic and has no expected/{name}.txt")
    for name in sorted(recordings - set(deterministic)):
        problems.append(f"{lesson.name}: expected/{name}.txt belongs to no deterministic cell")

    # The lesson prints the output under most cells so it can be read on a train.
    # If that printed copy and the recording disagree then one of the two is
    # lying to somebody, and the reader is the one who cannot tell.
    for cell in cells:
        if cell.name not in deterministic or cell.shown is None:
            continue
        recording = lesson / "expected" / f"{cell.name}.txt"
        if recording.exists() and recording.read_text(encoding="utf-8") != cell.shown:
            problems.append(
                f"{lesson.name}: the output printed under {cell.name} in the lesson "
                f"is not what expected/{cell.name}.txt records"
            )

    return problems


def produce(lesson: Path, cells: list[Cell]) -> dict[str, str]:
    """Run the cells on a real VM and hand back what each one printed."""
    with tempfile.TemporaryDirectory(prefix="bake-") as work:
        room = Path(work)
        (room / "cells").mkdir()
        for position, cell in enumerate(cells):
            (room / "cells" / f"{position:02d}__{cell.name}.exs").write_text(cell.code, encoding="utf-8")

        finished = subprocess.run(
            ["elixir", str(RUNNER), str(room), str(lesson)],
            capture_output=True,
            text=True,
        )
        if finished.returncode != 0:
            raise Broken(f"{lesson.name} did not finish\n{finished.stdout}{finished.stderr}")

        return {
            path.stem.split("__", 1)[1]: path.read_text(encoding="utf-8")
            for path in (room / "out").glob("*.txt")
        }


def difference(name: str, recorded: str, got: str) -> str:
    lines = difflib.unified_diff(
        recorded.splitlines(keepends=True),
        got.splitlines(keepends=True),
        fromfile=f"expected/{name}.txt",
        tofile="this run",
        n=1,
    )
    return "".join(lines).rstrip()


def compare(lesson: Path, cells: list[Cell], output: dict[str, str]) -> list[str]:
    meta = tomllib.loads((lesson / "meta.toml").read_text(encoding="utf-8"))
    deterministic = meta["bake"]["deterministic"]
    problems: list[str] = []

    for cell in cells:
        if cell.name not in deterministic:
            continue
        got = output[cell.name]
        recording = lesson / "expected" / f"{cell.name}.txt"
        recorded = recording.read_text(encoding="utf-8")
        if got != recorded:
            problems.append(f"{lesson.name}: {cell.name} printed something else")
            problems.append(difference(cell.name, recorded, got))

    return problems


def write(lesson: Path, cells: list[Cell], output: dict[str, str]) -> list[str]:
    """Rewrite the recordings, and the copy the lesson shows, from this run."""
    meta = tomllib.loads((lesson / "meta.toml").read_text(encoding="utf-8"))
    if "bake" not in meta:
        raise Broken(f"{lesson.name}: meta.toml has no [bake] section, so there is nothing to write")
    deterministic = meta["bake"]["deterministic"]
    changed: list[str] = []

    notebook = lesson / "lesson.livemd"
    lines = notebook.read_text(encoding="utf-8").splitlines()

    # Backwards, so that replacing one block does not move the line numbers of
    # the blocks that have not been replaced yet.
    for cell in reversed(cells):
        if cell.name not in deterministic:
            continue
        got = output[cell.name]

        recording = lesson / "expected" / f"{cell.name}.txt"
        if not recording.exists() or recording.read_text(encoding="utf-8") != got:
            recording.write_text(got, encoding="utf-8")
            changed.append(f"{lesson.name}: rewrote expected/{cell.name}.txt")

        if cell.span is not None:
            start, close = cell.span
            fresh = got.rstrip("\n").split("\n")
            if lines[start:close] != fresh:
                lines[start:close] = fresh
                changed.append(f"{lesson.name}: rewrote the output shown under {cell.name}")

    notebook.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lessons", nargs="*", help="lesson ids, or nothing for all of them")
    parser.add_argument("--offline", action="store_true", help="only the half that needs no Erlang")
    parser.add_argument("--write", action="store_true", help="rewrite the recordings from this run")
    args = parser.parse_args()

    if args.offline and args.write:
        print("bake: --offline cannot write recordings, because it never runs anything")
        return 1

    try:
        chosen = lessons(args.lessons)
    except Broken as problem:
        print(f"bake: {problem}")
        return 1

    problems: list[str] = []
    notes: list[str] = []
    cell_count = 0

    for lesson in chosen:
        try:
            cells = parse(lesson / "lesson.livemd")
        except Broken as problem:
            problems.append(f"bake: {problem}")
            continue

        cell_count += len(cells)
        found = bookkeeping(lesson, cells)

        if args.offline:
            problems.extend(found)
            continue

        # A lesson whose books do not add up is not worth running, unless the
        # point of the run is to fix the books. Half of what bookkeeping reports
        # is a recording that has gone stale, and refusing to write a fresh one
        # until somebody fixes the stale one by hand is a tool arguing with the
        # person using it.
        if found and not args.write:
            problems.extend(found)
            continue

        try:
            output = produce(lesson, cells)
        except Broken as problem:
            problems.extend(found)
            problems.append(f"bake: {problem}")
            continue

        if not args.write:
            problems.extend(compare(lesson, cells, output))
            continue

        try:
            notes.extend(write(lesson, cells, output))
        except Broken as problem:
            problems.append(f"bake: {problem}")
            continue

        # Whatever writing could not fix is still a problem, and what is left is
        # the set that needs a person: a cell in no list, a recording with no
        # cell, a name in both lists.
        problems.extend(bookkeeping(lesson, parse(lesson / "lesson.livemd")))

    for note in notes:
        print(note)
    for problem in problems:
        print(problem)

    how = "checked" if args.offline else "ran"
    print(f"bake: {how} {cell_count} cells across {len(chosen)} lessons, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())

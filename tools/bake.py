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

Not every cell can be compared as it stands. A banner prints the build in front
of you and a timing cell prints wall clock times, so `meta.toml` sorts the cells
into three:

  deterministic   the output is the same everywhere, compared byte for byte
  normalised      the output is the same once the noise is filtered out
  not_compared    run so that one which stops compiling is caught, nothing more

The middle one is where most of the interesting cells end up. A cell that prints
a pid, a port, a reference, a duration, a path or a node name prints something
different every time and is still saying the same thing, so `tools/normalise`
erases those shapes and the recording holds the filtered form. The filters are
named per cell, because the shape that is noise in one lesson is the answer in
the next.

Run:
  python3 -m tools.bake              every lesson, run and compare
  python3 -m tools.bake t07 m02      only these
  python3 -m tools.bake --offline    the half that needs no Erlang
  python3 -m tools.bake --write      run and rewrite the recordings
  python3 -m tools.normalise         what the filters are
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

from tools.normalise import FILTERS, Unknown, normalise

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


@dataclass
class Plan:
    """What `meta.toml` says should happen to each cell's output."""

    deterministic: list[str]
    normalised: dict[str, list[str]]
    not_compared: list[str]

    @property
    def compared(self) -> set[str]:
        return set(self.deterministic) | set(self.normalised)

    @property
    def listed(self) -> set[str]:
        return self.compared | set(self.not_compared)

    def recorded(self, name: str, text: str) -> str:
        """What goes in `expected/`, which for a normalised cell is the filtered form."""
        return normalise(text, self.normalised.get(name, []))


def plan(lesson: Path) -> Plan:
    meta = tomllib.loads((lesson / "meta.toml").read_text(encoding="utf-8"))
    if "bake" not in meta:
        raise Broken(f"{lesson.name}: meta.toml has no [bake] section, so nothing knows what to compare")
    bake = meta["bake"]
    return Plan(
        deterministic=bake.get("deterministic", []),
        normalised=bake.get("normalised", {}),
        not_compared=bake.get("not_compared", []),
    )


def bookkeeping(lesson: Path, cells: list[Cell]) -> list[str]:
    """Everything that can be checked without running a single line of Elixir."""
    problems: list[str] = []
    try:
        sorted_into = plan(lesson)
    except Broken as problem:
        return [str(problem)]

    seen: set[str] = set()
    for cell in cells:
        if cell.name in seen:
            problems.append(f"{lesson.name}: two cells called {cell.name}, so one recording has two owners")
        seen.add(cell.name)

    lists = [
        ("deterministic", set(sorted_into.deterministic)),
        ("normalised", set(sorted_into.normalised)),
        ("not compared", set(sorted_into.not_compared)),
    ]
    for index, (name, names) in enumerate(lists):
        for other, others in lists[index + 1 :]:
            for both in sorted(names & others):
                problems.append(f"{lesson.name}: {both} is listed as {name} and as {other}")

    for name in sorted(seen - sorted_into.listed):
        problems.append(f"{lesson.name}: cell {name} is in the notebook and in no list in meta.toml")
    for name in sorted(sorted_into.listed - seen):
        problems.append(f"{lesson.name}: meta.toml lists {name} and the notebook has no such cell")

    # A filter that does not exist is a typo, and a typo in a filter name would
    # otherwise pass silently as a cell nobody normalises. A cell that has one is
    # left out of everything below, because there is no honest way to filter its
    # output until somebody fixes the name.
    misspelt: set[str] = set()
    for name, wanted in sorted(sorted_into.normalised.items()):
        for filter_name in wanted:
            if filter_name not in FILTERS:
                misspelt.add(name)
                problems.append(
                    f"{lesson.name}: {name} asks for a filter called {filter_name}, "
                    f"and there is no such filter. There are {', '.join(sorted(FILTERS))}"
                )

    recordings = {p.stem for p in (lesson / "expected").glob("*.txt")}
    for name in sorted(sorted_into.compared - recordings):
        problems.append(f"{lesson.name}: {name} is compared and has no expected/{name}.txt")
    for name in sorted(recordings - sorted_into.compared):
        problems.append(f"{lesson.name}: expected/{name}.txt belongs to no cell that is compared")

    # A filter named for a cell it does nothing to is a filter somebody copied
    # from another lesson. It lies about why the cell is in the normalised list,
    # and the cost is that a reader of `meta.toml` learns something untrue about
    # the output.
    #
    # Asking whether it fired means looking for the mark it leaves, because the
    # recording is the filtered form and the noise it erased is long gone by the
    # time anybody reads it. That also keeps this checkable with no Erlang on the
    # machine, which is the whole point of the offline half.
    for name, wanted in sorted(sorted_into.normalised.items()):
        recording = lesson / "expected" / f"{name}.txt"
        if name in misspelt or not recording.exists():
            continue
        text = recording.read_text(encoding="utf-8")
        for filter_name in wanted:
            if filter_name in FILTERS and FILTERS[filter_name].mark not in text:
                problems.append(
                    f"{lesson.name}: {name} asks for the {filter_name} filter and "
                    f"there is nothing in its output for that filter to erase"
                )

    # The lesson prints the output under most cells so it can be read on a train.
    # If that printed copy and the recording disagree then one of the two is
    # lying to somebody, and the reader is the one who cannot tell. For a
    # normalised cell the printed copy is the raw output from a real machine,
    # because a reader wants to see a duration rather than the word TIME, so the
    # two are compared through the filters.
    for cell in cells:
        if cell.name not in sorted_into.compared or cell.shown is None:
            continue
        if cell.name in misspelt:
            continue
        recording = lesson / "expected" / f"{cell.name}.txt"
        if not recording.exists():
            continue
        if recording.read_text(encoding="utf-8") != sorted_into.recorded(cell.name, cell.shown):
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
    sorted_into = plan(lesson)
    problems: list[str] = []

    for cell in cells:
        if cell.name not in sorted_into.compared:
            continue
        got = sorted_into.recorded(cell.name, output[cell.name])
        recording = lesson / "expected" / f"{cell.name}.txt"
        recorded = recording.read_text(encoding="utf-8")
        if got != recorded:
            problems.append(f"{lesson.name}: {cell.name} printed something else")
            problems.append(difference(cell.name, recorded, got))

    return problems


def write(lesson: Path, cells: list[Cell], output: dict[str, str]) -> list[str]:
    """Rewrite the recordings, and the copy the lesson shows, from this run."""
    sorted_into = plan(lesson)
    changed: list[str] = []

    notebook = lesson / "lesson.livemd"
    lines = notebook.read_text(encoding="utf-8").splitlines()

    # Backwards, so that replacing one block does not move the line numbers of
    # the blocks that have not been replaced yet.
    for cell in reversed(cells):
        if cell.name not in sorted_into.compared:
            continue
        got = output[cell.name]

        # The recording holds the filtered form and the lesson holds the raw
        # form, so a reader sees what a machine really printed and CI compares
        # the part of it that does not move.
        recording = lesson / "expected" / f"{cell.name}.txt"
        fresh = sorted_into.recorded(cell.name, got)
        if not recording.exists() or recording.read_text(encoding="utf-8") != fresh:
            recording.write_text(fresh, encoding="utf-8")
            changed.append(f"{lesson.name}: rewrote expected/{cell.name}.txt")

        if cell.span is not None:
            start, close = cell.span
            shown = got.rstrip("\n").split("\n")
            if lines[start:close] != shown:
                lines[start:close] = shown
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
        except (Broken, Unknown) as problem:
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

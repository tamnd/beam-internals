"""The corpus manifest, checked against the corpus.

An artefact with no entry in `corpora/manifest.toml` is not evidence, it is a
file somebody found. This checks that in both directions: every entry names a
file that is there, and every file that is there has an entry.

Then it checks the entry is true. The size and the sha256 have to match the
bytes on disk, so an artefact cannot be replaced without the manifest saying
so. And a tape carries the same provenance in its own header, written by the
recorder at the moment of recording, so the manifest and the tape are compared
field by field. A manifest that says a tape came from x86_64 when the tape says
aarch64 is caught here rather than by a reader wondering why the numbers look
wrong.

Run: python3 -m tools.corpus
"""

from __future__ import annotations

import gzip
import hashlib
import re
import tomllib
from pathlib import Path

from tools import erlterm

CORPORA = Path("corpora")
MANIFEST = CORPORA / "manifest.toml"
LESSONS = Path("lessons")

# Files under corpora that are the corpus talking about itself rather than
# recorded output.
NOT_ARTEFACTS = {"manifest.toml", "README.md"}

# Inputs live here. They are hand written rather than recorded, so they get the
# lighter schema: what it is for and what was recorded from it.
SOURCES = "src"

ARTEFACT_FIELDS = [
    "path",
    "produced_by",
    "kind",
    "flavor",
    "arch",
    "os",
    "build",
    "recorded",
    "by_whom",
    "why",
    "needed_by",
    "bytes",
    "sha256",
]
SOURCE_FIELDS = ["path", "why", "used_by"]

FLAVORS = {"emu", "jit"}
ARCHES = {"x86_64", "aarch64"}

TAG = re.compile(r"^OTP-\d+\.\d+(\.\d+)?$")
ERTS = re.compile(r"^\d+\.\d+(\.\d+)?$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
LESSON_ID = re.compile(r"^(o|t|m|s)\d{2}$|^c[abc]\d$")
BLUEPRINT_REF = re.compile(r"^BP-[A-Z]+-\d{3}$")


def check(data: dict) -> tuple[list[str], dict]:
    problems: list[str] = []
    artefacts = data.get("artefact", [])
    sources = data.get("source", [])
    defaults = data.get("defaults", {})

    seen: set[str] = set()
    ahead = 0

    for index, entry in enumerate(artefacts):
        name = entry.get("path", f"artefact {index}")
        row = defaults | entry

        for field in ARTEFACT_FIELDS:
            if field not in entry:
                problems.append(f"{name}: missing {field}")

        if "path" in entry:
            if entry["path"] in seen:
                problems.append(f"{name}: listed twice")
            seen.add(entry["path"])
            problems += check_path(name, entry["path"], artefact=True)

        problems += check_build(name, row)
        problems += check_bytes(name, row)

        for lesson in entry.get("needed_by", []):
            if LESSON_ID.match(lesson):
                if not list(LESSONS.glob(f"*/{lesson}")):
                    ahead += 1
            elif not BLUEPRINT_REF.match(lesson):
                problems.append(f"{name}: needed_by {lesson!r} is not a lesson id or BP-AREA-000")
        if not entry.get("needed_by"):
            problems.append(f"{name}: nothing declares it needs this")

    problems += check_sources(sources, seen)
    problems += check_coverage(seen, {s.get("path") for s in sources})

    return problems, {"artefacts": len(artefacts), "sources": len(sources), "ahead": ahead}


def check_path(name: str, path: str, artefact: bool) -> list[str]:
    if path.startswith("/") or ".." in Path(path).parts:
        return [f"{name}: path has to be relative to corpora and stay inside it"]
    on_disk = CORPORA / path
    if not on_disk.is_file():
        return [f"{name}: nothing at corpora/{path}"]
    inside_sources = Path(path).parts[0] == SOURCES
    if artefact and inside_sources:
        return [f"{name}: corpora/{SOURCES} holds inputs, so this belongs under [[source]]"]
    if not artefact and not inside_sources:
        return [f"{name}: a source belongs under corpora/{SOURCES}"]
    return []


def check_build(name: str, row: dict) -> list[str]:
    problems = []
    if row.get("flavor") not in FLAVORS | {None}:
        problems.append(f"{name}: flavor {row.get('flavor')!r} is not one of {sorted(FLAVORS)}")
    if row.get("arch") not in ARCHES | {None}:
        problems.append(f"{name}: arch {row.get('arch')!r} is not one of {sorted(ARCHES)}")
    if "tag" in row and not TAG.match(str(row["tag"])):
        problems.append(f"{name}: tag {row['tag']!r} should look like OTP-29.0.5")
    if "erts" in row and not ERTS.match(str(row["erts"])):
        problems.append(f"{name}: erts {row['erts']!r} should look like 17.0.5")
    if "recorded" in row and not DATE.match(str(row["recorded"])):
        problems.append(f"{name}: recorded {row['recorded']!r} should look like 2026-09-05")
    if "sha256" in row and not SHA256.match(str(row["sha256"])):
        problems.append(f"{name}: sha256 {row['sha256']!r} is not sixty four hex characters")
    if not str(row.get("produced_by", "")).strip():
        problems.append(f"{name}: produced_by has to be the command, runnable, not a description of one")
    return problems


def check_bytes(name: str, row: dict) -> list[str]:
    path = row.get("path")
    if not path:
        return []
    on_disk = CORPORA / path
    if not on_disk.is_file():
        return []

    problems = []
    raw = on_disk.read_bytes()
    if "bytes" in row and row["bytes"] != len(raw):
        problems.append(f"{name}: the manifest says {row['bytes']} bytes and the file is {len(raw)}")
    digest = hashlib.sha256(raw).hexdigest()
    if "sha256" in row and row["sha256"] != digest:
        problems.append(
            f"{name}: the file has changed since the manifest was written, sha256 is now {digest}"
        )

    if path.endswith(".tape.gz"):
        problems += check_tape(name, row, on_disk)
    return problems


# A tape says the same things about itself that the manifest says about it,
# because the recorder wrote them at the moment of recording. Every pair here
# is a way for a manifest to be wrong that nobody would otherwise notice.
def check_tape(name: str, row: dict, path: Path) -> list[str]:
    try:
        header = tape_header(path)
    except (OSError, erlterm.TermError) as problem:
        return [f"{name}: the tape header will not read, {problem}"]

    problems = []

    def says(field: str) -> str:
        value = header.get(field)
        return value.decode("utf-8") if isinstance(value, bytes) else str(value)

    if "kind" in row and says("kind") != row["kind"]:
        problems.append(f"{name}: the manifest says kind {row['kind']} and the tape says {says('kind')}")
    if "flavor" in row and says("flavor") != row["flavor"]:
        problems.append(
            f"{name}: the manifest says flavor {row['flavor']} and the tape says {says('flavor')}"
        )
    if "by_whom" in row and says("by_whom") != row["by_whom"]:
        problems.append(
            f"{name}: the manifest says {row['by_whom']} recorded it and the tape says {says('by_whom')}"
        )
    if "erts" in row and says("erts") != str(row["erts"]):
        problems.append(f"{name}: the manifest says erts {row['erts']} and the tape says {says('erts')}")

    # The tape holds the full architecture triple and the manifest holds the
    # instruction set on its own, so this is a prefix rather than an equality.
    if "arch" in row and not says("arch").startswith(row["arch"] + "-"):
        problems.append(f"{name}: the manifest says arch {row['arch']} and the tape says {says('arch')}")

    # Likewise the tape holds the release and the manifest holds the tag it was
    # cut from, so OTP-29.0.5 has to agree with 29.
    if "tag" in row and not str(row["tag"]).startswith(f"OTP-{says('otp')}."):
        problems.append(f"{name}: the manifest says {row['tag']} and the tape says OTP {says('otp')}")

    # And the tape holds the moment while the manifest holds the day.
    if "recorded" in row and not says("recorded").startswith(str(row["recorded"])):
        problems.append(
            f"{name}: the manifest says recorded {row['recorded']} and the tape says {says('recorded')}"
        )

    return problems


def tape_header(path: Path) -> dict:
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        for line in handle:
            text = line.strip()
            if not text or text.startswith("%%"):
                continue
            return erlterm.parse(text)
    raise erlterm.TermError("the tape has no header")


def check_sources(sources: list[dict], artefacts: set[str]) -> list[str]:
    problems: list[str] = []
    seen: set[str] = set()
    for index, entry in enumerate(sources):
        name = entry.get("path", f"source {index}")
        for field in SOURCE_FIELDS:
            if field not in entry:
                problems.append(f"{name}: missing {field}")
        if "path" in entry:
            if entry["path"] in seen:
                problems.append(f"{name}: listed twice")
            seen.add(entry["path"])
            problems += check_path(name, entry["path"], artefact=False)
        used_by = entry.get("used_by", [])
        if not used_by:
            problems.append(f"{name}: nothing was recorded from this, so it is not an input to anything")
        for target in used_by:
            if target not in artefacts:
                problems.append(
                    f"{name}: used_by names {target!r}, which is not an artefact in this manifest"
                )
    return problems


def check_coverage(artefacts: set[str], sources: set[str | None]) -> list[str]:
    problems = []
    for path in sorted(CORPORA.rglob("*")):
        if not path.is_file() or path.name.startswith("."):
            continue
        relative = path.relative_to(CORPORA).as_posix()
        if relative in NOT_ARTEFACTS:
            continue
        if relative in artefacts or relative in sources:
            continue
        if Path(relative).parts[0] == SOURCES:
            problems.append(f"corpora/{relative}: an input with no [[source]] entry saying what it is for")
        else:
            problems.append(f"corpora/{relative}: a file with no entry, so it is not evidence")
    return problems


def main() -> int:
    if not MANIFEST.exists():
        print(f"corpus: {MANIFEST} is missing")
        return 1

    with MANIFEST.open("rb") as handle:
        data = tomllib.load(handle)

    problems, counts = check(data)
    for problem in problems:
        print(problem)

    ahead = counts["ahead"]
    note = f", {ahead} recorded ahead of the lesson that needs them" if ahead else ""
    print(
        f"corpus: {counts['artefacts']} artefacts, {counts['sources']} sources{note}, "
        f"{len(problems)} problems"
    )
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())

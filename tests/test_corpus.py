"""The corpus manifest checker.

The manifest is the difference between evidence and a file somebody found, so
the thing worth testing is every way it can end up describing something other
than what is on disk: a file that was replaced, a file that was truncated, a
file nobody declared, an entry with nothing behind it, and a tape whose own
header disagrees with the row that claims to describe it.
"""

from __future__ import annotations

import gzip
import hashlib
from pathlib import Path

import pytest

from tools import corpus

TAPE = (
    '#{schema => 1, kind => reds, otp => <<"29">>, erts => <<"17.0.5">>, '
    'arch => <<"aarch64-apple-darwin24.6.0">>, flavor => jit, '
    'by_whom => <<"tamnd">>, recorded => <<"2026-09-05T10:00:00Z">>}.'
)


@pytest.fixture
def corpora(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    root = tmp_path / "corpora"
    (root / "traces").mkdir(parents=True)
    (root / "src").mkdir()
    monkeypatch.setattr(corpus, "CORPORA", root)
    monkeypatch.setattr(corpus, "LESSONS", tmp_path / "lessons")
    return root


def write_tape(root: Path, name: str = "traces/one.tape.gz") -> Path:
    path = root / name
    with gzip.open(path, "wt", encoding="utf-8") as handle:
        handle.write("%% bxtrace tape, schema 1, kind reds\n")
        handle.write(TAPE + "\n")
        handle.write("{'$tape_end', 0}.\n")
    return path


def entry(file: Path, **overrides: object) -> dict:
    raw = file.read_bytes()
    row = {
        "path": file.name if file.parent.name == "corpora" else f"{file.parent.name}/{file.name}",
        "produced_by": "./bxtrace/record.escript one",
        "kind": "reds",
        "flavor": "jit",
        "arch": "aarch64",
        "os": "darwin 24.6.0",
        "build": "opt",
        "recorded": "2026-09-05",
        "by_whom": "tamnd",
        "why": "the opening figure for t07",
        "needed_by": ["t07"],
        "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }
    row.update(overrides)
    return row


def manifest(artefacts: list[dict], sources: list[dict] | None = None) -> dict:
    return {
        "defaults": {"tag": "OTP-29.0.5", "erts": "17.0.5"},
        "artefact": artefacts,
        "source": sources or [],
    }


def problems(data: dict) -> list[str]:
    found, _ = corpus.check(data)
    return found


def test_a_complete_entry_passes(corpora: Path) -> None:
    tape = write_tape(corpora)
    assert problems(manifest([entry(tape)])) == []


def test_a_missing_field_is_caught(corpora: Path) -> None:
    tape = write_tape(corpora)
    row = entry(tape)
    del row["by_whom"]
    assert any("by_whom" in problem for problem in problems(manifest([row])))


def test_a_replaced_file_is_caught(corpora: Path) -> None:
    tape = write_tape(corpora)
    row = entry(tape)
    tape.write_bytes(tape.read_bytes() + b"\n")
    assert any("changed since the manifest" in problem for problem in problems(manifest([row])))


def test_a_truncated_file_is_caught(corpora: Path) -> None:
    tape = write_tape(corpora)
    assert any("bytes and the file is" in problem for problem in problems(manifest([entry(tape, bytes=99)])))


def test_an_entry_with_nothing_behind_it_is_caught(corpora: Path) -> None:
    tape = write_tape(corpora)
    row = entry(tape)
    tape.unlink()
    assert any("nothing at corpora/" in problem for problem in problems(manifest([row])))


def test_a_file_nobody_declared_is_caught(corpora: Path) -> None:
    write_tape(corpora)
    (corpora / "traces" / "stray.txt").write_text("where did this come from\n")
    assert any("not evidence" in problem for problem in problems(manifest([])))


def test_the_same_path_twice_is_caught(corpora: Path) -> None:
    tape = write_tape(corpora)
    assert any("listed twice" in problem for problem in problems(manifest([entry(tape), entry(tape)])))


def test_a_path_that_leaves_the_corpus_is_caught(corpora: Path) -> None:
    tape = write_tape(corpora)
    assert problems(manifest([entry(tape, path="../secrets")])) != []


def test_an_artefact_under_src_is_caught(corpora: Path) -> None:
    source = corpora / "src" / "l1.erl"
    source.write_text("-module(l1).\n")
    assert any("belongs under [[source]]" in problem for problem in problems(manifest([entry(source)])))


def test_an_unknown_arch_or_flavor_is_caught(corpora: Path) -> None:
    tape = write_tape(corpora)
    assert problems(manifest([entry(tape, arch="sparc")])) != []
    assert problems(manifest([entry(tape, flavor="turbo")])) != []


def test_needed_by_has_to_name_something(corpora: Path) -> None:
    tape = write_tape(corpora)
    assert any("nothing declares it needs this" in p for p in problems(manifest([entry(tape, needed_by=[])])))
    named = problems(manifest([entry(tape, needed_by=["chapter four"])]))
    assert any("is not a lesson id" in p for p in named)


# The part a hand written manifest cannot be trusted on. The recorder wrote
# these fields into the tape at the moment of recording, so a row that says
# something else is a row that was edited afterwards.
@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("kind", "pass"),
        ("flavor", "emu"),
        ("arch", "x86_64"),
        ("by_whom", "somebody else"),
        ("erts", "17.0.4"),
        ("recorded", "2026-01-01"),
    ],
)
def test_a_row_that_disagrees_with_the_tape_is_caught(corpora: Path, field: str, value: str) -> None:
    tape = write_tape(corpora)
    found = problems(manifest([entry(tape, **{field: value})]))
    assert any("the tape says" in problem for problem in found), found


def test_a_tag_that_disagrees_with_the_tape_is_caught(corpora: Path) -> None:
    tape = write_tape(corpora)
    data = manifest([entry(tape)])
    data["defaults"]["tag"] = "OTP-28.3.1"
    assert any("the tape says OTP 29" in problem for problem in problems(data))


def test_a_tape_that_will_not_read_is_caught(corpora: Path) -> None:
    tape = write_tape(corpora)
    row = entry(tape)
    with gzip.open(tape, "wt", encoding="utf-8") as handle:
        handle.write("%% bxtrace tape\n#{schema => 1\n")
    row["bytes"] = tape.stat().st_size
    row["sha256"] = hashlib.sha256(tape.read_bytes()).hexdigest()
    assert any("will not read" in problem for problem in problems(manifest([row])))


def test_a_source_nothing_was_recorded_from_is_caught(corpora: Path) -> None:
    (corpora / "src" / "l1.erl").write_text("-module(l1).\n")
    source = {"path": "src/l1.erl", "why": "an input", "used_by": []}
    assert any("not an input to anything" in problem for problem in problems(manifest([], [source])))


def test_a_source_pointing_at_an_artefact_that_is_not_there_is_caught(corpora: Path) -> None:
    (corpora / "src" / "l1.erl").write_text("-module(l1).\n")
    source = {"path": "src/l1.erl", "why": "an input", "used_by": ["passes/gone.tape.gz"]}
    assert any("is not an artefact" in problem for problem in problems(manifest([], [source])))


def test_an_input_with_no_source_entry_is_caught(corpora: Path) -> None:
    (corpora / "src" / "l1.erl").write_text("-module(l1).\n")
    assert any("no [[source]] entry" in problem for problem in problems(manifest([])))


def test_a_source_and_the_artefact_recorded_from_it_pass_together(corpora: Path) -> None:
    tape = write_tape(corpora)
    (corpora / "src" / "l1.erl").write_text("-module(l1).\n")
    source = {"path": "src/l1.erl", "why": "an input", "used_by": ["traces/one.tape.gz"]}
    assert problems(manifest([entry(tape)], [source])) == []


# An artefact recorded for a lesson that has not been written yet is allowed,
# because the recording has to exist before the lesson can be graded against
# it. It is counted rather than hidden, so the debt stays visible.
def test_recording_ahead_of_the_lesson_is_counted_not_refused(corpora: Path) -> None:
    tape = write_tape(corpora)
    found, counts = corpus.check(manifest([entry(tape, needed_by=["m34"])]))
    assert found == []
    assert counts["ahead"] == 1

"""The claim ledger checker.

The ledger is the record of what this book asserts about the runtime and how
each assertion was checked. The caps are the part worth testing, because they
are what stops a lesson from quietly filling up with things that were shown once
on one machine and never checked again.
"""

from __future__ import annotations

import tomllib
from pathlib import Path

from tools import ledger

BASE = {
    "id": "CLM-SCHED-0001",
    "text": "A process gets 4000 reductions before the scheduler takes the core back.",
    "where": ["m14"],
    "evidence": "observed",
    "by": ["cell:m14/reduction-budget"],
    "verified": "2026-09-02",
    "by_whom": "tamnd",
}


def claim(**overrides: object) -> dict:
    merged = dict(BASE)
    merged.update(overrides)
    return merged


def test_a_complete_claim_passes() -> None:
    assert ledger.validate([claim()]) == []


def test_a_missing_field_is_rejected() -> None:
    incomplete = claim()
    del incomplete["by_whom"]
    assert any("by_whom" in problem for problem in ledger.validate([incomplete]))


def test_a_malformed_id_is_rejected() -> None:
    assert ledger.validate([claim(id="CLM-1")]) != []


def test_an_unknown_evidence_class_is_rejected() -> None:
    assert ledger.validate([claim(evidence="seems right")]) != []


def test_an_observed_claim_needs_a_cell() -> None:
    problems = ledger.validate([claim(by=["erts/emulator/beam/erl_vm.h:56@OTP-29.0.5"])])
    assert problems != []


def test_a_contractual_claim_needs_a_citation() -> None:
    problems = ledger.validate([claim(id="CLM-DIST-0001", evidence="contractual", by=["the docs say so"])])
    assert problems != []


def test_demonstrated_only_is_capped_per_lesson() -> None:
    claims = [
        claim(id=f"CLM-SCHED-000{n}", evidence="demonstrated-only", by=["cell:m14/x"]) for n in range(1, 5)
    ]
    assert any("demonstrated-only" in problem for problem in ledger.validate(claims))


def test_the_committed_ledger_is_valid() -> None:
    with Path("blueprints/ledger.toml").open("rb") as handle:
        data = tomllib.load(handle)
    assert ledger.validate(data["claim"]) == []

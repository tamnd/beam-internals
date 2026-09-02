"""The claim ledger, checked.

Every claim has an entry, every entry declares an evidence class, and the two
weak classes are capped per lesson. Without the caps, "we ran it a thousand
times" becomes the default evidence for every ordering claim in the project,
which is how the folklore this book corrects got made in the first place.

Run: python3 -m tools.ledger
"""

from __future__ import annotations

import re
import tomllib
from collections import Counter
from pathlib import Path

LEDGER = Path("blueprints/ledger.toml")

CLASSES = {"observed", "proved", "contractual", "demonstrated-only", "unobservable"}
CAPS = {"demonstrated-only": 2, "unobservable": 3}

REQUIRED = ["id", "text", "where", "evidence", "by", "verified", "by_whom"]

CLAIM_ID = re.compile(r"^CLM-[A-Z]+-\d{4}$")
LESSON_ID = re.compile(r"^(o|t|m|s)\d{2}$|^c[abc]\d$")
BLUEPRINT_REF = re.compile(r"^BP-[A-Z]+-\d{3}#\d$")


def validate(claims: list[dict]) -> list[str]:
    problems: list[str] = []
    seen: set[str] = set()
    per_lesson: Counter[tuple[str, str]] = Counter()

    for index, claim in enumerate(claims):
        name = claim.get("id", f"entry {index}")

        for field in REQUIRED:
            if field not in claim:
                problems.append(f"{name}: missing {field}")

        if "id" in claim and not CLAIM_ID.match(claim["id"]):
            problems.append(f"{name}: id should look like CLM-AREA-0001")
        if claim.get("id") in seen:
            problems.append(f"{name}: duplicate id")
        seen.add(claim.get("id", ""))

        evidence = claim.get("evidence")
        if evidence not in CLASSES:
            problems.append(f"{name}: evidence {evidence!r} is not one of {sorted(CLASSES)}")

        if not claim.get("by"):
            problems.append(f"{name}: evidence class {evidence} with nothing in `by`")

        # A cell in a lesson and a case in a conformance suite are both somebody
        # running the thing and writing down what came back, so both count as
        # having observed it. A case is the stronger of the two, because it runs
        # in CI on every change and a lesson cell runs when a reader opens the
        # notebook, but requiring a cell would mean a claim can only be observed
        # if it happens to be interesting enough to teach.
        if evidence == "observed" and not any(
            str(item).startswith(("cell:", "case:")) for item in claim.get("by", [])
        ):
            problems.append(f"{name}: observed, so `by` has to name a lesson cell or a conformance case")

        if evidence == "contractual" and not any("@OTP-" in str(item) for item in claim.get("by", [])):
            problems.append(f"{name}: contractual, so `by` has to name a cited document")

        for place in claim.get("where", []):
            if LESSON_ID.match(place):
                if evidence in CAPS:
                    per_lesson[(place, evidence)] += 1
            elif not BLUEPRINT_REF.match(place):
                problems.append(f"{name}: `where` entry {place!r} is not a lesson id or BP-X-000#N")

    for (lesson, evidence), count in sorted(per_lesson.items()):
        cap = CAPS[evidence]
        if count > cap:
            problems.append(f"{lesson}: {count} {evidence} claims, the cap is {cap}")

    return problems


def main() -> int:
    if not LEDGER.exists():
        print(f"ledger: {LEDGER} is missing")
        return 1

    with LEDGER.open("rb") as handle:
        data = tomllib.load(handle)

    claims = data.get("claim", [])
    problems = validate(claims)

    for problem in problems:
        print(problem)

    counts = Counter(claim.get("evidence") for claim in claims)
    summary = ", ".join(f"{k} {v}" for k, v in sorted(counts.items()) if k)
    print(f"ledger: {len(claims)} claims ({summary}), {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())

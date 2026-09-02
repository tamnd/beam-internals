"""The repository itself, checked the way a reader would find it broken.

These are not unit tests of a function, they are assertions about the state of
the repository that would otherwise only be caught by somebody noticing. A label
referenced from a workflow that does not exist in the label file is the sort of
thing that fails once, at three in the morning, in a scheduled job nobody is
watching.
"""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

from tools import bplint, labels

WORKFLOWS = sorted(Path(".github/workflows").glob("*.yml"))


def test_there_are_workflows() -> None:
    assert WORKFLOWS


def test_every_action_is_pinned_to_a_commit() -> None:
    unpinned: list[str] = []
    for path in WORKFLOWS:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            match = re.search(r"uses:\s*(\S+)", line)
            if not match or match.group(1).startswith("./"):
                continue
            if not re.search(r"@[0-9a-f]{40}\b", match.group(1)):
                unpinned.append(f"{path}:{number}: {match.group(1)}")
    assert unpinned == []


def test_every_pinned_action_says_which_release_it_is() -> None:
    missing: list[str] = []
    for path in WORKFLOWS:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if "uses:" in line and re.search(r"@[0-9a-f]{40}", line) and "#" not in line:
                missing.append(f"{path}:{number}")
    assert missing == []


def test_every_workflow_declares_permissions_and_a_timeout() -> None:
    for path in WORKFLOWS:
        text = path.read_text(encoding="utf-8")
        assert "permissions:" in text, f"{path} does not declare permissions"
        assert "timeout-minutes:" in text, f"{path} has a job with no timeout"


def test_every_label_a_workflow_applies_exists() -> None:
    known = {label["name"] for label in labels.parse(Path(".github/labels.yml").read_text())}
    used: set[str] = set()
    for path in WORKFLOWS:
        used.update(re.findall(r"--label (\S+)", path.read_text(encoding="utf-8")))
    assert used <= known, f"workflows apply labels that are not defined: {sorted(used - known)}"


def test_every_label_an_issue_template_applies_exists() -> None:
    known = {label["name"] for label in labels.parse(Path(".github/labels.yml").read_text())}
    used: set[str] = set()
    for path in Path(".github/ISSUE_TEMPLATE").glob("*.yml"):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("labels:"):
                used.update(re.findall(r'"([^"]+)"', line))
    assert used <= known, f"templates apply labels that are not defined: {sorted(used - known)}"


def test_the_label_file_is_valid() -> None:
    parsed = labels.parse(Path(".github/labels.yml").read_text())
    assert labels.validate(parsed) == []


def test_the_drift_watchlist_and_the_pin_agree_on_the_upstream_repo() -> None:
    with Path("drift.toml").open("rb") as handle:
        drift = tomllib.load(handle)
    with Path("refcheck.toml").open("rb") as handle:
        pin = tomllib.load(handle)["pin"]
    assert pin["upstream"].endswith(drift["upstream"]["repo"])


def test_every_watched_file_says_why_it_is_watched() -> None:
    with Path("drift.toml").open("rb") as handle:
        drift = tomllib.load(handle)
    for watch in drift["watch"]:
        assert watch.get("why"), f"{watch['file']} is watched with no reason recorded"


def test_the_blueprint_template_passes_the_blueprint_checker() -> None:
    template = Path("blueprints/_template.md")
    assert template.exists()
    assert bplint.check(template) == []


def test_the_licences_are_both_present() -> None:
    for name in ("LICENSE-CODE.txt", "LICENSE-CONTENT.txt", "NOTICE"):
        assert Path(name).read_text(encoding="utf-8").strip()

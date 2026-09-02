"""Watch Erlang/OTP for the changes that would make this book wrong.

Two things get checked. Whether a release newer than the pin exists, and whether
any of the files in drift.toml has moved away from what it said when a person
last read it. The second one is the useful half, because a new opcode or a
spent term tag changes blueprints and lessons whether or not anybody bumps the
pin.

Writes a markdown report to stdout and exits 1 when something moved, so the
workflow can turn that into an issue. It never edits content.

Run: python3 -m tools.drift
"""

from __future__ import annotations

import json
import os
import re
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.github.com"
RAW = "https://raw.githubusercontent.com"


def fetch(url: str, accept: str = "application/vnd.github+json") -> bytes:
    request = urllib.request.Request(url, headers={"Accept": accept, "User-Agent": "beam-internals-drift"})
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def newer_tags(repo: str, pin: str) -> list[str]:
    data = json.loads(fetch(f"{API}/repos/{repo}/tags?per_page=100"))
    names = [tag["name"] for tag in data if tag["name"].startswith("OTP-")]
    if pin not in names:
        return [n for n in names[:5]]
    return names[: names.index(pin)]


def measure(text: str, watch: dict) -> str:
    kind = watch["kind"]
    if kind == "lines":
        return str(len(text.splitlines()))
    if kind == "count":
        return str(len(re.findall(watch["pattern"], text, re.MULTILINE)))
    if kind == "value":
        found = re.search(watch["pattern"], text)
        return found.group(1) if found else "not found"
    raise ValueError(f"unknown watch kind {kind}")


def main() -> int:
    config = tomllib.loads(Path("drift.toml").read_text(encoding="utf-8"))
    pin = tomllib.loads(Path("refcheck.toml").read_text(encoding="utf-8"))["pin"]

    upstream = config["upstream"]
    repo = upstream["repo"]
    branch = upstream["branch"]

    lines: list[str] = []
    moved = 0

    try:
        tags = newer_tags(repo, pin["tag"])
    except urllib.error.URLError as error:
        print(f"drift: could not reach {repo}: {error}")
        return 0

    if tags:
        lines.append(f"Releases newer than the pin `{pin['tag']}`: {', '.join(f'`{t}`' for t in tags)}.")
        lines.append("")
        moved += 1

    rows = ["| File | Watching | Pinned | Now |", "| --- | --- | --- | --- |"]
    for watch in config["watch"]:
        path = watch["file"]
        try:
            text = fetch(f"{RAW}/{repo}/{branch}/{path}", accept="text/plain").decode("utf-8", "replace")
        except urllib.error.URLError as error:
            rows.append(f"| `{path}` | {watch['kind']} | {watch['expected']} | unreachable, {error} |")
            continue
        now = measure(text, watch)
        expected = str(watch["expected"])
        if now != expected:
            moved += 1
            rows.append(f"| `{path}` | {watch['kind']} | {expected} | **{now}** |")
        else:
            rows.append(f"| `{path}` | {watch['kind']} | {expected} | {now} |")

    lines.extend(rows)
    lines.append("")

    for watch in config["watch"]:
        lines.append(f"`{watch['file']}`: {watch['why']}")
        lines.append("")

    lines.append(
        f"Compared against `{repo}` branch `{branch}`. The pin is `{pin['tag']}` at `{pin['commit'][:12]}`."
    )

    print("\n".join(lines))
    return 1 if moved else 0


if __name__ == "__main__":
    raise SystemExit(main())

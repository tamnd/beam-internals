"""Render the animations, and put each still where its scene says it belongs.

Manim writes into a media directory named after the scene class and the version
of Manim that drew it, which is a sensible thing for a rendering tool to do and
a terrible name to reference from a lesson. This moves the still to the path the
scene file declares in its `STILL` constant, so a lesson links to a stable name
and the figure travels with the lesson if the lesson moves.

The video is not copied anywhere. It is large, it is generated, and a diff of an
mp4 tells a reviewer nothing, so it stays under the media directory and out of
the repository.

Run:
  python3 -m tools.figures                  every scene
  python3 -m tools.figures m02_tag_doors    one of them
  python3 -m tools.figures --still-only     skip the video, which is the slow part
"""

from __future__ import annotations

import argparse
import ast
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path("bxmanim")
MEDIA = Path("build/anim")

# The still is what ends up in the book, so it gets the higher of the two
# resolutions. The video is watched in a browser at the width of a column.
STILL_QUALITY = "-qp"
VIDEO_QUALITY = "-qh"


class Broken(Exception):
    pass


def scene_files() -> list[Path]:
    return sorted(p for p in ROOT.glob("*.py") if p.stem != "vocabulary")


def declared(path: Path) -> tuple[str, list[str]]:
    """The still path and the scene class names, read without importing Manim.

    Parsing rather than importing keeps this readable from a machine that has
    never installed the anim extra, which is every machine running `just check`.
    """
    tree = ast.parse(path.read_text(encoding="utf-8"))

    still = None
    scenes = []
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == "STILL":
                    still = ast.literal_eval(node.value)
        if isinstance(node, ast.ClassDef) and any(
            isinstance(base, ast.Name) and base.id.endswith("Scene") for base in node.bases
        ):
            scenes.append(node.name)

    if still is None:
        raise Broken(f"{path} declares no STILL, so nobody knows where its still belongs")

    moving = [name for name in scenes if not name.endswith("Still")]
    frozen = [name for name in scenes if name.endswith("Still")]

    if len(moving) != 1 or len(frozen) != 1:
        raise Broken(
            f"{path} should hold one moving scene and one ending in Still, and it holds "
            f"{moving or 'none'} and {frozen or 'none'}"
        )

    return still, [moving[0], frozen[0]]


def render(path: Path, scene: str, quality: str, save_frame: bool) -> Path:
    command = [sys.executable, "-m", "manim", "render", quality, "--media_dir", str(MEDIA)]
    if save_frame:
        command += ["-s", "--format=png"]
    command += [str(path), scene]

    finished = subprocess.run(command, capture_output=True, text=True)
    if finished.returncode != 0:
        raise Broken(f"{scene} did not render\n{finished.stdout}\n{finished.stderr}")

    where = MEDIA / ("images" if save_frame else "videos") / path.stem
    produced = sorted(where.rglob("*.png" if save_frame else "*.mp4"), key=lambda p: p.stat().st_mtime)
    if not produced:
        raise Broken(f"{scene} reported success and left nothing under {where}")
    return produced[-1]


def one(path: Path, still_only: bool) -> None:
    still, (moving, frozen) = declared(path)

    frame = render(path, frozen, STILL_QUALITY, save_frame=True)
    destination = Path(still)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(frame, destination)
    print(f"{path.stem}: still at {destination}")

    if still_only:
        return

    video = render(path, moving, VIDEO_QUALITY, save_frame=False)
    print(f"{path.stem}: video at {video}, not committed on purpose")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenes", nargs="*", help="scene file stems, or nothing for all of them")
    parser.add_argument("--still-only", action="store_true", help="skip the video")
    args = parser.parse_args()

    files = scene_files()
    if args.scenes:
        wanted = set(args.scenes)
        files = [p for p in files if p.stem in wanted]
        missing = wanted - {p.stem for p in files}
        if missing:
            print(f"no such scene file: {', '.join(sorted(missing))}")
            return 1

    if not files:
        print(f"no scene files under {ROOT}")
        return 1

    for path in files:
        try:
            one(path, args.still_only)
        except Broken as problem:
            print(problem)
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

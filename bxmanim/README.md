# bxmanim

The animation vocabulary, built on Manim Community Edition.

The vocabulary is fixed on purpose. A word means the same thing in every animation in the book, so a reader learns the notation once rather than re-reading a legend in each figure. New shapes and new colours are a change to the vocabulary and get argued about as such.

Scenes are committed. Rendered video is not, because it is large, it is generated, and a diff of an mp4 tells a reviewer nothing.

Every animation needs a still that carries the same information, for print, for a slow connection, and for anybody who cannot watch a moving image. The still is not a courtesy, it is part of the figure.

## Rendering

```
just setup-anim                 install Manim, which just setup deliberately does not
just anim m02_tag_doors         the video and the still
just anim-still m02_tag_doors   the still on its own, which takes seconds
just anim-all                   every scene, after a change to the vocabulary
```

The still lands at the path the scene file declares in its `STILL` constant, which is next to the lesson that shows it. Manim writes into a directory named after the scene class and its own version number, which is a reasonable thing for a rendering tool to do and a terrible name for a lesson to link to, so `tools/figures.py` moves it.

Manim is not in the `dev` extra. It is the heaviest dependency in the repository, nothing in `just check` needs it, and a contributor fixing a typo in a lesson should not wait for it to build.

## The shape of a scene file

One file per figure, holding exactly two scenes and one constant.

```python
STILL = "lessons/02-terms/m02/files/tag-doors.png"

class TagDoors(Scene): ...       # the moving one
class TagDoorsStill(Scene): ...  # the still, whose name ends in Still
```

`tests/test_figures.py` enforces that shape and checks that the declared still is committed. The rule about stills used to live in the paragraph above and nowhere else, which meant it held for as long as somebody remembered it.

The still is not a frame grabbed out of the video. It is built from the same vocabulary calls, so the two cannot end up in different notations, and it is laid out for a reader who will never see the moving one.

## The vocabulary

`vocabulary.py` holds the palette and the shapes. The palette is Open Color, the same swatches the Excalidraw figures use, so a still drawn by hand and a still rendered by Manim look like they came from the same book.

Colour says what a term costs.

| Colour | Meaning |
| --- | --- |
| Blue | A header word, which is not a term at all |
| Green | A pointer, so there is heap at the other end |
| Orange | An immediate that spends four bits on its tag |
| Grape | An immediate that spends six |
| Grey | Payload, the part of the word that carries the value |
| Amber | A mask, and in motion the mask being applied right now |

Every string goes through `label` or `mono`, which lay out at one large point size and scale the result down. Pango loses most of the width of a space at small sizes, so text built directly at font size 17 reads as "whatisleftoftheword", and the way you find that out is that somebody tells you the captions look wrong.

## What exists

| Scene | Lesson | What it shows |
| --- | --- | --- |
| `m02_tag_doors` | `m02` | The tag tree, two bits at a time, and how wide each kind of tag ends up |

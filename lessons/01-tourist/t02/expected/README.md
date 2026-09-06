# Recorded output for t02

One file per cell, named after the `<!-- cell: name -->` marker above it in `lesson.livemd`. They are written by `just bake --write` and compared by `just bake`, so nothing here was typed by a person reading a screen.

Seven cells, all seven compared. Five of them are compared as they came out and two are compared through a filter from `tools/normalise`.

`banner.txt` goes through `build-flags`, because the emulator's build line carries this machine's scheduler counts and whichever optional features it was built with. What is left is the release, the compiler version and the word size. The compiler version is the one that matters here: the pass count belongs to the compiler application, not to the emulator, so this file is what fails first when the compiler moves.

`module.txt` goes through `paths`, because a temporary directory is different on every machine and on every operating system. The byte count on the same line is not filtered and is worth comparing.

`erlc-time.txt` is the point of the lesson. Thirty three names in the order the compiler ran them, the three that carry sub passes, and the totals. Every one of those numbers is a fact about the compiler version in `banner.txt` and about nothing else, which is why they can be compared byte for byte across two architectures.

`shapes.txt` records word counts, and a word is eight bytes on every machine this was verified on. On a 32 bit build the same forms would give different figures and the comparison would fail, correctly, because the lesson says 64 bit in its first paragraph.

`catch-me.txt` records a rejection, on purpose. The cell takes a valid instruction, changes a register to one that nothing wrote and hands the assembly back to the compiler, and what this file records is the compiler refusing it by name. If this file ever records an acceptance, the second validator has stopped checking something it used to check, and that is the largest thing this lesson could tell you.

`boss.txt` records a failing run, also on purpose. The notebook ships with three wrong answers in the grader call, because a lesson that arrives with the answers typed in is not a prediction gate. Baking what the committed notebook actually prints means the recording matches the file, with no substitution step in between.

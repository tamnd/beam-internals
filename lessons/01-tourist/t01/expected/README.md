# Recorded output for t01

One file per cell, named after the `<!-- cell: name -->` marker above it in `lesson.livemd`. They are written by `just bake --write` and compared by `just bake`, so nothing here was typed by a person reading a screen.

Six cells, all of them compared. There is nothing in this lesson that prints a duration, a pid or an address, which is unusual and is a property of the subject: every number here is a count of words or of table entries, and those are the same on every machine of the same word size.

`banner.txt` is recorded through the `build-flags` filter in `tools/normalise`. The emulator's build line carries this machine's scheduler counts and whichever optional features it was built with, so that part is erased and what is left is the release, the erts version and the word size. That is what the lesson is pinned to, and it is the one file here that fails loudly on the wrong OTP release.

`lens.txt` records eight words for `<<1, 2, 3>>` and that is not a typo. A binary written out inside a cell is stored off the process heap, so the eight words are the reference to it and not the bytes. Building the same three bytes with `:binary.copy/2` gives three, which is measured properly in `m02`. If this file ever records three for the literal, that is a change in how literals are built rather than a change in what a binary costs.

`boss.txt` records a failing run and that is deliberate. The notebook ships with four `false` answers in the grader call, because a lesson that arrives with the answer typed in is not a prediction gate. Baking what the committed notebook actually prints means the recorded file matches the file, with no substitution step and nothing for a tool to get subtly wrong. One of the four happens to be right, which is what makes the run worth reading.

If `ceiling.txt` starts failing, the small integer range moved, which would be one of the largest changes to the term layout in twenty years. Check the word size first.

# Recorded output for t07

One file per cell, named after the `<!-- cell: name -->` marker above it in `lesson.livemd`. `just bake` will rewrite these once the baker exists. Until then they were produced by running the cells in order on a clean VM and pasting what came out.

Seven cells are here and two are not, and the split is written down in `meta.toml` under `[bake]` so a tool can act on it rather than a person having to know.

Six of the seven are byte for byte identical on every machine that was tried. They were checked on aarch64 macOS and on x86-64 Linux, both Erlang/OTP 29 erts-17.0.5 running the JIT, and the two produced the same characters. That is the reason it is worth committing them at all. A number that moves between machines cannot be a regression test.

`banner.txt` is the seventh and it is recorded through the filters in `tools/normalise`. The emulator's build line carries this machine's scheduler counts and whichever optional features it was built with, and the cell prints the scheduler count again on a line of its own, so both of those are erased and what is left is the release, the erts version, the flavor and the word size. That turns a cell nobody could compare into the one file here that fails loudly on the wrong OTP release, which it does.

The two that are not recorded print timings that cannot be filtered without erasing the answer. `fairness` prints four finishing times and the spread between them, and the spread is the point of the cell, so erasing the times erases the lesson. `not-time` prints reduction counts that move by a few hundred between runs on one machine, and those counts are what the cell is about. Both still get run, so a cell that stops compiling is caught.

`boss.txt` records a failing run and that is deliberate. The notebook ships with two zeroes in the grader call, because a lesson that arrives with the answer already typed in is not a prediction gate. Baking what the committed notebook actually prints means the recorded file matches the file, with no substitution step and nothing for a tool to get subtly wrong. The two measured figures on that line, 100002 and 200001, are the part worth watching.

If a recorded file starts failing, that is the interesting case. It means the reduction accounting moved, and the first thing to check is whether the compiler changed what it does with the loops in the lesson rather than whether the VM changed what it charges.

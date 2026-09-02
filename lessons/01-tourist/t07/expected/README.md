# Recorded output for t07

One file per cell, named after the `<!-- cell: name -->` marker above it in `lesson.livemd`. `just bake` will rewrite these once the baker exists. Until then they were produced by running the cells in order on a clean VM and pasting what came out.

Six cells are here and three are not, and the split is written down in `meta.toml` under `[bake]` so a tool can act on it rather than a person having to know.

The six are byte for byte identical on every machine that was tried. They were checked on aarch64 macOS and on x86-64 Linux, both Erlang/OTP 29 erts-17.0.5 running the JIT, and the two produced the same characters. That is the reason it is worth committing them at all. A number that moves between machines cannot be a regression test.

The three that are not recorded print wall clock times or machine details. `banner` prints your OTP build. `fairness` prints millisecond timings. `not-time` prints microseconds. Comparing any of those against a stored file would fail on a busy machine and teach the reader to ignore a red build, which is worse than not checking at all. They still get run, so a cell that stops compiling is caught.

`boss.txt` records a failing run and that is deliberate. The notebook ships with two zeroes in the grader call, because a lesson that arrives with the answer already typed in is not a prediction gate. Baking what the committed notebook actually prints means the recorded file matches the file, with no substitution step and nothing for a tool to get subtly wrong. The two measured figures on that line, 100002 and 200001, are the part worth watching.

If a recorded file starts failing, that is the interesting case. It means the reduction accounting moved, and the first thing to check is whether the compiler changed what it does with the loops in the lesson rather than whether the VM changed what it charges.

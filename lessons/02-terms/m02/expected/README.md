# Recorded output for m02

One file per cell, named after the `<!-- cell: name -->` marker above it in `lesson.livemd`. `just bake` will rewrite these once the baker exists. Until then they were produced by pulling each fenced cell out of the notebook with a script, running the files in order, and keeping what came out, so the recordings are the notebook's own code rather than a retyped copy of it.

Seven cells are here and one is not, and the split is written down in `meta.toml` under `[bake]` so a tool can act on it rather than a person having to know.

The seven are byte for byte identical on every machine that was tried. They were checked on aarch64 macOS and on x86-64 Linux, both Erlang/OTP 29 erts-17.0.5 with Elixir 1.20.4, and the same extraction script was run on both, so the two sides compared the same characters produced by the same source. That is the reason it is worth committing them at all. A number that moves between machines cannot be a regression test.

The one that is not recorded is `banner`, which prints the OTP build in front of you. It still gets run, so a cell that stops compiling is caught, and comparing a build string against a stored file would fail for every reader who is not on the machine this was written on.

`boss.txt` records a failing run and that is deliberate. The notebook ships with four zeroes in the grader call, because a lesson that arrives with the answer already typed in is not a prediction gate. Baking what the committed notebook actually prints means the recorded file matches the file, with no substitution step and nothing for a tool to get subtly wrong. The four measured figures on those lines, 4 and 6 and 8 and 20, are the part worth watching.

Every one of these numbers is a 64 bit number. On a 32 bit build `bisect.txt` would be wrong, `sizes.txt` would be wrong for the two float rows, and `threshold.txt` would keep the same 64 byte boundary with different word counts on either side. No 32 bit build was available, so nothing here was checked against one, and the lesson says so in its own words rather than leaving the recordings to imply a coverage that does not exist.

If a recorded file starts failing, the interesting question is which one. A change in `sizes.txt` or `shapes.txt` means a representation moved. A change in `threshold.txt` means `ERL_ONHEAP_BINARY_LIMIT` moved or the off heap pair changed size. A change in `order.txt` means the standard order of terms changed, which would be a language level event and not a VM detail.

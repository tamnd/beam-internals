# Recorded output for m02

One file per cell, named after the `<!-- cell: name -->` marker above it in `lesson.livemd`. `just bake` will rewrite these once the baker exists. Until then they were produced by pulling each fenced cell out of the notebook with a script, running the files in order, and keeping what came out, so the recordings are the notebook's own code rather than a retyped copy of it.

Eight cells are here and none are left out, and how each one is compared is written down in `meta.toml` under `[bake]` so a tool can act on it rather than a person having to know.

Seven of the eight are byte for byte identical on every machine that was tried. They were checked on aarch64 macOS and on x86-64 Linux, both Erlang/OTP 29 erts-17.0.5 with Elixir 1.20.4, and the same extraction script was run on both, so the two sides compared the same characters produced by the same source. That is the reason it is worth committing them at all. A number that moves between machines cannot be a regression test.

`banner.txt` is recorded through the filters in `tools/normalise`, because the build line the emulator prints carries this machine's scheduler counts and whichever optional features it was built with. Those are erased and the release, the erts version and the word size are kept, so the file says nothing about who ran it and still fails loudly on the wrong OTP release.

`boss.txt` records a failing run and that is deliberate. The notebook ships with four zeroes in the grader call, because a lesson that arrives with the answer already typed in is not a prediction gate. Baking what the committed notebook actually prints means the recorded file matches the file, with no substitution step and nothing for a tool to get subtly wrong. The four measured figures on those lines, 4 and 6 and 8 and 20, are the part worth watching.

Every one of these numbers is a 64 bit number. On a 32 bit build `bisect.txt` would be wrong, `sizes.txt` would be wrong for the two float rows, and `threshold.txt` would keep the same 64 byte boundary with different word counts on either side. No 32 bit build was available, so nothing here was checked against one, and the lesson says so in its own words rather than leaving the recordings to imply a coverage that does not exist.

If a recorded file starts failing, the interesting question is which one. A change in `sizes.txt` or `shapes.txt` means a representation moved. A change in `threshold.txt` means `ERL_ONHEAP_BINARY_LIMIT` moved or the off heap pair changed size. A change in `order.txt` means the standard order of terms changed, which would be a language level event and not a VM detail.

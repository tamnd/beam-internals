# Recorded output for m55

One file per cell, named after the `<!-- cell: name -->` marker above it in `lesson.livemd`. They were produced by pulling each fenced cell out of the notebook, running the whole set in order inside one VM, and keeping what came out. The recordings are the notebook's own code and not a retyped copy of it, which matters more here than it did in m02 because several of these cells depend on the ones before them.

Ten cells are recorded and one is not. The split lives in `meta.toml` under `[bake]` so a tool can act on it.

The ten are byte for byte identical on aarch64 macOS and on x86-64 Linux, both Erlang/OTP 29 erts-17.0.5 with Elixir 1.20.4, with the same extraction script run on both sides. A number that moves between machines cannot be a regression test, so that check is the reason these files are worth committing.

The one that is not recorded is `banner`, which prints the OTP build in front of you. It still runs, so a cell that stops compiling is caught, and comparing a build string against a stored file would fail for every reader who is not on the machine this was written on.

Two of these files need a word of warning.

`maps.txt` is the fragile one and it is fragile on purpose. The first three lines record which order the pairs came out in, and that order follows the order the VM created the key atoms in rather than anything about the map. The cell makes two fresh atoms in reverse alphabetical order right before it builds the map, so the answer is pinned to something the cell itself controls, and only then is it safe to record. Take that setup away and the same script gives a different answer on the same machine on the next run. The forty pair line is the walk order of a hash trie, which is stable for a fixed set of keys on a fixed build and is not stable across builds.

`boss.txt` records a failing run and that is deliberate. The notebook ships an encoder with one clause written wrong, so the recorded output shows both kinds of report the grader can produce, a raised exception and a byte level diff. Baking what the committed notebook actually prints means the recording matches the file with no substitution step. When a reader finishes the boss fight their own output will not match this file, and that is the point.

Everything in `wire.txt` and `integers.txt` assumes a 64 bit build. On a 32 bit build the heap columns would be wrong and the 2 to the 59 boundary would be 2 to the 27. No 32 bit build was available, so nothing here was checked against one.

If a recorded file starts failing, which one it is tells you what happened. A change in `wire.txt`, `integers.txt`, `atoms.txt` or `strings.txt` means the format itself moved, which is a distribution protocol event and would be in the release notes. A change in `decode.txt` means the same thing, since that cell checks a hand written reading against the encoder. A change in `options.txt` means the compression path or the local encoding changed. A change in `maps.txt` most likely means the encoder stopped following atom creation order, which would be an improvement and still a break.

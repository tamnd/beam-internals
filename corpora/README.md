# Corpora

Recorded output that lessons are graded against, and the reason somebody with no working runtime can still read the whole book.

Every artefact is listed in `manifest.toml` with the command that produced it, the build it came from, the machine, and the date. An artefact with no manifest entry is scratch, and scratch belongs in `scratch/`, which is ignored.

The interpreter output has to live here because a stock release build ships only the JIT flavor, so there is no interpreter on a reader's machine to observe. That is measured rather than assumed, and it is why Part 5 of the curriculum is the one part that needs a local build.

## Layout

```
corpora/
  manifest.toml
  dis/               erts_debug:df/1 output from an interpreter build
  jdump/             +JDdump output, x86-64 and aarch64
  passes/            erlc +time, -S, +to_core, +dabstr for the four canonical programs
  chunks/            .beam files and their chunk dumps
  dumps/             crash dump specimens, fourteen causes
  traces/            trace captures, msacc, instrument
  dist/              packet captures of a full distribution handshake
  tables/            genop.tab, ops.tab, bif.tab, atom.names snapshots
```

Recorded output is evidence, so it is treated like evidence. If you cannot say which build produced a file, it does not go in.

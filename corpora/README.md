# Corpora

Recorded output that lessons are graded against, and the reason somebody with no working runtime can still read the whole book.

Every artefact is listed in `manifest.toml` with the command that produced it, the build it came from, the machine, and the date. An artefact with no manifest entry is scratch, and scratch belongs in `scratch/`, which is ignored.

## Recording something

Nobody types a manifest entry. The recorder prints it, because the recorder is the only thing that knows what build it was running inside at the time.

```
./bxtrace/record.escript --list          what there is to record
./bxtrace/record.escript l1-passes       record one, print its entry
./bxtrace/record.escript --all           record all of them
```

Paste what it prints into `manifest.toml`, then run `just corpus` to check it. The checker compares the entry against the bytes on disk, so if you record again and forget to update the entry, it says so and tells you the size and digest it found.

## What the checker actually checks

Three things, and each one is a way a manifest has been wrong before.

First, both directions. Every entry names a file that is there, and every file that is there has an entry. A file nobody declared is not evidence.

Second, the bytes. The size and the sha256 in the entry have to match the file, so an artefact cannot be quietly replaced or truncated.

Third, the tape against itself. A `.tape.gz` carries its own provenance in the header, written by the recorder at the moment of recording. The manifest row and that header are compared field by field, so a row claiming x86_64 for a tape recorded on aarch64 is caught here rather than by a reader wondering why the numbers look odd.

## Inputs

`src/` holds the programs the recordings were made from. They are written by hand rather than recorded, so they get a lighter entry: what the program is for and what came out of it.

```toml
[[source]]
path = "src/l1.erl"
why = "the smallest module that still runs the whole compiler pipeline"
used_by = ["passes/l1.tape.gz"]
```

`used_by` is the useful field. A source that nothing was recorded from shows up as a problem, which is how a program that was interesting once stops living here forever.

The interpreter output has to live here because a stock release build ships only the JIT flavor, so there is no interpreter on a reader's machine to observe. That is measured rather than assumed, and it is why Part 5 of the curriculum is the one part that needs a local build.

## Layout

```
corpora/
  manifest.toml
  src/               the programs the recordings were made from
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

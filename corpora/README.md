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
  dumps/             fourteen crash dump specimens, as postmortem tapes
  traces/            trace captures, msacc, instrument
  dist/              packet captures of a full distribution handshake
  tables/            genop.tab, ops.tab, bif.tab, atom.names snapshots
```

Recorded output is evidence, so it is treated like evidence. If you cannot say which build produced a file, it does not go in.

## The crash dump specimens

Fourteen of them, under `dumps/`. Reading a dump is a skill and a skill needs examples, so each one is a node made to die in a particular way.

Eight died of different causes. A deliberate halt with a string, a halt whose slogan is a formatted term, an uncaught exit before the node finished booting, a system process killed out from under the kernel, the atom table filling, the port table filling, a signal from an operator, and a dump cut off by a byte budget.

Six died the same way with the node doing something different at the time. Two thousand processes alive, a dirty CPU scheduler in the middle of a job, one process holding a two million element list, fifty thousand messages queued for a process that is not reading them, five hundred ETS tables, and a node connected to another node. That second group is the one that shows which parts of a dump are about the cause of death and which parts are there every time.

### What is kept is the tape, not the dump

A stock dump is about 1.8 MB and most of that is heap and atom text that means nothing away from the machine it came from. Fourteen of those would be thirty megabytes of near identical hex in a repository of prose.

So what is stored is the postmortem tape: every section, every fact, and every line of every section that is not a blob, with a digest and a line count standing in for the blobs. About a hundred kilobytes each, and it holds every fact a lesson would want to quote. The dump itself is reproducible, because the recipe is the recording.

### The specimens check themselves

Each one declares what it expects to find in its own dump: the slogan, whether the dump should be complete, which sections have to be there, how many of them, and any line that has to appear. The recorder checks the dump against that before it writes a tape.

A slogan is not an API and a section list is not a promise, so one day a release will change one. When it does, the recording fails and names the specimen and what it saw. That is a much better morning than finding out from a lesson that quotes a dump which no longer exists.

### One of them looks different on macOS

The `dirty-scheduler` specimen has no dirty scheduler sections when it is recorded on a Mac. That is not a bug in the specimen. The emulator only walks the dirty schedulers for a dump if it can wrap the walk in its home made try catch built from signal handlers, and it does not do that on Apple platforms, so the whole block is compiled out. A macOS dump has ten `=scheduler` sections and not one dirty one.

What survives everywhere is in the process section, where the process running the dirty job is `DIRTY_RUNNING` and its last scheduled call is the dirty BIF. That is what the specimen insists on, so it holds wherever it is recorded.

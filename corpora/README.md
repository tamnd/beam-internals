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

## The disassembly tapes

Two of them, under `dis/`, and they are the reason this directory exists at all.

`erts_debug:disassemble/1` prints what the loader left in memory: the opcode it chose for each instruction, the operands inline after it, and how many bytes the whole thing takes. On a stock release it prints nothing, because the whole function is inside `#ifndef BEAMASM` and the JIT half of it returns false at `erts/emulator/beam/beam_debug.c:512@OTP-29.0.5`. So `erts_debug:df/1` on a machine you installed with a package manager opens a file, writes nothing to it and reports `ok`.

Read one with `just dis`, which does not need a runtime of any kind.

```
python3 -m tools.dis corpora/dis/l1.tape.gz
```

What comes out is a memory layout rather than an assembly listing. Each instruction has an offset inside its function, a size in bytes, and the same size in machine words, because the word count is the finding. The first word of an instruction holds the address of the C code that runs it and everything after it is operands sitting inline, so a three word instruction is one dispatch and two operands, and `return` is one word and nothing else.

The other finding is in the names. `add(A, B) -> A + B` compiles to `gc_bif2` and arrives in memory as `i_plus_xxjd`, where the suffix is the loader saying it has already worked out that both operands are x registers and the result goes in one. The accumulator loop in `fib/3` arrives as `i_increment_rWd` and `swap_xx`, neither of which the compiler has ever heard of.

### Recording them again

You need an OTP built with `--disable-jit`, and the recorder refuses on anything else rather than writing an empty tape. A configure line with the optional applications turned off builds in around twenty five minutes on eight cores.

```
./configure --prefix=... --disable-jit --without-wx --without-javac --without-odbc
make -j8 && make install
```

A build that small has no crypto, so the recorder cannot work out a sha256 for the manifest entry. Copy the tape onto an ordinary machine and print the entry there instead, which works because every field in it is read out of the tape rather than asked of the machine printing it.

```
./bxtrace/record.escript --by you l1-dis    on the interpreter build
./bxtrace/record.escript --entry l1-dis     anywhere, once the tape is in place
```

## The native code tapes

Two of them, under `jdump/`, and they are the other half of the pair above. The disassembly tapes are what the interpreter runs. These are what the JIT emitted for the same module of the same release, one on x86-64 and one on AArch64.

`erl +JDdump true` makes the JIT write one `<module>.asm` file for every module it compiles, which is every module it loads, including the hundred or so a bare node loads on the way up. The flag is read once at startup, at `erts/emulator/beam/erl_init.c:150@OTP-29.0.5`, so it cannot be turned on from inside a running node. The recorder starts a child with the flag set, in a directory of its own, and keeps the one file it asked for.

What makes the dump readable is that the assembler is told to log the name of the BEAM instruction before emitting the code for it, at `erts/emulator/beam/jit/arm/beam_asm_module.cpp:458@OTP-29.0.5` and at the same place in the x86 assembler. So the file arrives already grouped by BEAM instruction, and the grouping is the emulator's own rather than something guessed at here.

Read one with `just jdump`, and put both side by side with `just jdump-compare`. Neither needs a runtime.

```
python3 -m tools.jdump corpora/jdump/l1-x86_64.tape.gz
python3 -m tools.jdump --compare corpora/jdump/l1-x86_64.tape.gz corpora/jdump/l1-aarch64.tape.gz
```

The comparison is what the pair was recorded for.

```
module l1, 2 architectures

                             x86_64  aarch64
BEAM instructions                56       61
distinct BEAM instructions       19       20
native instructions             129      132
modules compiled at boot        110      109

BEAM instruction          x86_64  aarch64
i_flush_stubs                  .        5
i_minus_jIssd                  .        1
i_minus_ssjd                   1        .
i_plus_jIssd                   .        2
i_plus_ssjd                    2        .
```

It would be no surprise that two machines have different native code. The surprise is that the difference reaches back into which BEAM instructions the loader picked, for one beam file on one release. `i_plus s s j d` is in the x86 table at `erts/emulator/beam/jit/x86/ops.tab:1232@OTP-29.0.5` and `i_plus j I s s d` is in the AArch64 table at `erts/emulator/beam/jit/arm/ops.tab:1305@OTP-29.0.5`, and the loader picks from whichever table its emulator was built with. Neither of them is `i_plus_xxjd`, which is what the interpreter picks for the same line of source.

`i_flush_stubs` exists only on AArch64, at `erts/emulator/beam/jit/arm/ops.tab:951@OTP-29.0.5`, where the emulator's own comment says it flushes veneers before entering a new function. A branch on AArch64 does not reach the whole address space, so anything far away needs a small trampoline, and the assembler is told where the safe places to put one are.

Nothing on either tape is an address. A stub jumping into the emulator's C code shows up as `mov x14, 4412950416`, which is a different number on every run of the same machine, so any operand that wide is replaced by `addr(N)` against a table kept only while recording. The runs of `.byte` go the same way and for a second reason: they hold the module's own metadata, which includes the full path of the file it was compiled from, so copying them onto a tape would publish a directory off somebody's machine. What is kept is the label and the byte count.

### Recording them again

Both need a stock release, because the interpreter has no JIT to dump and the recorder refuses on it rather than writing an empty tape. They also need one machine of each architecture, which is the part that cannot be worked around: an x86-64 machine cannot produce the AArch64 tape and neither of them can produce the disassembly tape.

```
./bxtrace/record.escript --by you l1-jdump-x86_64     on an x86-64 release
./bxtrace/record.escript --by you l1-jdump-aarch64    on an AArch64 release
```

`--list` marks each one with what it needs, and running everything on a machine that cannot record one of them says so and skips it rather than failing.

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

# bxtrace

The tape recorders. Small programs that capture a real run and write it into `corpora/` with everything needed to say where it came from.

A recorder writes a manifest entry alongside its output, with the command, the build, the machine and the date. That is the difference between evidence and a file somebody found.

Recorders are deliberately dull. They set trace flags, they read counters, they write files. Anything clever belongs in `bxray`, where it can be inspected, or in a lesson, where it can be explained.

## The tape format

A tape is a recording of something the VM did, kept so it can be replayed by somebody who was not there. There are four kinds, and they share one format so that a widget able to draw one does not need a second parser for the next.

```
corpora/traces/four-spinners.tape.gz
  gzipped text
    %% bxtrace tape, schema 1, kind reds     a comment naming the format
    #{schema => 1, kind => reds, ...}.       the header, one term
    {in, 1, 4000}.                           an event, one per line
    {out, 1, 0, budget}.
    ...
    {'$tape_end', 41822}.                    the footer, carrying the count
```

Text, because a tape that can be diffed is a tape whose change between two releases can be read by a person. One term per line, because a tool that only wants the third event should not have to parse the first two hundred thousand. Gzipped, because a scheduling trace of one busy second is large and repetitive and these files are committed.

Terms are written with `~0tp`, and the three parts of that all earn their place. The zero is the line width and means never wrap, because a term broken across four lines to fit in eighty columns breaks the one term per line rule everything else rests on. The `t` is unicode, so a binary holding text keeps its characters rather than turning into escapes. The `p` rather than `w` is the readability: `~w` writes `<<"29">>` as `<<50,57>>`, which parses back to exactly the same binary and tells a person nothing. Both survive the round trip, so the only thing that changes is whether the claim about being diffable by a person is actually true.

The footer is the reason a truncated tape is caught rather than quietly read short. A recorder killed halfway through leaves a file that looks fine until somebody notices the run ended early, and a count at the end turns that into an error at the point of reading instead of a puzzle three weeks later.

## What may go on a tape

Anything that survives being written as text and read back on a machine that never ran the recorder. That rules out pids, ports, references and funs, and `bxtrace_tape:write/2` refuses them rather than writing something a reader cannot parse.

A pid is the interesting one. It prints as `<0.113.0>`, which no parser will take back, and even if one did, the number names a slot in a process table that stopped existing when the run ended. A recorder that wants to talk about a process gives it an index and carries the mapping on the tape, where a reader can see it. The refusal names the path into the term:

```erlang
1> bxtrace_tape:portable({event, [ok, {nested, self()}]}).
{not_portable, pid, [2, 2, 2]}
```

## The header

Every fact a machine can state about itself is filled in by `bxtrace_tape:header/3`. The two it cannot are asked of the caller: who recorded this, and what needs it.

| field | why it is there |
| --- | --- |
| `schema` | A reader meeting a tape from the future says so rather than guessing. |
| `kind` | `reds`, `pass`, `dis`, `jdump` or `postmortem`. |
| `recorded`, `by_whom`, `why` | Provenance. The same rule `corpora/manifest.toml` states. |
| `otp`, `erts`, `build` | Two builds of the same release do not behave the same. |
| `arch`, `wordsize` | Heap words are a different number of bytes on each. |
| `flavor` | A stock release ships the JIT flavor only, so an `emu` tape can only have come from a local build. |
| `schedulers`, `schedulers_online` | A scheduling trace means nothing without them. |
| `os` | The last thing anybody thinks of and the first thing that explains a difference. |

## The reduction tape

`bxtrace_reds:record/2` runs a workload with tracing on and writes down every scheduling event it caused.

```erlang
{ok, Result} = bxtrace_reds:record("corpora/traces/one-spinner.tape.gz",
                                   #{by_whom => "tamnd",
                                     why     => "the opening figure for t07",
                                     run     => fun() -> spin(200000) end,
                                     for     => 60000}).
```

The tape is a process table, then what the workload spent, then the events in the order the VM timestamped them.

```erlang
{proc,1,<<"<0.92.0>">>,<<"the workload">>}.
{proc,2,<<"<0.10.0>">>,<<"erlang:apply/2">>}.
{spent,1,200006}.
{event,1,0,spawned,6,0,[{p,2},{erlang,apply,[{'fun',<<"#Fun<bxtrace_reds.1.87845483>">>},[]]}]}.
{event,1,12,in,6,1,[{erlang,apply,2}]}.
{event,1,19,out,6,0,[{spinner,spin,1}]}.
```

An event is `{event, Index, Micros, Tag, Scheduler, Lag, Info}`. The index is the process, the microseconds count from the first event on the tape, the scheduler is the one the VM says the event happened on, and the info is whatever that tag carries. Absolute monotonic time is a large negative number that means nothing off the machine that recorded it, so every tape starts at zero and two tapes recorded an hour apart line up.

Pids go on the tape twice. Once in the process table, as the text the shell would have shown, and after that only as the index. A pid is a slot number in a table that stopped existing when the run ended, so a tape that mentioned one anywhere else would be a tape a reader on another machine could not follow. The same goes for anything else the trace hands over live: a fun becomes `{'fun', Text}`, a port becomes `{port, Text}`, and a pid inside an event becomes `{p, Index}` so it still points at a row of the table.

`Lag` is how many messages were sitting in the collector's mailbox when it picked that one up. It is there so a reader can tell a gap in the run from a gap in the recording. The timestamps come from the VM at the moment the event happened, so they stay exact no matter how far behind the collector is, but a long stretch of high lag is still worth knowing about before drawing conclusions from what is around it. The header carries the deepest it ever got as `peak_lag`.

## Why there is no reduction count on each event

The obvious design is for the collector to read `process_info(Pid, reductions)` each time a process is scheduled out, which would give a reduction count per slice. That was the first version and it does not work.

Reading another process's reduction count is a signal round trip. The collector sends a signal, the target handles it the next time it is scheduled, and the answer comes back. On one spinning process doing two hundred thousand reductions, doing that twice per event put the collector so far behind that its mailbox held 107 of the run's 110 messages before it handled the first one. By the time it got around to asking, the process it wanted to ask about had exited, and every single sample on the tape read `gone`. The samples that did land were the ones from runs where the collector happened to get scheduled early, which is a recorder whose output depends on the recorder.

So the number is read by the workload about itself, one line after the work finishes, and written to the tape as `{spent, Index, Reductions}`. A process reading its own counter is exact and costs a handful of reductions.

Ten runs of the same two hundred thousand iteration loop, on two machines:

| | reductions the loop spent | how far behind the collector got |
| --- | --- | --- |
| macOS, aarch64, 10 schedulers | 200006 to 200012 | 2 to 82 |
| Linux, x86-64, 8 schedulers | 200006 to 200014 | 2 to 5 |

The workload's number holds to within eight reductions on each machine and starts at exactly the same value on both, while the recorder's own lag swings by a factor of forty on one of them and barely moves on the other. That gap is the argument. A number read from inside the process does not care how the recorder is doing, and a number read from outside it is mostly a measurement of the recorder.

That covers the workload and not the other processes on the tape, which is the honest limit of what can be measured from outside a process. Getting a count per slice for everything needs a tracer written as a NIF, because that callback runs in the context of the traced process rather than in a collector of its own. The schema has room for it and it is not needed for the figure the reduction tape exists to draw.

## The two flavors do not count them the same way

Both numbers in the table above came off a stock release, which is the JIT. The same loop on an emulator configured `--disable-jit` comes out lower, and not by a wandering amount.

| iterations | JIT, minus the iteration count | interpreter, minus the iteration count |
| --- | --- | --- |
| 4000 | 3 | 4 |
| 50000 | 3 | -7 |
| 200000 | 3 | -45 |
| 400000 | 3 | -95 |
| 800000 | 3 | -195 |

The JIT column is a constant. One reduction per call, plus three for the call into the loop and the read that follows it, and it does not move with the size of the loop.

The interpreter column falls by one for every four thousand iterations, which is the default slice. So the interpreter charges one reduction less each time the loop is scheduled out and back in, and a long loop ends up about one part in four thousand cheaper there than the same loop under the JIT. Every number in both columns repeated exactly across five runs, so this is arithmetic rather than noise.

It matters here only because the tests say what the loop cost and they have to hold on both, so the floor in `bxtrace_reds_test` allows one lost reduction per slice. It matters more generally because a reduction is the unit the scheduler is fair in, and two emulators of the same release disagreeing about how many of them a loop took is worth knowing before quoting one.

## The pass tape

`bxtrace_pass:record/2` compiles a module and writes down what the compiler did to it.

```erlang
{ok, Result} = bxtrace_pass:record("corpora/passes/l1.tape.gz",
                                   #{by_whom => "tamnd",
                                     why     => "the 93 stages figure",
                                     source  => "corpora/src/l1.erl",
                                     stages  => [to_core, to_asm]}).
```

The figure it exists for: a six line module goes through 33 top level passes and 60 named sub passes on the way to a beam file, and the validator runs twice, before and after the back end, because the compiler does not trust its own peephole optimisers.

```erlang
{source,<<"l1">>,<<"-module(l1).\n-export([add/2, fib/1]).\n...">>}.
{pass,1,remove_file,46,4536,0}.
{pass,2,parse_module,11262,7912,0}.
{pass,19,beam_ssa_opt,12994,15104,31}.
{subpass,19,beam_ssa_opt,ssa_opt_live,39,15}.
{subpass,19,beam_ssa_opt,ssa_opt_cse,14,10}.
{stage,to_core,<<"l1.core">>,<<"module 'l1' ['add'/2,...">>}.
{stage,to_asm,<<"l1.S">>,<<"{module, l1}.  %% version = 0\n...">>}.
```

A pass is `{pass, At, Name, Micros, Bytes, SubPasses}`. `At` is where it came in the pipeline, `Bytes` is how large the thing it handed on was, and `SubPasses` is how many distinct ones ran underneath it. A sub pass is `{subpass, At, Parent, Name, Micros, Runs}`, where `At` points back at the pass it belongs to.

`Runs` is the one number `erlc +time` cannot show you. Sub passes run once per function rather than once per module, so on this three function module the 60 named sub passes account for 310 invocations, and `erlc` folds all of that into one line each before printing.

### Reading the handler instead of the printout

`erlc +time` prints the same timings, and parsing what it prints is the obvious way to record them. It loses things.

The printed format is `~-30s` for a top level pass and `~-27s` for a sub pass, at `lib/compiler/src/compile.erl:1412@OTP-29.0.5` and `lib/compiler/src/compile.erl:1435@OTP-29.0.5`. A name longer than the field runs into the colon and a name longer still is cut off, and on a stock OTP 29 that already happens: `skip_outgoing_tail_extraction` prints as `skip_outgoing_tail_extracti`. Times arrive rounded to a millisecond, sizes to a tenth of a kilobyte, and the sub passes arrive already folded, so `Runs` is gone.

None of that is necessary, because the printing is a handler and the handler can be replaced. The atom `time` expands to `{time, fun print_pass_times/2}` at `lib/compiler/src/compile.erl:1197@OTP-29.0.5`, and the tuple form is looked up and called at `lib/compiler/src/compile.erl:1319@OTP-29.0.5`. Passing our own function there gets the same data one step earlier: exact native time, exact bytes, whole names, and every invocation.

The liberty is that the tuple form is not documented, only the bare atom is. So the recorder checks the shape on the way in and stops with a message naming what changed, and there is a test that does nothing but assert that shape. A release that moves it shows up as a failing test rather than as a strange tape three weeks later.

One detail worth knowing if you write a handler of your own: it does not run in your process. The compiler spawns a worker to compile in, which is why `no_spawn_compiler_process` exists as an option, so the handler has to send rather than store.

### Capturing the intermediate forms

Each stopping point gets its own compile, because a compile can only stop once. These modules are small and the alternative is reaching inside the pipeline, which would make the tape a recording of our own cleverness rather than of the compiler.

Which file a stopping point writes is not guessed at. `to_core` writes `l1.core` and `to_asm` writes `l1.S`, but `to_exp` writes `l1.abstr` under the same name `to_abstr` uses, `dexp` writes `l1.expand`, and `to_dis` writes a beam file as well as its listing. So the compile runs into an empty directory and whatever turns up in it is the answer, minus any beam file, because a beam file is the output rather than a stage on the way to it.

A stage's text goes on the tape as one binary, so a two hundred line listing is one line of tape with its newlines escaped. That looks odd the first time and it is the rule the whole format rests on.

## The disassembly tape

`bxtrace_dis:record/2` loads a module and writes down what the loader left in memory.

```erlang
{ok, Result} = bxtrace_dis:record("corpora/dis/l1.tape.gz",
                                  #{by_whom => "tamnd",
                                    why     => "the opcodes the loader chose",
                                    source  => "corpora/src/l1.erl"}).
```

The finding it exists for: not one instruction in memory is the instruction the compiler emitted. The beam file for `add(A, B) -> A + B` holds `gc_bif2`, and what is loaded is `i_plus_xxjd`, where the suffix is the loader saying it has already worked out that both operands are x registers and the result goes in one. The accumulator loop in `fib/3` arrives as `i_increment_rWd` followed by `swap_xx`, and neither of those names appears anywhere in the compiler.

```erlang
{function,3,<<"fib">>,3,7,160}.
{instruction,8,3,0,40,<<"i_func_info_IaaI">>,<<"0 `l1` `fib` 3">>}.
{instruction,9,3,40,24,<<"i_is_eq_exact_immed_frc">>,<<"f(@11) r(0) `0`">>}.
{instruction,10,3,64,16,<<"move_return_x">>,<<"x(1)">>}.
{instruction,11,3,80,24,<<"i_increment_rWd">>,<<"r(0) -1 x(0)">>}.
```

A function is `{function, At, Name, Arity, Instructions, Bytes}` and an instruction is `{instruction, At, Function, Offset, Bytes, Op, Args}`. The offset is measured from the start of the function and the size is measured to the next instruction, so the sizes of a function's instructions add up to its size exactly. There is a test for that, because it is the check that would catch a walk that stopped early.

`Bytes` is the interesting column. Divide it by the word size and a `return` is one word, `move_return_x` is two, and `i_plus_xxjd` is three. The first word holds the address of the C code that runs the instruction and everything after it is an operand sitting inline in the code, which is what threaded code means and what makes the whole module a run of words rather than a stream of bytes to decode.

### Nothing on the tape is an address

A printed disassembly starts every line with the machine address of the instruction, and prints a branch target the same way, so the same module disassembled twice on the same machine gives two different files. Both go.

An instruction records its offset from the start of its function. A branch target that names another instruction in this module is rewritten to `@` and that instruction's index, so `f(00007FC7C2FC8348)` becomes `f(@11)`. Two machines that loaded the same module then produce byte identical rows, which is what makes a tape recorded on one worth reading on another.

Anything that looks like an address and is not one of the module's own instructions is left alone and counted in the header as `unresolved_addresses`. It is zero on both corpus tapes. Quietly replacing something nobody checked is how a tape ends up describing something that was never there.

### This one needs a build

`erts_debug:disassemble/1` is inside `#ifndef BEAMASM` and the JIT half of it is one line returning false, at `erts/emulator/beam/beam_debug.c:512@OTP-29.0.5`. A stock release ships the JIT flavor only. So on any machine you can set up with a package manager, `erts_debug:df/1` opens a file, writes nothing to it and reports `ok`.

The recorder refuses on the JIT rather than writing an empty tape, and says why. `corpora/README.md` has the configure line and the two step recording, which is two steps because a build small enough to be quick has no crypto in it and cannot work out the sha256 for its own manifest entry.

### Why not keep the output of erts_debug:df/1

`df/1` is a loop over `erts_debug:disassemble/1` that throws away everything except the printed line, at `lib/kernel/src/erts_debug.erl:436@OTP-29.0.5`. The BIF hands back the address of the next instruction and the MFA the current one belongs to, and both are gone by the time the text reaches the file. Calling it directly keeps them, which is where every instruction's size and every function boundary comes from without parsing anything back out.

## The native code tape

`bxtrace_jdump:record/2` compiles a module, loads it in a child node with the dump flag on, and writes down what the JIT made of it.

```erlang
{ok, Result} = bxtrace_jdump:record("corpora/jdump/l1-aarch64.tape.gz",
                                    #{by_whom => "tamnd",
                                      why     => "what the JIT emitted for six lines",
                                      source  => "corpora/src/l1.erl"}).
```

A group is `{group, At, Function, Op, Natives}`, one per BEAM instruction, in the order the assembler emitted them. Under each group are the lines it produced: `{native, Group, Text}` for an instruction, `{note, Group, Text}` for something the emitter wanted a reader to know, `{label, Group, Text}`, `{align, Group, To}` for padding, and `{data, Group, Directive, Bytes}` for a run of bytes.

```erlang
{group,8,1,<<"i_plus_jIssd">>,10}.
{native,8,<<"and x8, x26, -16">>}.
{native,8,<<"adds x0, x25, x8">>}.
{native,8,<<"and x8, x25, x26">>}.
{native,8,<<"and x8, x8, 15">>}.
{note,8,<<"test for not overflow and small operands">>}.
```

The grouping is not guessed at. The assembler is asked to log the name of the BEAM instruction before emitting the code for it, at `erts/emulator/beam/jit/arm/beam_asm_module.cpp:458@OTP-29.0.5`, so the dump arrives already divided the way it should be divided.

The finding it exists for is the size of a group. `add(A, B) -> A + B` is one BEAM instruction on the interpreter, one entry in a table, one dispatch. Here it is ten native instructions, and reading them tells you why: four to test that both arguments are small integers and that the sum did not overflow, one branch past the slow path, and then three to set up a call into the runtime for the case where any of that failed. The fast path is inline and the general case is still a call, which is the whole trade the JIT is making.

### Two architectures, one module

The pair in `corpora/jdump/` is the same six lines recorded on x86-64 and on AArch64, and `python3 -m tools.jdump --compare` puts them side by side. Some of the differences are what you would expect from two instruction sets. One is not: the two machines do not agree on which BEAM instructions to run. `corpora/README.md` has the table and the citations.

### Nothing on the tape is an address

Same rule as the disassembly tape, and the dump needs it more. A stub jumping into the emulator's C code shows up as `mov x14, 4412950416`, and that is a different number every run on the same machine. Any operand at least four bytes wide is replaced by `addr(N)` against a table kept only while recording, so two stubs going to the same place still look the same and neither shows a number that means anything elsewhere. The header says how many distinct ones there were, and a tape reporting none would mean the replacing had stopped working rather than that the dump was clean.

Runs of bytes are counted rather than copied, for a second reason on top of that one. They hold the module's own metadata, which includes the full path of the file it was compiled from, so a tape that copied them would publish a directory off somebody's machine.

Those bytes turn up in one more place, and finding it is the reason a section marker keeps only its name. A section line should read `.section .rodata {#1}` and usually does. Sometimes it arrives as `.section .rodata3, 0x69, 0x6F, 0x6E, 0x6B, 0x00,  {#1}`, with a fragment of the module's own compile chunk sitting in the middle of it, left in the assembler's log buffer. It is not every run and not every machine, which is the worst way for this to behave: the first version of this recorder copied that line as it stood, both committed tapes had four bytes of a compile chunk in them, and the run that caught it was a CI job on a third machine where the leftover bytes were not even valid text. So the name is taken up to the first character that cannot be in one and the rest of the line goes. There is a test that no row on a tape is anything but printable ASCII, which is the general form of the same rule.

### This one needs a release

The mirror image of the disassembly tape. The interpreter has no JIT, `+JDdump true` on it writes nothing, and the recorder refuses rather than reading a file that was never created. So the two tapes cannot come off the same machine, and running the tests on either flavor leaves the other one's cases reported as skipped with the reason next to them.

It also needs both architectures, which is the part with no way around it. An x86-64 machine cannot produce the AArch64 tape, and that is exactly why the pair is committed.

## The postmortem tape

`bxtrace_post:record/2` reads a crash dump and writes the index that makes it navigable.

```erlang
{ok, Result} = bxtrace_post:record("corpora/dumps/halt-slogan.tape.gz",
                                   #{by_whom => "tamnd",
                                     why     => "the simplest dump there is",
                                     dump    => "/tmp/halt-slogan.dump"}).
```

The dump this was written against is 1.78 MB, 58735 lines and 1167 sections. The honest description of reading one in a text editor is that you scroll until you give up. The tape is 100 KB and 18044 rows: one row naming each section, 16711 facts, 118 summaries of encoded memory, and 48 lines that are not facts.

```erlang
{section,149,proc,<<"<0.5.0>">>,11867,19}.
{fact,149,<<"State">>,<<"Waiting">>}.
{fact,149,<<"Spawned as">>,<<"erts_dirty_process_signal_handler:start/0">>}.
{fact,149,<<"Reductions">>,<<"7">>}.
{fact,149,<<"Program counter">>,<<"0x000000010365cfb0 (erts_dirty_process_signal_handler:msg_loop/0 + 80)">>}.
{line,149,18,<<"arity = 0">>}.
{section,1050,proc_heap,<<"<0.0.0>">>,17813,138}.
{blob,1050,138,4027,<<"046a584bfd03080232bf75f6033eb597b63ea973fb1f359d0d86b271c54e5bcb">>}.
```

A section is `{section, At, Kind, Id, Line, Lines}`. `At` numbers the sections in file order and everything under a section points back at it, and `Line` is where that section starts in the dump, so a reader who wants the raw text knows where to look. The two are separate on purpose: one orders the tape and the other addresses the file.

The tape is an index, and `Line` on every row is what makes it an index of something rather than a summary of it. Anybody holding the dump can go straight to the line the row came from.

### Facts and blobs

Most sections are a list of `Key: Value` lines and go on the tape as facts. The rest are encoded memory, one line per term or per slot, in a form written for a decoder rather than for a person. Those become one `{blob, At, Lines, Bytes, Digest}` row. The encoded heaps of forty three processes are most of the file and none of the reading.

The digest is what makes a summary worth having. Two heaps of the same size are common and two heaps with the same contents are not, so a blob row carrying only a line count and a byte count would report a match that is not there.

Which sections are which is a list in the source rather than a guess about the contents. The keys are the binaries the file used and are never turned into atoms, because reading a file nobody in this repository wrote and putting its words in the atom table fills the one table with no way to take anything back out.

Nothing is dropped either way. A line in a fact section that is not shaped like a fact goes on the tape as `{line, At, N, Text}`, and a stock dump has 48 of those: 42 `arity = 0` lines that follow a program counter, 5 stack trace lines under the scheduler that was running, and the date on the first line of the header. There is a test whose whole job is to add up the fact rows and the line rows of every section and check they account for its lines exactly.

### Where the section list comes from

A crash dump is a flat list of sections. A section starts with a line whose first character is `=`, and the rest of that line is a tag, then optionally a colon and an id. That is the entire structure, and it is the same split `crashdump_viewer` does one character at a time at `lib/observer/src/crashdump_viewer.erl:1007@OTP-29.0.5`.

The tags are a fixed list, written out as macros at `lib/observer/src/crashdump_viewer.erl:127@OTP-29.0.5` so that a misspelling in the viewer is a compile error rather than a section it quietly skips. Two of them are spelled differently there than in the file, because `end` and `fun` are reserved words, so the viewer calls them `ende` and `fu`. This recorder keeps the names the file uses and writes them as the quoted atoms `'end'` and `'fun'`, which read back through `erl_parse` like any other atom.

A tag not on the list still goes on the tape, as a binary rather than an atom, and the header counts it under `unknown_kinds`. A test asserts that list is empty for a stock dump, which is how a release that adds a section shows up as a failing test rather than as a tape with one row spelled oddly.

### Truncated dumps

A dump ends with `=end`. Anything else means the node died while writing it, or the disk filled, or somebody copied the file while it was still being written.

The recorder reads it anyway and says so in the header as `complete => false`. Most real crash dumps are truncated, because whatever killed the node often gets around to killing the write as well, and a recorder that refused them would refuse the dumps people actually turn up with.

### What the dump says about itself against what the machine says

The header has two halves. The usual fields describe the machine that read the dump. A `dumped` map holds what the dump says about the node that wrote it: the format version, the time, the slogan, the system version, the atom count and which thread was running.

Keeping them apart matters because a dump copied off another machine is the normal case rather than the odd one. Merging the two would produce a tape claiming a dead node's heap was measured in the reading node's word size.

### The fourteen specimens

A recorder for crash dumps is not much use without crash dumps, so `bxtrace_specimen` holds fourteen recipes, each one a child node made to die in a particular way. Eight of them die of different causes and six die the same way with the node in a different state. `corpora/README.md` lists them.

Each recipe carries what it expects the dump to contain, and the recorder checks the dump against that before it writes a tape.

```erlang
#{name => "port-table-full",
  why => "the port table filled, so the dump has a full port table to read",
  flags => ["+Q", "1024"],
  eval => "...",
  expect => #{slogan_starts => <<"Runtime terminating during boot ({system_limit,">>,
              complete => true,
              kinds => [erl_crash_dump, port],
              at_least => #{port => 500}}}
```

Five things can be asserted: the slogan exactly or by prefix, whether the dump should end with `=end`, which section kinds have to be present, how many of a kind there have to be, and any line that has to appear somewhere in the file. The last one exists because some of what makes a specimen the specimen is not a section, it is a flag on a process.

A slogan is not an API and a section list is not a promise, so a release will change one eventually. When it does, the recording stops and names the specimen and what it actually saw, which beats finding out from a lesson quoting a dump that no longer exists.

The `at_least` figures are deliberately loose. Asking a node for 1024 ports and getting 859 into the dump is not a bug, it is the emulator keeping slots for itself, and a floor of 500 proves the table filled without pinning a number that was never the point.

## Reading one

```erlang
{ok, Header, Events} = bxtrace_tape:read(Path).
{ok, Header, Total} = bxtrace_tape:fold(Path, fun count/2, 0).
ok = bxtrace_tape:describe(Path).
```

`read/1` holds the whole tape in memory, which is what a test wants and what a small tape can afford. Anything recorded from a real run gets folded. `describe/1` prints the header and a count per event tag, which is the question people actually ask about a file sitting in `corpora/`.

## Running the tests

```
just bxtrace-test              every module
just bxtrace-test bxtrace_tape one of them
```

Most of the disassembly tests report as skipped, with the reason next to them and the count in the summary. They need an emulator built `--disable-jit` and you are almost certainly not sitting on one. A skipped case is not a passing case and the runner does not pretend otherwise.

The native code tests are the other way round and skip on that build instead, so between the two suites every case runs somewhere and no machine runs all of them. They are also the slowest thing here, because a recording starts a whole node and that node compiles a hundred modules to native code before it gets to ours. One recording is made and handed to every case rather than one each, which is the difference between eleven seconds and two minutes.

These are separate from the conformance suites because the two answer different questions. A conformance suite asks whether the runtime still behaves the way a blueprint says, and a failure there is news about Erlang. These ask whether our own code works, and a failure here is news about us. They do share an assertion vocabulary, because there is no reason for one repository to have two of those.

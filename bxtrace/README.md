# bxtrace

The tape recorders. Small programs that capture a real run and write it into `corpora/` with everything needed to say where it came from.

A recorder writes a manifest entry alongside its output, with the command, the build, the machine and the date. That is the difference between evidence and a file somebody found.

Recorders are deliberately dull. They set trace flags, they read counters, they write files. Anything clever belongs in `bxray`, where it can be inspected, or in a lesson, where it can be explained.

## The tape format

A tape is a recording of something the VM did, kept so it can be replayed by somebody who was not there. There are three kinds, and they share one format so that a widget able to draw one does not need a second parser for the next.

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
| `kind` | `reds`, `pass` or `postmortem`. |
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

## The postmortem tape

`bxtrace_post:record/2` reads a crash dump and writes the index that makes it navigable.

```erlang
{ok, Result} = bxtrace_post:record("corpora/dumps/out-of-memory.tape.gz",
                                   #{by_whom => "tamnd",
                                     why     => "the fourteen causes figure",
                                     dump    => "corpora/dumps/out-of-memory.dump"}).
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

The tape is an index and not a replacement. The dump stays in `corpora/dumps` and the tape points into it.

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

These are separate from the conformance suites because the two answer different questions. A conformance suite asks whether the runtime still behaves the way a blueprint says, and a failure there is news about Erlang. These ask whether our own code works, and a failure here is news about us. They do share an assertion vocabulary, because there is no reason for one repository to have two of those.

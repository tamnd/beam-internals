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

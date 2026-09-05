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

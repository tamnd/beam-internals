# Layout

What lives where, and why it lives there rather than somewhere else.

## Top level

```
beam-internals/
  lessons/           the curriculum
  blueprints/        the normative specifications and the claim ledger
  corpora/           recorded real output, committed, with provenance
  bxray/             the observation library, an OTP application
  bxkino/            the Livebook widgets
  bxtrace/           the tape recorders
  bxmanim/           the animation vocabulary
  tools/             the checkers and the generators
  conformance/       the oracle stack and the scorecard
  capstones/         reference implementations
  site/              the book site
  tests/             tests for the tools
  otp/               git submodule, pinned to OTP-29.0.5
```

## lessons

One directory per lesson, named by its stable id. Ids never change and never get renumbered, because they appear in urls, in blueprint cross references, in the claim ledger and in other people's notes. A deleted lesson leaves a tombstone page.

```
lessons/07-scheduling/m34/
  lesson.livemd      the lesson, plain markdown, hand written
  meta.toml          id, title, part, env, duration, deps, blueprint, boss
  boss.exs           the boss fight grader
  expected/          committed output, one file per cell, written by `just bake`
  files/             figures and helper modules, under the name Livebook uses
```

`lesson.livemd` opens in Livebook Desktop with no repository present. Nothing in this pipeline is required to run a lesson, which is the point of choosing the format.

Ids carry their pass. `o` for orientation, `t` for the tourist pass, `m` for the mechanic pass, `s` for surgery, `ca` and `cb` and `cc` for the three capstone tracks.

## blueprints

```
blueprints/
  _template.md       the nine sections
  NOTATION.md        the pseudocode dialect, defined once and used in all sixty
  terms/BP-TERM-001.md
  sched/BP-SCHED-004.md
  ledger.toml        every claim, its evidence, its class, when a human last checked it
```

A blueprint may not reference the lesson it came from, except in its header. Checked by `tools/bplint`.

## corpora

Recorded output that lessons are graded against, and the reason somebody with no runtime at all can still read the whole book. Every artefact is listed in `manifest.toml` with the command that produced it, the build hash, the machine and the date.

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

The interpreter output has to be in here because a stock release build ships only the JIT flavor, so there is no interpreter on a reader's machine to observe. That is measured, not assumed, and it is the reason Part 5 of the curriculum is the one part that needs a local build.

## bxray

An OTP application, installable on its own with rebar3, with no dependency on Livebook or on anything else in this repository. One rule: it never tells you anything the BEAM would not tell you itself. It formats, correlates and renders. `bxray:source/1` prints the underlying call for any function it offers, so you can drop the library and keep working.

## bxtrace

The tape recorders, and the format they record into.

```
bxtrace/
  src/bxtrace_tape.erl   the format, one reader and one writer
  src/bxtrace_reds.erl   the reduction tape, every scheduling event of a run
  src/bxtrace_pass.erl   the pass tape, what the compiler did to a module
  test/                  the tests, run by test.escript
  test.escript           our own code, needs a release and nothing else
  tape.escript           what is on a tape, without drawing any of it
```

A tape is gzipped text, one Erlang term per line, with a header carrying the build it came from and a footer carrying the event count. Text so it can be diffed across a pin bump, one term per line so a reader does not have to parse the whole thing, and a count at the end so a recorder that was killed halfway leaves a file that fails to read rather than one that reads short. `bxtrace/README.md` has the format and the rule about what may go on a tape.

## tools

Small programs, standard library only wherever possible, so they run in seconds and so a prose change gets an answer before the coffee is poured.

| Tool | Job |
| --- | --- |
| `lintprose` | The house style rules as a script rather than as a thing reviewers are asked to notice. |
| `refcheck` | Every citation resolves in the pinned tree and the surrounding text still hashes to what a human checked. |
| `ledger` | Every claim has an entry, every entry has evidence of the class it declares, and the per lesson caps hold. |
| `bpc` | Generates blueprint sections from the VM's own tables and fails the build if a generated section was hand edited. |
| `bplint` | The nine sections, the field classifications, and the rule about not referencing the chapter. |
| `bake` | Runs every cell of every lesson the way Livebook runs them, and compares what came out against `expected/`. |
| `drift` | Watches upstream and opens issues. Never edits content. |

## site

MkDocs Material, with `mike` giving one published version per OTP minor. `site/_build` is generated and not committed. Publishing is a separate decision from building, so the deploy workflow runs on request rather than on every merge.

## otp

A git submodule pinned to a tag and a commit, `OTP-29.0.5` at `5cf5f9725452f4e1b6a4890e8ff0305d76924b98`. A tag alone is mutable and a commit alone loses the human readable version, so both get recorded. Every citation in this repository is of the form `path:line@OTP-29.0.5` and is resolved against this submodule by `refcheck`.

Run `just pin` to fetch it. It is about 400 MB and you only need it to run `just citations-strict`, so a prose change does not require it. CI checks that the commit in the submodule and the commit in `refcheck.toml` are the same, because a pin that says one thing and points at another is worse than no pin.

## What is not here

Build output, kernel or emulator artefacts, rendered animations, the site build, and anything a tool can regenerate. Scratch traces go in `scratch/`, which is ignored. Anything a lesson depends on goes in `corpora/` instead, committed, so the build stays reproducible.

# beam-internals

A complete visual teardown of the BEAM, the runtime behind Erlang and Elixir, taught from zero and specified precisely enough to build a node that a real Erlang cluster will talk to.

Status: early. Nothing here is finished. The scaffold, the checkers and the CI are being built in the open, and the work is laid out in [13 milestones](https://github.com/tamnd/beam-internals/milestones) starting with [M0](https://github.com/tamnd/beam-internals/issues/1), which exists to find out whether the format works before a hundred lessons get written in it.

Pinned to Erlang/OTP 29.0.5, erts-17.0.5.

## The problem

The BEAM is the best documented virtual machine of its size, and people still cannot answer basic questions about it.

Ask an experienced Elixir developer how many reductions a process gets before it yields and most will say 2000. The answer is 4000, it has been 4000 for years, and it takes one line of grep in a tree you can clone in thirty seconds to find out. The number is wrong in blog posts, in conference talks, in interview questions and in the mental models of people who have shipped BEAM systems for a decade. That is not a knowledge gap, it is a habit. The runtime is so good at handling concurrency, memory and failure on your behalf that nobody develops the reflex to look.

The material that does exist has a shape problem. The BEAM Book is genuinely good and genuinely current, and it is a book. You read it, you look at the diagrams, and at no point does the machine you are reading about say anything back to you. The ERTS internal documents are written by the people who wrote the emulator and are excellent where they exist, but they are notes for implementers, not a path for a beginner. Conference talks give you a box labelled scheduler, a box labelled run queue, an arrow, and then they end.

And the thing people usually want to learn has no line to follow. CPython has an eval loop. GCC has passes in order. Linux at least has a system call that starts somewhere and finishes somewhere. A BEAM node is ten scheduler threads pulling from run queues forever, plus signals arriving from other threads, plus a collector that runs per process whenever allocation says so, plus a poll set and a timer wheel. Nothing starts and nothing ends. Walk it front to back and you will get lost, because there is no front.

## The approach

Every claim in this book is something you can watch happen, on a real BEAM, in a browser tab, with nothing installed.

That works because of a fact about the BEAM that almost nobody uses. A stock release build, the one you get from `brew install erlang` or `apt install erlang`, already reports its own allocator strategies, its own microstate accounting across 33 threads, its own garbage collection generations, its own ETS concurrency decisions and all 93 stages of its own compiler, from unprivileged Erlang, with no rebuild and no patches. It will hand you the machine code its JIT wrote for your function. It will hand you the BEAM assembly the compiler produced, with the types it proved. It will take its own `.beam` files apart chunk by chunk. In the three sibling projects to this one, an observable runtime was something the toolkit had to manufacture. Here it is the design intent, and the whole book leans on it.

**One click to a real BEAM.** Every lesson opens in a hosted, sandboxed, throwaway node running an unmodified OTP 29.0.5 release build. Not a simulation, not WebAssembly, not a different VM that looks similar. The Software Mansion team looked seriously at putting a full BEAM in a browser and concluded it was not feasible, so this project hosts one instead. Unmodified matters: if the node ran a patched emulator, every measurement in the book would carry an asterisk and you could not reproduce it on your laptop.

**Predict, then run, then explain.** You commit to an answer before the machine gives one. Does sending a 63 byte binary to another process copy it? What about 65 bytes? Does `ets:lookup/2` copy? Two processes, one link, both exit at the same instant, how many exit signals get delivered? Most experienced BEAM programmers get several of these wrong, and being wrong on the record is what makes the correction stick.

**Three passes over the same ground, not one walk from front to back.** See it, understand it, change it. Day one is the whole machine end to end in a plain Erlang shell, from source text to machine code to a crash dump, using nothing but the standard install. Only then does the C start. Somebody who stops after the first pass has a complete shallow model instead of a deep understanding of the first third and nothing else.

**Concurrency claims get proved, not demonstrated.** One run of a concurrent program shows you one interleaving. That is evidence, not proof, and a book about a concurrency runtime that ships one-interleaving evidence is teaching the habit that produced the folklore in the first place. Ordering and atomicity claims are backed by Concuerror exploring interleavings exhaustively, by the TLA+ model of linking that ships inside the OTP tree, or by the Coq formalisation of Core Erlang out of ELTE and Kent. A lesson gets at most two claims that are only demonstrated.

**The VM describes itself in tables, so the specification is generated from them.** `genop.tab` is 757 lines listing 191 generic instructions. `ops.tab` holds 334 transformation rules. `beam_makeops` is 3,676 lines of Perl that turns them into the interpreter, the loader and both JIT backends. `bif.tab` has 473 entries, `atom.names` has 739, `erl_term.h` holds the entire tag taxonomy. Two of the documents in `erts/doc/guides` are public wire standards rather than internal notes. Every part of the blueprint set that can be generated from those files is generated from them, so it cannot go stale quietly, and the diff between OTP 28 and OTP 29 is a build artefact rather than an afternoon of reading.

## What gets built

104 lessons in sixteen parts, in three passes. Ten for the tour, sixty two for the mechanics, thirteen for surgery, and nineteen across three capstone tracks. Roughly 95 hours of reader time, which is the honest number and is on the front page rather than buried.

60 blueprints. Each one a normative specification you could implement against without reading the lesson it came from, and none of them allowed to say "as we saw in the chapter". Structures, algorithms, edge cases, the observable surface, conformance test ids, porting notes, and two sections that no other BEAM document writes down: the ordering guarantees stated together with their boundaries, and the enumerated yield points. A reimplementation that misses a yield point does not give wrong answers, it gives a runtime that stops responding under load, which is much harder to debug.

Three capstones. A loader and an interpreter for real `.beam` files. A node that a real OTP 29 cluster completes a handshake with, exchanges signals with, and produces correct `nodedown` behaviour for when you break the connection. And one real change to the emulator, carried to a pull request that the OTP team would take seriously.

The second capstone is the one worth building the project around, because it is the only conformance test in this space that is not a percentage. Either a real, unmodified Erlang node pings you and lists you in `erlang:nodes()`, or it does not. There is no partial credit and no room for a generous reading of your own work.

## What you need to know already

You write Erlang or Elixir comfortably. Everything else is taught, including the C. There are two ramps at the front, one for reading Erlang if you only know Elixir, and one for reading C if you never intend to write any. The first build of the emulator happens at lesson eleven, after ten lessons of real work, and not before.

## Layout

`LAYOUT.md` has the full map. The short version:

| Directory | What is in it |
| --- | --- |
| `lessons/` | The curriculum. One directory per lesson, each a Livebook markdown file with its metadata, its grader and its committed output. |
| `blueprints/` | The normative specifications, plus the claim ledger. |
| `corpora/` | Recorded real output. Crash dumps, traces, disassembly, JIT dumps, packet captures, with a manifest saying what produced each one. |
| `bxray/` | The observation library, an OTP application. Formats and correlates what the BEAM already tells you, and never computes anything itself. |
| `bxkino/` | The Livebook widgets. |
| `bxtrace/` | The tape recorders behind the three signature artefacts. |
| `bxmanim/` | The shared animation vocabulary. |
| `tools/` | The checkers. House style, citations, the claim ledger, the blueprint compiler, the drift watcher. |
| `conformance/` | The oracle stack and the scorecard. |
| `capstones/` | Reference implementations, deliberately incomplete, which exist to prove the blueprints are sufficient. |

## The lesson format

A lesson is a Livebook markdown file. Plain markdown, readable in any renderer, diffable in review, and openable in Livebook Desktop with no repository and no build step. The directives the site uses to gate predictions, mark blueprint fragments and register claims are html comments, so they are invisible in a normal markdown view and inert in stock Livebook.

This is different from the three sibling projects, which all had to build a notebook compiler. That subsystem does not exist here and will not be missed.

## Prior art, and where this fits

[The BEAM Book](https://github.com/happi/theBeamBook) by Erik Stenman and contributors reached version 1.0 in June 2025, runs to about 400 pages, and is CC BY 4.0. It is good and it is current. This project cites it, quotes it with attribution, and does not paraphrase it. Where a measurement here disagrees with it, the disagreement gets filed as an issue on that repository with the evidence attached, and the issue number goes in the blueprint. Two projects on the same subject in a community this size should be complementary in public, and the corpus and the conformance suite here are things that book could use.

`erts/emulator/internal_doc` in the OTP tree is fifteen documents and 5,823 lines written by the implementers. `beam_makeops.md` and `BeamAsm.md` are better than anything this project would write, so the blueprints link to them and specify what they leave out, which is the observable surface, the invariants and the tests.

[AtomVM](https://github.com/atomvm/AtomVM) is a different virtual machine for constrained devices, and [Popcorn](https://popcorn.swmansion.com) builds on it to get Elixir into a browser. Both are discussed once, as comparisons, and neither is used as a stand-in for the BEAM.

## Contributing

Read `CONTRIBUTING.md` first. The short version is that a claim without evidence does not ship, a citation without a version tag does not ship, and a benchmark without a machine and a method attached does not ship. Issues labelled `good first issue` are real ones, not busywork.

## Licence

Prose, lessons, blueprints and figures are CC BY-SA 4.0. Code is Apache-2.0. Quoted Erlang/OTP source stays under Apache-2.0 with its notice retained, and quoted BEAM Book material stays under CC BY 4.0 with attribution. `NOTICE` lists everything third party that this repository quotes.

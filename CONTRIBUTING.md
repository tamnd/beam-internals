# Contributing

The rules here are short and most of them are enforced by a script, because a rule that lives only in a document stops being a rule around lesson forty.

## Before you start

Open an issue first for anything larger than a typo. Lessons and blueprints are sequenced, and a lesson written out of order usually assumes something the reader has not met yet.

Issues labelled `good first issue` are real work with a clear finish line. Issues labelled `status/gate` are decision points where the answer changes the plan, so they want a measurement rather than an opinion.

## The rules that get things rejected

**A claim needs evidence.** Any sentence that asserts the BEAM does something is a claim, and every claim gets an entry in `blueprints/ledger.toml` naming what backs it. The classes, strongest first, are: a cell in this repository that CI runs, a proof from Concuerror or PropEr or TLA+ or Coq, a quote from an upstream normative document, a concurrency claim backed by runs alone, and source reading with no runtime evidence. The last two are capped at two and three per lesson. The caps are the point. They force you to find an observation or admit the gap.

**A citation needs a version.** Write `erts/emulator/beam/erl_vm.h:53@OTP-29.0.5`. A line number with no tag is noise within a year. `refcheck` resolves it against the pinned submodule and compares a hash of the surrounding lines against what was there when somebody last read them.

**Do not cite generated files.** Citing `beam_hot.h` instead of `ops.tab` is a common mistake and the checker knows the generated file list. Cite the table, not the thing the table produced.

**Show it before you explain it.** A lesson opens with a question, asks for a prediction, runs the experiment, and only then reads the source. Reading code to explain something you have already watched happen works. Reading code first is how internals writing loses people.

**Every lesson has a surprise.** If nothing in it contradicts what a reasonable reader expected, it is a reference page, and reference pages belong in the blueprint.

**No `timer:sleep/1` as synchronisation.** Use a monitor, a receive, or `erlang:trace_delivered/1`. This gets rejected every time. A lesson about a concurrent runtime that synchronises by sleeping is teaching the habit the runtime exists to prevent.

**Say the number.** 4000 reductions, not "a fixed budget". 233 words, not "a small initial heap". Numbers are checkable and vagueness is where staleness hides.

**Benchmarks name the machine and the method.** Scheduler count, build type, architecture, what was measured and how. `bxray:banner/0` prints most of it for you.

## House style

`tools/lintprose` checks these on every push, so you do not have to remember them.

Second person, present tense, active voice. You spawn a process, it gets a 233 word heap.

No em dashes. Use a comma, a full stop, or brackets.

Banned words, and the linter has the current list: `simply`, `just`, `obviously`, `of course`, `trivially`, `as you would expect`, `note that`, `it turns out`. Most of them tell a reader that the problem is them. The last one is a lie, because it did not turn out, somebody decided, and there is usually a commit.

Identifiers in backticks every time, including in prose. `HTOP`, `Eterm`, `CONTEXT_REDS`, `beam_ssa_opt`. Somebody scanning for a symbol finds it by shape.

One new term per paragraph at most, introduced in the glossary first with an anchor.

One sentence per line is fine and so is one paragraph per line. Do not wrap a line in the middle of a sentence, because it makes diffs unreadable.

No horizontal rules. Headings do that job.

## Quoting other people's work

Erlang/OTP source is Apache-2.0. Quote it, keep the notice, cite it with the pinned tag, and quote only the lines under discussion. If you need two hundred lines, the lesson is two lessons.

`erts/emulator/internal_doc` and `erts/doc/guides` get linked, not paraphrased. Quote when the exact wording is the subject, which it is for wire formats, guarantees and error terms. A paraphrase of a normative document is a second normative document that will eventually disagree with the first.

The BEAM Book is CC BY 4.0. Cite it, quote it with attribution in the form `The BEAM Book, v1.0, section 7.3, Erik Stenman et al., CC BY 4.0`, and never paraphrase it. Where you disagree, say so with evidence, open an issue on `happi/theBeamBook`, and put the issue number in the blueprint.

## Blueprints

Nine sections, in order, none of them silently missing. An empty section is written out with the word None, because a missing section and an empty section are different claims.

A blueprint may not reference its lesson outside the header. No "as we saw above", no "recall", no link into `lessons/`. The test is to hand it to somebody who has not read the book and ask them to implement the subsystem. Their questions are the review comments.

Every field in section 2 is classified as normative, incidental or debug only. Getting this wrong is the most common review failure, because it is what tells a reimplementer which of the emulator's choices they have to copy.

Every ordering guarantee in section 4 needs at least one line saying what is not guaranteed. A guarantee with no stated boundary is where distributed Erlang bugs come from.

## Pull requests

One lesson, one blueprint or one tool per pull request. Run `just check` first, which is what CI runs.

Two reviewers, and one of them has not written anything in that part of the curriculum. The outside reviewer is the one who catches assumed context, and assumed context is what makes internals writing unreadable to the people who need it most.

If you changed a lesson cell, run `just bake` and commit the new expected output with a sentence saying why it changed. A changed output that nobody explains is a failing build on purpose.

## Reporting something wrong

Open an issue with `kind/bug`. Wrong, stale and mis-cited all count. If a number in this repository disagrees with a number you measured, that is the most useful issue you can file, so include your `bxray:banner/0` output.

Security reports about the hosted node go to the address in `SECURITY.md`. Security reports about Erlang/OTP itself go to the OTP team, not here.

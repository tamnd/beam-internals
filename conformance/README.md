# Conformance

The oracle stack, and the scorecard that says how each blueprint was checked.

A blueprint that says a thing is true has to say how somebody would find out it was false. For sequential behaviour that is usually a test. For anything concurrent it is not, because a test that passes a thousand times has shown that a schedule exists, not that every schedule is safe. That distinction is the reason this directory exists.

## Running it

```
just conformance              every suite
just conformance ct_dist_001  one suite
./conformance/run.escript --list
```

The runner needs an Erlang release on the path and nothing else. No build tool, no package manager, no dependencies beyond the runtime the suites are checking. That is a deliberate constraint rather than a stage the project has not grown out of: a conformance suite that takes three commands to install is a conformance suite people stop running, and these have to still run in ten years against a release nobody has built yet.

The banner prints the release in front of you and the release the blueprints are pinned to. A green run against the wrong build is then visible in the log instead of invisible in an assumption.

## Layout

```
conformance/
  run.escript          the runner
  SCORECARD.md         one row per blueprint, and what was not covered
  suites/
    ct_assert.erl      the assertion vocabulary, deliberately small
    ct_dist_001.erl    BP-DIST-001, the external term format
```

A suite is a module exporting `blueprint/0` and `cases/0`. `cases/0` returns `{Id, Tier, Title, Fun}` and a case passes by returning and fails by throwing. The runner insists that the blueprint the suite names exists and that its header names the suite back, so a suite pointed at a document that has been renamed stops the run rather than reporting on nothing.

## The gate

`bplint` will not let a blueprint sit at `reviewed` or `stable` unless a suite file exists for the id in its header and section 7 names that id. A blueprint at `draft` needs none of this, which is the point of `draft`: a document has to be writable before it is checkable.

## The oracles

| Oracle | What it is for |
| --- | --- |
| Concuerror | Systematic exploration of Erlang schedules, for signal ordering and link and monitor claims |
| PropEr | Properties over terms, encodings and table operations |
| TLA+ | Models where the interesting behaviour is a protocol rather than a program |
| Coq, via HARP | Where a proof already exists upstream and the blueprint should cite it rather than restate it |

None of them is wired up yet, and the first suite here needs none of them, for the reason the scorecard gives. Plain assertions are the right instrument for a pure function on one process, and reaching for an oracle to check one would be ceremony.

## The scorecard

`SCORECARD.md`, one row per blueprint, saying which oracle checked it and what it did not cover. The point of writing down what was not covered is that a blank in that column is a decision somebody made, not a gap nobody noticed.

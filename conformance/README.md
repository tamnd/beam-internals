# Conformance

The oracle stack, and the scorecard that says how each blueprint was checked.

A blueprint that says a thing is true has to say how somebody would find out it was false. For sequential behaviour that is usually a test. For anything concurrent it is not, because a test that passes a thousand times has shown that a schedule exists, not that every schedule is safe. That distinction is the reason this directory exists.

## The oracles

| Oracle | What it is for |
| --- | --- |
| Concuerror | Systematic exploration of Erlang schedules, for signal ordering and link and monitor claims |
| PropEr | Properties over terms, encodings and table operations |
| TLA+ | Models where the interesting behaviour is a protocol rather than a program |
| Coq, via HARP | Where a proof already exists upstream and the blueprint should cite it rather than restate it |

## The scorecard

One row per blueprint, saying which oracle checked it and what it did not cover. The point of writing down what was not covered is that a blank in that column is a decision somebody made, not a gap nobody noticed.

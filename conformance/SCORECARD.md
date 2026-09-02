# Scorecard

One row per blueprint, saying which oracle checked it and what that oracle did not cover.

The second column is the one to read. A blank in it would mean somebody decided there was nothing left uncovered, which has never once been true, so a blank is treated as an unfinished row rather than a clean bill of health.

| Blueprint | Status | Suite | Oracle | Cases | Runs green on |
| --- | --- | --- | --- | --- | --- |
| BP-DIST-001 | reviewed | `CT-DIST-001` | assertions, no oracle | 23 | aarch64 macOS, x86-64 Linux |
| BP-TERM-001 | draft | none yet | none | 0 | nothing |
| BP-SCHED-001 | draft | none yet | none | 0 | nothing |

## What CT-DIST-001 does not cover

**Where a yield happened, as against that one did.** Two cases show that encoding and decoding a large term charge more than one scheduler slice, which proves the process was put down and picked up again. Neither shows how many times or where. The reduction counter is the only instrument Tier 0 has and it cannot tell four traps from forty. The map sort and the compression chunk, which are the other two yield points in section 4, have no case at all. Distinguishing them needs a trace, which is Tier 1 work and is not done.

**The 32 bit word size.** `size-integer-band` fails rather than skips on any word size other than 8. That is deliberate. The heap column of section 2.5 has never been run on a 32 bit build, so the honest outcome on one is a failure that says the numbers were never written down, not a green run that implies they were checked.

**`minor_version` 0 and 1.** Not exercised. The float format under version 0 is a 31 byte zero padded decimal field read back with `sscanf`, and matching it needs a range of values compared against recorded output, which belongs in `corpora/` rather than in an assertion.

**Funs against a node without the module.** Section 5 says a decoded fun does not work if the module is missing and that the failure is deferred to the call. Reproducing that needs two nodes, which is Tier 2, and this suite is Tier 0 throughout.

**The tag census in section 2.4.** The counts of 25 emitted and 31 accepted were made by reading the emulator. Exercising them would need a way to enumerate what the encoder can produce, which nothing in Erlang offers.

**Anything concurrent.** Nothing in this blueprint is concurrent, which is why assertions are enough for it and why the oracle column says so rather than being left empty. The first blueprint that needs Concuerror will be one about signals, and the reason this one does not is worth stating so that a later reader does not read the blank as an oversight.

## Why there is no oracle behind CT-DIST-001

The oracles in `README.md` exist for claims a test cannot settle. A test that passes a thousand times has shown that a schedule exists and not that every schedule is safe, so anything about ordering between processes needs systematic exploration rather than repetition.

The external term format has none of that. It is a pure function from a term to bytes and back, run on one process, with no shared state and no scheduling decisions that change the answer. Assertions on chosen values are the right instrument, and reaching for PropEr or Concuerror here would produce something slower that checks the same things less legibly.

The one place a property would earn its keep is the round trip, where "for every term, decoding an encoding gives the term back" is a genuine property and the corpus is a hand picked approximation of it. That is worth doing when PropEr is a dependency this repository already has. It is not one yet, and adding a package manager to the conformance path to generate terms that the corpus already covers by hand is the wrong trade this early.

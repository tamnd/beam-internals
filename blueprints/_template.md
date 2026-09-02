# BP-AREA-000 Title of the thing being specified

Status: draft
Applies to: OTP-29.0.5 (erts-17.0.5)
Lesson: m00
Depends on: BP-AREA-000
Conformance: CT-AREA-000

## 1. Scope

One paragraph. What this specifies, and what adjacent thing it does not, with a pointer to the blueprint that does. Scope boundaries are where reimplementations accidentally leave holes.

## 2. Data structures

Every structure, field, type, unit and valid range, in a table, with the C names on the left because that is what a reader greps for.

Each field is classified. A `normative` field is one a reimplementation has to have something equivalent to. An `incidental` field is the emulator's own choice and a port may do something else. A `debug-only` field exists in a debug build and nowhere else. Getting this classification right is most of the value of this section.

Word level layouts are drawn rather than described. Alignment and padding are stated when they are observable.

| Field | Type | Class | Meaning |
| --- | --- | --- | --- |
| | | | |

## 3. Algorithms

Numbered steps in the dialect defined in `NOTATION.md`. Not C, because C invites transliteration. Not prose, because prose invites interpretation.

Any step that can allocate, fail, block or be preempted carries a marker: `[alloc]`, `[fail]`, `[lock: name]`, `[yield]`. The markers are what section 4 generates its yield point list from, so the two cannot disagree.

Complexity is stated in the unit a reader can measure, which is usually reductions and sometimes words.

## 4. Invariants, ordering guarantees and yield points

Invariants get a stable id, are phrased as something that could be checked, and name their evidence class.

Ordering guarantees are stated as pairs. What is guaranteed, and then what is not. A guarantee with no stated boundary is where distributed Erlang bugs come from, and most writing about the BEAM states the first half and stops.

Yield points are enumerated, generated from the `[yield]` markers in section 3. A reimplementation that misses one does not give wrong answers, it gives a runtime that stops responding under load.

## 5. Edge cases and error behaviour

Exact behaviour at the boundaries: empty, one, maximum, negative, wrong type, wrong arity, wrong node, dead process, closed port, purged module, limit exceeded. Exact exception class, exact reason term, exact stack trace shape. `{badarg, ...}` and `badarg` are different and reimplementations get it wrong.

Resource limits are listed with their defaults and with what happens on exhaustion, which differs per limit.

## 6. Observable surface

How to see each thing in sections 2 and 3 from outside, without source access. The `process_info` key, the `system_info` key, the `erts_debug` call, the trace flag, the emulator flag, the crash dump section, the `instrument` field.

A field in section 2 with no entry here is either debug only or a gap, and this section has to say which.

## 7. Conformance

The test ids in `conformance/` that check this blueprint, each with what it asserts and which tier it belongs to. A blueprint with no test ids stays at draft.

## 8. Porting notes

What a reimplementation has to do differently, for three named targets, because portability advice with no target is not advice.

Rust: no garbage collector, different aliasing rules, and every reference into a moving heap becomes an arena index.

Go: a collector that fights the per process heap model, and goroutines that look like processes and are not.

A WebAssembly host: no threads by default, no mmap, no signals.

## 9. Provenance

Every source reference as `path:line@OTP-29.0.5`. Every claim's evidence class. Every upstream document quoted, with its licence. The date a person last checked this against the pinned tree, and who.

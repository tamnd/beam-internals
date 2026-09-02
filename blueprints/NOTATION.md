# Notation

The pseudocode dialect used in section 3 of every blueprint. Defined once here so that sixty specifications read the same way.

It is deliberately not C and deliberately not prose. C invites transliteration, and a reimplementation that transliterates ERTS inherits decisions it did not need to make. Prose invites interpretation, and interpretation is where two implementations quietly disagree.

## Shape

Steps are numbered. Nesting is indentation. Conditions are `if`, `else if`, `else`. Loops are `for each x in xs` or `while cond`. Early exit is `return v`. Failure is `fail reason`, and the reason is the exact term the BEAM produces.

```
1. if the heap has room for Need words
2.     HTOP := HTOP + Need
3.     return the old HTOP
4. else
5.     garbage collect for Need words          [yield] [alloc]
6.     if the heap still has no room for Need words
7.         fail system_limit
```

## Names

Machine state that has a name in the emulator keeps that name, in backticks, so a reader can grep for it. `HTOP`, `STOP`, `E`, `I`, `FCALLS`, `c_p`. Everything else gets an ordinary English name.

Word sized quantities are counted in words, never in bytes, because that is what `erlang:process_info/2` and `erts_debug:flat_size/1` report and a reader will be comparing against those.

## Markers

Any step that does one of these things carries a marker at the end of the line.

| Marker | Means |
| --- | --- |
| `[alloc]` | The step can allocate on the heap, and therefore can trigger a collection. |
| `[fail]` | The step can raise. Section 5 says with what. |
| `[lock: name]` | The step takes a named lock. The order locks appear in is the lock order. |
| `[yield]` | The step is a point where the process can be preempted. |
| `[signal]` | The step enqueues or dequeues a signal to another process. |
| `[copy]` | The step copies a term rather than sharing it. |

The `[yield]` markers are what section 4 builds its yield point list from. The list is generated, so a step that yields and a section 4 that does not mention it cannot both survive the build.

## Types

Where a value's representation matters, it is written as it appears on the heap rather than as an abstract type. `boxed(ARITYVAL, 3)` is a three element tuple. `immed(SMALL, 42)` is the integer 42. `cons(H, T)` is a list cell. This keeps section 3 honest about when something is a pointer and when it is a value, which is the distinction most of the algorithms turn on.

## What the dialect does not have

No memory model. Ordering claims belong in section 4, where they are stated as guarantees with boundaries and backed by a checker, rather than being smuggled into pseudocode as an assumed sequential consistency.

No error handling sugar. A step that can fail says so with `[fail]` and section 5 says what the failure looks like. Wrapping it in a construct that hides the failure path would hide the thing a reimplementer most needs.

No concurrency primitives. Two processes never appear in the same numbered sequence. Interaction between processes is described in section 4 as ordering guarantees, because a numbered list of steps across two processes is an interleaving, and picking one interleaving to write down is the mistake this whole project is arguing against.

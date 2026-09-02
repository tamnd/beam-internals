# BP-SCHED-001 The reduction budget

Status: draft
Applies to: OTP-29.0.5 (erts-17.0.5)
Lesson: t07
Depends on: none
Conformance: CT-SCHED-001

## 1. Scope

This specifies the per process execution budget on a normal scheduler: how the counter is represented, when it is decremented, what happens when it reaches the end, how the total is accumulated across slices, and how all of that is observed from Erlang. It covers both execution flavors, the just in time compiler and the interpreter, because they charge at different instructions and a reimplementation has to reproduce the totals rather than the instruction choice.

It does not specify which process runs next. Run queue structure, the four priorities, the low priority skip count, migration between schedulers and load balancing are BP-SCHED-002. Dirty scheduler dispatch and how work that ran on a dirty scheduler is priced are BP-SCHED-003. Port task reductions are BP-IO-002. Signal delivery costs are BP-SIG-001. None of those four are written yet, and the boundary matters most at the dirty scheduler edge, because a process executing there is not charged by this specification at all and two of the observables in section 6 disagree about whether that work exists.

## 2. Data structures

There is no packed layout here. The budget is one signed 32 bit field on the process, one unsigned accumulator next to it, and a handful of counters on the scheduler and the run queue that different observables read. The interesting part of this section is which of them a reimplementation has to have and which are the emulator's own bookkeeping.

| Field | Type | Class | Meaning |
| --- | --- | --- | --- |
| `fcalls` | `Sint32` | normative | Reductions left in the current slice. Valid only while the process is executing. Placed early in `struct process` so the generated code can reach it with a short instruction. |
| `reds` | `Uint` | normative | Reductions this process has consumed in every slice that has finished. Never decreases while the process is alive. |
| `def_arg_reg[5]`, spelled `REDS_IN` | `Eterm` slot used as an integer | incidental | The value `fcalls` was given when this slice started. Reductions used so far in the slice is `REDS_IN` minus the live counter. The emulator borrows an argument register slot for it rather than adding a field. |
| `esdp->virtual_reds` | `int` | incidental | Reductions charged to the scheduler rather than to the process, used when work is done on behalf of somebody else. Subtracted before the slice total is added to `reds`. |
| `rq->procs.reductions` | `Uint` | incidental | Per run queue total of actual reductions. The sum over run queues is what `statistics(reductions)` returns. |
| `rq->procs.prio_info[prio].reds` | `int` | incidental | Per priority total, using the floored figure from section 3.5 rather than the actual one. Feeds load balancing and nothing observable. |
| `rq->check_balance_reds` | `int` | incidental | Countdown to the next balance check, in floored reductions. |
| `rq->wakeup_other_reds` | `int` | incidental | Reductions since this run queue last considered waking a sleeping scheduler, actual figure. |
| `esdp->reductions` | `Uint` | incidental | Per scheduler total, floored figure. |
| `esdp->check_time_reds` | `int` | incidental | Countdown to the next time correction check, in actual reductions. |
| `debug_reds_in` | `Uint` | debug-only | Copy of `REDS_IN` kept so a debug build can assert the counter never moved in a direction it should not. Absent from a release build. |
| `FCALLS` | machine register | incidental | Where the just in time compiler keeps `fcalls` while Erlang code is running. `r14d` on x86-64 and `w22` on aarch64. Spilled to `fcalls` on the way out to C and reloaded on the way back. |
| `CONTEXT_REDS` | compile time constant, 4000 | normative | The full slice. |
| `erts_modified_timings[level].context_reds` | `int` | incidental | The slice actually handed out when the emulator was started with `+T level`. A test aid, described in section 5. |

The counter has two valid ranges and which one applies depends on the flavor.

```
just in time compiler, always, and interpreter with saved calls off:

    0 ......................................................... 4000
    ^ nothing left, yield at the next check                     ^ full slice

interpreter with saved calls on:

-4000 ......................................................... 0
    ^ nothing left, yield at the next check                     ^ full slice
```

The interpreter shifts the whole window down by `CONTEXT_REDS` when the saved calls buffer is present, so that every dispatch fails its cheap test and lands in the slow path where the call can be recorded. The just in time compiler does not use that trick, because it swaps the active code index instead. A reimplementation that has no equivalent of the saved calls buffer keeps the first window and can ignore the second, and this is the reason `fcalls` is signed.

## 3. Algorithms

Complexity throughout is stated in reductions, since that is the unit being defined. The one number that matters for the whole section: a call plus its return costs two reductions in both flavors, and a tail call plus the eventual single return that ends the chain costs one per iteration plus one.

### 3.1 Charge on function entry, just in time compiler

Emitted once at the head of every Erlang function, as the last part of the function prologue. Calls themselves are ordinary jumps and cost nothing.

```
1. if code point of origin tags are enabled
2.     store the address of the next instruction in `c_p->i`
3. FCALLS := FCALLS - 1
4. if FCALLS <= 0
5.     enter the shared yield fragment                         [yield]
6. fall through into the body of the function
```

### 3.2 Charge on return, just in time compiler

Emitted at every `return`, and at the fused forms that pop a value and return in one instruction.

```
1. leave the Erlang stack frame
2. FCALLS := FCALLS - 1
3. if FCALLS < 0
4.     enter the return dispatch fragment                      [yield]
5. jump to the saved continuation pointer
```

The two conditions are not the same. Entry yields when the counter reaches zero, return yields only when it goes below zero. A process whose counter reaches exactly zero on a return therefore finishes that return and stops at the next function entry instead.

### 3.3 Charge on dispatch and on return, interpreter

The interpreter charges at the call instead of at the callee, and reaches the same total. `Floor` is 0 when the saved calls buffer is absent and `-CONTEXT_REDS` when it is present.

```
1. read the instruction word at `I`
2. if FCALLS > 0 or FCALLS > Floor
3.     FCALLS := FCALLS - 1
4.     jump to the instruction
5. else
6.     go to the context switch                                [yield]
```

The return path is the same shape with the same condition, entered after the continuation pointer has been popped and `x0` has been checked.

```
1. if FCALLS > 0 or FCALLS > Floor
2.     FCALLS := FCALLS - 1
3.     jump to the instruction at `I`
4. else
5.     set `c_p->current` to null and `c_p->arity` to 1
6.     go to the context switch                                [yield]
```

Setting the arity to 1 before switching out records that exactly one live value, the return value in `x0`, has to survive the switch.

### 3.4 Charge from C

Built in functions, garbage collection and anything else running outside generated code charge themselves with a macro rather than by decrementing the register.

```
1. `fcalls` := `fcalls` - Amount
2. if `fcalls` < 0
3.     `fcalls` := 0
```

The clamp is why a caller cannot go into debt. Asking to be charged more than is left charges what is left. The interpreter's version of the same macro clamps at `-CONTEXT_REDS` instead when the saved calls buffer is present, which is the lower edge of the second window in section 2.

The variant used for work done on behalf of another process moves the same amount into `esdp->virtual_reds` as it takes out of `fcalls`, so the work still ends the slice but is not added to this process's total.

### 3.5 Scheduling out, accumulating and replenishing

Reached from any of the yield points above, and also from a process blocking or exiting.

```
1. used := REDS_IN - FCALLS
2. copy the live registers out of the machine into the process
3. actual := used - `esdp->virtual_reds`                       [lock: run queue]
4. `esdp->virtual_reds` := 0
5. `p->reds` := `p->reds` + actual
6. charged := actual
7. if charged < CONTEXT_REDS / 10
8.     charged := CONTEXT_REDS / 10
9. `rq->procs.reductions` := `rq->procs.reductions` + actual
10. `rq->procs.prio_info[prio].reds` := ... + charged
11. `rq->check_balance_reds` := `rq->check_balance_reds` - charged
12. `rq->wakeup_other_reds` := `rq->wakeup_other_reds` + actual
13. `esdp->check_time_reds` := `esdp->check_time_reds` + actual
14. `esdp->reductions` := `esdp->reductions` + charged
15. put this process back on a run queue, or park it              [signal]
16. pick the next process                                      [yield]
17. `p->fcalls` := the slice for this process
18. REDS_IN := `p->fcalls`
19. copy the live registers into the machine and resume
```

Step 7 is the one that surprises people. A process that used four reductions and blocked is billed four to everything a program can read, and four hundred to the load balancer, because a context switch costs the machine far more than four reductions of work and a balancer that believed the four would never move anything. The floor reaches steps 10, 11 and 14. It is deliberately absent from steps 5, 9, 12 and 13, which is why `process_info(P, reductions)` and `statistics(reductions)` agree with each other and neither agrees with anything the balancer thinks.

## 4. Invariants, ordering guarantees and yield points

### Invariants

| Id | Statement | Evidence |
| --- | --- | --- |
| INV-SCHED-001 | For a process running on a normal scheduler, `fcalls` is in the range 0 to the slice size, and in the range minus the slice size to 0 in the interpreter with the saved calls buffer present. | source reading, asserted in a debug build |
| INV-SCHED-002 | The slice is `CONTEXT_REDS`, which is 4000. | observed, CLM-SCHED-0001 |
| INV-SCHED-003 | `erlang:system_info(context_reductions)` returns `CONTEXT_REDS` with no arithmetic in between, so the observable and the constant cannot drift apart. | observed, CLM-SCHED-0002 |
| INV-SCHED-004 | A call and its return cost two reductions in both flavors, and the flavors reach the same total for the same program. | observed, CLM-SCHED-0003 |
| INV-SCHED-005 | `p->reds` never decreases while the process is alive. Every write is an addition of a non negative amount. | source reading |
| INV-SCHED-006 | No charge can take `fcalls` below the bottom of its window, so a slice can be exhausted but never overdrawn. | source reading, asserted in a debug build |
| INV-SCHED-007 | The reductions a process is charged do not depend on how long the work took. | observed, CLM-SCHED-0005 |

### Ordering guarantees

ORD-SCHED-001. Guaranteed: a process reading `erlang:process_info(self(), reductions)` sees a value that includes the slice in progress, computed as the finished total plus `REDS_IN` minus the live counter minus the scheduler's virtual reductions, and two successive readings never go backwards. Not guaranteed: that a reading taken by any other process is current. The in flight part is added only when the caller and the subject are the same process and that process is marked running, so a reading from outside reports the total as of the subject's last schedule out and can lag by a whole slice. It can lag much further than a slice when the subject is executing on a dirty scheduler, because that execution is one long slice with no intermediate schedule out, and four readings taken 200 milliseconds apart during a one second dirty call return the same number every time.

ORD-SCHED-002. Guaranteed: `statistics(reductions)` never goes backwards, and its second element is the difference since the previous call by the same node. Not guaranteed: that it agrees with `statistics(exact_reductions)`. The two read different sets of run queues. The plain form sums the normal run queues and the dirty ones, the exact form blocks thread progress so that every scheduler has written its process out, and then sums the normal run queues only. On a node that has done dirty work the exact figure is therefore the smaller of the two, and the gap is the whole cost of that dirty work rather than a rounding difference. Four processes each spending 50 milliseconds on a dirty CPU scheduler open a gap of several hundred thousand reductions, and how many depends on the machine, because the cost of a dirty call is computed from how long it took.

ORD-SCHED-003. Guaranteed: the `out` trace message from the `running` trace flag arrives once per schedule out, and for a process that does nothing but tail recurse the count of them is the iteration count divided by the slice. Not guaranteed: any relationship between those messages and wall clock time, or that a process which yields voluntarily produces an `out` message at a slice boundary.

### Yield points

Generated from the `[yield]` markers in section 3. A reimplementation that misses one of these does not compute wrong answers, it produces a runtime that stops answering under load.

| Where | Section | Condition |
| --- | --- | --- |
| Entry to any Erlang function | 3.1 | counter reached zero |
| Return from any Erlang function | 3.2 | counter went below zero |
| Interpreter instruction dispatch on a call | 3.3 | counter at or below the floor |
| Interpreter instruction dispatch on a return | 3.3 | counter at or below the floor |
| Picking the next process | 3.5 | unconditional |

`erlang:yield/0` is not a separate mechanism. The loader turns the call into an instruction that enters the same return dispatch fragment as 3.2, unconditionally, with `true` already in `x0`.

## 5. Edge cases and error behaviour

**Zero at a return.** The counter reaching exactly zero on a return does not yield. The process completes the return and stops at the next function entry, per the two conditions in sections 3.1 and 3.2.

**A slice that is not 4000.** Starting the emulator with `+T Level`, where `Level` is 0 to 9, replaces the slice with a value from a table: the same, three quarters, a half, seven eighths, a third, ten elevenths, a quarter, five sevenths, a fifth, six sevenths. The smallest is a fifth, at level 8, which is 800. `erlang:system_info(context_reductions)` still returns 4000, because it returns the constant and not the value in use. This is the one case where the observable in INV-SCHED-003 is misleading, and it is detectable only by counting preemptions: 100000 tail calls produce 25 schedule outs by default and 125 under `+T 8`, on both x86-64 and aarch64.

**`erlang:bump_reductions/1`.** Raises `error:badarg` for a negative integer, for a non integer, and for an integer too large to be a small, with the argument list and an `error_info` map naming `erl_erts_errors` in the stack trace entry. For a valid argument it is clamped twice: first to `CONTEXT_REDS` by the built in function itself, then to whatever is left of the slice by the charging macro in section 3.4. Asking for 999999 at the start of a slice charges 4000 by default and 800 under `+T 8`.

**A process that has never run.** `fcalls` is zero from process creation until the first schedule in, and `reds` is zero. Neither is observable in that window, because the process cannot yet be the caller and an outside reading returns the finished total, which is zero.

**A dead process.** `erlang:process_info(Pid, reductions)` returns the atom `undefined` once the process is gone. Its reductions stay in the run queue totals, so `statistics(reductions)` keeps counting work done by processes that no longer exist, and the sum of `process_info` over live processes is always smaller.

**A dirty scheduler.** Reduction counting is off. `fcalls` is set to the full slice on entry and ignored, with a comment in the source saying it is set only so that code reading the field is not confused. The cost of the call is computed from elapsed time when it comes back, which is why a dirty call can be charged hundreds of thousands of reductions.

**Garbage collection.** Charged to the process that triggered it, out of the same slice, through the macro in section 3.4. A body recursive function that builds 100000 stack frames is charged a little over twice its depth, and the excess is thirteen minor collections and the work around them. Thirteen is stable across machines because it follows from the heap growth policy. The reduction excess is not, because it is small enough that whatever else the process is doing shows up in it.

**The saved calls buffer.** Turning on saved calls for a process in the interpreter shifts the counter window down by a full slice so that every dispatch takes the slow path. Every place that reads the counter has to add `CONTEXT_REDS` back before reporting or comparing. The just in time compiler achieves the same effect by switching the active code index, so its window never moves.

**Writing the counter.** `erts_debug:set_internal_state(reds_left, N)` sets the remaining slice to `N` for the calling process, for `N` from 0 to `CONTEXT_REDS`. It raises `error:undef` unless internal state was enabled first with `erts_debug:set_internal_state(available_internal_state, true)`. An `N` outside the range is ignored and the call still returns `true`, so it reports success for a write it did not perform.

**Resource limits.** There is no limit to exhaust here and no failure mode. The slice is replenished unconditionally at every schedule in, and `reds` is a `Uint`, which on a 64 bit machine at a plausible ten million reductions per second per scheduler and a thousand schedulers would take about sixty thousand years to wrap.

## 6. Observable surface

Every field in section 2 appears here, including the ones with no observable, because a field that cannot be seen from outside is a fact about the specification and not an omission from it.

| Field or behaviour | How to see it |
| --- | --- |
| `CONTEXT_REDS` | `erlang:system_info(context_reductions)`, subject to the `+T` caveat in section 5 |
| `reds` | `erlang:process_info(Pid, reductions)`, and the `reductions` key in the process section of a crash dump |
| `fcalls` | No direct read. It is visible only through the difference between a self reading and an outside reading of `process_info`, and it can be written with `erts_debug:set_internal_state(reds_left, N)` |
| `REDS_IN` | Not observable on its own. Contributes to a self reading of `process_info` |
| `esdp->virtual_reds` | Not observable. Subtracted before anything a program can read |
| `rq->procs.reductions` | `statistics(reductions)`, summed over normal and dirty run queues, and `statistics(exact_reductions)`, summed over normal run queues only after blocking thread progress |
| `rq->procs.prio_info[prio].reds` | Not observable |
| `rq->check_balance_reds` | Not observable. Its effects show up as processes moving between schedulers, which is BP-SCHED-002 |
| `rq->wakeup_other_reds` | Not observable. Its effects show up as a sleeping scheduler waking, which is BP-SCHED-002 |
| `esdp->reductions` | Not observable directly. `statistics(scheduler_wall_time)` reports time rather than this counter |
| `esdp->check_time_reds` | Not observable |
| `debug_reds_in` | Debug build only, and then only as an assertion failure |
| `FCALLS` register choice | Visible in the disassembly from `erl +JDdump true`, and nowhere in Erlang |
| A yield actually happening | `erlang:trace(Pid, true, [running])`, which delivers `{trace, Pid, out, MFA}` on schedule out and `{trace, Pid, in, MFA}` on schedule in |
| A slice that took too long | `erlang:system_monitor(Pid, [{long_schedule, Milliseconds}])` |
| The slice boundary as a program sees it | `erlang:yield/0`, which ends the slice at a point the program chose |

## 7. Conformance

The ids below are allocated and the harness described in `conformance/` does not exist yet, so this blueprint stays at draft. Every row names an assertion that is already checkable by hand, and the two that need more than a single node are marked.

| Id | Asserts | Tier | Backs |
| --- | --- | --- | --- |
| CT-SCHED-001 | `erlang:system_info(context_reductions)` is 4000 on the pinned release. | T0 | CLM-SCHED-0001, CLM-SCHED-0002 |
| CT-SCHED-002 | A tail recursive loop of N iterations is charged N plus one, a body recursive loop is charged twice that plus collection, and a loop calling through a leaf is charged three times. | T0 | CLM-SCHED-0003 |
| CT-SCHED-003 | Two loops with the same iteration count and wall clock times three orders of magnitude apart are charged within a quarter of each other. | T0 | CLM-SCHED-0005 |
| CT-SCHED-004 | A process running a tail recursive loop produces exactly one `out` trace message per 4000 iterations. | T0 | CLM-SCHED-0004 |
| CT-SCHED-005 | A body call whose result every clause returns unchanged is compiled to a tail call and charged one reduction rather than two, checked by reading `erlc -S` output rather than by timing. | T0 | CLM-SCHED-0007 |
| CT-SCHED-006 | Starting with `+T 8` quintuples the preemption count for a fixed iteration count while leaving `erlang:system_info(context_reductions)` at 4000. | T1, needs a second emulator start | none yet |
| CT-SCHED-007 | After dirty work, `statistics(reductions)` exceeds `statistics(exact_reductions)` by the cost of that work, and `erlang:process_info(Pid, reductions)` does not move while the subject is on a dirty scheduler. | T1, needs a dirty scheduler | none yet |

## 8. Porting notes

**Rust.** The counter is trivial to port and the yield is not. A tail recursive Erlang loop compiles to a machine loop with no stack growth, so a port that maps Erlang function entry onto a Rust function call inherits Rust's stack and has to reimplement tail calls before the counter means anything. Keep the counter in a register through the interpreter loop, not behind a borrow, because a `RefCell` on the hot path costs more than the reduction it counts. The clamp in section 3.4 wants `saturating_sub` rather than a checked subtraction, since the whole point is that overdraft is silently impossible rather than an error to handle.

**Go.** A goroutine is not a process and the difference lands exactly here. Go's scheduler preempts goroutines on its own schedule, asynchronously, using signals, and knows nothing about reductions. A port that gives each Erlang process a goroutine gets fairness from Go and then has to charge reductions anyway, because the counts are observable from Erlang and programs depend on them. The two preemption systems will disagree about when a process stopped, and only the reduction one may be visible through `process_info`. Charge the counter in the generated code as this specification does and treat Go's preemption as invisible.

**A WebAssembly host.** No threads by default, so there is one scheduler and the yield point is where the whole runtime returns to the host event loop. That makes step 16 of section 3.5 a return rather than a call, and everything live at that moment has to be in the linear memory rather than on the host stack. The upside is that the yield points enumerated in section 4 are the complete list of places the runtime can be suspended, which is exactly the list a host needs. Keep the slice at 4000 rather than tuning it to a frame budget, because the counts are observable and a program that measures its own reductions should get the same answer on every host.

## 9. Provenance

Source references, all resolved against the pinned tree.

| What | Where |
| --- | --- |
| The constant | `erts/emulator/beam/erl_vm.h:53@OTP-29.0.5` |
| `fcalls` on the process | `erts/emulator/beam/erl_process.h:1062@OTP-29.0.5` |
| `reds` on the process | `erts/emulator/beam/erl_process.h:1100@OTP-29.0.5` |
| `virtual_reds` on the scheduler | `erts/emulator/beam/erl_process.h:707@OTP-29.0.5` |
| `REDS_IN` | `erts/emulator/beam/beam_common.h:249@OTP-29.0.5` |
| Charge on entry, aarch64 | `erts/emulator/beam/jit/arm/instr_common.cpp:3114-3115@OTP-29.0.5` |
| Charge on entry, x86-64 | `erts/emulator/beam/jit/x86/instr_common.cpp:3233-3234@OTP-29.0.5` |
| Charge on return, aarch64 | `erts/emulator/beam/jit/arm/instr_call.cpp:51-52@OTP-29.0.5` |
| Charge on return, x86-64 | `erts/emulator/beam/jit/x86/instr_call.cpp:70-71@OTP-29.0.5` |
| Entry charge placed in the prologue, aarch64 | `erts/emulator/beam/jit/arm/ops.tab:929-944@OTP-29.0.5` |
| Entry charge placed in the prologue, x86-64 | `erts/emulator/beam/jit/x86/ops.tab:852-866@OTP-29.0.5` |
| Interpreter dispatch | `erts/emulator/beam/emu/macros.tab:154-166@OTP-29.0.5` |
| Interpreter return dispatch | `erts/emulator/beam/emu/macros.tab:222-231@OTP-29.0.5` |
| The interpreter's shifted window | `erts/emulator/beam/emu/beam_emu.c:405-416@OTP-29.0.5` |
| Charging from C, and the clamp | `erts/emulator/beam/bif.h:71-78@OTP-29.0.5` |
| The interpreter's version of the same clamp | `erts/emulator/beam/bif.h:117-140@OTP-29.0.5` |
| Slice total, and the accumulation into `reds` | `erts/emulator/beam/erl_process.c:9678-9700@OTP-29.0.5` |
| The load balancing floor | `erts/emulator/beam/erl_process.c:67@OTP-29.0.5` |
| Which counter gets the floored figure | `erts/emulator/beam/erl_process.h:529-536@OTP-29.0.5` |
| Replenishing at schedule in | `erts/emulator/beam/erl_process.c:10435@OTP-29.0.5` |
| Loading the register at schedule in | `erts/emulator/beam/jit/x86/process_main.cpp:279-281@OTP-29.0.5` |
| Register choice, x86-64 | `erts/emulator/beam/jit/x86/beam_asm.hpp:127@OTP-29.0.5` |
| Register choice, aarch64 | `erts/emulator/beam/jit/arm/beam_asm.hpp:87@OTP-29.0.5` |
| `system_info(context_reductions)` | `erts/emulator/beam/erl_bif_info.c:3362-3363@OTP-29.0.5` |
| `process_info(Pid, reductions)` | `erts/emulator/beam/erl_bif_info.c:2114-2121@OTP-29.0.5` |
| The in flight part, and why it is zero from outside | `erts/emulator/beam/beam_common.c:2393-2409@OTP-29.0.5` |
| `statistics(reductions)` and `statistics(exact_reductions)` | `erts/emulator/beam/erl_bif_info.c:4240-4267@OTP-29.0.5` |
| Which run queues each of those sums | `erts/emulator/beam/erl_process.c:12102-12137@OTP-29.0.5` |
| `bump_reductions/1` | `erts/emulator/beam/bif.c:5393-5405@OTP-29.0.5` |
| `erts_debug:set_internal_state(reds_left, N)` | `erts/emulator/beam/erl_bif_info.c:5062-5072@OTP-29.0.5` |
| The modified timing table | `erts/emulator/beam/erl_init.c:157-168@OTP-29.0.5` |
| Modified timing replacing the slice | `erts/emulator/beam/erl_process.c:9633-9638@OTP-29.0.5` |
| Reduction counting off on a dirty scheduler | `erts/emulator/beam/beam_common.c:196-204@OTP-29.0.5` |
| `erlang:yield/0` becoming an instruction | `erts/preloaded/src/erlang.erl:11519-11522@OTP-29.0.5` |

Evidence classes for the claims this blueprint carries are in `blueprints/ledger.toml` under CLM-SCHED-0001 through CLM-SCHED-0007. The invariants in section 4 name their class in the table.

Nothing upstream is quoted here. The Erlang/OTP source is Apache-2.0 and is cited rather than reproduced, except for the two short pseudocode restatements in sections 3.1 and 3.2, which are the dialect in `NOTATION.md` rather than the original code.

Checked against the pinned tree on 2026-09-02 by tamnd. The runtime figures in sections 5 and 6 were produced on two machines on the same day, both on OTP 29 erts-17.0.5 with the just in time compiler: aarch64 macOS 24.6.0 and x86-64 Linux in the `erlang:29.0.5` container image. The preemption counts, the two clamped `bump_reductions/1` figures, the frozen `process_info` readings during dirty execution and the `undefined` for a dead process were identical on both.

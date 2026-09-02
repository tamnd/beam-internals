# Capstones

Three reference implementations. Each one exists because it forces a different part of the book to be precise enough to build from.

**Track A, the loader and the interpreter.** Read a real `.beam` file, decode its chunks, and run the result. This is what proves the term representation and the instruction set were specified rather than described.

**Track B, the node.** Speak the external term format and the distribution protocol well enough that a stock Erlang node completes a handshake and exchanges messages with it. The wire formats are public standards, so this one has an external judge.

**Track C, surgery.** Change the runtime itself and defend the change. The deliverable is not the patch, it is the argument for why the patch is safe.

A capstone is finished when somebody else can run it against the conformance suite and get the same answer. Reference implementations here are read by learners, so they are written to be read, and the commentary is part of the deliverable rather than a comment on top of it.

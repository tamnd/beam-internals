# bxray

The observation library. An OTP application, installable on its own with rebar3, with no dependency on Livebook or on anything else in this repository.

It has one rule. It never tells you anything the BEAM would not tell you itself. It formats, it correlates, and it renders. It does not compute, guess, or smooth over.

`bxray:source/1` prints the underlying call for anything the library offers, so a reader can see exactly which BIF or trace flag produced a number, drop the library, and keep working. A library that a reader cannot walk away from has taught them the library rather than the runtime.

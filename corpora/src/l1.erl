%% The smallest module that still has something to compile.
%%
%% Six lines, three functions, one of them recursive with an accumulator. It is
%% the module the pass tape is recorded from, and the source of the figure that
%% a six line module goes through 33 top level passes and 60 named sub passes on
%% the way to a beam file.
%%
%% Do not add to it. The point it makes is that the pipeline runs in full for
%% something this small, and a module that grew a little every time somebody
%% wanted to show one more thing would stop making that point.
%%
%% bxtrace_pass_test carries its own copy of these six lines, so that the test
%% suite does not depend on the corpus being present. If you change one, change
%% both, and re-record corpora/passes/l1.tape.gz.
-module(l1).
-export([add/2, fib/1]).
add(A, B) -> A + B.
fib(N) -> fib(N, 0, 1).
fib(0, A, _) -> A;
fib(N, A, B) -> fib(N - 1, B, A + B).

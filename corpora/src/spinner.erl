%% A workload whose cost can be worked out on paper.
%%
%% A tail recursive loop of N iterations costs N reductions and nothing else,
%% which is what makes it worth recording. A tape that says something near N is
%% a tape that measured the loop, and a tape that says something far from N
%% measured the recorder.
%%
%% It is a module rather than a fun inside the recorder so that the command in
%% corpora/manifest.toml is one somebody else can run.
-module(spinner).
-export([spin/1]).
spin(0) -> ok;
spin(N) -> spin(N - 1).

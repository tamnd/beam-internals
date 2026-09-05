%% The one lie that makes a distribution handshake recordable.
%%
%% Two nodes shaking hands over TCP is easy to arrange and hard to watch. The
%% bytes go straight from one operating system socket to another, and the only
%% ways in are to run tcpdump as root, or to put something in the middle. Root
%% is not available in a container and is not something a recorder should ask
%% for, so this is the something in the middle.
%%
%% A relay cannot simply pretend to be the other node. The handshake carries the
%% responder's name and the initiator checks it, at
%% erts/emulator/../dist_util.erl:recv_challenge_new@OTP-29.0.5, where the name
%% that came back has to be the atom of the node that was asked for. So the
%% relay has to sit in front of the real node rather than replace it, and both
%% ends of the recording stay stock OTP.
%%
%% Getting the initiator to dial the relay is the whole job of this module. A
%% node about to connect asks its epmd module where the other node is, at
%% lib/kernel/src/inet_tcp_dist.erl:456@OTP-29.0.5, and `-epmd_module' says
%% which module that is. So everything here is handed straight to erl_epmd
%% except one answer: asked for the node being recorded, it gives the relay's
%% port instead of the real one. Nothing else about either node changes, and
%% neither of them can tell.
%%
%% Only the node doing the recording runs with this. The other node registers
%% with the real epmd and is found through it in the ordinary way.

-module(bxtrace_wire_epmd).

-export([start_link/0, register_node/2, register_node/3]).
-export([port_please/2, port_please/3, listen_port_please/2, names/1]).
-export([address_please/3]).

%% Everything that is not the redirect. The kernel supervisor starts whichever
%% module `-epmd_module' names, at lib/kernel/src/erl_distribution.erl:85
%% @OTP-29.0.5, so start_link/0 has to be here too even though there is nothing
%% of ours to start.
start_link() -> erl_epmd:start_link().

register_node(Name, Port) -> erl_epmd:register_node(Name, Port).
register_node(Name, Port, Family) -> erl_epmd:register_node(Name, Port, Family).
port_please(Name, Host) -> erl_epmd:port_please(Name, Host).
port_please(Name, Host, Timeout) -> erl_epmd:port_please(Name, Host, Timeout).
listen_port_please(Name, Host) -> erl_epmd:listen_port_please(Name, Host).
names(Host) -> erl_epmd:names(Host).

%% The redirect, and it is deliberately narrow. One node name is answered from
%% the command line and every other name goes to epmd, so a node running with
%% this behaves normally towards everything except the one peer being recorded.
%%
%% The four element reply is the short path. inet_tcp_dist takes an address and
%% a port together and never calls port_please/2 at all, which is what keeps the
%% real port from being looked up and used.
address_please(Name, Host, Family) ->
    case {relay(), init:get_argument(bxtrace_wire_peer)} of
        {{ok, Port}, {ok, [[Name]]}} -> {ok, {127, 0, 0, 1}, Port, 6};
        _ -> erl_epmd:address_please(Name, Host, Family)
    end.

relay() ->
    case init:get_argument(bxtrace_wire_relay) of
        {ok, [[Port]]} -> {ok, list_to_integer(Port)};
        _ -> no
    end.

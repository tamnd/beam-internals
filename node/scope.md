# What the Node defends against, and what it does not

The Node is a hosted sandbox that runs Erlang typed by anonymous people with no account and nothing installed. That is the whole point of it and it is also the entire risk surface, so this page says what the isolation is for, what it is not for, and how each control gets checked.

It is published before the sandbox exists. A set of controls written after a service is already up is a set of controls nobody outside the project can review, and the review is the part that matters.

Nothing is hosted today. The Node is on rung 4 of the ladder in `ladder.toml`, so every badge in the book links to the recorded corpus and there is no sandbox running anywhere. What follows is what will be true when there is one.

## What one session is

A Firecracker microVM restored from a snapshot, holding an unmodified OTP 29.0.5 release and a single Livebook session. Two virtual CPUs, 512 MB of memory, a read only root filesystem with a tmpfs overlay, no route off its bridge, and ten minutes. The gateway talks in. Nothing talks out.

At the end of a session the VM is destroyed and the snapshot is restored fresh for the next one. There is no shared filesystem, no shared network and no state carried across.

Distribution lessons need two nodes, so they get a pair of microVMs on a private bridge with a route to each other and nowhere else, started together and torn down together. That is the only case where a session has any network at all.

## What is defended

Every row here has a way of being checked that runs, because a control that is only ever read off a configuration file is a control nobody has tested.

| Threat | Control | How it is checked |
| --- | --- | --- |
| Escape to the host | Firecracker with the jailer. A minimal device model, a seccomp filtered VMM, one unprivileged process per VM, and no shared kernel with anything else we run. | A host side test asserts the VMM process runs under its own uid, in its own namespace, with no capabilities and the seccomp filter loaded. It runs on every deploy and fails the deploy. |
| Reaching our infrastructure | No egress. No route off the bridge, no DNS resolver, no NAT, no address translation to anywhere. | A session opens a connection to every address on a list, including our own gateway, and every attempt has to fail. Verified by running it rather than by reading the firewall. |
| Reaching third parties | The same control. A sandbox with network access is an open proxy, and this is the abuse case that would end the project. | The same test, with public addresses on the list. |
| Persistence into the next session | Read only root filesystem, tmpfs overlay, VM destroyed at the end, snapshot restored fresh. | A test writes a marked file, ends the session, takes a new one and looks for the mark. Finding it fails the deploy. |
| Reading another session | One VM per session, no shared memory, no shared filesystem, no bridge between them apart from a paired lesson's own private one. | The same paired test, run from the other side, checking a paired VM can reach its partner and nothing else. |
| Resource exhaustion | Two virtual CPUs, 512 MB, a disk quota on the overlay, ten minutes, one session per address at a time. | A session tries to take more than each cap and has to be stopped by the cap rather than by the host running out. |
| Denial of service on the service | A queue with a published position, rate limits per address and per network, a global ceiling on sessions, and a budget circuit breaker. | A load test at ten times expected concurrency has to degrade into the queue rather than fail, and the breaker has to move the ladder down on a synthetic budget alarm. |
| Mining | Ten minutes and two virtual CPUs make it uneconomic. A monitor flags sustained full use with no traffic on the session websocket. | A synthetic miner is run against the monitor and has to be flagged and cut inside the session. |

## What is not defended

Saying this plainly is worth more than a longer list above.

**Erlang and OTP itself.** A bug in the runtime is a bug for the OTP team, at https://github.com/erlang/otp/security. The Node runs an unmodified release on purpose, which means it inherits whatever is in that release.

**Upstream software we did not write.** Livebook, Kino, Firecracker and the host kernel, unless our configuration is what makes a bug in them exploitable, in which case it is ours.

**The fact that a stranger's code runs at all.** That is the product. Reporting that the Node executes arbitrary Erlang is reporting the feature.

**Anything about what you type being private.** A session is not confidential. Assume the code you run can be seen by the people running the service, and do not paste anything you would mind an operator reading. There is no account, so there is nothing to protect, and that is the trade the design makes.

**Timing and other side channels between a session and the machine under it.** A shared CPU is a shared CPU. The mitigations are whatever the host kernel has, and a reader who wants to measure the host from inside a VM can probably learn something about it. This is a book about a runtime, and half its lessons are about measuring things precisely, so pretending otherwise would be dishonest.

**Availability.** There is no service level anywhere in this project. The Node is expected to be down sometimes, and when it is, the badge becomes a link to the recorded corpus and every lesson still reads with every number in place. That is the ladder rather than an apology for not having one.

**Resource use inside the published limits.** Two virtual CPUs and ten minutes are there to be used.

## What a full escape would cost

The hosts run in an account of their own, on a network with no path to anything else this project owns. No secrets in the image. No credentials on the machines. No deploy keys, no registry tokens, no access to the repository or to the site.

An escape that reaches the host should cost the hosts and nothing else. A report showing it costs more than that is the report we most want, and it is the reason the blast radius is written down here rather than assumed.

## Before the badge is turned on

A third party review of the sandbox, with the findings addressed and the report summarised in public. Until that has happened the Node stays on rung 4, which is the state the book is written to survive.

Reports go through GitHub private vulnerability reporting on this repository. `SECURITY.md` has the process and the response times.

# Security

## Scope

This project plans to host a public sandbox that runs Erlang typed by anonymous users, called the Node. That is the whole point of it and it is also the entire risk surface, so the controls are written down rather than assumed.

In scope for a report here:

- Anything that escapes the microVM sandbox, reaches the host, or reaches another session.
- Anything that gets network traffic out of a session. Sessions have no egress at all, and a sandbox with network access is an open proxy.
- Anything that persists state from one session into the next.
- Anything that lets one session deny service to others beyond the published rate limits.
- Vulnerabilities in the code in this repository, including the tools, the widgets and the gateway.

Not in scope here:

- Vulnerabilities in Erlang/OTP itself. Report those to the OTP team through the process at https://github.com/erlang/otp/security, not to us. If you tell us first we will tell you the same thing and lose you time.
- Vulnerabilities in Livebook, Kino, Firecracker or any other upstream dependency, unless our configuration is what makes them exploitable.
- The fact that the Node runs arbitrary user code. It is designed to.
- Resource use inside the published limits of 2 vCPU, 512 MB and ten minutes.

## Reporting

Use GitHub private vulnerability reporting on this repository, under Security, Report a vulnerability. That gets a response within three working days.

If you would rather use email, the address is in the repository profile. Please do not open a public issue for anything in the escape or egress categories above.

Include what you did, what happened, and what you expected. A reproduction that another person can run is worth more than a description of the class of bug.

## What we will do

Acknowledge within three working days. Give you an assessment and a plan within ten. Fix escape and egress issues before anything else in the backlog. Credit you in the advisory unless you would rather we did not.

If the Node is affected, it goes to state 4 of the degradation ladder while the fix is prepared, which means the badge on every lesson becomes a link to the recorded corpus. Every lesson stays readable with all of its real output, so taking the sandbox down costs interactivity and does not cost information. That is why the ladder was designed before the sandbox was built.

## Design notes, for anyone reviewing the sandbox

Each session is a Firecracker microVM restored from a snapshot, with a read only root filesystem and a tmpfs overlay, no route off its bridge, no DNS, seccomp filters through the jailer, and a hard time to live. The VM is destroyed at the end of a session and the snapshot is restored fresh for the next one. The gateway talks in and nothing talks out.

Distribution lessons need two nodes, so they get a pair of microVMs on a private bridge with no route anywhere else, torn down together. That is the only case where a session has any network at all.

The hosts run in an account of their own, on a network with no path to anything else this project owns, with no secrets in the image and no credentials on the machines. A full escape should cost us the hosts and nothing more. If you find a way to make it cost more than that, that is the report we most want.

# Security

Semel is pre-1.0 software. It runs the compilers and linkers a project's formula names,
in sandboxes of its own making, on the machine that runs `semelserv`; it fetches
nothing, and the only network traffic is between `semel` and `semelserv` over a
Unix-domain socket on that machine.

## Reporting a vulnerability

Please report a vulnerability privately through GitHub's private vulnerability
reporting on this repository, rather than in a public issue. Say what you found, how
to reproduce it, and what you think it allows. You will get an acknowledgement within
a week, and a fix or a decision as soon as there is one.

## What is in scope

- A formula, a config file or a pushed source that makes the engine or a tool read or
  write outside the input file system, the object store and the sandbox it was given.
- A way to make one user's `semelserv` act on another user's behalf on a shared machine.
- A cache entry that is served for inputs it was not computed from.

## What is out of scope

- The tools themselves: a defect in `swiftc`, `clang`, `actool` or `libtool` is theirs.
- A project that runs arbitrary code by design, such as a build-tool plugin or a script
  build phase, which Semel does not run today.

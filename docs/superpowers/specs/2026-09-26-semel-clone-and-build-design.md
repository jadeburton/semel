# Clone and build: `semel build` (B-110)

**Status:** proposed
**Date:** 2026-09-26
**Builds on:** B-109 (the two-file configuration), B-30 role 3 (the local daemon).

## What a stranger goes through today

Both routes were walked by hand on 2026-09-26 with a throwaway home, as a person who had
just cloned a project would. The transcripts are the evidence for every claim below.

**A C project.** Start `semelserv` in one terminal. In another,
`semel 'base tree' 'build hello --into out' check`. The result is **25 errors across 9
nodes, printed twice**: the same "Missing configuration" paragraph once per compiler and
preprocessor node, eight times, then the whole block again as the settle report — about a
hundred and fifty lines carrying four lines of information. The root cause,
`clang.cfg has not been pushed`, is the last error: the formula says `<../clang.cfg>`, one
level above the folder `build` pushed, and nothing says `push clang.cfg`. Fixing the settings
means running `tools` three times, pasting, and knowing to add `sdkPath`, `target` and
`cStandard` by hand — `tools clang.compiler` prints the four descriptor lines and not
`sdkPath`, so the reader cannot see what is still missing without another failed build.
After that: three products, and the second build reports `5 computed, 4 from cache`.

**A Swift package, the README's route.** `build swift/MyApp` fails on a missing
`semel.config`; the report says to run `tools swift.packageReader`, and the real answer,
`semel-swift prepare`, is not named. `prepare` itself is the best moment in either
transcript: one command, clear output. The next build fails on `MyLibrary`, the path
dependency beside `MyApp`, which `build` did not push; the error names the folder and the
fix is a `push` the README mentions in a comment. Its hint reads `semel-swift
<package-root>`, without the verb. And every build from then on prints a warning that
`semel.config` holds unused `clang.*` keys, because `prepare` wrote clang settings for a
package with no C targets.

**First hurdles.** `semel help` is "Unknown command: help". A typo gets no suggestion.

The engine's side of both transcripts is right: the graph settled, the products matched,
the second build hit the cache. Everything wrong is on the road to it, and all of it is the
client's to fix.

## The target

```
git clone …/hello && cd hello
semel build
```

On a machine that has never seen the project, that either builds, or prints **one command
to run next**. `build` starts the engine if none is running, pushes what the formula
declares it needs from the tree, waits, reports each cause once, and exports the products
to a known folder.

## Decisions

- **The engine starts itself and stays.** `semel` that finds no server at the socket
  starts `semelserv` beside its own executable and connects; the daemon is left running,
  as a resident graph should be (B-30 role 3). `semel stop` ends it, and so does removing
  the socket file (B-73). Nothing is stopped on the client's behalf.
- **`build` follows the formula's inputs within the tree.** A formula declares what it
  reads; when a settle reports a source that has not been pushed and that source exists
  under `base`, `build` pushes it and waits again. Each push is printed with the formula
  that asked for it, and `--no-follow` turns it off.
- **Products go to `semel-out` under `base` when `--into` is not given**, and `push` never
  sends that folder back in.
- **One error per cause.** Nodes of one type carrying one message are one entry, and the
  settle report is printed once.
- **`help` exists, and a typo names its nearest verb.**

## The engine starts itself

`semel` connects to `SemelPaths.serverSocket`. When nothing listens there it prints today
`no server at <socket>; start one with semelserv` and exits. Instead it starts
`semelserv` — the executable beside its own, found through `CommandLine.arguments[0]` —
with the environment it has (`SEMEL_HOME`, `SEMEL_SOCKET` pass through unchanged), waits
for the socket the way the end-to-end harness's `SocketWait` does, and connects. One line
says so: `Started semelserv (graph: …/graph.sqlite)`.

The daemon outlives the client. That is the point of a resident graph: the next `semel`
finds it warm. `semel stop` asks it to exit, which is the shutdown B-73 already built for a
removed socket file. There is no idle timeout; a machine's user decides when the engine
goes, as with any other daemon they keep.

Two clients starting a server at once is the race `Server.swift` already refuses: the
second finds the socket taken, and connects to the first.

## `build` follows the formula's inputs

`build <folder>` is `push <folder>`, `wait`, `errors`, and then `export`. It becomes a loop:

1. `push <folder>`, `wait`.
2. Every source the settle reports as **not pushed** names a path in the input file system,
   which is one path under `base` on disk (`input:/clang.cfg` is `<base>/clang.cfg`).
3. For each such path that exists under `base`: push it, printing which formula asked.
4. `wait` again, and repeat from 2 until a round pushes nothing new. Then report and export.

```
Push folder: hello
Push file: hello/hello.fmla
Push file: hello/src/hello.c
…
hello/hello.fmla needs ../clang.cfg
Push file: clang.cfg
✅ 23 nodes scheduled, 23 computed, 0 from cache, 0 errors
   appeared: output:/hello/hello
   …
Exported 3 files into /…/tree/semel-out/hello
```

For the Swift package the second round pushes `swift/MyLibrary`, named by the converter.

**The rules that keep it inside expectations:**

- **Only under `base`.** `base` is the boundary of the user's tree, and the folder named is
  where the formula is, not the boundary. A formula reaching outside `base` gets the report
  and no push — the same line `prepare` draws: nothing is fetched, everything comes from
  the tree. It follows that the behaviour depends on where the user stands: from `tree/`,
  `semel build hello` finds `clang.cfg`; from inside `hello/`, `semel build .` has `base`
  at `hello/` and reports `../clang.cfg` as outside it. That is what `base` means already,
  and `help` and the README say it in one sentence: *build follows the formula's inputs
  within your tree.*
- **Only what the graph asked for.** Nothing is pushed unless a node reported it absent by
  name. A large unrelated folder beside the project stays where it is.
- **Only what exists.** A reported path that is not on disk stays an error; the user really
  lacks it.
- **Said every time, with the reason.** `hello/hello.fmla needs ../clang.cfg` before the
  push line, so the reach is visible when it happens and attributed to the formula the
  user wrote — or `prepare` wrote — rather than to `build`.
- **`--no-follow`** pushes the named folder and nothing else, as today. Rarely wanted; its
  line in `help` is what tells a reader the default follows.
- **Bounded.** A round must push a path it has not pushed before, or the loop stops.
- **Client side.** Pushing is the CLI's; the daemon never reads the user's disk.

**The report carries the path, typed.** The client today would have to recognise
`has not been pushed` in an `ErrorEntry`'s message. `ErrorEntry` gains an optional
`missingSource: String?` — the input-file-system path — set by `ErrorReport` where it
writes that sentence, so the client acts on a field and the sentence stays prose.

`alsoPush` leaves the end-to-end roster: it hand-coded this rule per fixture.

## Where the products go

`--into` stays, and stays the export; without it, products go to `<base>/semel-out/<folder>`.
The name is stated in `help` and in the line `build` prints, and `push` **never sends the
export destination** — `build` knows it, and excludes it from the walk — so a later
`build .` from `base` does not push yesterday's products in as today's sources. That rule
holds for `--into` pointing inside the tree as well.

## One error per cause

`ErrorReport.entries` folds a cascade onto its causes (B-74) and reports one entry per
node. Eight compilers each missing the same four settings are eight entries carrying one
paragraph. They become one:

```
❌ ClangCompiler ×3 (#21, #25, #27)
   · Missing configuration. …
```

The fold is by type and by the entry's items, after the cascade fold, in `ErrorReport`
rather than in a renderer, so the `errors` event and the `errors` verb agree. The
`downstreamCarrierCount` of the folded entry is the sum.

**Printed once.** `build` runs `errors` after `wait` so that a scripted run has the whole
report in its output, and the idle-time `errors` event has already printed the same
records as they arrived. The event is what a subscribed prompt should see; a `build` that
will ask for the report at the end suppresses the event's printing for its duration and
prints the report once. The exit-status accounting (`countErrorRecords`) is untouched: it
counts records, not lines.

## The report names the one command

`RequiredSettings` says "Run `tools <namespace>` … as a block to paste". With B-109 it says
`tools --write semel.machine.config` for the machine keys, and lists the project keys with
`=…`. When the tree holds a `Package.swift` and no `semel.config`, the builder's own report
names `semel-swift prepare <folder> --platform <p>`: `prepare` is the command for that
tree, and the report is where a reader looks. The converter's hint gains its verb:
`semel-swift prepare <folder>`.

`prepare` writes the namespaces the tree's converters will read and no other: `clang.*`
only when a manifest declares a C-family target, which `PackageScan` already reads. The
unused-key warning then says something when it fires.

## `help`, and typos

`help` lists every verb with one line each, grouped as the README groups them, and `help
<verb>` prints that verb's line and its flags. An unknown verb names the nearest registered
one when the edit distance is small: `Unknown command: buidl — did you mean build?`.

## Constraints

- **`base` is still a session concept.** It defaults to the current directory, which is
  what makes `cd hello && semel build` work; the fence rule above is what makes it matter.
- **`check` is not part of `build`.** The harness runs it explicitly, and a user who wants
  it types it.
- **Nothing here changes the engine's model.** Every change is in the CLI, the protocol's
  error record, `ErrorReport`'s folding, `prepare`, and the reports' wording.

## Acceptance

1. With no server running, `semel build hello` starts one, says so, builds, and leaves it
   running; a second `semel ls` finds it. `semel stop` ends it and removes the socket.
2. The C fixture with `clang.cfg` beside its folder and the Swift fixture with `MyLibrary`
   beside its package both build from a single `build` with no `push`, printing the
   attributed line; `--no-follow` reproduces today's report. The roster's `alsoPush` is gone
   and every fixture still passes.
3. A formula naming a path outside `base` gets the report and no push; a reported path
   missing on disk stays an error; the loop stops when a round pushes nothing.
4. Without `--into`, products land in `<base>/semel-out/<folder>`, `build` says so, and a
   following `build .` from `base` pushes nothing under `semel-out`.
5. Eight nodes of one type with one message are one entry naming all eight; `build` prints
   the report once; the exit status is unchanged.
6. `help`, `help build`, and `buidl` → "did you mean build?".
7. `prepare` on a package tree with no C target writes no `clang.*` block, and the build
   prints no unused-key warning.
8. The tutorial's Part 1 opens `semelserv` for the reader in one terminal because the
   tutorial watches its log; the README's clone-and-build section is `prepare` then
   `semel build`, with the daemon started for the reader.

## Open questions

- **`semel-out` or `.semel-out`?** A hidden folder is out of the way; a visible one is
  findable. The push exclusion makes either safe.
- **Should `build` run `prepare` for a package tree that has no config?** It would make the
  Swift route one command. Against: `prepare` vendors dependencies and writes files into
  the checkout, which is more than a build should do unasked. Left as a named command, for
  now.

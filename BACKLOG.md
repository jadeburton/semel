# Backlog

Bugs: what is broken, wrong or owed in what exists. Features and direction are in
`FUTURE.md`, whose items take their IDs from the same sequence.

IDs are stable and never reused, and one sequence spans both files — the next ID is one
above the highest in either. Reference them in commits (`closes B-07`) and in discussion.
Status is `open`, `doing` or `dropped`. Finished items are removed rather than marked done:
the commit that closed one carries its reasoning, and `git log --grep=B-07` finds it. An
item that turns out to be a feature moves to `FUTURE.md` and keeps its ID.

An item tagged `For Fable Only` is one where choosing the approach is most of the work — an
architectural boundary, an invariant, a semantics decision, a design with more than one
defensible answer — so it is done by the most capable model available and not delegated.
An untagged item is mechanical, specified by a design already written, or found by
experiment, and any model can take it.

## Cache

## Command line

What a user sees at the prompt. Found by using `semel` on IceCubesApp and the C fixture
(2026-09-23); the engine-side report these lean on is the settle-time artifact diff, which
the `artifacts` event carries.

**B-110** `open` `For Fable Only` — **Clone and build: `semel build` is one command — residuals.**
Done 2026-09-26 (design and "As built":
`docs/superpowers/specs/2026-09-26-semel-clone-and-build-design.md`): `semel` starts the
engine it finds missing and `semel stop` ends it; `build` follows the formula's inputs
within `base` — a source the settle reports as not pushed travels typed as
`ErrorEntry.missingSource`, is pushed with `hello/hello.fmla needs ../clang.cfg`, and the
build waits again; `--no-follow` — and the roster's `alsoPush` is gone; products go to
`<base>/semel-out/<folder>` and `push` never sends an export folder back in; nodes of one
type carrying one report are one entry, printed once; a failed build of a package tree
with no config names `semel-swift prepare`; `prepare` writes `clang.*` only for a tree with
a C-family target; `help`, and a typo names its nearest verb. Done 2026-09-28 ("Residual
1, as built" in the same document): a package dependency outside the built folder is one
round — a stalled converter demands the folder of each package it waits for, which the
settle reports as an unpushed source like any other, and a source under an unpushed folder
something needs is reported as that folder's detail, so `build` prints `Packages/semel.fmla
needs ../Helper` and pushes the package whole. What remains:

1. **A changed source outside the built folder is not re-pushed.** `build` follows what is
   reported missing; a `semel.machine.config` beside the folder that is rewritten after a
   toolchain change is the user's to `push`. Following the inputs the graph already holds
   outside the folder would close it. Design rather than mechanics: it needs a decision on
   how far `build` reaches unasked into sources outside the folder.

**B-161** `done` — **A refused push of a large locked folder said only that a reply was too
large, and `ls` then showed `(empty)`.** Reported 2026-10-12: about 20,000 files pushed, `ls`
printed `(empty)`; under `begin`, `push`, `ls`, `commit`, `ls` the files were listed inside
the batch and gone after the `commit`, and nothing printed read as an error. Reproduced on
main at 1e372b2 with release binaries: the tree held a locked folder, `Dependencies/<name>`
with its `.semel-lock`, whose lock did not match what the pushed folder folds to. The lock
barrier (B-146) worked as designed: the outermost `commit` refused the batch, the unlocked
files pushed beside the folder with it, and replayed it whole; an unbatched push is a batch
of one and is refused the same way. What hid it was the refusal itself. `batchRejected`
named every changed path below the locked folder, and with 20,000 of them the `endBatch`
reply was 1,064,529 bytes, over the frame's 1 MiB limit, so the server sent `replyTooLarge`
in its place and the client printed `the server's reply to 'endBatch' is … bytes, over the
1048576-byte limit for one reply; …`: nothing about the batch being taken back, which lock
refused it, or how to re-lock. The interactive client also reset its batch depth only on
`batchRejected`, so after the `replyTooLarge` it believed a batch still open that the server
had closed, and the next `commit` closed nothing. Not caused by a recent merge: the barrier
dates from #175 (2026-10-09). Separate invocations (`semel begin`, then `semel 'push tree'`)
are separate sessions, and a session's batch is committed when it ends, by design.

Fixed 2026-10-12. `batchRejected` names at most `ErrorResponse.batchRejectedPathsListed`
(50) of the batch's paths and counts the rest in a field of its own, `pathsNotListed`, so the
refusal fits one frame whatever the batch's size (protocol 31); the client prints the first
five, as it did, and `and N more`, N counting the carried paths it does not print with
`pathsNotListed`, and a line `input: as it was before the batch; nothing the batch
pushed or removed is there`, beside the folder, lock, expected, found and the remedy
(`re-lock with: semel-swift prepare`). An outermost `commit` that fails for any reason now
leaves no batch open at the client, since the server closes the batch before it answers.
The owner then confirmed the lock's refusal was what they hit, and that they missed it
because it came after the line saying the files were pushed; two more changes follow from
that. A push says what it did only once its batch's fate is known: `Pushed N files` when its
own batch commits; when the barrier refuses it, `push: N files sent, and none of it
committed`, decided from the typed refusal and printed as the refusal's first line; inside a
batch the user opened, `Sent N files, pending the commit`, and `commit` then says
`Committed.` or prints the refusal. And every error the client prints starts with ❌, added in
one place, `ErrorMark`, which `CommandInterpreter.outputError` and `main`'s few errors before
an interpreter exists go through.

`FrameMessageTests` pins the bounded rejection within a frame; `SessionPluginTests` the
depth; `LockedFolderEndToEndTests` pushes 20,000 files under a mismatched lock, unbatched
and under `begin` … `commit`, through the real `semel` and `semelserv`, and checks the
printed paths and count, the push's lines and the mark; `LockedFolderServerTests` checks
over a socket that a refusal of 1,001 paths carries fifty and counts the rest.

Open for the owner, not decided: whether a mismatch in one locked folder should reject the
unlocked files pushed beside it in the same batch. B-146 made a batch all or nothing, which
is what a mirror's atomicity rests on; the cost is that a push of a whole tree lands nothing
when one vendored copy has moved.

**B-163** `open` — **`restore`'s reply lists every path it changed, and a restore across a
large tree passes the frame's limit.** Found 2026-10-12 while fixing B-161, not seen in use.
`DaemonResponse.restored(name:contentRoot:changedPaths:)` carries every path the restore
changed, so a restore between two checkpoints that differ by tens of thousands of files —
a re-vendor of a large package, or a tree pushed whole — makes a reply over the 1 MiB
limit, and the client hears `replyTooLarge` in place of what the restore did, though the
restore itself stood. The fix is B-161's shape: a bounded sample of the paths and an
integer count of the rest, as fields of the typed reply, with a protocol bump. (B-162 is
taken by another agent's PR not yet open; this entry skips it.)

**B-164** `done` — **`push **/*.*` was refused by Charts' lock, and the refusal gave two
hashes and no way to see that one file was missing.** Reported 2026-10-12 on main with
Charts 5.1.0 vendored by `semel-swift prepare` (lock `Dependencies/Charts.semel-lock`,
content root `sha256:82e51b57…`, exactly what a fresh `prepare` writes):

```
push **/*.*
push: 20730 files and 314 folders sent, and none of it committed
Dependencies/Charts is locked, and the batch changes it without a lock it matches: nothing of the batch is committed
  lock: Dependencies/Charts.semel-lock
  expected: sha256:82e51b57…  found: sha256:783cd4bc…
  paths: Dependencies/Charts, Dependencies/Charts.semel-lock, Dependencies/Charts/Assets, … and 654 more
  input: as it was before the batch; nothing the batch pushed or removed is there
```

No `Not on disk, kept:` line, so the engine held nothing stale. The cause: `**/*.*` matches
only names holding a dot, and Charts has `LICENSE` at its root, the only dot-less regular
file in the 5.1.0 tree. The lock covers it, the push never sent it, and the folder the
batch left folded to another root. The barrier was right to refuse; the push was wrong to
send part of a locked folder, and the refusal could not say which part was missing.

Fixed 2026-10-12, in two parts.

1. **The refusal names what the folder lacks and what it holds beyond the lock.**
   `batchRejected` gains `listing`, a `LockListing` (SemelNodeKit, shared with
   `ErrorCondition.batchRejected`; protocol 32): `compared(notPushed:notPushedNotListed:
   notInTheLock:notInTheLockNotListed:)`, each list bounded at fifty as B-161's paths are
   and the rest counted; `lockTreeNotHeld`; or `notComparable` for a lock that does not
   parse or was folded under another format. The barrier computes it inside the commit's
   savepoint, before the replay, by walking the lock's root and the folder's pushed root
   together through their documents (`FolderContentRoot.namesDiffering`, on
   `lines(ofDocument:)`), into a subfolder only where the two roots differ; a name on one
   side only is said once, a folder with a trailing `/`. The client prints `not pushed:`
   and `not in the lock:` after `found:`, five names and `and N more`; B-161's lines,
   wording and mark are unchanged. The lock's documents are in the engine's store only
   once the engine has folded that tree itself — its root is a hash `prepare` took of the
   disk — so a copy the engine has never accepted as its lock describes it, the owner's
   first push among them, cannot be compared name by name, and the refusal says `not
   compared: the engine holds no copy of the tree the lock records, …`. Once a copy has
   landed, a later batch that leaves it short — an `rm`, a partial push, another copy of
   the same release elsewhere in the tree pushed in part — is named file by file.
2. **A push that reaches a locked folder pushes it whole.** In `push`, a matched entry
   below a folder `F` with `F.semel-lock` beside it on disk stands for `F` whole, read from
   the disk as `push F` sends it, and the push says so first: `Pushing
   Dependencies/Charts whole: it is locked` (several folders on one line, named as a push
   names paths). It applies to patterns and to lists of files; a folder the push already
   sends whole is left alone, the nearest locked folder above an entry is the one widened
   (the one the barrier checks it against), and nothing outside the locked folder is
   added. A pattern that matches only the lock itself widens too when the server does not
   hold that lock as the disk has it: a lock pushed anew names its folder, and after a
   re-vendor the lock alone would only be refused. A lock the server holds byte for byte
   does not widen, which is what keeps `semel-watch` — whose launch mirror pushes a tree's
   locks while leaving the locked folders alone — as it was. The widening only adds; B-162's
   removal for a new lock follows from the folder's expansion as before.

Tests: `LockedFolderWholePushTests` (root, six: `**/*.*` over two locked copies holding a
`LICENSE`; a pattern reaching one; a file list; a lock alone; a lock the server holds;
folders already whole); `LockedFolderEndToEndTests.test_aGlobPushOfAPreparedTreePushesTheLockedCopyWholeWithItsLicense`
(real `prepare` of a repository with a `LICENSE`, then `push **/*.*` through `semel` and
`semelserv`); `LockedFolderServerTests` (a partial push of a second copy of a held release
names `LICENSE` as not pushed and the client prints it; an `rm`; files and a folder not in
the lock; a tree never held is `lockTreeNotHeld`); `FrameMessageTests` and
`MessageJSONTests` (the fields bounded within a frame, round trips);
`ErrorRenderingTests` (five and the count on each line, the not-compared line);
`FolderContentRootNamesDifferingTests` (SemelNodeKit). The widening tests and the server's
listing tests fail with their fix taken out.

Checked by hand with release binaries, a package depending on Charts 5.1.0 and a fresh
`prepare` (lock `sha256:82e51b57…`): on main at 4116caa `push **/*.*` was refused with
`found: sha256:783cd4bc…`, the owner's two hashes; with the fix it printed `Pushing
Dependencies/Charts whole: it is locked` and `Pushed 580 files and 1 folder`, and `ls`
showed `LICENSE`. An `rm Dependencies/Charts/LICENSE` after it was refused with `found:
sha256:783cd4bc…` and `not pushed: Dependencies/Charts/LICENSE`: the one file the owner's
push left out.

**B-167** `done` — **A push of a large tree said nothing for tens of seconds.** Reported
2026-10-17: "When I use the semel CLI to push files, there is almost no feedback for a very
long time." The owner pushes trees of about 20,000 files. Measured on main at 3734886 with
release binaries, a fresh home and a `semelserv` started first, pushing a generated tree of
20,730 files in 337 folders, 436 MB, sizes from 1 KB to 1 MB (93% under 16 KB), with
temporary timing lines in the client and the server:

| phase | `push tree` (cold) | `push tree` (unchanged) | `push tree/**/*.*` (cold) | `push tree/**/*.*` (unchanged) |
|---|---|---|---|---|
| connect, banner | 0.6 s | 0.02 s | 0.6 s | 0.02 s |
| wildcard match (walk, `lstat`) | — | — | 0.67 s | 0.74 s |
| server's roots (`contentRoots`) | 0.001 s | 0.017 s | — | — |
| walk, read and hash on every core (`FolderOnDisk.read`) | 1.36 s | 1.58 s | — | — |
| work list | 0.03 s | 0.04 s | 0.08 s | 0.09 s |
| first `pushFiles` leaves | +1.4 s from the push's start | (none sent) | +0.76 s | +0.84 s |
| sending, pipelined (2 in flight × 64 files / 8 MB) | 21.7 s | 0.003 s | 26.5 s | 9.9 s |
| of which the server's interning, off its queue | 4.2 s | — | 4.8 s | 1.0 s |
| of which the server's recording, on its queue | 21.8 s | — | 26.5 s | 9.9 s |
| the implicit batch's commit (`endBatch`, the lock barrier) | 0.53 s | 0.001 s | 0.38 s | 0.48 s |
| total, start to `Pushed` | 24.4 s | 1.7 s | 27.8 s | 11.3 s |

Until `Pushed 20730 files and 1 folder` the user saw nothing at all: one line, printed once
the commit had answered (B-161), after 24 s of silence. The settle is not a phase of the
push: the push does not wait for it, and its summary arrives as an event, at the prompt or
during the next command. Recording on the server's one queue is the push's cost — about
1.05 ms a file, creeping from 60 ms to 78 ms per request of 64 over the push; the client's
own work is under 2 s, and the pipeline keeps the queue fed. Two slower-than-they-should-be
findings, measured and filed as B-170 and B-171: a wildcard push of files the server
already holds sends and records every one of them (9.9 s for 20,730 unchanged files),
because B-132's comparison runs only for a folder argument; and the server's recording
time per file is about a third above the 0.75 ms the 2026-10-04 measurement of a 4,537-file
push implies.

Fixed 2026-10-17. At a terminal, a push says what it is doing on one line redrawn in place
(carriage return and erase, no scrollback): `Reading files…` from the first moment, before
a wildcard's walk; `Comparing with what the server holds…` while it waits for the roots or
the children; `Reading 12,800 of 20,730 files…` while the folder is read and hashed, from the
listing on, every 256 files (`FolderOnDisk.read(…, onFilesRead:)`); `Pushing 8,192 of
20,730 files (160.0 MB sent)…` as each batch's replies come back, counted as the last line
counts and the bytes being what the server has answered for, none for a file it already
held; then `Committing 20,730 files: waiting for the server…`, since the commit is one reply
whose progress the client cannot see. Inside a batch the user opened there is no commit,
and no such line. The line is erased before the push's own lines, on every way out, so
`Pushed` is still said only once the batch has committed and a refusal still prints with its
`❌`; a line printed meanwhile — a file that cannot be read, a settle's summary — lands above
it and the line comes back. A new phase is drawn at once and a count within one at most
every 0.1 s. It is drawn by the progress indicator (`IndicatorLine.show`, `PushStatus`) and
so only where the progress line is: a terminal, not `dumb`, not `SEMEL_PROGRESS=0`. A pipe,
a script's log and `semel-watch`'s reports see exactly the lines they saw before. Nothing of
it crosses a port. Checked by hand under `script(1)` with the same tree: the first line
0.0 s after the banner, the read's counts from 0.5 s, `Pushing` from 1.7 s, moving every
0.13 s for 23 s, `Committing` for 0.4 s, then `Pushed`.

Tests: `PushStatusTests` (root): the phases' wording; a folder push going through every
phase from the first moment, with the counts only growing to the total; the commit said
before `endBatch` and the line gone before `Pushed`; no commit inside an open batch; the
line erased before a refusal is thrown; a wildcard push; and the indicator's drawing — at
once on a new phase, held back within one, around a printed line, erased for good, cut to
the width, nothing when disabled, and a settle wait taking the line. `FolderOnDiskTests`
(SemelNodeKit) for the read's counts. The push's phase tests fail with `FilePlugin.swift`
as it was.

**B-169** `done` — **The summary line claimed `every product has a value` over a graph with no
products, and the prompt's "has a value" read as engine talk.** Reported 2026-10-17 by the
owner, verbatim: "I got semel itself to build inside semel without errors, then I deleted
semel.machine.config inside semel. It correctly removed all output files but the error
message is confusing: `no product:` / `semel.machine.config has been removed` / `1 error ·
every product has a value`. "every product has a value" is the confusing part. There are 0
products here. I also think we need to rework the term "has a value", it exists in other
places of the UI but it is a bit esoteric. Other options: "is in error" (when has no value)
or "is pending" when has no value but soon will, or "exists" if we really have to say it has
a value. The `ls` command should align the rightmost column of statuses such as `[pending]`
etc." Reproduced on main at 3734886 with release binaries on `swift/CPackage`: build, `rm`
its `semel.machine.config`, then `errors` printed exactly that, and `ls` staggered its
statuses by name length (`hello  [failed]` over `hello.dylib  [failed]`). The summary counted
only the products the error records named, so a graph with none said every one had a value,
and nothing told the reader that the removed file was the machine's configuration or how to
get it back.

Fixed 2026-10-17, in the client's words only; the engine's vocabulary (`NoValueReason`, "has
a value") is unchanged. The owner's wording, refined the same day: a product holding a value
is **up to date** — a declarative state, where "built" read as an event — one without is
**pending** or **in error**, and a source pushed and then taken away is **removed**.
`ValueState` in the client is the one table, by case:

| `NoValueReason` | word |
|---|---|
| (a value) | up to date |
| `pending` | pending |
| `initializing` | pending |
| `inputNotProduced` | pending |
| `inputInError` | in error |
| `error(documentHash:)` | in error |
| `deleted` | removed (neither pending nor in error: nothing the graph will produce by itself) |

- **The summary line counts the graph's products**, from a `ProductTally` (`products`,
  `upToDate`) the server reads with `ProductReach.tally` — a tree product once, by its folder
  — and sends with the `errors` reply and the idle-time event (protocol 34): `1 error · 2 of 5
  products up to date`, `no errors · 5 products up to date`, `3 errors · no products up to
  date`, and with zero products `1 error · no products`. `errors` with no errors and a clean
  `build` print it where they printed `No errors.`. The monitor's card, which has only the
  records, says `1 error · 2 products in error`, and nothing about products when they name
  none.
- **`no product:` is left out when the graph holds no products.**
- **A removed machine file is its own condition**, `ErrorCondition.machineFileRemoved(path:)`
  in `SemelNodeKit`, decided by the engine from the removed `StaticFile`'s name (the one name
  B-109's writers write), with the `write with:` remedy the unpushed file already had — the
  command each namespace selected out of it registered, here `semel-swift prepare`, B-109's
  writer of the Swift half (`semel-clang` writes the clang half). No node publishes it, so no
  `implementationVersion` moves; the protocol bump covers the record's document.
- **`ls`** prints `[up to date]` beside a product in `output:` holding its value, `[pending]`
  for what was `[not produced]` there, `[in error]` for `[failed]`, `[removed]` for
  `[deleted]`; `[not pushed]` and `[unreferenced]` stay. The status column is right-aligned to
  the one column the longest name with a status and the longest status of the listing
  reach; mode and size are unchanged. A source in `input:` holding its value, and a folder, carry no status.
- `errors <product>` with nothing stopping it says `libModels.a has no errors.`; the
  converter's waiting states read `include files pending: …`; the monitor's products window
  marks a failed product `in error`.

After, the owner's scenario:

```
swift/CPackage/semel.machine.config, the machine's configuration, has been removed
  write with: semel-swift prepare swift/CPackage

1 error · no products
```

Tests: `ErrorRenderingTests` (the summary line in its four shapes and after an export, the
fallback without a tally, the graph with no products and no heading, each `NoValueReason`'s
word, the removed machine file's lines), `NavigationPluginTests` (every `ls` word, `[up to
date]`, right alignment with names of different lengths), `ProductReachTests` (the tally),
`UnpushedFileReportingTests` (the removed machine file's document and remedy, and a removed
file of another name), `RequestHandlerTests` (the tally in the reply and the event).

## Performance

Measured 2026-09-27 on the IceCubes packages tree (`C1/icecubes/Packages`, thirteen
packages, 26 Swift targets): a cold build of 321 s into an empty home, 2,627 nodes; a
rebuild with nothing changed took 18.7 s and a one-file add 35.5 s for six scheduled nodes,
neither broken down yet. With a compiler that compiles once its folder walk has finished
(B-112), the cold build took 93 s; with results written as each node finishes rather than
once a whole batch has (B-113), 85 s.

Measured 2026-09-28 on the IceCubes app tree (`icecubes-app`, 8039 files pushed, a fresh
home, debug build): a cold build of 146 s; a second build with nothing changed 17 s, of which
`push icecubes-app` alone was 14.9 s, the export 0.9 s and the settle 0.01 s; a one-file edit
rebuilt in 19.9 s, the push again about 15 s. The push cost about a dozen serialised
database reads per file, a lookup and a pin read per folder on the way to it. With the root,
the path, its pins and the file's ports read in one query, and an unchanged file hashed
rather than stored (B-131), an unchanged push of the same tree took 5.0 s against 15.7 s
measured before on the same machine, a one-file edit's push 5.0 s against 15.6 s, and a
build with nothing changed 10.2 s against 17.3 s; the cold build was 142 s against 148 s.
A `sample` of the server puts about two thirds of the remaining push in the request handler,
most of it that one query — parsing it is a third of its cost — and the rest in the round
trip each file makes. What remains is one request per file, which a push that sends a
manifest and only the bytes the server lacks would remove (B-132).

Measured 2026-09-29 against `xcodebuild`, the first comparison with a build Semel did not
make: the same pinned commits, the same Apple M4 (10 cores), Xcode 26.6, Debug, package
resolution excluded, Xcode with `CODE_SIGNING_ALLOWED=NO`, fresh derived data and its
compilation cache off, Semel's release binaries into a fresh home. Each row is one build.

| NetNewsWire, Mac (`netnewswire-mac`) | `xcodebuild` | Semel |
|---|---|---|
| clean build | 32.0 s | 61.2 s, plus `prepare` 25.7 s once per clone |
| nothing changed | 8.7 s | 1.7 s |
| one app-level file edited (`Mac/AppDelegate.swift`) | 8.6 s | 9.2 s (427 nodes: the signed bundle re-published) |
| one base-package file edited (`RSCore/AppConfig.swift`) | 9.0 s | 6.5 s (478 nodes, 30 from cache) |

| IceCubes app, simulator (`icecubes-app`) | `xcodebuild` | Semel |
|---|---|---|
| clean build | 93.9 s | 95.6 s, plus `prepare` 32.7 s once per clone |
| nothing changed | 5.1 s | 4.3 s |
| one app-level file edited (`Tabs/ToolbarTab.swift`) | 5.6 s | 12.9 s (5 nodes) |
| one base-package file edited (`Env/CurrentAccount.swift`) | 5.7 s | 6.4 s (55 nodes, 24 from cache) |

Semel's Mac build signs the bundle ad hoc, Xcode's is unsigned. What the rows say: a cold
build is Xcode's by two to one on NetNewsWire and even on IceCubes; a build with nothing
changed is Semel's; a one-file edit is even, except the IceCubes app-level edit, where
Semel's 12.9 s is the push of 8,039 unchanged files (about 5 s) and one module's compile
and relink behind it. The push is B-132's; the cold build's gap is the converters' passes
and the per-node cost B-124 left, and the signed bundle re-publishing every entry after
an executable changes (427 nodes for one edit).

Measured 2026-09-30 on the IceCubes app tree (`icecubes-app`, 8,041 files, release binaries,
a fresh home each, the cached checkout less `.git`, `prepare --platform ios-simulator`),
after a push that compares roots with the disk and sends only what differs (B-132), against
`main` before it, built and run the same way in the same hour. The machine was shared —
load average 13 to 16, another agent building — so the cold builds took 204 s where the
rows above took 142 s; the two columns were run back to back and compare with each other.

| IceCubes app tree | before (B-131) | after (B-132) |
|---|---|---|
| `push icecubes-app`, nothing changed (three runs) | 4.43 s, 4.25 s, 4.21 s | 0.86 s, 0.70 s, 0.67 s |
| `build icecubes-app`, nothing changed | 4.83 s | 1.36 s |
| `push icecubes-app` after a one-file edit (`Tabs/ToolbarTab.swift`) | 4.25 s | 0.51 s |
| `build icecubes-app` with a one-file edit (5 nodes, 3 computed) | 20.14 s | 13.60 s |

An unchanged push is now one request for the roots and the batch around nothing; a one-file
edit adds one request for the children of the folders on its path and the file itself. The
server's part is two queries — 2 ms for the tree's 1,670 folders, once an index on
`Node(parentNodeID, kind)` let the subtree walk step to subfolders without reading every
file's row (0.4 s without it). What remains of the 0.7 s is the client opening and hashing
8,041 files, on every core; a cache of hashes by size and modification time would take most
of it, at the price of trusting a timestamp.

Measured 2026-09-30, before and after a folder's subtree manifest (B-135): a cold build's
passes, counted as every `process` run a debug `semelserv` logs, by node type, over the
IceCubes app (`icecubes-app`, `prepare --platform ios-simulator`) and NetNewsWire's Mac app
(`netnewswire-mac` with its overlay, `--platform macos`), each into a fresh home from one
prepared copy; before is `main` at `b2eaf0a`, after is B-135 on that same commit, both
without B-132's push. A run a node makes and then publishes
nothing is a pass it waited through; a fetch "not ready" is a node read and put back
because an input was pending.

| IceCubes app | before | after |
|---|---|---|
| evaluations, all nodes (fetches not ready) | 823 (1,023) | 749 (1,000) |
| `SwiftFormulaConverter`, 17 nodes | 140 runs, 4–11 each, median 10 | 100 runs, 4–8, median 7 |
| `XcodeProjectConverter` | 6 runs | 3 |
| `ProjectBuilder` (not ready) | 9 (139) | 8 (126) |
| `ProjectFinder` (not ready); wires into it | 14 (9); 1,672 | 6 (6); 2 |
| `SwiftCompiler`, 35 nodes | 112 runs, at most 5 for one | 92, at most 3 |
| `ClangPreprocessor`, 35 nodes; `AssetCatalogCompiler`, 4 | 70; 14 | 70; 12 |
| wires in the settled graph | 9,314 | 6,327 |

| NetNewsWire, Mac | before | after |
|---|---|---|
| evaluations, all nodes (fetches not ready) | 1,379 (1,264) | 1,089 (1,014) |
| `SwiftFormulaConverter`, 20 nodes | 113 runs, 3–8 each, median 5.5 | 86 runs, 3–6, median 4 |
| `XcodeProjectConverter` | 9 runs | 7 |
| `ProjectBuilder` (not ready) | 9 (129) | 8 (119) |
| `ProjectFinder` (not ready); wires into it | 17 (9); 808 | 7 (6); 2 |
| `ClangPreprocessor`, 71 nodes | 444 runs, median 7 | 205, median 3 |
| `SwiftCompiler`, 23 nodes | 56 runs, at most 5 for one | 52, at most 3 |
| `XCFrameworkSliceSelector`; `AssetCatalogCompiler` | 9; 4 | 3; 3 |
| wires in the settled graph | 27,728 | 24,505 |

The walks are gone from the counts: no converter, compiler or preprocessor runs once per
level of a folder any more, and the finder reads one wire. What a converter's runs are now
is its inputs arriving: the reader's manifest, the dependencies' manifests a level of the
dependency graph per pass, the target trees, the locks and then the content roots they are
compared with (B-06). The Xcode converter's seven on NetNewsWire are its xcconfig includes,
followed a file per pass; the builder's eight are its includes arriving.

Wall time says less than the counts on this machine today: other builds shared it, its
load average went from 4 to 16 between runs, and the same binaries' cold build of IceCubes
ranged over 105–166 s. Release binaries, one build per row, load average in brackets:

| cold build, release | before | after |
|---|---|---|
| IceCubes app | 105.2 s (4.7), 138.5 s (7.4), 117.7 s (13.3), 166.4 s (9.6) | 115.4 s (7.7), 132.9 s (4.7), 120.6 s (9.9), 210.9 s (15.2) |
| NetNewsWire, Mac | 65.5 s (3.8), 134.2 s (16.3) | 64.7 s (11.4), 78.8 s (9.7) |

In debug binaries, where every evaluation costs more, the difference shows: 250 s against
148 s for IceCubes and 250 s against 146 s for NetNewsWire, the settle after the push 168 s
against 74 s for IceCubes (at load averages of about 7 before and 5 after). The server's own CPU time over a release cold build, which is the
engine and not the tools, was 65.4 s against 66.2 s for IceCubes and 60.3 s against 52.1 s for
NetNewsWire in the quietest pair of each: the passes the walks cost were latency more than
work.

What a release cold build of IceCubes spends its time on now, from `sample`s of the server:
the push, file by file (about 30 s; B-132 makes an unchanged push cheap, not a first one);
then the flush that drains after it, rebuilding
manifests and folding content roots (`symbolicLinkTargets`, `pinnedStates` and
`contentStates`, each a join over a folder's children, per folder marked) for 15–20 s before
any node is selected — the subtree manifests' own folds do not appear in the samples; then
the thirty package readers' `swift package dump-package`; then the compiles. On NetNewsWire,
with a third of the files, the push is 9 s and the build is the compiles.

Measured 2026-10-01: a cold `push` of a tree of 4,708 files in 1,505 folders (174 MB: this
repository, NetNewsWire's Mac checkout, the IceCubes app and the C1 IceCubes packages, side
by side) into a fresh home, release binaries, `main` at `929fbbb` against several files to a
request (`pushFiles`). The server never went above one core: `ps` peaked at 93–99%. A
`sample` of the server during the push put the request queue busy 95% of the time, the rest
waiting for the client's next request; of the queue's time, 82% was GRDB and SQLite — a
sixth preparing statements, a sixth opening a read transaction per read, a tenth committing
and checkpointing the log, the rest the graph's own queries and inserts, most of them making
the 1,505 folders (`ensureEntirePathExistsAsFolders`, 46%) and the files' nodes (28%) —
then 12% writing the object store and 1% SHA-256. After: the bytes are hashed and stored on
every core before the queue, and the queue records 64 files in one transaction, each file's
own transactions kept as savepoints inside it. The machine was shared (load average 5–20,
another agent's end-to-end run), so the two were run alternately, six rounds each:

| cold push, 4,708 files | `main` | `pushFiles` |
|---|---|---|
| wall time, median of six (best) | 18.8 s (17.6 s) | 14.4 s (13.8 s) |
| wall time, the two quietest rounds (load 5–7) | 15.3 s, 15.3 s | 11.3 s, 11.7 s |
| server CPU, average over the push (peak) | 92% (99%) | 117% (138%) |
| files per second, median (quietest) | 250 (308) | 327 (417) |

What the queue does now is the graph: the commits and the read transactions are gone from
the samples (checkpointing 0.5%, from 6%), and the interning is 4% of its time, spent
waiting on the cores that do it. Of what remains, a fifth is SQLite preparing the same few
statements again — GRDB's query interface and `Row.fetchAll(sql:)` prepare per call, where a
cached statement would not — and a quarter is a new folder's first fold, its manifest and
content root read over children it does not have yet (`Folder.didCreate`). The queue also
waits about a tenth of the push for the client, which reads a batch's files before it sends
them and sends the next only after the answer; a client that read the next batch while the
server records this one would take most of that.

Measured 2026-10-10, swift-syntax as the benchmark B-80 names: 603.0.2, built through a
wrapper package whose one target depends on its seventeen library products (the test-support
ones left out), `prepare --platform macos` and debug binaries into a fresh home on an M4
shared with other builds (load average 6–9). A cold build took 37 s — 70 nodes, the push
and the converter's passes included — and a build with nothing changed under a second;
`swift build` of the same wrapper, packages resolved, took 17 s. A compile here is a module
at a time with `-whole-module-optimization`, where SwiftPM's debug build compiles a module's
files in batches across the cores, which is most of the gap on a package whose two largest
modules, `SwiftSyntax` and `SwiftParser`, are most of its source. swift-dependencies 1.17.0,
its macro built from swift-syntax, took 44 s cold under the same conditions.

Measured 2026-10-12, swift-syntax 603.0.2 at its own root (B-80 item 2): `prepare --platform
macos` takes the package at the top as the one root and vendors nothing, and the build is
every library product, the two test-support ones the wrapper left out among them — nineteen
archives. Debug binaries, a fresh home started by the build itself, `SEMEL_JOBS` unset (ten
jobs), an M4 shared with other agents' work (load average 5–7): two cold builds took 62 s and
71 s, 128 nodes, and a build with nothing changed 2.1 s. `swift build` of the checkout, every
target, took 57 s at a load average of 11–16. Where the time goes is the module-at-a-time
compile above; a loaded machine moves the figure a long way — a cold build at a load average
of 145–170 took 200 s.

Measured 2026-10-01 again, on the same four trees assembled afresh — 4,530 files in 1,345
folders, 166 MB: this repository as `git archive` exports it at `2957914`, the other three
less `.git` — release binaries, a fresh home per push, `main` at `dcf606f`. A `sample` of
`main`'s server put a third of the database queue under `selectChildPorts`: with an equality
on each side of its join and no statistics, SQLite read a folder's child ports as every port
of that name in the graph, each looked up in `Node` to test its parent, and a new folder's
first fold asked four of them; `selectPath`, run twice per file, scanned `Node` for the same
reason. A `CROSS JOIN` now puts the children and the path first, as `selectSubtree` already
did. With those gone, preparing statements was a quarter of the queue: the accessors a push
runs now prepare each text once per connection (`Database.cachedStatement`), and a batch is
one transaction, so a statement stays prepared for the whole batch. A folder being made folds
over no children without reading any, since it can have none, and a fold reads a per-kind
port only for a kind the folder holds. Alternated, six rounds each, load average 4–6.5:

| cold push, 4,530 files | `main` | joins, cached statements, folder creation |
|---|---|---|
| wall time, median of six (best) | 10.3 s (10.1 s) | 4.1 s (3.9 s) |
| wall time, the two quietest rounds (load 4–5) | 10.2 s, 10.4 s | 4.1 s, 4.1 s |
| server CPU time per push, median | 12.4 s | 6.2 s |
| server CPU, average over the push | 121% | 150% |
| files per second, median (best) | 442 (451) | 1,107 (1,154) |

A step at a time, earlier the same evening at load 2–3 on `2957914`: 9.5 s for `main`, 7.0 s
with the joins fixed, 3.8–4.2 s with the statements cached too. The fold at a folder's
creation was a percent of the queue by then, inside the noise.

| the database queue, one sampled push each (load 3.5–4.5) | `main` | after |
|---|---|---|
| busy, of the push's wall time | 84% | 67% |
| samples (≈ ms) | 8,789 | 3,268 |
| SQLite running statements | 3,032 (35%) | 421 (13%) |
| SQLite preparing statements | 1,493 (17%) | 13 (0.4%) |
| SQLite committing, savepoints, the log | 179 (2%) | 191 (6%) |
| GRDB decoding rows and binding arguments | 1,591 (18%) | 862 (26%) |
| the engine's own Swift | 1,278 (15%) | 882 (27%) |
| the object store, on the queue | 1,212 (14%) | 899 (28%) |

What is left is the engine and GRDB's decoding (half) and the object store (a quarter). A new
folder interns a manifest of its own, a file written to the store and superseded at the next
fold, and touches the empty tree's root and names; a file's metadata document is interned at
its creation and again at its push, each a touch of the same object. `selectPath` decodes
every node on the path whole, properties and all, and a cold push walks a new file's path
three times: the unchanged-file check, the walk that makes its folders, and the file's own
placement (`resolveFolderID`). The queue now waits about a third of the push for the client.
The settle after a push folds each marked folder once, as before, outside a transaction,
where every read expires the cached statements (GRDB's `PRAGMA query_only`), so the flush
prepares as often as it did; folding in one transaction would keep them prepared.

Measured 2026-10-04 on the same four trees assembled again — this repository as `git archive`
exports it at `2b37367`, the other three less `.git` — 4,537 files pushed, release binaries,
a fresh home per push, `main` at `2b37367`. A `sample` of `main`'s server put the request
queue recording batches 65% of the push, the connection cutting and hashing the next batch
12% (on the connection's thread, before the queue, and so after the batch before it had been
recorded), and nothing at all 23%. A `sample` of the client put it waiting for replies nine
tenths of the push and reading files a twentieth. So two changes: the client keeps
`FilePlugin.batchesInFlight` batches sent ahead of their replies (`sendWithoutWaiting`), and
collects the replies in order; and a server connection prepares a request — a push's files
hashed and stored — on a queue of its own, ahead of the queue that hands requests to the
handler in arrival order, so batch k+1 is hashed while batch k is recorded. The client half
alone gave 3.9 s and an idle queue 18% of the push. Alternated, six rounds each, load
average 5–7:

| cold push, 4,537 files | `main` | one in flight | two in flight | three in flight |
|---|---|---|---|---|
| wall time, median of six (best) | 4.03 s (3.97 s) | 3.91 s (3.83 s) | 3.44 s (3.38 s) | 3.54 s (3.35 s) |
| wall time, the two quietest rounds (load 5.0–5.9) | 3.98 s, 3.99 s | 3.83 s, 3.91 s | 3.63 s, 3.46 s | 4.92 s, 3.61 s |
| server CPU time per push, median | 6.2 s | 6.1 s | 6.0 s | 6.0 s |
| files per second, median | 1,126 | 1,160 | 1,319 | 1,282 |
| request queue recording, of the push (one sampled push) | 65% | | 84% | |

Two it is: three is no faster and holds another 8 MB in flight. One in flight reads the next
batch during the last but still hashes it after, which is why it barely moves. What the queue
does not record now (16%) is mostly before the first batch: the client starting, asking for
the roots and folding the disk (about a tenth of the push). Recording is the push now: the
engine, GRDB's decoding and the object store, as the table above lists them.

Measured 2026-10-04: the same four trees assembled afresh — 4,537 files in 1,375 folders,
170 MB, this repository at `2b37367` — release binaries, a fresh home per push, the push
and then the settle after it (`wait`), with the time the loop spent in the flush read from
a counter both binaries were built with. The settle's wall time is the package readers'
processes and moved with the machine (47–80 s either way); the flush is the engine's. The
flush is now one transaction with a savepoint per fold, folds the deepest marked folder
first, and a folder made on the way to a pushed file holds no folds until it: a new tree
is folded once per folder, where parents first folded an ancestor once per level below it
(23 folds against 8 on `FolderBatchFoldTests`' tree), and a push no longer writes an empty
listing per new folder or interns a file's metadata twice. The shape was measured first,
five rounds each alternated, load 4–7:

| the flush after a cold push, median of five (best) | |
|---|---|
| `main`, no transaction | 3.23 s (3.08 s) |
| a transaction per fold | 2.03 s (1.97 s) |
| a transaction per round of the flush | 1.82 s (1.53 s) |
| one transaction for the flush | 1.50 s (1.49 s) |

Then the finished branch against `main`, alternated, six rounds each, load 5.5–10:

| cold push of 4,537 files, then the settle | `main` | after |
|---|---|---|
| push wall time, median of six (best) | 5.6 s (4.1 s) | 4.5 s (3.7 s) |
| server CPU over the push, median | 7.8 s | 7.0 s |
| the flush, median of six (best) | 3.9 s (3.4 s) | 2.7 s (1.6 s) |
| server CPU over the settle, median | 12.8 s | 12.0 s |

| one sampled flush (load 12–14) | `main` | after |
|---|---|---|
| samples (≈ ms) | 6,300 | 1,150 |
| the object store | 3,544 (56%) | 937 (82%) |
| SQLite running statements | 1,585 (25%) | 63 (5%) |
| of which re-preparing expired statements | 699 (11%) | 17 (1.5%) |
| SQLite committing | 186 (3%) | 1 (0.1%) |
| the engine's own Swift and GRDB | 975 (15%) | 148 (13%) |

| the push's database queue, one sampled push each, first 4 s | `main` | after |
|---|---|---|
| the object store | 29% | 8.5% |
| a folder's creation (`Folder.didCreate`) | 21% | 0.2% |
| `selectPath` | 19% | 29% |

What the flush does now is write the documents it folds: a new object per folder for its
manifest, its root and its subtree manifest, each a file created in a temporary name,
reopened, written, made read-only and renamed (`DataObjectStore.store`, two thirds of the
flush, `createFile` alone two fifths of that). The objects are the folds' own and cannot be
skipped; creating each with its final mode in one `open` would take the reopen and the
`chmod`. On the push's queue what is left of the store is touches: the `true` every new
folder is pinned with and the metadata document files share, each a `setAttributes` per
use. `selectPath` decoding whole nodes is now the push queue's largest single cost.

Measured 2026-10-10, before and after B-149: NetNewsWire's Mac app (`netnewswire-mac` with
its overlay, `prepare --platform macos`), debug binaries, a cold build into a fresh home and
then `rm netnewswire-mac` and `wait`; before is `main` at `57e49e0`. The settle's counts are
its summary line, the `process` runs those a debug `semelserv` logs, the entries the rows
the cache gained.

| `rm netnewswire-mac` | before | after |
|---|---|---|
| the request | 7.0 s | 1.5 s |
| the settle | 15.2 s | 3.5 s |
| nodes scheduled / computed / from cache | 843 / 842 / 1 | 10 / 1 / 0 |
| `process` entered | 842 | 2 (the finder, twice) |
| cache entries written | 252 | 0 |
| nodes collected | 4,508, at idle | 4,508, in the settle |

The request is one transaction where it was a commit per write, and so is each pass of the
collector; the finder lets go of the project first, the collector takes everything only it
held before the pass starts anything else, and a node whose static input is a removed
source publishes the state without running. What is left of the settle is the 4,508
deletions and the idle reports. A cold build was unchanged: 94.5 s before, 95.1 s after,
852 nodes computed and 430 entries both times.

Measured 2026-10-12 for B-155: the server's memory through a cold push of Sequel Ace's clone
and the start of its build. The cached checkout less `.git`, the overlay's xib, `prepare
--platform macos` (41,391 files pushed, 1.1 GB, 27 files over 5 MB and the largest 68 MB),
release binaries, a fresh home each run, `push sequel-ace` from one `semel` session — the
tree holds the formula, so the build starts as the push commits — and the server stopped
300 s after the push returned. The footprint is `footprint -p` every two seconds, in MB of
2^20 bytes as `footprint` and `vmmap` give them; live is `heap`. Before is `main` at
`d7a5ad9`. The machine was shared with other agents' builds, so a push's peak moved by a
few hundred MB from run to run.

| `semelserv`, Sequel Ace | before | after |
|---|---|---|
| peak footprint during the push | 370–830 MB (two runs) | 430–500 MB (two runs), 41 MB live |
| peak footprint in the 300 s after it | 6,430 MB, 5.8 GB of it live in 18 M allocations | 400 MB |
| time at 4 GB or more | about 100 s | none |

Each fix's share, the same tree and method:

| | peak during the push | peak in the 300 s after it |
|---|---|---|
| `main` | 370–830 MB | 6,430 MB |
| + subexpressions filled once (`GraphSpecRewriter`) | 880 MB | 1,390 MB |
| + formula calls evaluated once | 780 MB | 250 MB |
| + pushed files stored from the body | 760 MB | not run |
| + large bodies mapped, the decoder's room released | 430–500 MB | 400 MB |

Whether the push grows with the tree: the clone without its formula, so the push is all the
server does, pushed as one copy and as two side by side.

| push only | 41,391 files | 82,782 files |
|---|---|---|
| before | 880 MB | 1,020 MB, 748 MB of it freed large blocks |
| after | 500 MB | 460 MB |

What the after column holds is mostly libmalloc's cache of freed large blocks: up to 64 of
them, dirty — 364 MB of a 434 MB footprint at one moment of the Sequel Ace push, against
41 MB live. It is bounded by count and does not grow with the tree, and
`malloc_zone_pressure_relief` does not release it (B-155).

**B-170** `open` — **A wildcard push sends and records every file the server already
holds.** Measured 2026-10-17 while working on B-167, on main at 3734886 with release
binaries, over a generated tree of 20,730 files in 337 folders (436 MB) the server already
held byte for byte: `push tree/**/*.*` took 11.3 s, 9.9 s of it sending all 20,730 files in
324 `pushFiles` requests for the server to record as unchanged, against 1.7 s for `push
tree`, which sent none. The comparison with the server's roots and children (B-132) runs only
in `expand`, for an entry the matcher returned as a folder; a wildcard returns files, each
of which becomes `.send` at once. The owner pushes with `**/*.*`, so this is their everyday
case, and with B-164's widening a locked folder reached by the pattern is already compared.
The fix would group the matched files by the folders they are in, ask for those folders'
roots and children in one request each as `expand` does, and send only what differs, keeping
the work list's order and its report (`[no change]`, the `unchanged` count) as they are.

**B-171** `open` — **Recording a pushed file on the server's queue costs about 1.05 ms, a
third more than the 2026-10-04 figure.** Measured 2026-10-17 while working on B-167, on main
at 3734886 with release binaries and a fresh home, with temporary timing around the queue's
turn in `RequestHandler.pushFiles`: a cold `push tree` of 20,730 files (436 MB) spent 21.8 s
recording on the queue over 324 requests of 64 files, and 4.2 s interning off it. Per request,
the queue's time grew over the push: 60 ms for the first fifty requests, 59 ms for the next
fifty, then 71, 67, 66 and 78 ms per request for each fifty after that (cumulative 3.0, 6.0,
9.5, 12.9, 16.2 and 20.1 s at requests 50 to 300). A cold `push tree/**/*.*` of the same tree
spent 26.5 s recording (1.28 ms a file); the same push of the unchanged tree 9.9 s (0.48 ms
a file). The 2026-10-04 measurement of a cold 4,537-file push (3.4 s) implies about 0.75 ms
a file. Not yet profiled: whether the growth is the graph's size (a folder's lookups or its
manifest refold growing with its children), the journal of the implicit batch, or the
machine's load during the run, which was not idle. A `sample` of the server during the push
is the next step.

## Design, correctness and code quality

**B-165** `done` — **Sequel Ace stopped building: Firebase's FirebaseCoreExtension did not
compile once it had the Objective-C bundle accessor.** The nightly end-to-end run on main
at 6e9bf82 (run 38458159093, 2026-10-13) failed its external-projects step with no log
kept; the archived roots held one with a home and no output, `sequel-ace`. Run locally
with release binaries, its first build failed in two sources of FirebaseCoreExtension:

```
In file included from sequel-ace/Dependencies/firebase-ios-sdk/FirebaseCore/Extension/.DerivedSources/resource_bundle_accessor.m:1:
  <built-in>:2:22: error: no matching '#pragma clang module begin' for this '#pragma clang module end'
      2 | #pragma clang module end /*FirebaseCoreExtension*/
```

and the same for `FirebaseCore/Extension/dummy.m`. 6e9bf82 (B-55 item 8,
SwiftFormulaConverter v28) gave every Objective-C target with resources SwiftPM's
`resource_bundle_accessor.h`, forced into each compile with `-include`, and placed it in a
hidden `.DerivedSources` inside the target's folder. FirebaseCoreExtension declares
`publicHeadersPath: "."`, so its folder is its module's umbrella directory, and clang's
walk of an umbrella directory takes in hidden folders: the accessor header became a
header of the module the sources are compiled as. `clang -E` with `-fmodule-name` writes
`#pragma clang module end` after an `-include`d header of the own module without the
matching `begin`, and the compile of that text fails. Reproduced in a scratch folder with
the same flags; the same header outside the umbrella directory preprocesses clean.
`swift build` on a target shaped like it (`publicHeadersPath: "."`, a `.m`, a processed
resource) generates and compiles the accessor too, from
`.build/…/Ext.build/DerivedSources`, outside every target. NetNewsWire's PLCrashReporter
and CodeEdit, whose targets with the accessor have an `include` folder, passed.

Fixed 2026-10-14: the accessor's two files are under `.DerivedSources` at the input root,
at the target folder's path below it (`input:/.DerivedSources/<target folder>/…`), so
they are no target's and in no module. SwiftFormulaConverter v29. Pinned by
`SwiftFormulaConverterTests.test_theAccessorsFilesAreOutsideTheTargetsFolder`, which
failed before the fix; `sequel-ace` builds twice with identical bytes again.

**B-162** `done` — **A dependency re-vendored with fewer files was refused by its lock on
every push.** Reported 2026-10-12 on a proprietary package depending on
[Charts](https://github.com/danielgindi/Charts). `semel-swift prepare` had written
`Dependencies/Charts.semel-lock`. Every `push` and `build` of the tree was then refused at
`commit`, and running `prepare` again on main at 1e372b2 changed nothing:

```
Not on disk, kept: 5 files and 1 folder (push only adds; rm removes them): App/Dependencies/Charts/Charts.podspec, App/Dependencies/Charts/Package.resolved, …, App/Dependencies/Charts/Source/Supporting Files/Charts.h, App/Dependencies/Charts/Tests/ChartsTests/__Snapshots__Silicon__/
App/Dependencies/Charts is locked, and the batch changes it without a lock it matches: nothing of the batch is committed
  lock: App/Dependencies/Charts.semel-lock
  expected: sha256:82e51b57426781b0a31ccf643874c85172c95a333faf65c97143270e22083b9c
  found: sha256:bce0febc5461a6a25461278807652a57d921634207bacde3fb5582efd46042da
  paths: App/Dependencies/Charts.semel-lock, App/Dependencies/Charts/CONTRIBUTING.md, … and 270 more
  re-lock with: semel-swift prepare
```

The two folds agree. On a fresh engine, Charts 5.1.0 (Mac) and master (simulator) are
prepared, pushed and built with no refusal. Charts holds no links, pipes, case-only name
pairs or `Package@swift-*` manifests, and its one declared resource
(`PrivacyInfo.xcprivacy`) is on disk. The `expected` root above is the lock a fresh 5.1.0
`prepare` writes, byte for byte.

The cause is what the engine already held. The lock was written over a copy that
replaced an older one the engine still held: 4.1.0 to 5.1.0, where Charts became DGCharts
and renamed or dropped files (`Charts.h`, the podspec, two schemes, and a folder of
snapshots named `__Snapshots__\u{F8FF}Silicon__`, U+F8FF being Apple's logo). A push only
adds, so the old copy's files stayed in `input:` below the new copy. The folder's pushed
root folded them, the lock folded only the disk, and the barrier refused the batch. Every
later push was refused the same way, since none of them could remove anything, and
`prepare` could not help, since it never talks to the engine. The client's own line said
what was wrong (`Not on disk, kept`). `rm` of those paths in the push's batch let it land.
`semel-watch` already mirrored a locked folder when its lock changed (B-146); `push` and
`build` did not, which broke the README's promise that a build after `prepare` "pushes
both in one batch and lands".

Fixed in the client. A push that sends a lock the server does not hold as the disk has it
mirrors the folder that lock locks, in the push's batch: what the server holds below that
folder and the disk lacks (by `lstat`, so a dot-named folder the walk does not list is
left alone) is removed with `rm`. The push says so in one line before its own (`Locked
anew: <folder>; with the push, taking out 5 files and 1 folder the copy no longer holds:
…`), and `rm` adds no `Removed` lines of its own. With B-161's wording, the push's last
line then says whether the batch stood: `Pushed`, `Sent …, pending the commit`, or, on a
refusal, `sent, and none of it committed`, which takes the removal back too. A lock is a
statement about its whole folder, and its file is something the user put there, so the
removal is the lock's and not the push's. A push that brings no new lock only adds, below
a locked folder or anywhere else, and a file gone from a locked copy without a new lock is
still refused. AGENTS.md's "A push only adds" and the README's locked-folders section name
the exception. `DependencyLock.dependencyPath(lockedBy:)` is the inverse of `lockPath`,
which `semel-watch` now uses too. Left open: a name holding `*` or `?` is not removed,
because `rm` reads its argument as a wildcard. The batch is then refused, naming the path
as kept.

No node changed, so there are no version bumps. The lock's document and its fold are
unchanged, and existing locks stay valid. Tests: `ReVendorPushTests` (root, five cases: a
re-vendor that drops a file and renames a folder lands, with the folder's pushed root
equal to the lock's; a re-vendor whose lock the copy does not match is refused, its
removal taken back with the batch; a file gone outside the re-locked folder is kept; a file gone from a
locked copy with no new lock is refused and kept; a new lock over a copy that lost nothing
removes nothing). Two of these fail without the fix. `LockFoldParityTests` gains the
shape: a copy re-vendored with fewer files over the one the graph holds, whose pushed root
differs from the lock until the leftovers are removed. Checked by hand: Charts 4.1.0
prepared and pushed, the pin moved to 5.1.0, `prepare`, then `build`: the build lands,
removes the six leftovers, and builds the target importing DGCharts.

Not fixed, seen on the way: when a re-resolution drops a dependency (swift-algorithms and
swift-numerics, which Charts 4.1.0 needed and 5.1.0 does not), `prepare` leaves its copy
and lock in `Dependencies`.

**B-158** `done` — **The cache limit's loop test read one trim where the engine made
several.** Seen 2026-10-12 in CI on PR #201, which touched nothing in the cache:
`CacheSizeLimitLoopTests.test_aGraphThatWritesMoreThanTheLimitKeepsBuildingAndSaysWhatWasEvicted`
(B-148) found `evicted 4 entries (4.0 KB) — LabellingSampleTool 4; it holds 5.0 KB` where
it expected 5 and 5, and the last trim's report held 1 eviction where it expected 5. On
main at 0a501a0 it passed 200 runs in 200 on an idle machine, and failed 320 in 600 with
twelve copies running at once on the owner's ten-core Mac.

Fixed 2026-10-12. The engine was right and the test read one settle where there were
several. The test pushed the second edition of its five sources as five writes outside a
batch, with the loop running. Each write wakes the loop, and the loop settled after
whichever of them had landed. Every settle trims, and each trim evicted the first edition's
entries that no node stood on any longer: the ones whose tools had already been run on the
second edition. The others were still held, which is what the line's "it holds 5.0 KB" and
the note about held entries say. Printing every notice and the last trim in each failing
run showed this every time. Out of 354 failures, each had between two and five eviction
lines, which always added up to 5. The CI run was the split 4 then 1. The engine promises
one settle only for a batch, so the test's push is now one batch. The test also asserts
that exactly one eviction line was reported. With the change it passed 200 in 200 alone
and 600 in 600 under the same load.

**B-156** `done` — **The removal end-to-end test counted a node that may or may not run.**
Seen 2026-10-11: `RemovalEndToEndTests.test_removingTheFixtureRunsOnlyTheFinderAndWritesNoEntry`
(B-149) failed in an agent's root suite run with 2 nodes computed where it expected 1, and
1 time in 3 run alone. Under twelve CPU burners on the owner's ten-core Mac it failed 4
rounds in 20, with 2, 3 and 6 computed. No cache entry was written and no error reported in
any of them.

Fixed 2026-10-12. The engine was right and the test over-specified. `rm c` wakes the
`ProjectFinder` and, in the same round of the pass, every node reading a file it removed.
A tool among them is stopped by the state its input stands in (`stateStoppingProcess`).
A node that tolerates an absent value is not stopped, by design: the `ConfigMerger` over the
project's `semel.config` (on `override`), and each `ClangIncludeFinder` over a source.
These run in-process beside the finder. If one finishes after the finder's write, the
collector has taken it and its result is dropped uncounted. If it finishes first, its
result is written and counted computed, and the node is collected a moment later. A
settle record logged per node showed this every time: the merger, or the merger and three or
four include finders, written `computed` before the finder. "Exactly one computed" was the
order two threads finish in, not something B-149 promised. The test is now
`test_removingTheFixtureLetsGoOfItAndWritesNoEntry`. It asserts nothing from the cache, no
entry written, no error, and the project gone from `input:` and `output:`. That no tool
is started over a removed source is held by `RemovalSettleTests`, where the runner can
count runs. The old listing check, `ls /`, printed `(empty)` whatever the graph held, so it
was true before the removal too. The test now runs `ls` and `ls -o`, and checks first that
both name the project. With the change, both tests of the class passed 40 rounds in 40, under the same burners and
beside release builds of `SemelCore`.

Not done: starting the finder alone when a pass wakes it, so that nothing it lets go of
runs at all. That would serialise every settle that changes a listing behind the finder,
50 to 200 ms on NetNewsWire, to save runs of nodes that cost less.

**B-151** `done` — **Two settle tests failed now and then on a slow machine.** Seen
2026-10-10 on the hosted runner (three cores), on a documentation-only pull request whose
check passed on main just before: `CheckpointTests.test_aRestoreRoundTripsFilesAddedRemovedRelinkedAndReModed`
failed twice in two runs with `restore before: no product: app/lib/Lib.swift has been
removed`, and `SettleRecordTests.test_theFirstBuildRecordsEveryNodeAsNewAndComputed` with
a tool recorded `fromCache` where it had been computed. Under twelve CPU burners on the
owner's ten-core Mac the first failed 13 rounds in 80 and the second 4 in 250. Two causes
in the engine, both races between the processing loop and the writes beside it.

Fixed 2026-10-11. **A settle was reported over writes no pass had processed.** The loop
reported when no work signal was pending, but a batch holds its signal back to its end and
the signal travels through a Task, so a removal committed in a batch could be in the graph
the report read while its wake-up was still on its way. The `rm` before the restore took
`app/lib` in one transaction after the pass of the push before it had run its collector;
the report then read `Lib.swift` removed and not yet collected, said so as an error, and
the interpreter counted it against `restore`, the command running when the event arrived.
Each of five failures logged made its report with wake-ups requested and not consumed. A settle is
now reported only when every wake-up asked for has been taken by a pass and no batch is
open: a pass that ends inside a batch marks the loop idle — a `wait` inside the batch still
returns — and leaves the report to the batch's end, which wakes the loop and counts a
wake-up, so a waiter after it waits for the report. No batch opens while a report is being
read. `SettleReportBoundaryTests` holds a pass open, removes a file a node reads and pushes
it back in one batch, and fails without the change on the removal reported between.

**A node ran twice over the same inputs in one settle.** A node is unscheduled as it
starts and reads its inputs on its own thread a moment later, while the loop writes other
results; an input written in between schedules it again, and its run reads that value all
the same. The second run read what the first had, and was answered from the entry the
first had just stored, so the settle record called a node it had computed a hit — the
settle record's per-node log showed tool 9 `computed` and then `fromCache` within one pass.
B-147 made this visible: before it, a node faster than the cache floor stored no entry and
the second run was a second run. The write of a result now takes the node off the schedule
when its inputs, after the write, are what the run read; the wires its own demands add are
inputs it did not read, so those still run it again. `RescheduledRunTests` holds a node
between its start and its read, writes its input, and fails without the change on the
`fromCache` outcome. With the first change the restore test passed 60 in 60 under the
burners, 60 in 60 beside a release build and 60 in 60 under `taskpolicy -c background`;
with both, 60 in 60 for it and 150 in 150 for the record test, under the burners.

**B-144** `done` — **Deleting a running server's home sometimes failed with a permission error.**
Seen 2026-10-09 twice in one day, once on the hosted runner (PR #170's first check) and
once on the owner's Mac (an agent's root suite run), and passed on rerun both times:
`SocketFileTests.test_deletingTheServersHomeStopsTheServerCleanly` failed in its
`removeItem(at: home)` with `NSCocoaErrorDomain 513`, "“home” couldn't be removed because
you don't have permission to access it". The test starts `semelserv` over a home of its
own and removes the home while the server runs.

Fixed 2026-10-10. The cause is the test's ordering, not the server. `BuildEngine.start()`
starts the processing loop as a task and returns, and `semelserv` goes on to listen, so the
socket file can appear while the loop's first pass is still running: it makes the
`ProjectFinder` and the `input:` and `output:` roots, processes the finder, interns its
first objects (each written in its shard under a temporary `.<hash>.<uuid>` name, then
renamed) and commits to the graph, and a pool connection opened after the walk removed
`graph.sqlite` creates it again with its `-wal` and `-shm`. The test waited for the socket
file only. Foundation's removal walks the tree depth first; a file created in a folder the
walk has emptied makes the folder's `rmdir` fail, and the error is reported against the
top path as 513 with an underlying `EPERM`: a loop creating files under a folder while
another thread removes it reproduces exactly that error 283 times in 300. Looping the
test's shape against the debug `semelserv` failed 6 rounds in 40 on a quiet machine and 6
in 40 at a load of 10 with a release build running; what was left each time was a shard,
a temporary object in it, or a recreated database. Nothing the server writes is out of
place: the first settle is the engine's work, and the server stops cleanly whatever is
removed under it. The test now runs `semel wait` through the socket before the removal,
so the engine is idle when the walk starts, and an idle engine writes nothing: 0 in 40,
loaded and not.

The same race elsewhere: the end-to-end harness stops each server with SIGTERM and waits
for it to exit before it removes a run root, and kills and waits on a failure, so nothing
is writing then; the sweep of stale roots touches only roots a day old, best effort.
`ErrorReportEndToEndTests` removes its home after `semel stop`, with every build in it
already settled, and ignores a failure. `WatcherTests` waits for idle before it removes its
store (B-146). None of them can hit it.

**B-143** `done` — **A fresh `prepare` and `build` could fail on the lock `prepare` had just
written.** Reported 2026-10-09 on a proprietary tree: `semel-swift prepare` vendored a
dependency and wrote its lock, and the next `build` stopped with `is not the tree its lock
records`, nothing edited between. The dependency held no links, and dot-files and
dot-folders at several levels. `LockFoldParityTests` folds 28 crafted shapes on disk
(`FolderContentRoot.root(ofFolderAt:)`), pushes each as the client pushes and compares with
the engine's fold after the settle. The shapes that agreed are kept as guards:
- modes 600, 664, 640, 444, 775, 700, 4755, 2755 and 1644 (each reads as `st_mode & 0o7777`
  on both sides, and the wire carries it raw);
- links inside the folder, outside it, absolute, dangling, looping, above themselves, and
  one naming its target in another case (`/` is plain APFS, so case-insensitive);
- a hard link;
- empty folders and folders holding only empty folders, dot-names or a dangling link
  (both sides drop them);
- a folder nobody can list, and a path past `PATH_MAX` (both sides see nothing there,
  silently);
- dot-names at every level, including a dot-folder of plain files and a plain folder
  inside a dot-folder;
- files and folders hidden by `UF_HIDDEN` (neither the lister nor `FolderOnDisk` enumerates
  with `.skipsHiddenFiles`, so both keep them);
- NFC and NFD names (both sides take the lister's bytes);
- spaces, quotes and control characters in names;
- an empty file, and one over the 8 MB push batch;
- lock-like and file-like names;
- a mixed-mode `semel-artifacts` framework;
- xattrs and the immutable flag.

What diverged:

1. **A pipe or a socket in the tree.** The lister listed it as a file. The disk fold could
   not read it (a pipe blocks on open, a socket refuses it) and failed `prepare`, while the
   push skipped it and went on. `ExternalFileSystemLister` now takes a regular file or a
   folder (links followed) and nothing else, so both sides leave such a node out.
2. **What the graph holds and a copy's fold never sees** — the owner's case. A vendored
   folder's `contentRoot` folds every child the engine has. Two kinds of child are never in
   a copy's fold:
   - a dot-named file pushed by name: `build`'s follow of a missing source,
     `push <path>/.file`, a watcher's `--only`, then kept by every later push through
     `HeldTree.hiddenFiles`;
   - a ghost: a name a converter asked for that nobody pushed, folded `not-produced`.

   `SwiftFormulaConverter` made ghosts under valid packages. It asked for
   `Sources/<Target>` for every target that names no `path:`, where SwiftPM also looks in
   `Source`, `src` and `srcs`, case-insensitively on a Mac's volume. It also asked for every
   declared resource whether the folder held it or not.

   The fix chosen keeps the lock locking what the push pushes. The alternative was forbidding
   such demands under a locked folder. It was not chosen because a demand is how the follow
   finds a source, and demands that hang on the lock's outcome were B-133's loop.

   `Folder` now publishes `pushedContentRoot`. It is the same fold, from the same reads and
   marks, less every dot-name, every child without content, every product and every
   subfolder left empty by that rule: `FolderOnDisk`'s fold by construction.
   `DependencyLockCheck` compares the lock with it. It also wires the whole root, which it
   reads only when a lock fails, to name what the comparison left out: "2 dot-named: …,
   1 asked for and never pushed: …" (`FolderContentRoot.lines(ofDocument:)`, the writer's
   inverse).
3. **The converter's ghosts themselves.**
   - A target that names no folder is now found from the manifests of its package folder
     and of the predefined folders it holds (`DefaultTargetFolders`). One none of them holds
     is the conversion's error naming the four paths tried.
   - A declared resource the target's folder lacks is named in a notice and not asked for,
     as SwiftPM warns and builds without it.
   - A declared catalog or bundle is read from its folder's manifest. The walk never
     enters such a folder, so `.process("Resources/Media.xcassets")` and
     `.copy("Foo.bundle")` were asked for as files of the folder's path.

`FolderContentRoot`'s document is unchanged and so is its tag. Existing locks stay valid:
the disk fold is what it was, and the engine side now matches it. `SwiftFormulaConverter`
is version 21 (new demands, a new lock comparison). `Folder` gains an output port, which
needs no version, as it never processes.

Not fixed, filed here:
- ~~(a) A dot-named declared resource is still asked for as declared, so the follow pushes
  it by name. It is built and not locked. A dot-named declared *folder* cannot be pushed at
  all (`hiddenFile` takes files only).~~ Done 2026-10-10, under "the lock locks what the
  push pushes". The client cannot read a manifest, so the lock carries what `prepare`
  read from it: one `hidden <path>` line per dot-named file a target declares as a
  resource, a file on disk in no dot-named folder (`Preparation.hiddenResourceFiles`,
  `DependencyLock.hiddenFiles`). `prepare` folds those files into the root it records;
  `FolderOnDisk.read` walks the files the lock beside a folder names, whether the walk
  starts above the lock or inside the folder, so a push of the tree sends them; and the
  engine's pushed root keeps every dot-named file holding content, as a push sends every
  one the graph holds (B-77 item 5), and leaves out only a dot-named folder. The three
  folds agree by construction and the file is locked. The flip side is deliberate: a
  dot-named file pushed into a locked folder by its name and named by no lock is now
  compared, and fails the lock and the barrier, since the build would read a file the
  lock does not describe. A lock whose `hidden` lines are not what the manifest declares
  is re-vendored (`CopyReason.hiddenFilesDiffer`). A declared dot-named *folder* stays
  unsupported: no push sends one, so no manifest in the graph ever holds it and the
  converter cannot tell it from a file not pushed yet; it is asked for by its path, the
  follow cannot push it, and the build stops naming it as never pushed.
- ~~(b) A hand-written `SwiftFormulaConverter` with no `root:` over a vendored folder reads
  `semel.config` and `semel.machine.config` from inside it.~~ Done 2026-10-10. A node type
  can declare a property the formula's folder fills when the formula that names it leaves
  it out (`NodeDescriptor.formulaFolderProperty`), and `ProjectBuilder` fills it, in an
  `include` and at any depth of a product. The converter declares `root`, so `root:` is
  the folder of the formula that names it, never the package's; only a converter no
  formula named, one a test wires by hand, still takes its package's folder.
  `ProjectBuilder` is version 8.
- ~~(c) A `.fmla` inside a vendored package is built by `FormulaFilePlugin`, which does not
  skip `Dependencies`.~~ Done 2026-10-10. `ProjectFinder` makes no builder for a project
  file at any depth below a locked folder, a folder `F` with `F.semel-lock` beside it, and
  a notice names each one skipped with the folder whose lock it is under. The lock rather
  than the name `Dependencies`, because the lock is the engine's own rule, the one the
  lock barrier reads, and the folder's name is the Swift toolchain's. `ProjectFinder` is
  version 5.

**B-139** `done` — **`wait` could return before the pass a push asked for had run.**
Found 2026-10-04: `SettleTests.test_aWaiterNeverSlipsBetweenTheWakeUpAndThePassItAsksFor`
failed on `main` about one run in three at a load average of 6 (`round 146: the wait
returned before the pass ran`). The cause is in `BuildEngine.waitUntilIdle`, not in the
test: a waiter took the loop's idle mark from the `IdleState` actor and then compared the
wake-ups requested with the loop's count of those consumed, read under a lock, and the two
reads were not one. Between them the loop could take the push's signal, mark itself busy
and consume every wake-up outstanding — B-128 put the busy mark before the consumption,
which closes the window on the loop's side and not on the waiter's. The waiter then found
every request consumed, by a pass that had not run, and returned with the push's folder
still marked: a `build` waiting there could export against manifests not yet folded. An
idle mark now carries the count of wake-ups its passes answered, and a waiter compares
with that (`IdleState.Mark.settledThrough`), so what it judges is what the mark it holds
settled, whatever the loop has done since. Not caused by #160: the window is between two
reads in the waiter, and folding a new folder later or sooner moves neither; a cheaper
push brings the batch's end and the wait closer together, which can only make the loop's
wake-up land in it more often. Not reproduced on demand: the interleaving needs the
waiter's task descheduled between its two reads, and the test's 200 rounds are the
regression check.

**B-133** `open` `For Fable Only` — **A subgraph that rewires itself without converging looks,
from the prompt, like one still working; and a path a vendored package lacks reads as a
lock mismatch.**
Found 2026-09-28 building NetNewsWire for the Mac (B-77 item 2): `Dependencies/Sparkle`
declares one `.binaryTarget(url:checksum:)`, its `SwiftFormulaConverter` was processed
6,497 times in ten minutes with a node collected every round, and `semel build` never
printed a result. The loop itself is fixed (2026-09-28): the converter asked for a
target's folder only once the package's lock had passed, the remote binary target has no
folder, the demand made a ghost the package's content root folds, the lock failed, the
failed pass withdrew the demand, the collector took the ghost and the lock passed again.
The converter now demands the target folders before it compares the lock and on every
pass whatever the lock says, and a binary target is not compiled but named — `binary
target Sparkle of package Sparkle is not built (B-133)` — for the feature in B-77 item 2
(`SwiftFormulaConverterTests`, `VendoredPackageSettleTests`; converter v9). Since
2026-09-29 an `.xcframework` is built (B-77 item 2, map item 1), found through a walk that
asks for nothing a vendored package does not list; only an artifact that is not one — an
`.artifactbundle` — is still named as not built. What remains:

1. **Non-convergence is silent.** Any node whose demands alternate with what they cause
   loops the same way, and `build` waits for ever. Whether the engine notices a node
   reprocessed over inputs it has seen before within one settle, and reports it as the
   build's error naming the node and what it keeps demanding, wants a decision on what
   "seen before" costs to keep.
2. ~~**A folder a vendored package's manifest names and the package lacks** ends the build
   on the lock, naming two roots and not the path.~~ Done in B-143: the lock compares the
   folder's pushed root, which leaves a ghost out, so the build ends on the folder itself,
   `…/Sources/Sparkle/ has not been pushed`; a target that names no path is no longer
   guessed into a ghost, and a failed lock names what it did not compare.

**B-47** `done` — **The SDK is declared but not a graph input.**
Done 2026-09-12: the declared identity is version *and* build, `26.5 (25F70)`, checked
against the machine; and the Swift compiler and linker put a fingerprint of the SDK tree —
every file's path, size and mtime; 1.2 s cold, 0.4 s warm, once per process — into their
cache key through `Node.cacheKeyMaterial`, so two machines with the same declared SDK and
different contents no longer share an entry. Content hashing was measured at 4.4 s and
rejected; a cross-launch cache keyed on the SDK directory's mtime was rejected because that
mtime does not change for a file edited deep inside.

Done 2026-10-10: the fingerprint lives in `SemelNodeKit` (`SDKFingerprint.swift`), a
machine fact every toolchain reads, still walked once per process per SDK (1.0 s on this
machine under load). Every node that reads an SDK keys on it: `ClangPreprocessor` (10),
`ClangCompiler` (6), `ClangLinker` (5) and `IBToolCompiler` (4) fold the tree at `sdkPath`
into their material beside the tool binary's, as the Swift tools fold the tree behind
`-sdk`. And an SDK change now wakes the graph: every namespace whose tool reads the SDK
declares `sdkFingerprint` as a machine setting, so `semel-swift prepare` writes the
fingerprint's hash under each into `semel.machine.config` on every run (`semel-clang`
writes it too, and rewrites it with `--force`). A changed SDK is a changed line in a
pushed file, which changes what each `ConfigFilter` over that namespace publishes and
reschedules every node reading it — an Xcode update that keeps the version and build, or
a header edited in place, rebuilds an already-built graph without a `reset`, once
`prepare` has run and the file is pushed (the watcher pushes it when it changes). Both
halves stay: the key is what protects a cache shared between machines, and a machine file
that no longer describes the SDK; the line is what schedules. The invariant is written in
`AGENTS.md`: every node input is in the input file system, derived from it, or declared as
coming from outside.

What stays with B-03: the SDK as a content-addressed input is the container digest. The
fingerprint reads paths, sizes and mtimes, not bytes, so an edit that keeps a file's size
and restores its mtime is not seen; it is taken once per process, so an SDK changed under
a running server keys as it was until the server restarts; and the tool binary has only the
key half — the machine file names a tool by its version, so a binary replaced under one
version is keyed apart but not woken.

## App bundles

Building the app that consumes the packages, for the simulator first. Design:
`docs/superpowers/specs/2026-09-14-semel-app-bundles-design.md`. A hand-written formula
builds and launches a SwiftUI app (`EndToEnd/Fixtures/swift/HelloApp`, the roster's
`swift-hello-app`). Tree-valued ports and tree products (B-63) are
built: `TreeManifest`, `expectedOutputFolders`, `TreeFile`, `TreeMerger`, and
`product 'name/'`. The Apple resource nodes (B-64) are built: `SemelApple` with
`AssetCatalogCompiler`, `StringCatalogCompiler` and `InfoPlistBuilder`; HelloApp builds
with an asset catalog and a string catalog and runs in the simulator. The Xcode project
converter (B-65) is built: `XcodeProjectConverter` builds the application and the four
extensions it embeds from the project file, and `semel-swift prepare` on a folder holding
an `.xcodeproj` resolves the project's packages through Xcode, vendors them and writes the
formula and config; a fresh clone of IceCubesApp goes from `prepare` to a launched app in
two commands. Device signing is deliberately out — the simulator needs none beyond what
`ld` does. An app includes its packages with `include funcs`, so its build root holds the
app and not their archives, and the linker writes small objc_msgSend stubs, so an app's
executables are byte-reproducible. actool's is not, so `AssetCatalogCompiler` publishes
each `Assets.car` in a canonical form that `assetutil` reads as the file actool wrote, and
a signed bundle is byte-reproducible whole (B-89).

**B-159** `done` — **A tree of library packages with an asset catalog had no actool
settings.** Seen 2026-10-12 in the nightly roster on main at 0a501a0: the `icecubes` entry,
IceCubes' five library roots for the simulator, failed every product with `missing
settings: apple.assetCatalogCompiler.…`, on `resource: Colors.xcassets` (DesignSystem's
`Resources`). The `icecubes-app` entry and both Backyard Birds entries passed.

The cause was B-77 item 5 (#199). `SwiftFormulaConverter` 27 compiles a target's catalogs in
one actool run, `assets<Target>()`, and the target's Swift compile reads the symbols it
writes (`ImageResource.floor1`), which Backyard Birds' packages need. Before it, a package's
catalogs were compiled only into its resource bundle, which only an app's formula reaches,
so a tree whose roots are libraries never ran actool. `semel-swift prepare` on a tree of
packages wrote the Swift namespaces, and clang's for a C-family target (B-110), and never
actool's: a project's formula always selects it, a tree's never had. Reproduced with
release binaries on a cold copy of `C1/icecubes/Packages`: `prepare --platform
ios-simulator`, then `build` failed with the nightly's message.

Fixed 2026-10-12 in `prepare`, not in the converter. A tree of packages now gets
`apple.assetCatalogCompiler` when one of its targets, its own or vendored, has a catalog the
converter compiles, for every platform, in the halves B-109 puts it in: the tool and
`assetutilPath` in the machine file, the platform, deployment version and devices in
`semel.config`. Which catalogs count is the converter's walk, `SemelSwift.compilesAssetCatalog`:
an `.xcassets` folder reached through no hidden folder, whole-folder resource or `.docc`,
not excluded, in the sources scope or a declared resource, or a declared catalog. The same
copy then builds all five archives cold, and the `icecubes`, `icecubes-app` and both
Backyard Birds roster entries pass with byte-identical builds and no exemption. No node's
output changed, so no version moved.

Not done: a tree whose package has a xib or a storyboard gets no ibtool block either. It
does not fail today, since only a bundle, which only an app reaches, compiles one.

**B-152** `done` — **ibtool and actool failed for every client on the machine: the pooled
`ibtoold` kept the working directory of a sandbox Semel had removed.** Seen 2026-10-10
and again 2026-10-11 (B-77 item 4, Sequel Ace). Every xib, storyboard and catalog of a
build failed with `IBCurrentDirectoryPath … currentDirectoryPath is unexpectedly nil`. So
did `xcrun ibtool --compile` run by hand from a folder that existed, and so did the
SemelApple suite's real-ibtool tests, until the daemons went. One of the nine `ibtoold
--sending-client-environment` processes then running had its working directory in
`…/T/TemporaryItems/NSIRD_semelserv_…`, a tool-run folder that `LocalFileSystemTool` had
made and then removed.

The cause, found by experiment on Xcode 26.6 from folders that were kept: `ibtool` and
`actool` are clients of a per-user pool of `ibtoold` daemons shared by every run on the
machine. A daemon starts in `/`, whichever folder its client ran in; `ibtool --version`
starts one. An `actool` request leaves its daemon in the client's working directory. Six
`actool` runs from six folders left five daemons in five of them. With those folders
removed, twelve `ibtool` runs out of twelve failed as above, from a folder that existed,
until the daemons exited after about two minutes idle. That is why the failure cleared
between sessions and came back with the next build: `LocalFileSystemTool` removed every
run's folder. The first slice of B-77 item 4 put this down to something outside Semel. It
was Semel.

A first fix ran the two tools in sandbox folders that were emptied and reused rather than
removed. That exposed the second half of the same fault. A pooled daemon left by an
`actool` run in one folder resolves a later `ibtool` client's relative paths against that
folder, not the client's own. Eleven of Sequel Ace's xibs failed with `Interface Builder
could not open the document … because it does not exist`, naming the folder of the
catalog compiled before them. Setting `PWD`, or passing the full environment, made no
difference. Starting the daemon first from a lasting folder could not help either, since
the daemon starts in `/` and each request moves it.

Fixed 2026-10-11 by never using the pool. `ibtool` and `actool` both read
`IBToolNeverDeque=YES` from the environment (it is in the binary's strings, beside
`IBCLIServerNeverDequeue`), and with it a client starts a daemon of its own that leaves
nothing behind. Measured: six parallel `ibtool` runs and three `actool` runs, with
relative paths, all passed while a pooled daemon sat in a folder none of them used. No
new daemon outlived them, and the pooled one did not move. `IBToolCompiler` and
`AssetCatalogCompiler` pass it on every run (`InterfaceBuilderDaemon.environment`), and so
do the real-tool tests. With a pooled daemon sitting in a foreign folder, the SemelApple
suite passed. Each run's folder is a temporary one removed after the run, as for every
other tool, and the command line keeps its relative paths. It costs a daemon started per
run, about 0.6 s, where a pooled daemon answers at once.

Residual: something else on the machine running `ibtool` or `actool` with the pool can
still poison the pool for its own later clients, but never Semel's.

**B-154** `open` — **ibtool is not a function of its input.** Found 2026-10-11 by the
roster's byte comparison of Sequel Ace's two builds (B-77 item 4), and reproduced outside
Semel on Xcode 26.6. Two kinds.

**A storyboard's nibs vary in form. Fixed 2026-10-11.** ibtool gives a Mac storyboard's
view controllers fresh UUIDs on every compile (`NSViewControllerIdentifiersToUUIDs` in the
`.storyboardc`'s `Info.plist`, and inside its nibs). It also lists a scene's connections in
a new order each run, which reorders the archive's objects, the object-to-parent table and
the object ids with them. Three compiles of Sequel Ace's `ProgressWindowController.storyboard`
gave three trees. `IBToolCompiler` (5) now publishes every NIBArchive it writes in
canonical form (`NibArchive`, `NibCanonicaliser`):

- the connections sorted by what they connect;
- the parent and id tables sorted by object, with the ids handed out again in that order;
- objects numbered by a depth-first walk from the root, keys sorted, classes in order of
  first use;
- each storyboard UUID derived from the document and the identifier.

The canonical archive is read back and checked against ibtool's, object by object through
the renumbering, and a nib that cannot be put in that form is `nibNotCanonical`. The three
compiles now give one tree. Sequel Ace's other twenty-four xibs and NetNewsWire's, which
ibtool wrote the same each run, keep their content. A canonical nib loads with `NSNib` to
the same objects as ibtool's.

**A document whose layout differs. Detected 2026-10-11; the project's to fix.** Sequel
Ace's `ImportAccessory.xib` stores frames its constraints do not give: its accessory view at
707 × 184 where the constraints make it 160 tall, and its labels, pop-ups and tab view at an
older layout's places. ibtool updates such frames when it compiles, and does so differently
from run to run: eight compiles gave four nibs, each view at one of two places 24 points
apart. That is a different nib, not a different encoding of one, so no canonical form
exists. `IBToolCompiler` therefore compiles every document twice and refuses one whose two
canonical forms differ, as `toolOutputVaries`, with the remedy to resolve the layout. The
roster's `sequel-ace` lays an overlay (`Fixtures/external/sequel-ace`) with the xib's six
frames set to what AppKit's layout gives them at run time, which is what Interface
Builder's "Update Frames" writes. Sixteen compiles of the corrected file gave one nib, and
the roster's two builds are byte-identical with no exemption.

Compiling twice doubles ibtool's time per document. With `IBToolNeverDeque=YES` (B-152)
each run already costs about 0.6 s more, since it starts a daemon of its own instead of
taking one from the pool. Still open: a document whose ambiguity the two runs happen to
resolve alike passes, and is caught by the roster's comparison, not by the node.

**B-155** `done` — **A large app made the server's memory grow without bound.** Seen
2026-10-11 building Sequel Ace (B-77 item 4). Six cold builds in a row were killed with
SIGKILL about thirteen minutes in. Swap went from 10 GB to 40 GB in three and a half minutes,
and the server's footprint reached 24 GB and was still growing. A sample of the server put
every compute thread in `ProjectBuilder.fillingFormulaFolder`, under `outputFileSpec`.

Half fixed 2026-10-11. A tree product, `product 'Sequel Ace.app/' = signed_Sequel_Ace().files`,
publishes one `OutputFile` per entry of the tree, each wrapping a `TreeFile` over the tree's
expression. `outputFileSpec` filled each entry's spec with the formula's folder and the
project's root by walking it whole: `fillingFormulaFolder` and `adding(property:)` each
rebuild the tree below a node. So the signed bundle's expression, every compile of the app
and its packages, was rebuilt for each of the bundle's 270 files. The expression is filled
once already, for the wire that brings the tree. Each entry now shares it, and only the
entry's own `TreeFile` and `OutputFile` are given the two properties
(`ProjectBuilder.fillingTopNode`). The specs are the same as before. The cold build then
completed: 610 s with `SEMEL_JOBS=4`.

Still open then: the server's footprint reached 7.5 GB about ninety seconds into the same
build, just after the push of the clone's 41,392 files, and stayed between 4 and 6 GB to
the end. `heap` at one of those moments counted 155 MB live against 4.2 GB of footprint,
and `malloc_zone_pressure_relief` every five seconds changed nothing.

Fixed 2026-10-12. The push was not the cause; the pass of the formula's builder that
follows it was, and the push had a smaller cost of its own. Measured with release binaries
over a fresh home, the footprint sampled every two seconds and `vmmap`, `heap` and `sample`
taken as it passed 1, 2 and 4 GB (`BACKLOG.md`, Performance, 2026-10-12, for the figures).

1. **The builder spelled its products out.** At 6.3 GB of footprint `heap` counted 5.8 GB
   live in 18 million allocations, every compute thread in
   `GraphSpecNode.adding(property:)` under `ProjectBuilder.process`. Filling the products
   with the formula's folder and the project's root rebuilt every node it met, so a
   subexpression reached many times — the settings under every compile, every compile
   under the app and again under the bundle that signs it — came back once per occurrence,
   each in storage of its own. `GraphSpecRewriter` rewrites each distinct subtree once and
   shares the copy; one filler serves a builder's pass. The 155 MB against 4.2 GB was most
   likely this burst after it: here the footprint stood at 4.3 GB after the pass with
   70 MB resident, and fell to 110 MB over the next 30 s.
2. **The formula resolver evaluated every function call afresh.** With the fill shared, a
   burst of up to 1.4 GB remained; at 1.0 GB `heap` counted 0.96 GB live in 4.4 million
   allocations, every compute thread in `FormulaResolver.evalFuncCall`, the generated
   formula calling its settings and module functions from every target. A call's value is a
   function of its arguments, so the resolver keeps each and a call made again is the first
   call's value.
3. **A pushed file was held four times over.** The frame's buffer, the body copied out of
   it, the file copied out of the body (`subdata`) and copied again into an array to hash
   and store. Files are now slices of the body and stored from where they lie
   (`Data.intern()`).
4. **The decoder kept the largest frame's room for the life of the connection**
   (`removeFirst`), and a large body went through malloc twice. A body of 1 MB or more is
   now received into a mapping of its own and handed over as the frame's `Data` without a
   copy, unmapped when the frame goes (`FrameDecoder`, `MappedBody`).

Not the database: the page cache is 64 MB (`cache_size=-65536`) and `vmmap` never showed
more, there is no `mmap_size`, and the WAL is a file, not the server's memory, checkpointed
by SQLite as it passes 1,000 pages, since each push request commits its own transaction.
Nor the journal, whose rows are in the database. What grows with the tree in memory during
a push is about 40 MB at 41,000 files — the journal's recorded paths and the settle's
record of the ports written — all live.

What remains is the allocator's, and it does not grow with the tree. libmalloc keeps up to
64 freed large blocks dirty for reuse, and `vmmap` shows them as `MALLOC_LARGE (empty)`:
364 MB of a 434 MB footprint at one moment of the push, against 41 MB live. With the cache
switched off (`MallocLargeCache=0`) the same push, before items 3 and 4, peaked at 306 MB
where it otherwise reached 780 MB. `malloc_zone_pressure_relief` after every request with a
body of 1 MB or more released none of it: tried, measured at the same 765 MB, and removed.
Fewer large allocations do help, which is what items 3 and 4 are: the frames, most of the
churn, no longer go through malloc at all. Twice the files pushed peaks no higher.

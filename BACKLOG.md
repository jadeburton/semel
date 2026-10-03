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


## Design, correctness and code quality

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
2. **A folder a vendored package's manifest names and the package lacks** — a target whose
   `path:` is wrong — is a ghost under the package, and the build ends on the lock:
   `is not the tree its lock records`, naming two roots and not the path. The converter,
   or the lock check, could name the demanded paths under the folder that nothing pushed.

**B-47** `open` `For Fable Only` — **The SDK is declared but not a graph input.**
Closed so far (2026-09-12): the declared identity is version *and* build, `26.5 (25F70)`,
checked against the machine; and the Swift compiler and linker put a fingerprint of the SDK
tree — every file's path, size and mtime; 1.2 s cold, 0.4 s warm, once per process — into
their cache key through `Node.cacheKeyMaterial`, so two machines with the same declared SDK
and different contents no longer share an entry. Content hashing was measured at 4.4 s and
rejected; a cross-launch cache keyed on the SDK directory's mtime was rejected because that
mtime does not change for a file edited deep inside.

What remains: a cache key can only stop a wrong reuse. An SDK edited in place under an
already-built graph is not rebuilt, because an unscheduled node never recomputes its key.
Closing that needs the SDK to be a graph input — the gigabyte-of-headers problem — which is
B-03's container digest. Also: only the Swift tools fingerprint the SDK. `ClangPreprocessor`
and `ClangLinker` read the SDK at `sdkPath` too, and their keys carry the path and the tool
binary's fingerprint but not what is behind the path.

The invariant the original TODO stated (every node input exists inside the input file
system or is derived from it) is still worth writing into `AGENTS.md`, but not in those
words: sources the runtime fills — `StaticFile` from a push, B-108's `FormulaPrelude` from
the plugins — and the machine facts in a key (the SDK, the tool binary) are inputs from
outside the input file system by design. It has to be stated as "or declared as coming from
outside", which is B-43's external port.

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

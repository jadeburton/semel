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


## Design, correctness and code quality

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

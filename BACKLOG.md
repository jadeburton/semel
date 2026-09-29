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

**B-130** `open` `For Fable Only` — **A node of a kind this server no longer links stops a push and the
build says `No errors.`**
Found 2026-09-28 while refreshing the tutorial (B-129). The tutorial removes its
`MyLineCounter` type and builds again: a stale row of that kind stays in the graph, and the
first push that wakes it prints `The operation couldn't be completed.
(SemelNodeKit.TypeRegistryError error 1.)` where a `Push file:` line should be. The
folder push stops at that file — the files after it show no push line — and the build
then prints `No errors.` and exports nothing, because the failure happened in the push,
not in a node the error report reads. `check` names it (`kind 39 #51: its kind 39 is a
type this server does not link`) and `reset` clears it, but nothing at the prompt says so.
Two things wrong: a push that hits a node it cannot make should report the file and go
on to the next, as it does for a file it cannot read; and a graph holding a kind the
server does not link should be said at launch or at the first settle — as the B-29
schema check refuses a database it cannot read — with `reset` named as the way out,
rather than surfacing as a Cocoa sentence in the middle of a push. Which of the two
(refuse at launch, or carry the node as an error the report shows) is the decision.

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
executables are byte-reproducible. What follows is what is left: `actool`'s output is not.

**B-89** `open` `For Fable Only` — **`actool` output is not byte-reproducible: `.icon` renditions carry a
UUID and pid, and the appearance table's order varies.** Two separate causes, both in
IceCubesApp's compiled asset catalogs. First, `actool` embeds a fresh UUID, its pid and a
mach timestamp in the names of the renditions it generates from an Icon Composer `.icon`
bundle, so the app's `Assets.car` differs between two identical cold builds (eight
rendition names) even though the catalog's inputs and actool's arguments are
character-for-character the same in both builds; only the app's catalog carries a `.icon`
input. Second, and independent of a `.icon` input: an asset catalog with more than one
appearance can have its appearance table's entry order vary between two identical
compiles. The widgets extension's catalog — 18,856 bytes, two colorsets with light and
dark appearances and an appiconset, no `.icon` — differed in exactly this way in one of
three two-build comparisons, 16 bytes in all: the two entry names `UIAppearanceAny` and
`UIAppearanceDark` written in swapped order, and the four
key indices pointing at them following suit; `xcrun assetutil --info` on the two files
differs only in a timestamp field that is the file's own mtime, confirming the content
itself is the same table, reordered. The roster exempts every `Assets.car` of
`icecubes-app`; removing that exemption is this item's exit.

*Nothing Apple ships turns either cause off* (2026-09-27, Xcode 26.6 and 26.2, `actool`
run directly, each compile in a fresh directory holding copies of the inputs, as the
sandbox does). Both causes reproduce outside Semel: the app's catalog with `AppIcon.icon`
gave a different `Assets.car` on every one of three compiles, and the widgets catalog two
variants in ten (8:2 on 26.6, 6:4 on 26.2). The rendition suffix is
`<UUID>-<pid>-<mach time>`, the shape of `NSProcessInfo.globallyUniqueString`, so the name
comes from a temporary file named unique. Ruled out:

- **A flag.** `actool` accepts no `--help`, and its asset-catalog frameworks carry no
  determinism, serial-compilation or reproducibility switch (`strings` over
  `AssetCatalogFoundation`, `AssetCatalogKit`, `IconComposerFoundation`).
  `--output-format` selects the format of `actool`'s own report and was not tried
  against the catalog.
- **An environment variable.** `actool` reads none that selects behaviour; the one it
  looks for, `RC_XBS`, is Apple's build service.
- **Address randomisation behind the order.** `actool` is a launcher: the work happens in
  `ibtoold`, which it spawns itself from its own directory and which has no override for
  its location, so spawning `actool` without ASLR (`_POSIX_SPAWN_DISABLE_ASLR`) leaves the
  order varying.
- **Interposing `globallyUniqueString`.** `ibtoold` is signed with library validation, so
  `DYLD_INSERT_LIBRARIES` cannot load a library of ours into it.
- **Another Xcode.** 26.2 behaves as 26.6.

What remains is Semel's own: a node after `actool` that puts `Assets.car` in a canonical
form — rendition names with the unique suffix replaced by one derived from the rendition's
content, and the appearance table in name order with the key indices renumbered to match.
That rewrites Apple's undocumented BOM-based CAR format, and the replacement suffix need
not keep the name's length (the pid varies in digits), so it is a rewrite of the file
rather than a patch in place. Whether that is worth owning, against keeping the exemption,
is the decision.

*ibtool is not affected* (2026-09-29, Xcode 26.6), though it launches the same `ibtoold`.
Five of NetNewsWire's Mac xibs compiled three times each, every run in a fresh folder, and
an iOS xib and two storyboards (`.storyboardc` folders of nibs) twice, came out
byte-identical; `IBToolCompilerTests` pins it on one xib with the real tool, and
`swift-hello-app`'s `Card.nib` goes through the roster's four builds unexempted (B-77).
Only its human-readable notices name the document's absolute path, and they are a log.

*An ad-hoc signature is reproducible, and carries this item's variation* (2026-09-29, macOS
26.6, `codesign-83.100.6`). `codesign --force --sign - --timestamp=none` over the same
bundle twice, at two paths two seconds apart, with entitlements, wrote the same bytes and
the same cdhash: no identity, no signing time, nothing of where it ran. `CodeSignerTests`
pins it with the real tool through the sandbox, a nested extension and a versioned
framework included (B-77). But a signature seals what it signs: `_CodeSignature/CodeResources`
holds every resource's hash and each executable's code directory the hash of that seal, so
an `Assets.car` that differs moves both — seen in `food-truck-mac`, where the widget's
catalog differed between two builds and so did both seals and both executables. The roster
exempts those only when an `Assets.car` differs too (`mayDifferWithExempt`); a canonical
`Assets.car`, this item's exit, would make the signed bundle whole-byte reproducible.

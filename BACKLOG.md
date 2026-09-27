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

**B-14** `open` `For Fable Only` — **No blob GC.**
Unreferenced objects accumulate in the object store with no collector: `DataObjectStore` has
no delete, and the collectors that exist — cache-entry trimming, unreferenced nodes — remove
rows and leave their objects. Less "not urgent" than it was: since B-26, every edit interns
a fresh content-root document per ancestor folder (B-26 residual 3).

## Command line

What a user sees at the prompt. Found by using `semel` on IceCubesApp and the C fixture
(2026-09-23); the engine-side report these lean on is the settle-time artifact diff, which
the `artifacts` event carries.

**B-110** `open` — **Clone and build: `semel build` is one command — residuals.**
Done 2026-09-26 (design and "As built":
`docs/superpowers/specs/2026-09-26-semel-clone-and-build-design.md`): `semel` starts the
engine it finds missing and `semel stop` ends it; `build` follows the formula's inputs
within `base` — a source the settle reports as not pushed travels typed as
`ErrorEntry.missingSource`, is pushed with `hello/hello.fmla needs ../clang.cfg`, and the
build waits again; `--no-follow` — and the roster's `alsoPush` is gone; products go to
`<base>/semel-out/<folder>` and `push` never sends an export folder back in; nodes of one
type carrying one report are one entry, printed once; a failed build of a package tree
with no config names `semel-swift prepare`; `prepare` writes `clang.*` only for a tree with
a C-family target; `help`, and a typo names its nearest verb. What remains:

1. **A package dependency takes three rounds.** The converter's "waiting for a package"
   error carries no typed path, so `build` follows what the converter *wired* — the
   manifest, then the target folders — one settle each. A `missingSource` on that error,
   naming the package folder, would make it one round.
2. **A changed source outside the built folder is not re-pushed.** `build` follows what is
   reported missing; a `semel.machine.config` beside the folder that is rewritten after a
   toolchain change is the user's to `push`. Following the inputs the graph already holds
   outside the folder would close it.
3. **The first settle's summary line prints before the follow answers it:**
   `❌ 18 nodes scheduled, …, 25 errors` and then the push that fixes it. True, and noise;
   holding the summary of a settle the loop answers is the fix.

## Performance

Measured 2026-09-27 on the IceCubes packages tree (`C1/icecubes/Packages`, thirteen
packages, 26 Swift targets): a cold build of 321 s into an empty home, 2,627 nodes; a
rebuild with nothing changed took 18.7 s and a one-file add 35.5 s for six scheduled nodes,
neither broken down yet. With a compiler that compiles once its folder walk has finished
(B-112), the cold build took 93 s; with results written as each node finishes rather than
once a whole batch has (B-113), 85 s.

**B-114** `open` `For Fable Only` — **A running tool holds a Swift concurrency thread.**
`LocalFileSystemTool` waits for its process with `waitUntilExit()` inside a task of the
engine's task group. The cooperative pool is as wide as the machine has cores, so the
number of tools running at once is capped by accident rather than by a setting, and any
other work on that pool waits behind the compilers — whether the server's request handling
is among it has not been checked. Wanted: a declared limit on concurrent tools, and a
process wait that does not block a pool thread.

**B-115** `open` `For Fable Only` — **A node's `graphSpec` spells out its whole upstream graph.**
Each spec is its node's inputs rendered recursively, so a node shared by two consumers is
written out twice in everything below them, and the text grows with the graph. Measured:
8.9 MB of spec text over 2,627 nodes; each archive's `OutputFile` about 1.4 MB, each linker
about 690 KB; the column carries a UNIQUE index, so that is stored twice — some 18 MB of a
33 MB database. `Node.applySpecs` rebuilds a product's spec from the database and parses
the demanded one on every `ProjectBuilder` pass (13 in the cold build), walking shared
subgraphs once per product. Naming each input by its node's spec hash would make a spec one
level deep; identity by spec, and every reader of the column, would have to follow.

**B-116** `open` `For Fable Only` — **Every object passes through memory whole, and every read re-hashes it.**
A tool's output file is read into a `Data`, copied into a `[UInt8]`, hashed and written to
the store as a second file (`LocalFileSystemTool`, `Interning.intern`); every
`DataObjectStore.read` re-hashes the whole object to catch a corrupted store. For
IceCubes's 57 MB executable and 40 MB archives that is several full passes per file per
build. Streaming the hash and cloning the sandbox file into the store would remove the
copies; how often a read must be verified is the decision, since verification was added on
purpose.

## Design, correctness and code quality

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
app and not their archives. What follows is what is left: two places Apple's tools are
not byte-reproducible.

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

**B-90** `open` — **`ld` picks between two duplicate `_objc_msgSend` GOT entries non-deterministically.**
IceCubesApp's linked executable carries two GOT entries binding the same import,
`_objc_msgSend`, and which one the linker's `__objc_stubs` synthesis references varies
between two identical links of the same objects — 531 `ldr` displacements differ and so
does `LC_UUID`, while every symbol, address and fixup is identical. All inputs to the link
are the same hash in both builds. To find: the linker option that makes GOT emission
deterministic (`-no_deduplicate` is already passed by clang's driver in debug; check
`-fixup_chains` and `-ld_classic` behaviour), or confirm the duplicate originates from a
specific input. Evidence, from `icecubes-app`'s two-build comparisons: carrying the duplicate pair is necessary but not sufficient — which
of the executables carrying the pair flips varies — three of the four `.appex` executables
in one run, the app's own executable in another — while `IceCubesActionExtension` links a
single `_objc_msgSend` GOT entry (`dyld_info -fixups` shows one `_objc_msgSend$` line
against two for every other target) and has been identical in both runs; comparing its link
inputs against `IceCubesNotifications`'s is the shortest route to the input that introduces
the second entry. The roster exempts `Ice Cubes.app`'s executable and three of its four
extensions' (every one but `IceCubesActionExtension`'s) for `icecubes-app`; removing that
exemption is this item's exit.


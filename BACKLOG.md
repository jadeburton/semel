# Backlog

Concrete open items. `FUTURE.md` is for direction; this is for what is broken or owed.

IDs are stable and never reused — reference them in commits (`closes B-07`) and in
discussion. Status is `open`, `doing` or `dropped`. Finished items are removed rather than
marked done: the commit that closed one carries its reasoning, and `git log --grep=B-07`
finds it. `Not doing` keeps the decisions that would otherwise be raised again.

## Hermeticity and determinism

**B-03** `open` — **Run tool execution in a container.**
`ToolRunner` runs inside a dedicated process wrapping a Docker container configured with
the toolchain, SDK and system libraries, reset between builds. The container digest then
*is* the environment: `sdk=26.5 (25F70)` becomes `image=sha256:…`, and "did we miss an
input?" stops being a question only an audit can answer. Also the natural home for the
Remote Runner role (B-30).

**B-49** `open` — **Tool outputs must not depend on where the inputs are mounted — residuals.**
Done 2026-09-20: parts 1 and 2 — the sandbox contract is `ToolSandbox` (inputs at their
wire keys below a fresh root that is the working directory; every argument relative to it;
the root's canonical name `/semel`); `ClangCompiler` and `SwiftCompiler` record `/semel` as
the compilation directory, `ClangLinker` and `SwiftLinker` prefix the debug map with the
working directory, and `SwiftCompiler` serializes no debugging options, which is what kept
the sandbox root out of a `.swiftmodule` built without `-g`; the end-to-end harness builds
every fixture a third time from a copy at a longer-named mount and requires it to match.
The checkout prefix was never in the graph: the client pushes base-relative paths.

Of part 3, only the plumbing is done: the `projectRoot` property `ProjectBuilder` stamps on
every cacheable node, `GraphSpecNode.adding(property:value:where:)` that stamps it,
`Node.cacheKeyExcludedProperties` that keeps `projectRoot` out of a node's own key, and
`Node.projectRelative(wire:)`, which strips the root from a wire name — written, unit
tested directly, and not applied to a cache key. What remains:

1. **Applying the project-relative key.** `LocalFileSystemTool` materialises every input at
   its full wire key, and every node puts that full key on its command line, so stripping
   the key alone equates two placements whose bytes differ (preprocessor `#` line markers,
   `DW_AT_name`, `__FILE__`) and whose cached `inputWireSpecs` name the other placement's
   files instead of this one's. The key may be made project-relative only once the sandbox
   layout and the command lines are project-relative too, which is what the design's
   "canonical sandbox layout" (§3) must actually mean. A fix needs one fixture built at two
   different positions under `input:`, with the resulting products compared byte for byte.
2. The implicit clang module cache path in a Swift object built with `-g`
   (`/var/folders/<user>/C/clang/ModuleCache/…`): per user, stable on one machine,
   different between machines. Explicit modules would remove the cache rather than move it.
3. `OutputFile.path` and `ProjectBuilder.outputFolder` in their own nodes' keys. Both
   determine those nodes' outputs, so stripping them needs its own argument; neither sits
   upstream of a compile.
4. Whether `-Xfrontend -no-serialize-debugging-options` is safe in every graph. IceCubes
   builds with it; the fallback, if a graph ever needs the serialized search paths, is
   `-file-compilation-dir` alone and accepting the `.swiftmodule` leak.
5. `{sandbox}` substitution for a node that ever needs the real root: specified in the
   design, built by nothing, so the answer exists without an API.
6. `FolderManifest.baseFolderPath` (`SemelNodeKit/Sources/SemelNodeKit/FolderManifest.swift`)
   holds the folder's absolute input path and travels inside the serialized manifest that
   `SwiftCompiler` takes on `inputFolder`, `inputSubfolders` and `inputModuleMapFolders`.
   Currently load-bearing, not a mere residual: with item 1 unapplied, this absolute path
   inside a manifest value is what keeps the keys of two placements apart wherever a folder
   is wired, so it must not be removed before item 1 lands. Once the key is
   project-relative, the same absolute path costs missed hits across developers — never a
   wrong hit — and the fix is not in the key: it is what `Folder` publishes, or a manifest
   whose paths are root-relative, and every node that reads `baseFolderPath` — the clang
   preprocessor's `-I`, the Swift compiler's walk — has to follow. `CacheKeyMountIndependenceTests`
   prove the wire-name half of the design; this value half is what remains for a real Swift
   graph.

## Swift package conversion

**B-06** `open` — **Lock vendored dependencies by content hash.**
`ISSUE:` at `SwiftFormulaConverter.swift:434`. A `sourceControl` dependency resolves to a
vendored sibling directory with nothing checking that what is there is what was meant.

Approach: a recursive content hash over the vendored package's own folder in the input file
system — `input:/repo/GRDB.swift` — recorded and compared on every build. Guarantees the
dependency has not changed, without claiming to guarantee which version it is.

*What this does not need to fix.* Cache correctness is already guaranteed: a vendored
package's files are ordinary `StaticFile` nodes whose content hashes are wire values, and
`buildCacheKeyPartFromOneInput` puts every wire's key and value into the cache key. Adding
or removing a file changes the `Folder` manifest, which is also an input. So an edit to
vendored GRDB *already* changes the key of everything downstream. A lock adds nothing to
detection.

*What it does buy* is notification and consent. Today a change is silently absorbed — the
graph rebuilds and succeeds, and nobody is told their dependency moved. A lock turns that
into "expected `abc…`, found `def…`; update the lock if this was intended", which is the
same value `Package.resolved` and `yarn.lock` provide.

*Open sub-decision: where the lock lives.* Jade suggested graph configuration. The
counter-argument is that the value is entirely in the diff being reviewable — a hash in
node configuration lives in the database, so it cannot be diffed in review, shared between
developers, or inspected without the build system running. Recommendation is a checked-in
file in the vendored folder, which still reaches the graph as an ordinary `StaticFile` and
so participates in cache keys with no special path:

    GRDB.swift/.semel-lock
        content   sha256:abc…      enforced; a mismatch stops the build
        version   7.11.1           recorded only, never enforced
        origin    https://github.com/groue/GRDB.swift.git

Keeping an unenforced version line costs one line and answers two questions a hash cannot:
whether this is the library that was meant in the first place — a lock preserves a
first-time mistake forever — and whether a published advisory applies. Degrades gracefully:
absent → warn once, present and mismatched → fail.

The recursive content hash is there (B-26): a folder's `contentRoot` port carries a Merkle
root over everything under it, so `input:/repo/GRDB.swift`'s root is one port read — and it
is not qualified by the folder's path, so a lock survives the dependency being moved. What
remains for B-06 is recording that hash in a lock file and comparing it. Two notes for
whoever does: the fold is a stated text format with a version tag on its first line
(`FolderContentRoot`), so a recorded root that stops matching can be told from one the
format moved under; and a `contentRoot` wire is a real dependency, so the node that checks
the lock re-runs whenever anything under the vendored folder changes, which is the point.

**B-10** `open` — **Packages are named by a formula, not discovered — two residuals.**
Done 2026-09-12: `Package.swift` creates no builder; a `.fmla` says
`include SwiftFormulaConverter(path: <.>).formula` — `include` merges the formula text any
node produces, and knows nothing about packages; the converter wires its own reader from
the path — only the formula's products are published and they land beside the formula,
included names may not clash with the formula's own, and every node of the build reads its
settings from the config beside the named package — so this tree keeps one `semel.config`,
not six. What remains:

1. **Dependency overrides in the formula.** The converter resolves a git dependency to
   `<root>/Dependencies/<name>` (the `semel-swift` rule) and stalls when nothing is there;
   a formula cannot yet say "this URL is at that path". Needed the day a dependency has to
   come from somewhere the rule does not reach.
2. **Discoverability.** A pushed `Package.swift` that no formula names now builds nothing,
   silently. `ProjectFinder` sees every manifest and could report at idle the ones no
   builder's `includes` port reaches.

Granularity is per package, not per product: a dependency that also vends an executable
loses it. Acceptable until a real case shows up. The inferred-roots plan (converter
dependency lists unioned in `ProjectFinder`, a `publishProducts` property, the settle diff
hiding the flap) was declined the same day: a port, a protocol parameter, a property and an
ordering constraint to approximate what one line of formula states.

**B-55** `open` — **C targets in a Swift package: what the first case did not need.**
B-54 builds swift-cmark and CAtomic inside IceCubesApp's graph (39f27b1): a target whose
folder holds C-family sources and no top-level `.swift` gets a preprocessor and compiler
per file, its `include` folder goes on every dependent Swift target's `inputModuleMapFolders`,
and the objects link into the product's archive. Left for a package that needs them:
`cSettings` `.define` values are not carried (cmark's are Windows-only); source files in
nested folders are not compiled (the glob is one level); a `publicHeadersPath` other than
`include` is not honoured; and a package vending an *executable* with C targets would
need a `clang.linker` block, which the archive case never reads.

**B-26** `open` — **Recursive content hash for a folder tree.**
Done 2026-09-25: a `Folder` publishes a Merkle root on a `contentRoot` port of its own —
the hash of a document with one line per child carrying its kind, what it holds and its name:
a file's line carries its content hash and a subfolder's carries that subfolder's root,
ordered by name as UTF-8 bytes then by kind, and framed by each name's length. A change anywhere below moves every root above it, carried by the B-25
dirty mark, so an edit costs one fold per ancestor and not one per folder. Not on the
manifest, and this is the load-bearing part: the manifest is what a folder's children are
called, `ProjectFinder` and the converters are wired to it, and folding content in would
re-run all of them on every keystroke. The root is path-independent where the manifest is
not, so two copies of one tree are comparable wherever they stand. What remains:

1. **`output:` is opaque to the fold.** Every product's line says `notFolded`, so an
   `output:` folder's root identifies its names and not its content. The blocker is not the
   extra query — a product's bytes are one more join away, on its input wire — but
   invalidation: nothing notifies a folder when a product below it changes, so a folded
   product hash would go stale without the folder ever being rebuilt. Fixing it means giving
   `OutputFile` the notification `StaticFile` has. Wanted the day anyone syncs *products* to
   a peer, or checks an `output:` tree for consistency (B-63); neither B-06 nor the
   client/server reconciliation, both of which read `input:`, needs it.
2. **`notFolded` for a kind that is not a product.** The fold reads `Folder` and
   `StaticFile` and answers `notFolded` for every other kind under a folder. Today that is
   only `OutputFile`; a new kind of child would want its own answer rather than this one.
3. **The fold makes the object store grow on the per-edit path.** Each fold interns its
   document, so one edit writes a fresh document per ancestor — and for a folder of 3,000
   children that document is a couple of hundred kilobytes. The object store is
   append-only: nothing prunes, so a day of editing leaves a few thousand documents nobody
   will read again. A manifest is interned too, but a manifest moves only when a name does.
   Wanted alongside whatever collects the store; until then the growth is proportional to
   edits × depth rather than to the tree. Related: during a flush a folder can publish an
   intermediate root and then the settled one, so once B-06 wires a `contentRoot` consumer
   that consumer is woken twice for one edit — correct, because the flush drains before the
   pass selects, but twice.

## Cache

**B-11** `open` — **Probe determinism at write.**
Occasionally run a node twice before caching and compare. A node that is not reproducible is
marked never-cacheable. Fixes the problem at source rather than detecting symptoms forever,
and answers the question a shared cache most needs answered: which tools are safe to share.

**B-12** `open` — **Sampled re-verification of cache entries.**
Re-run entries and compare against what is stored. Must run *twice*, because a single re-run
cannot distinguish a bad cache from a non-deterministic tool. Weight by `cost × reuse`
rather than uniformly. On a shared cache, have each client ignore a small percentage of hits
and recompute: coverage is sampling-rate × fleet-size.

**B-107** `open` — **A cache entry's content is stored as a JSON array of integers.**
`CacheEntry.content` is `[UInt8]`, which GRDB encodes as `[104,101,…]`, so every byte of
entry JSON costs about 3.5 bytes on disk — roughly 0.75 MB at the 500-entry limit against
about 0.2 MB as bytes. Making the column a real blob changes the schema fingerprint, which
is a stopped launch and a re-push of every source, so it rides with the next unavoidable
schema change rather than on its own.

**B-14** `open` — **No blob GC.**
Unreferenced objects accumulate in the object store with no collector. Not urgent.

**B-15** `open` — **Cache abstraction behind a client interface.**
Make the engine talk to the cache as though it were a separate server, without a socket or a
separate process yet. Groundwork for the Cache Server role (B-30) that can be exercised
entirely in-process.

## Server

**B-30** `open` — **`semelserv` with three roles.**
One binary, three modes, sharing a wire protocol:
1. **Cache Server** — see `docs/superpowers/specs/2026-08-15-semel-cache-server-design.md`.
   This is the multi-user story (FUTURE.md "Settled direction"): every developer's local
   engine reads and writes it, behind the existing local cache as the near tier.
2. **Remote Runner** — executes tool commands inside, or against, a container (B-03)
3. **Local Build Daemon** — the surviving part of
   `docs/superpowers/specs/2026-08-15-semel-client-server-design.md`. Designed in
   `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md` and built: the
   `SemelProtocol` package, the in-process split behind `RequestHandler` and
   `InProcessConnection`, and `semelserv` plus `SocketConnection`. Wanted even with
   local building, because the point is a build that continues in the background regardless
   of which CLIs are open — local CLI to local daemon, one user, one graph. Do not write it
   for multiple users: that is the shared-build-server model the cache server superseded,
   and it is where the path authorisation and sync machinery came from. The artifact events
   CLIs subscribe to exist: the `artifacts` event carries one settle's diff — appeared,
   changed, disappeared — computed once per settle against the `ArtifactSnapshot` table,
   over the whole graph. Narrowing it to one worktree is this role's work and belongs at
   delivery, not in the engine: the engine's candidates are consumed as they are read, so a
   second, narrower diff of the same settle would find nothing left. A subscription is
   therefore a path prefix applied to the one diff, plus a retention window and a full
   resync from the snapshot table for a client beyond it. What remains of B-30 is roles 1
   and 2.

## Command line

What a user sees at the prompt. Found by using `semel` on IceCubesApp and the C fixture
(2026-09-23); the engine-side report these lean on is the settle-time artifact diff, which
the `artifacts` event carries.

**B-95** `open` — **Nothing tells the user when the build is done and the artifacts are there.**
After `push` or `build` the prompt returns at once and the graph settles in the background;
the only way to know when to `cp` or `export` is to poll `errors` or `ls output:`, or to run
`wait`, which blocks with no indication of progress. Wanted: a live indicator redrawn in
place rather than scrolled, in two sizes. Minimal: one line with the number of pending
nodes, which may rise while the cascade is still generating work, and a final line when the
graph settles. Maximal: the active nodes listed, a dashboard. The final line exists as the
settle summary, and what is missing is everything before it: the data is already counted —
`BuildEngine.processSomeNodes` knows scheduled, computed and from-cache per batch and the
summary accumulates them — so the work is a protocol message carrying the counts on each
batch rather than only at idle, and a terminal renderer; B-30 role 3's subscription is the
transport it grows into. Open, and to decide before building: whether
the indicator is opt-in or opt-out, and how the user keeps typing commands while it redraws
(a status line above the prompt, as `ninja` and `cargo` do, versus a mode entered with a
verb and left with a key).

**B-91** `open` — **The engine has no channel for anything but products and errors.**
`DaemonMessages` carry what was published, what failed, and one settle's totals; everything
else the engine knows about *why* — which wire changed, which nodes were scheduled, which
of them ran and which came from the cache, node by node — leaves through `Debug.log`, and
a release build compiles that out. The settle summary is the first step and carries the
three totals over the protocol; B-95's live indicator wants the same counts
per batch, so the three share one transport. This item is the rest of the channel: an
`explain <product>` (or `why`) command that walks upstream from a product to the wires
whose values changed since the last settle and names them, and a per-node record of
*ran* vs *from cache* that the summary and `explain` both read. The totals say that four
of ten nodes ran; only the record says which four. See FUTURE.md, "What the tutorial
taught us".

## Design, correctness and code quality

**B-105** `open` — **A node is named two ways in one product.**
A `check` finding names a node `Type #id 'path'`; `ErrorReport.label` names it `Type  'path'`
(two spaces, the id only as a last resort). The finding's form is the one to keep — a
finding is filed as a bug and the row is what the next person opens — so `ErrorReport.label`
should converge on it. Its output is pinned by tests on both sides of the wire, so the
change carries those test updates with it.

One surface over, the same word-for-several-states problem B-74 settled for the listing
does not arise for artifacts: an artifact's states reach the user through the settle diff,
which says appeared, changed or disappeared, and through the error report, which says the
rest. What a product that is not there reads as is the `ls` and `errors` vocabulary alone.

**B-43** `open` — **Formalise the nodes that break the dataflow rule, instead of leaving them
as back doors.**
A node's outputs are supposed to be a function of its inputs. Three types are not, and none
of them says so — they simply reach around the model, which makes the exception look like an
oversight rather than a part of the architecture.

They break *different* rules, and one concept will not cover all three.

*`StaticFile` — genuinely external.* No input ports, yet its output value arrives: the push
path writes its output port from outside. Same for user intent, "pinned" versus deleted.
Candidate fix: a fourth port kind, `.external(name)`, filled by the runtime rather than by a
wire. Purity then becomes universal — every node's output is a function of its declared input
ports, and what varies is only who fills them. That is also what would make B-02 enforceable:
"no node may read outside its declared inputs" cannot be stated while two types quietly do.

*`Folder.manifest` — not external at all.* It is a projection of the graph itself: the set of
child nodes, plus each child's pinned state, both read straight from the database, recomputed
by `onChildAdded`/`onChildContentChanged`/`onChildDeleted`. The dependency is the parent-child
edge, which the engine already has — represented as `parentNodeID` rather than N wire rows,
because a folder of 10,000 files would otherwise mean 10,000 wires. (That edge is also what
the missing index cost: 200 files, 3.39s to 0.63s.)

So the honest framing is that **the parent-child relation is a high-fan-out dependency edge,
and the child callbacks are its propagation mechanism** — the structural analogue of
`writeToOutputPort` scheduling downstream nodes. Nothing is wrong with it except that nothing
declares it, so it reads as a node reaching out to write itself.

*`OutputFile` — dissolved.* It read its own previous output port to decide whether to print
a status change. Change-notification moved to the engine, which reports one settle's
artifact diff against a snapshot table, and the self-read went with the printing. Nothing
is left of this case. `ProjectBuilder` held the same shape one surface over — a `products`
output port it wrote and read back, carrying the set of product paths between passes so it
could print a line when one went away — and it went the same way, port and all: a durable
table the engine compares at settle answers that question for the whole graph, where a
builder could answer it only for one project and only while the process lived.

*A correction to our own comment.* `Folder.pinnedOutputPort` is marked HACK for storing state
in a "fake" output. That is too harsh. Putting the state in an output port is what keeps it
inside the dataflow model: it can be wired, downstream nodes can see it, and it lands in cache
keys. A private state field would be invisible to all three. The fix is to declare what that
output means, not to invent a state slot beside the ports.

*Cost to know before starting.* If either external inputs or structural dependencies become
declared, `StaticFile` and `Folder` become nodes the engine schedules and processes — which is
arguably more correct, since a push *is* an event that should run the node. But
`descriptor.hasInputs` is now the single answer to "does the graph process this node"
(`3a0d68e`), load-bearing at six sites and pinned by `SourceNodeSchedulingTests`. The
distinction would have to become "wired inputs" rather than "inputs".

**B-44** `open` — **Naming: what is left after the 2026-09-12 sweep.**
Done: the `Tool` suffix is gone from the tool nodes, `ConfigSubset` is `ConfigFilter`,
`GraphShape` is `GraphSpec`, "expectation" is "spec" everywhere, and `searchKey` is
`graphSpec` (column included — an older database fails the B-29 schema check and has to be
deleted). The glossary and the naming rule live in `AGENTS.md`; the rename cost data moved
there too.

*Still open.* The config vocabulary — `Configuration` (a node type), `ConfigurationText`,
`semel.config`, `config namespace` — is four words circling one area. Not misleading, just
crowded; rename opportunistically, when already in the file.

*Decided, so it is not re-raised.* `isPinned` stays. *Pinned* means "cannot be moved" in
memory management, where the meaning here is "held alive by user intent rather than by
references" — a **GC root**. `isRooted` is more accurate only to a reader already thinking in
collector terms, and would read as "the root of the file system" to everyone else. Revisit
only if a real collector lands.

**B-47** `open` — **The SDK is declared but not a graph input.**
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
B-03's container digest. The invariant the original TODO stated (every node input exists
inside the input file system or is derived from it) is still worth writing into `AGENTS.md`;
nothing there says it.

**B-61** `open` — **`wait` across connections.**
Two things a socket server must settle before `wait` is offered to more than one client: a
`wait` can block indefinitely while another session holds a batch open, since a batched
work signal is counted but not sent until `endBatch` (fails safe, never a false settle;
the limit is pinned by `test_waitBlocksWhileAnotherSessionHoldsABatchOpen`); and
`waitUntilIdleBlocking` parks the caller's thread, so a listener must not call the handler
from a cooperative-pool thread.

**B-84** `open` — **SwiftPM leaves a dependent module's objects stale after a path
dependency changes.**
Both halves of the original item are answered, and what is left is upstream.

The stale *plan* is fixed. SwiftPM re-plans when llbuild's `PackageStructure` command is
dirty, and that command's inputs come from `BuildPlan.inputs`, which iterates
`graph.rootPackages`: the root package's target directories, its `Package.swift` and its
`Package.resolved`. Every other package here is a path dependency, so adding or removing a
source file in one of them is an input to nothing and `.build/debug.yaml` keeps the file
set it was written with — "cannot find 'X' in scope" for an added file, "missing inputs:
…/X.swift" for a removed one. `--disable-build-manifest-caching` plans every invocation for
about 0.15 s on this package, inside the noise of process start-up; `scripts/build.sh`
passes it and CI and `AGENTS.md` call the script.

The stale *value* is fixed for `Hello`. A default argument is not a call: the compiler
emits a default-argument generator with the constant folded in, as a coalesced copy in
every caller's object file (`mov w8, #0x9` inside
`SemelCLI.build/CommandInterpreter.swift.o`). `Hello.init(role:)` is an overload calling
`init(protocolVersion: ProtocolVersion.current, role:)`, so the read happens in
`SemelProtocol`; `test_helloWithNoVersionNamedCarriesTheProtocolModulesNumber` catches the
stale copy, not the reintroduction — reinstate the default argument and build clean and both
sides of it fold to the same number. "A constant that crosses a module boundary is not a
default argument" is an invariant in `AGENTS.md`, and that is what guards the reintroduction.

What remains is the SwiftPM defect underneath the second half, which the overload avoids
rather than cures: an incremental build can leave a dependent module's objects unrebuilt
after a change in a package it depends on — an undefined symbol at link time
([swiftlang/swift-package-manager#7715](https://github.com/swiftlang/swift-package-manager/issues/7715),
open since 2024-06) or a struct read at the wrong offsets
([#10502](https://github.com/swiftlang/swift-package-manager/issues/10502), open since
2026-09). The measurement on Swift 6.3.3 that produced the overload: with the default
argument in place, bumping `ProtocolVersion.current` from 9 to 10 and running one root
`swift build` linked `semel` at 9 and `semelserv` at 10. `rm -rf .build/arm64-apple-macosx`
is the only local answer to the general case. The plan-input bug has no tracker entry
of its own; filing one against `BuildPlan.inputs` is the other thing worth doing.


## App bundles

Building the app that consumes the packages, for the simulator first. Design:
`docs/superpowers/specs/2026-09-14-semel-app-bundles-design.md`. A hand-written formula
already builds and launches a SwiftUI app (`C1/swift/HelloApp`, 2026-09-14); what follows
is what a tool-decided file set needs. Tree-valued ports and tree products (B-63) are
built: `TreeManifest`, `expectedOutputFolders`, `TreeFile`, `TreeMerger`, and
`product 'name/'`. The Apple resource nodes (B-64) are built: `SemelApple` with
`AssetCatalogCompiler`, `StringCatalogCompiler` and `InfoPlistBuilder`; HelloApp builds
with an asset catalog and a string catalog and runs in the simulator. The Xcode project
converter (B-65) is built: `XcodeProjectConverter` builds the application and the four
extensions it embeds from the project file, and `semel-swift prepare` on a folder holding
an `.xcodeproj` resolves the project's packages through Xcode, vendors them and writes the
formula and config; a fresh clone of IceCubesApp goes from `prepare` to a launched app in
two commands. Device signing is deliberately out — the simulator needs none beyond what
`ld` does.

**B-67** `open` — **A converted project publishes every package's archive beside the app.**
Each included package formula publishes its `lib<P>.a` products beside the including
formula, so the app's build root ends with twenty archives nobody asked for — 40 MB each
for IceCubes. An include that brings only funcs, not products, or a package converter
that emits archives only when it is the root, would drop them; the product statement is
the only thing the app does not want.

**B-89** `open` — **`actool` output is not byte-reproducible: `.icon` renditions carry a
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
itself is the same table, reordered. To find: an actool flag or environment variable that
fixes the rendition identifier or the appearance order, whether actool has a
single-threaded mode that makes the appearance table's order stable, or whether
`--output-format` or a newer Xcode's `.icon` handling avoids the first cause; failing that,
the harness exempts `Assets.car` from `TreeDiff` for a project with a catalog carrying
either an `.icon` input or more than one appearance, named per project. Evidence: the
diagnosis's section 4. The roster exempts every `Assets.car` of `icecubes-app`; removing
that exemption is this item's exit.

**B-90** `open` — **`ld` picks between two duplicate `_objc_msgSend` GOT entries non-deterministically.**
IceCubesApp's linked executable carries two GOT entries binding the same import,
`_objc_msgSend`, and which one the linker's `__objc_stubs` synthesis references varies
between two identical links of the same objects — 531 `ldr` displacements differ and so
does `LC_UUID`, while every symbol, address and fixup is identical. All inputs to the link
are the same hash in both builds. To find: the linker option that makes GOT emission
deterministic (`-no_deduplicate` is already passed by clang's driver in debug; check
`-fixup_chains` and `-ld_classic` behaviour), or confirm the duplicate originates from a
specific input. Evidence: the diagnosis's section 3. Further evidence, from `icecubes-app`'s
two-build comparisons: carrying the duplicate pair is necessary but not sufficient — which
of the executables carrying the pair flips varies — three of the four `.appex` executables
in one run, the app's own executable in another — while `IceCubesActionExtension` links a
single `_objc_msgSend` GOT entry (`dyld_info -fixups` shows one `_objc_msgSend$` line
against two for every other target) and has been identical in both runs; comparing its link
inputs against `IceCubesNotifications`'s is the shortest route to the input that introduces
the second entry. The roster exempts `Ice Cubes.app`'s executable and three of its four
extensions' (every one but `IceCubesActionExtension`'s) for `icecubes-app`; removing that
exemption is this item's exit.

## End-to-end roster

Real-world projects for `EndToEnd/Tests/Projects.swift`, each chosen for something IceCubes
does not exercise. What is said about each project below is from memory of the project, not
from a clone: pin a commit, run `semel-swift prepare`, and let the first failure list correct
the entry. The gap list a project produces is worth more than its eventual pass.

**B-76** `open` — **A roster source for a clone plus a hand-written formula.**
`Project.source` is `.fixture` or `.git(url:commit:subfolder:)`, and only `prepare` writes
a formula into a clone. A C or C++ project has no converter, so its `.fmla` and `clang.cfg`
have to be laid over the clone from the fixtures folder — `.git(…, overlay:
"external/lua")` or similar. Blocks B-79.

**B-77** `open` — **More Xcode projects.** IceCubes is SwiftUI, synchronized folders, one
application target, simulator only, all library code in packages. In suggested order:

1. *apple/sample-food-truck* — small, no third-party dependencies, iOS and macOS, a local
   package, a widget extension. The first `sdk: 'macosx'` app build; the cheap second
   data point for the converter.
2. *NetNewsWire* — nearly every build setting lives in layered xcconfig files, so it is the
   hard test of evaluating settings the way Xcode layers them. Mac and iOS apps, framework
   targets, group-based file references rather than synchronized folders, some
   Objective-C, many local packages.
3. *CodeEdit* — macOS app over a large remote package graph; the tree-sitter grammars are
   many C targets with nested sources (B-55 through an app), build-tool plugins (SwiftLint),
   entitlements and sandbox.
4. *Mastodon iOS (official)* — IceCubes's domain with different structure: a Core Data
   `.xcdatamodeld` (wants a `momc` node), several extensions, generated-code build phases,
   a big local SDK package.
5. *Wikipedia iOS* — heavy Objective-C and Swift mixing, bridging headers, generated
   `-Swift.h`. Only when mixed-language app targets are in scope.

Expected to surface: script build phases, framework and dynamic-library targets,
Objective-C in the application target, Core Data models, storyboards and xibs (`ibtool`),
non-synchronized groups.

**B-78** `open` — **More Swift packages.**

1. *Semel itself* — `semel.fmla` exists; a macOS executable root rather than a static
   library, GRDB with a system-library SQLite, and no clone. One roster entry.
2. *swift-nio* — every residual of B-55 at once: `cSettings` `.define` values that matter,
   C sources in nested folders, header paths other than `include`, and executables
   (`NIOEchoServer` and the like) linking C targets, which need the `clang.linker` block.
   macOS, no macros. Should fail today in exactly the ways B-55 predicts.
3. *swift-crypto*, or *Vapor* which brings it — BoringSSL is C, C++ and `.S` assembly in
   deep folders, the hardest C-in-a-package there is; Vapor adds a transitive graph of
   some thirty git dependencies, which tests the `Dependencies/<name>` rule and B-10
   residual 1. After swift-nio passes.
4. *A second project sharing dependencies with IceCubes* (Nuke, SwiftSoup,
   swift-collections at the same commits) — what cross-project cache hits look like, for
   the local-engines-plus-cache-server design.

**B-79** `open` — **Real C and C++ projects.** The clang fixtures are a hello-world and a
six-file emulator. Needs B-76. `c-hello` is subsumed by `tutorial` — identical sources, the
same products plus `lines.txt` — so when a real C project is pinned it is `c-hello` that
goes, not the tutorial fixture. `RosterTests.test_theTutorialFixtureSourcesMatchTheCFixture`
compares the two `src/` trees, though, so that test and the tutorial's "copy
`EndToEnd/Fixtures/c`" instruction move to `Fixtures/tutorial` at the same time as `c-hello`.

1. *Lua 5.4* — about 35 files in one flat folder, no configure step, `liblua.a` plus the
   `lua` and `luac` executables.
2. *SQLite amalgamation* — one 250k-line translation unit: the preprocessor and compiler
   nodes and the cache with a single enormous entry, the opposite of IceCubes's 271 small
   ones.
3. *fmt* or *simdjson* — C++ beyond the emulator; few sources, heavy templates.

**B-80** `open` — **Projects that need macros.** The converter skips `macro` and `plugin`
targets (`SwiftFormulaConverter.swift:594`). These are the acceptance tests for the day
that changes, in rising cost:

1. *apple/sample-backyard-birds* — SwiftData's `@Model` comes from plugins shipped in the
   toolchain, so macro expansion is tested without building swift-syntax. Also widgets, a
   StoreKit configuration file, local packages.
2. *swift-syntax* alone — no macro support needed to build it; a large pure-Swift build and
   a useful performance benchmark in its own right.
3. *swift-dependencies* or *swift-composable-architecture* — package-defined macros built
   from swift-syntax and run as compiler plugins.
4. *isowords* — one `Package.swift` with some ninety targets and heavy resources (audio,
   fonts): graph scale and `Bundle.module`. Pulls in TCA, so it waits for 3.

## Not doing

**B-40** `dropped` — Subtree-scoped `reset`. Moot: users no longer share one graph.
**B-41** `dropped` — Scoping or privilege for `debug`. Moot for the same reason.

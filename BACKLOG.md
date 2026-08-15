# Backlog

Concrete open items. `FUTURE.md` is for direction; this is for what is broken or owed.

IDs are stable and never reused — reference them in commits (`closes B-07`) and in
discussion. Status is `open`, `doing`, `done` or `dropped`; done items stay for a while so
their reasoning is findable, then get pruned.

## Hermeticity and determinism

**B-01** `done` — **Audit every machine-derived input into the cache key.**
`cacheKeyEnvironment` now records the SDK for the Swift tools, but that was one instance of
a class. `DefaultTools` deliberately takes tool versions from the machine; environment
variables, locale, working directory and hostname were never examined. An input that
influences output but not the key makes two different builds collide on one entry — locally
a stale result, on a shared cache a wrong build handed to everyone.
*Outcome:* the engine was already hermetic by construction — `ToolExecutor` replaces
the environment rather than inheriting it, giving a fixed PATH with HOME and TMPDIR inside
the per-run sandbox and cwd there too. Exactly one node punched through it, and does no
longer (`SwiftPackageReaderTool`). Tool versions turned out fail-safe rather than silently
wrong: `Toolchain.parseVersion` keeps the build id deliberately, and the registry refuses a
tool whose reported version differs from the key's claim. Remaining gap tracked as B-17.
Superseded in the long run by B-03, which replaces enumeration with one value.*

**B-02** `open` — **Make it hard to read outside a node's declared inputs.**
Hermeticity is load-bearing for the whole design, and nothing currently prevents a node
function from calling `xcrun`, reading an environment variable or touching the filesystem.
Ideas: route all subprocess execution through `ToolExecutor` and forbid `Process` elsewhere;
scrub the environment before exec; run with a working directory that contains only declared
inputs.

**B-03** `open` — **Run tool execution in a container.**
`ToolExecutor` runs inside a dedicated process wrapping a Docker container configured with
the toolchain, SDK and system libraries, reset between builds. The container digest then
*is* the environment: `sdk=26.5 (25F70)` becomes `image=sha256:…`, and "did we miss an
input?" stops being a question only an audit can answer. Also the natural home for the
Remote Runner role (B-30).

**B-04** `open` — **Prevent non-deterministic Dictionary iteration.**
`allTargetsNamed` iterates `externalManifests` and picks whichever package the runtime
happens to yield first when two vend the same product name — against the AGENTS.md
invariant, and now on the transitive system-library path. Preferred approach, in order:
(a) take `[(String, Value)]` rather than `[String: Value]` in the few functions that produce
ordered output; (b) a test that builds the same project in two subprocesses and diffs the
results byte-for-byte, since hashing is seeded per process — this catches every order
dependence at once, and doubles as the determinism probe in B-11; (c) a source-scanning test
as a backstop. A wholesale `DeterministicDictionary` is judged high-cost and low-yield:
most dictionaries here are accumulated into, which is safe.

**B-05** `open` — **Environment-perturbation fuzzing for cache keys.**
Run a node twice varying something deliberately *not* in the key — `TMPDIR`, cwd, locale,
hostname, wall-clock. Any output difference means the key is under-specified. The systematic
version of how the SDK bug was found; belongs in the test suite, run once per node type.

**B-17** `open` — **`ToolDescriptor.recursiveHash` is designed but never populated.**
The slot exists on every tool descriptor and is read from
`properties["toolDescriptor.recursiveHash"]`, but nothing ever sets it, so it is always nil.
It is the intended place for a hash of the tool binary itself, which would close the
remaining gap after B-01: two different binaries reporting the same version string
currently share a cache key. Narrow, and B-03 subsumes it.

## Swift package conversion

**B-06** `open` — **Lock vendored dependencies by content hash.**
`ISSUE:` at `SwiftFormulaConverter.swift:183`. A `sourceControl` dependency resolves to a
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

Depends on B-26.

**B-07** `open` — **Registry dependencies are ignored.**
`TODO:` at `SwiftFormulaConverter.swift:189`. Neither resolved nor reported.

**B-08** `done` — **Unhelpful stall when a vendored package is missing.**
The converter reports `awaiting external packages: input:/…/GRDB.swift` without naming the
originating URL or saying that the package must be vendored there.

**B-09** `open` — **`.library(type: .automatic)` is always built dynamic.**
No static archive support; every library product becomes a `.dylib` by assumption rather
than by choice.

**B-10** `open` — **Publish only final products.**
`libSemelCore.dylib` and friends appear in `output:` though they are internal. A
product is an intermediate iff another discovered package consumes it — roots of the
dependency DAG are the deliverables. Nesting is *not* the right test: it misclassifies
`MyLibrary`, a sibling of `MyApp` consumed by it. Implementation is one boolean:
`SwiftFormulaConverter` already resolves its external package paths during its BFS, so it
can expose them; `ProjectFinder` unions them into an "is depended upon" set and sets
`publishProducts: false` on those `ProjectBuilder`s. Products still build and cache; they
just get no `OutputFile`.

**B-26** `open` — **Recursive content hash for a folder tree.**
`FolderManifestEntry` is `name`/`isFolder`/`isPinned` with no content hash, so a folder
manifest changes when names change but not when contents do. A Merkle root needs a derived
hash over the sorted `(name, contentHash)` pairs, folded up the tree. Wanted by B-06 for
locking a vendored dependency, and by the client/server design for making reconciliation
O(changed) rather than O(tree) — the same piece of work, worth building once.

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

**B-13** `open` — **Store key material alongside each entry.**
Today a mismatch says two builds disagreed and nothing about why. Recording node type,
`codeVersion`, properties, input wire keys and hashes, and `cacheKeyEnvironment` makes a
mismatch diffable and lets keys be recomputed offline.

**B-14** `open` — **No blob GC.**
Unreferenced objects accumulate in the object store with no collector. Not urgent.

**B-15** `open` — **Cache abstraction behind a client interface.**
Make the engine talk to the cache as though it were a separate server, without a socket or a
separate process yet. Groundwork for the Cache Server role (B-30) that can be exercised
entirely in-process.

## Performance

**B-16** `done` — **Folder manifest rebuilt a database query per child.**
Measured: pushing N files into one folder was O(N²) queries, because a manifest is rebuilt
on *every* child change and each rebuild asked every child for its pinned state
individually. Now one query per kind. 50/100/200 files went 0.30/0.99/3.39s → 0.14/0.34/0.84s,
and growth per doubling fell from ~3.4× to ~2.4×. Agreement with each type's own `isPinned`
is pinned by `test_manifestPinnedStateAgreesWithEachChildsOwn`. See B-18 for what remains.

**B-18** `done` — **Manifest rebuilds were dominated by two avoidable costs.**
Measured rather than assumed, and the assumption in this item's original text was wrong:
JSON encoding, hashing and storing the manifest are only 16% of a rebuild. The cost was
`buildManifest` itself — 84%. Within that, `pinnedStates` was 70%, from binding a folder's
200 children as an `IN` list; and fetching whole `Node`s decoded every child's properties
only to discard them. Fixed by projecting child summaries, joining on `parentNodeID`
instead of an `IN` list, and adding the missing index on `Node.parentNodeID` — which was
unindexed, so every tree walk in the system was a full table scan.

Pushing into one folder, cumulative across B-16 and B-18:

| files | original | after B-16 | after B-18 |
|-------|----------|-----------|-----------|
| 50    | 0.30s    | 0.14s     | 0.13s     |
| 100   | 0.99s    | 0.34s     | 0.28s     |
| 200   | 3.39s    | 0.84s     | 0.63s     |
| 400   | —        | —         | 1.58s     |

Still super-linear at ~2.3× per doubling. See B-25.

**B-25** `open` — **A folder manifest is still rebuilt on every child change.**
Each rebuild is O(children) and there are O(children) of them, so a single-folder push stays
quadratic no matter how cheap each rebuild gets — and it is 2 rebuilds per file, since both
`onChildAdded` and `onChildContentChanged` fire. The fix is to stop rebuilding per change:
mark the folder dirty and flush before the next processing pass. Deliberately not attempted
yet — manifest freshness is relied on between mutation and processing, so this is the one
change here that can actually break correctness rather than just speed.

**B-19** `open` — **`Folder.root(named:)` builds a graph shape on every call.**
`BUG:` at `Folder.swift` ("extremely slow. TODO cache"). Every `Folder.inputFileSystem` /
`outputFileSystem` does a `findOrCreateMatchingNode`, and those are called constantly. A
cache must key on the current `DatabaseLayer` identity, or it goes stale when the database
is swapped — which every test does. Not measured yet; measure before optimising.

**B-24** `open` — **`Folder.canBeDeleted` instantiates every child's node function.**
`TODO: slow` at `Folder.swift:63`. Same shape as B-16 but on the delete path.

**B-28** `done` — **Split the toolchains out of the engine.**
`SemelNodeKit` (the node-authoring API), `SemelSwift` and `SemelClang`, with the toolchain
packages depending on NodeKit and *not* on the engine — the absent arrow is what makes the
engine agnostic. Design and phasing in
`docs/superpowers/specs/2026-08-15-semel-package-split-design.md`.

Measured first: across all nine toolchain nodes there is exactly one reach into the graph
(`Folder.inputFileSystemName`), so the API needs no graph access and is smaller than it
looks. Two seams to open — `BuildEngine.registerTypes()` and `ProjectFinder`'s plugin array
— plus a kind-ID allocation rule, since existing IDs cannot be renumbered without orphaning
live databases.

**Step 1 done** (`b49e2b5`…`435fd5a`). SemelNodeKit exists and holds 13 files: the node
protocols, ProcessInput/Output, NodeValue, NodeDescriptor, NodeError, PolyFactory, Path,
DataObjectStore, DataToken, ToolExecutor, Toolchain, FileMetadata, GraphShapeArg and
FolderManifest. 63 tests; depends only on SemelDatabaseModels.

Two traps worth knowing before step 3. An `internal` overload becomes *invisible* rather
than ambiguous across modules, so `PolySerializable.toJSON` silently lost to
`Encodable.toJSON` and produced JSON with no `kind` — 51 runtime failures, no compile
error. And a stale build plan makes a dependency package's new or changed files invisible;
`rm -f <pkg>/.build/build.db <pkg>/.build/plan.json` when errors contradict a fix.

**Step 2 done.** `ProjectBuilderPlugin` and a `ProjectDiscovery` registry now live in
SemelNodeKit — not the engine — because a toolchain package must be able to contribute a
project kind without depending on the engine, which is the whole direction of the split.
`ProjectFinder` reads the registry instead of a hardcoded array. `registerTypes()` is split
into `registerEngineTypes()` and a `registerBuiltInToolchains()` whose existence measures
how far the split has got: it disappears when steps 3 and 4 land.

**Step 3 done.** SemelSwift holds the four Swift node types, SwiftToolSupport and
SwiftPackagePlugin, and depends on SemelNodeKit but *not* on the engine — which is now
provable: no Swift symbol appears anywhere in SemelCore's sources. `semel`'s
main.swift is the composition root and calls `SemelSwift.register()`.

Four more things turned out to be API rather than engine, each found by SemelSwift failing
to compile without them: the protocol's *default implementations* (invisible across a
module boundary, so every requirement came back as "does not conform"), the
`[String: String](plainText:)` configuration format, `asOutputNodeValue`, and
`FileSystemName` replacing the single `Folder.inputFileSystemName` reference.

SemelSwift has its own test harness — no database, no BuildEngine, no graph — which is the
evidence the seam is in the right place. `RecordingToolExecutor` is duplicated from the
engine's tests; a testing-support module for SemelNodeKit is the tidier answer once
SemelClang wants one too.

**Step 4 done.** SemelClang holds the three Clang nodes and IncludeFinder. It contributes
no project kind — a C project is described by a `.fmla` file, which the engine recognises
itself because a formula names no toolchain. `registerBuiltInToolchains()` is deleted: the
engine now registers only its own types and cannot name a toolchain at all.

Three of the engine's own test files had been reaching for `ClangCompilerTool` as a
convenient sample node. They now use `SampleTool`/`OtherSampleTool` from `SampleNodes.swift`,
which is what they should always have used — their subjects are the cache-key algorithm,
the type registry and unrecoverable-error handling, none of which has anything to do with C.
The golden cache-key value had to be re-recorded, since a node's type name is part of its
key.

**Step 5 done.** `BuildSystemCore` → `SemelCore`, `DatabaseModels` → `SemelDatabaseModels`,
`BuildSystemCLI` → `SemelCLI`, `BuildSystemTestCase` → `SemelCoreTestCase`. 80 files
rewritten.

Still carrying the old vocabulary, deliberately out of scope: the root package is named
`build_system` and the CLI's sources live in `build_system/`. Renaming those changes the
repository's own layout and the C1 test fixtures that reference those paths, which is a
wider blast radius than a module rename.

## Server

**B-30** `open` — **`semelserv` with three roles.**
One binary, three modes, sharing a wire protocol:
1. **Cache Server** — see `docs/superpowers/specs/2026-08-15-semel-cache-server-design.md`
2. **Remote Runner** — executes tool commands inside, or against, a container (B-03)
3. **Shared Build Server** — see
   `docs/superpowers/specs/2026-08-15-semel-client-server-design.md`
Role 3 is still wanted even with local building, because the point is a build that continues
in the background regardless of which CLIs are open — local CLI to local server. Write it as
if multiple users might share it, without the full auth apparatus for now.

**B-31** `done` — **Fix `ClangLinkerTool.asProcessOutput` port constants.**
Writes its values under `ClangPreprocessorTool.output` and `.infoLog` rather than its own.
Works only because all four constants are the same strings.

## Closed

**B-20** `done` — SDK is in the Swift tools' cache key (`e6ca4cd`).
**B-21** `done` — Object hashes verified on read (`7f59a92`).
**B-22** `done` — Vendored static archive linked into the product; `libsqlite3.dylib`
removed from the tree.
**B-23** `done` — `SwiftPackageReaderTool` no longer overrides HOME and TMPDIR back to the
real machine, closing the only hole in the executor's sandbox.
**B-27** `done` — Product created/deleted events are decided by path in ProjectBuilder
(`ProductPresence`), not by OutputFile node lifecycle. Node identity includes static wiring,
so an OutputFile is deleted and recreated whenever anything upstream changes; reporting from
there announced a deletion every time a file was merely rebuilt.

## Not doing

**B-40** `dropped` — Subtree-scoped `reset`. Moot: users no longer share one graph.
**B-41** `dropped` — Scoping or privilege for `debug`. Moot for the same reason.

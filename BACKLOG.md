# Backlog

Concrete open items. `FUTURE.md` is for direction; this is for what is broken or owed.

IDs are stable and never reused — reference them in commits (`closes B-07`) and in
discussion. Status is `open`, `doing`, `done` or `dropped`; done items stay for a while so
their reasoning is findable, then get pruned.

## Hermeticity and determinism

**B-30-SDK** `done` — **The SDK is configuration, not ambient machine state.**
`semel.config`, in the same `key=value` format the wire already carries. The file this item
introduced survives; how a node reaches it does not — B-42 replaced the resolution model
underneath it, so read that item for the mechanism and this one only for what it settled.

What it settled and what still holds: an SDK version is a setting written in a file, under a
`<domain>.<node>.<key>` namespace, not something read off whichever machine happens to be
building. `SwiftCompilerTool` and `SwiftLinkerTool` fail loudly when the machine's SDK is not
the declared one, mirroring what `ToolExecutorRegistry` does for a pinned tool version.
Declaring nothing keeps the previous behaviour.

What B-42 replaced: the ancestor walk that asked for a file in every parent folder, the
merge-by-depth and cross-tool inheritance that resolved it, and the per-tool
`acceptedSettings` lists that filtered it. A node now takes its settings through a
`ConfigSubset` selector naming one prefix in one file, and keys nobody selected are reported
from the graph on idle rather than from a converter's `infoLog`.

*Not settled:* the check compares the version string only, not the build (`26.5`, not
`26.5 (25F70)`), because a build number is unpleasant to write in a config by hand. Two
different builds of one SDK version are still indistinguishable.

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
Superseded in the long run by B-03, which replaces enumeration with one value.

*Correction, later:* `cacheKeyEnvironment` was the wrong instrument and has been removed. It
could stop a wrong cache *hit* but could never trigger the rebuild that produces a right
one, because an unscheduled node never recomputes its key. See B-29 and B-30-SDK.*

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

**B-29** `open` — **Invalidate everything when Semel or the schema changes.**
A cache key can prevent a *wrong reuse*; it cannot cause a *recomputation*. Nodes are
scheduled only on creation, on a wire change, on `nudge()` or after `reset` — so anything
that changes outputs without changing a wire leaves stale artifacts published indefinitely,
whatever the key says. Upgrading Semel is exactly that.

So the marker has to trigger, not merely compare: record schema version and Semel version at
launch, and `reset` on mismatch — which preserves the input file system and rebuilds
everything derived. FUTURE.md already proposes the schema half ("dump the SQL schema as a
blob of text on launch and compare"); the Semel version is a second field in the same marker.

Deliberately *not* a hash of the binary in the cache key. It would be automatic where
`codeVersion` is manual, and the discrimination is the point: hashing the binary means every
rebuild of Semel — including a comment change — invalidates every entry for every project,
so nobody developing Semel would ever see a cache hit. (Update: `codeVersion` was deleted, 
as this is not a reliable enough mechanism.)

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
mismatch diffable and lets keys be recomputed offline. (Update: `codeVersion` was deleted, 
as this is not a reliable enough mechanism.)

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
200 children as an `IN` list; and fetching whole `NodeRecord`s decoded every child's properties
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

*Since:* `GraphShapeArg` has gone back to SemelCore as `GraphShapeProperty`. It was moved
here because `InputlessNodeFunction.graphShapeArgs` named it in the protocol, so a node
function could not be declared without it; that requirement no longer exists, and NodeKit
now exports no GraphShape type at all.

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

**B-42** `done` — **How configuration works, across both toolchains.**
Design: `docs/superpowers/specs/2026-08-30-semel-configuration-design.md`.

*The shape.* Inheritance is dead in both dimensions — no ancestor walk, no cross-tool
defaults. A configuration is one file, copied and edited rather than composed; this tree
carries six byte-identical copies, one beside each `Package.swift`, because discovery builds
each package separately. Every key lives under a global `<domain>.<node>.<key>` namespace
designed so a single master config can hold everything without collision, with `<node>`
derived from the node type name and pinnable when a rename would otherwise break users.

A node reads configuration through a `ConfigSubset` selector that names a prefix and takes the
file on a wire — so identity is *which file and which slice*, and the values themselves are
never in a searchKey. That fixes the original defect (settings as identity, orphaning cache on
every edit) and gives SemelClang a route to configuration for the first time.

On the 10,000-compiler problem it delivers less than the design first claimed, and the
difference is worth keeping written down. Editing the file still reschedules everything
downstream: the write marks the whole subgraph pending before the selector reprocesses, so the
selector's own write is `pending → value` and the cascade does not stop. What holds still is
node identity, so the woken compilers are the same nodes and hit cache. 10,000 reschedules and
cache lookups remain; 10,000 recompiles do not.

It also dissolves `acceptedSettings` — the prefix in the graph is the accepted set — and
recovers typo reporting in a better form, by asking the graph which prefixes anyone selected
and reporting the keys nobody claimed on the engine's idle hook.

*Costs accepted knowingly:* `sdkVersion` written once per node that reads it, no per-target
overrides (which would be most-specific-wins and therefore inheritance again), and one config
file per package with nothing but copying to keep them in step.

*Also closed by this:* the hardcoded fallbacks at `ClangLinkerTool.swift`,
`SwiftCompilerTool.swift` and the `std` default in the two Clang source stages. There are no
default values anywhere: a missing setting fails naming the key to write, because a literal in
the binary silently changes what a previous build meant when Semel is upgraded.

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

*`OutputFile` — dissolvable, not formalisable.* It reads its own previous output port only to
decide whether to print a status change. The engine already computes exactly that:
`writeToOutputPort` returns false when the value is unchanged. Move change-notification to the
engine — which has to happen anyway when printing becomes structured logging aimed at showing
system *state* rather than a flowing event log — and the self-read has no reason to exist.

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

**B-44** `open` — **Naming: what the vocabulary calls things, and where it disagrees with
itself.**
From a survey of the type inventory and term counts. The counts come from that survey and are
not independently checked, except where noted; the judgements are worth arguing with.

The useful test turned out not to be "is this term coined?" — coining is cheap to learn once
— but **"does it disagree with itself, or does it mislead?"** That ranking puts the invented
names lower than expected and the inconsistent ones higher.

*Self-contradiction: one concept, two names.* No design question attached, so these are the
cheap ones.
- **`Wildcard` (47) vs `glob` (46)**, in the same files. Verified firsthand:
  `ProjectBuilder.globMatch` calls `WildcardSegment.matches`, a mismatch introduced by
  `bae6a37` while removing a different duplication. `glob` is the standard term and already
  has equal footing.
- **`DataToken` (7) vs `DataObjectHash` (52)** — `DataToken` is literally a typealias for
  `DataObjectHash`: the *less* descriptive name wrapping the more descriptive one. Neither is
  standard. This is a **digest** (Git calls it an OID, Nix a store hash), and "token" suggests
  lexing or opacity rather than content addressing.
- **The config vocabulary** — `Configuration` (a node type), `ConfigSubset` (another),
  `ConfigurationText`, `semel.config`, `NodeFunctionDescriptor`. Five words circling one area.
  B-42 settled the model and deleted `ConfigSettings` and `ToolSchema`, but it added
  `ConfigSubset` — named as a placeholder, and explicitly left to be renamed here.

*Misleading about mechanism.*
- **`NodeFunction`** overpromises. It is not a function: it is a stateful wrapper with
  lifecycle callbacks (`didCreate`, `canBeDeleted`, `onChildAdded`), and one of its methods
  happens to be a transform. The dataflow term is *operator*. Note `3a0d68e` already
  introduced "source" for the no-input case — half of the standard *source / operator / sink*
  triad — so `NodeOperator` would finish a vocabulary already started. (The weaker argument,
  that `process` is impure because it returns wiring requests, does not hold: returning
  expectations is exactly what keeps wiring declarative instead of a side effect. The real
  impurities are elsewhere, and are B-43's subject.)
  **Settled differently.** `NodeOperator` was rejected: *operator* renames the transform and
  drops the ports and lifecycle that are the type's actual substance. `NodeType`, `NodeKind`
  and `NodeDefinition` all mislead for a different reason — the type is instantiated once per
  node, not once per kind, so a name denoting a category is wrong. What the type is, is a node.
  So it takes the name outright and the row becomes `NodeRecord`: the thing with ports and a
  lifecycle *is* the node, and the row is a record of it. `StaticFile: Node` then needs no
  explanation, where `StaticFile: NodeFunction` needed a sentence.
- **`ToolExecutor`** collides with Swift's own `Executor`/`SerialExecutor` in a codebase that
  uses `TaskGroup`, so a reader may expect scheduling and isolation where it means "run a
  binary in a sandbox". **`ToolRunner`**, or Bazel's *spawn runner*. The concrete type is
  already `LocalFileSystemTool` and says nothing about executors, so the protocol is the odd
  one out.
- **`isPinned` (26)** — the sharpest catch. In memory management *pinned* means "cannot be
  moved". The meaning here is "held alive by user intent rather than by references", which in
  a system with a real collector is exactly a **GC root**. `isRooted` is both standard and
  more accurate.

*Coined but clear — leave alone.* `GraphShape` is defensible; its nearest standard analogue is
Nix's **derivation** (a canonical description of a step plus its transitive inputs, whose hash
is its identity). Worth noting it names two things, the tree (`GraphShapeNode`) and the
rendered string stored as `searchKey`, a split the code has and the names do not. `Formula`,
`Wire`, `Port`, `Node`, `intern()` and `ghost` are all fine; `intern()` is exactly its
standard meaning.

*One argument knocked down.* `Expectation` is the most-used coined term at 198 occurrences,
and the obvious objection is the XCTest collision — but `expectation(` appears zero times in
this repo, so that clash is theoretical rather than lived. Bazel's term for an action
discovering more inputs mid-execution is *discovered inputs*. At 198 uses and no live
collision this is the worst effort-to-benefit on the list.

*What to do.* A **glossary in `AGENTS.md`, not a rename sweep**: Semel term → nearest standard
equivalent → *how it differs*. The third column is the point, because a borrowed name imports
its home semantics — call a `NodeFunction` an "action" and a Bazel reader assumes hermeticity
and one-shot scheduling, neither of which holds here. False familiarity is worse than
unfamiliarity.

Then rename opportunistically, when already in the file. Cost data point: renaming
`GraphShapeArg` to `GraphShapeProperty` (`a8e28cb`) took a full compile-error sweep, two test
files and two doc updates. Seven of those for their own sake is a bad trade. The exceptions
worth doing deliberately are the ones with no design question behind them: the `Wildcard`/
`glob` split and the `DataToken` alias — and `nudge`, which is only 2 occurrences if it should
ever become `invalidate`.

*Done.* `Wildcard`/`glob` (kept `Wildcard`, eliminated `glob`), the `DataToken` alias
(deleted, file now `Interning.swift`), and the `Node` swap in two phases: `Node` →
`NodeRecord`, then `NodeFunction` → `Node` with `NodeFunctionDescriptor` → `NodeDescriptor`,
`nodeFunction()` → `makeNode()` and `NodeFunctions/` → `Nodes/`.

Cost data point, and the reason the two-phase split was right: the compiler verified every
type site and caught nothing that mattered, while the damage landed in prose and in compound
identifiers. Comments went wrong three distinct ways — concept read as type, SQL identifier
read as a Swift path, grammar notation read as a type reference — and a substring match
turned `fromNodeFunction` into `fromNode`, colliding with the record already named that. Only
the collision was a compile error; the rest needed reading. Assume any future rename here
costs a prose audit, not a sweep.

*Still open.* 45 locals still spell `nodeFunction` while holding a `Node`; renaming them to
`node` shadows the `NodeRecord` often named `node` in the same scope, which Swift accepts
silently. `ToolExecutor` → `ToolRunner` and `ConfigSubset` are untouched; `isPinned` is
deliberately kept.

**B-45** `open` — **Database write failures are not classified as unrecoverable.**
`UnrecoverableError.swift` used to claim they were; `db5fcb7` corrected the claim rather than
making it true. A full disk currently trips the object-store path first, so this is a gap
rather than a live bug — but a database write that fails for the same reason is still filed
as "node 47 failed".

Harder than it looks, and the reason is worth keeping: GRDB reports every failure as
`DatabaseError`, mixing `SQLITE_FULL` and `SQLITE_IOERR` (this class) with `SQLITE_BUSY`
(transient) and `SQLITE_CONSTRAINT` (a bug in the caller). Conformance to `UnrecoverableError`
is per *type*, so the enum cannot simply conform — the same constraint that forced
`SandboxCreationError` out of `LocalFileSystemToolError`.

Two ways out. Wrap writes at the `DatabaseLayer` boundary and translate result codes into a
narrow unrecoverable type, which keeps the protocol as it is. Or give the protocol a
per-instance hook — `var isUnrecoverable: Bool { true }` by default — so a type whose cases
disagree can answer for each one. The second is smaller and would have avoided the split
above; it also makes it easier to classify something fatal by accident, which the per-type
rule currently makes impossible.

Also note the two `try? saveCacheForAllInputsAndOutputs` call sites: defensible today, since
failing to save a cache entry should not fail a build, but they would swallow whatever this
item introduces.

**B-46** `open` — **Set up SwiftLint, or an equivalent.**
Moved from `FUTURE.md`, which is for direction; this is a bounded task sitting among open
design questions.

*The concrete case for it.* SwiftLint ships `contains_over_filter_is_empty`, which is exactly
the defect `9019d50` fixed by hand in `Folder.canBeDeleted`:

    try (thisNode.allChildren.filter { try !$0.nodeFunction().canBeDeleted() }).isEmpty

That built the whole array rather than stopping at the first objection, on a path the
collector walks per level of a tree. A linter would have said so before anyone thought to
look.

*The honest limit of the case.* Little else fixed recently would have been caught. The
redundant-`try` sweep in `ae8c618` was the compiler's doing, and "comments should not narrate
the project's history" (`eec8009`) is not mechanically checkable. Expect a linter to catch a
class of small waste, not the things that took a conversation.

*The actual work is choosing the rule set, not installing it.* SwiftLint's default rules on a
codebase this size will produce a very long first run, and a wall of warnings nobody triages
is worse than none — it trains people to ignore the tool, and it buries the one finding that
matters. So the decision to make first is which rules are on:

- Rules that would have caught real defects here — `contains_over_filter_is_empty`,
  `empty_count`, `first_where`, `last_where` — are the reason to do this at all.
- Purely stylistic rules (line length, brace placement, trailing whitespace) need a separate
  decision, because they will produce the bulk of the noise and none of the value. Whatever is
  chosen has to match what is already written rather than reformat it.
- `force_unwrapping` and `force_try` deserve their own thought. They are common in this
  codebase and often deliberate — `insertOrGetID` force-unwraps a `SELECT` that cannot miss,
  and `thisNode.properties["path"]!` is load-bearing in the file-system types. Turning that
  rule on means either a large exemption list or a large argument.

*Also worth settling:* whether it runs in CI as a failure or a report, and whether formatting
is in scope at all — `swift-format` is a different tool with a different answer, and adopting
both is how a repo ends up with two opinions about the same line.

**B-47** `open` — **The SDK is declared but not an input.**
From a TODO at `SwiftCompilerTool.swift:169`, whose specific ask B-30-SDK already answered:
the setting does now live in a `semel.config` inside the input file system. What it was
pointing at does not.

`swift.sdkVersion` is *checked*, not *used*. `verifySDKVersion` compares the declared string
against what `xcrun` reports and fails loudly on a mismatch, which catches the wrong machine
but does not make the SDK an input. The path handed to `-sdk` still comes from
`resolveSDKPath()`, an `xcrun` call resolved once per process, and the thousands of headers
and stubs behind that path are never hashed, wired or named. Two machines with the same
version string and different SDK contents produce identical cache keys and different
artifacts, silently.

So the invariant the TODO stated — every node input must exist inside the input file system or
be derived from it — is still not true of the largest input a compile has. Worth stating
somewhere as an invariant, since nothing in `AGENTS.md` currently does; that omission is
probably why it took a TODO to notice.

*Why this is not simply "hash the SDK".* A macOS SDK is on the order of a gigabyte across tens
of thousands of files. Hashing it per build is not free, and putting it in the input file
system as ordinary `StaticFile` nodes would put a graph node per header into the database.
B-03 is the intended answer — a container digest stands in for the whole environment, and
`sdk=26.5` becomes `image=sha256:…` — which makes this an argument for B-03 rather than an
independent piece of work.

*Narrower thing worth doing sooner:* the declared version is compared as a version string only
(`26.5`, not `26.5 (25F70)`), so two builds of one SDK version are indistinguishable — already
noted as unsettled under B-30-SDK. Including the build identifier costs nothing and closes the
gap that a check can close.

**B-48** `open` — **`clang.*.std` is one key for a whole package, whatever language a file is.**
`ClangCompilerToolConfiguration.std` is a single value fed from one `clang.compiler.std` key, and
every `ClangCompilerTool` node in a package selects the same prefix — so there is no way to say
`c17` for the `.c` files and `c++20` for the `.cpp` ones. It is applied only when the file
classifies as C++ (`ClangPreprocessorTool.language(for:)`), which is why a mixed project builds at
all rather than failing on `-std=c++20` against a `.c` file.

That is also why `std` is required *for C++ compilation* rather than unconditionally, which is the
one place `40e...` departs from "every setting is required". The departure is sound — requiring it
unconditionally would make a mixed C/C++ project unbuildable — but the underlying shape is wrong:
a language standard belongs per language, not per package.

*Worth knowing:* the reproducibility argument is not weaker for C. Clang's default C standard has
moved across releases (gnu99, gnu11, gnu17), so an unspecified C standard carries the same hazard
as an unspecified C++ one. Both are mitigated only by the pinned `toolDescriptor.version`.

Approach: separate keys — `clang.compiler.cStandard` and `clang.compiler.cxxStandard` — each
required when a file of that language is compiled. Also worth revisiting `language(for:)`, which
misclassifies `.C` (uppercase, conventionally C++) and `.mm`.

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

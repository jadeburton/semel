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

**B-04** `open` — **Prevent non-deterministic Dictionary iteration.**
The known instance is fixed: `SwiftFormulaConverter.generateFormula` walked
`externalManifests` in dictionary order, so two vendored packages vending the same product
or target name resolved differently per process (reproduced at 5 failures in 12 runs); it
now walks them sorted by folder, lexically first wins. What remains is the safety net, in
order: (b) a test that builds the same project in two subprocesses and diffs the results
byte-for-byte, since hashing is seeded per process — this catches every order dependence
at once, and doubles as the determinism probe in B-11; (c) a source-scanning test as a
backstop. A wholesale `DeterministicDictionary` is judged high-cost and low-yield: most
dictionaries here are accumulated into, which is safe. Two sites worth a look under (c):
`ClangPreprocessor` and `ClangIncludeFinder` build file lists straight from input
dictionaries; harmless if the lists only feed sandbox materialisation, not if they reach a
command line.

**B-05** `open` — **Environment-perturbation fuzzing for cache keys.**
Run a node twice varying something deliberately *not* in the key — `TMPDIR`, cwd, locale,
hostname, wall-clock. Any output difference means the key is under-specified. The systematic
version of how the SDK bug was found; belongs in the test suite, run once per node type.

**B-17** `open` — **`ToolDescriptor.recursiveHash` is designed but never populated.**
The slot exists on every tool descriptor and is read from
`properties["toolDescriptor.recursiveHash"]`, but nothing ever sets it, so it is always nil.
It is the intended place for a hash of the tool binary itself, which would close the last
gap in the cache-key audit: two different binaries reporting the same version string
currently share a cache key. Narrow, and B-03 subsumes it.

**B-49** `open` — **Tool outputs must not depend on where the inputs are mounted.**
Compilers embed the invocation path in what they produce — DWARF debug info, `__FILE__`
expansions, the output filename derived from the source path, diagnostics on the log ports.
That is why the cache deliberately keys on wire *names* as well as values (`Cache.swift`:
content-only keys once returned another file's build), and it is what blocks cache reuse
across machines on the shared cache server (FUTURE.md "Settled direction", the 2026-08-15
cache-server spec): every developer mounts the same tree at a different checkout path, so
identical trees produce byte-different artifacts and can never share an entry. The same
applies within one machine to two branches of one project. This is the prerequisite for
the cache server being useful at all, not an optimisation on top of it.

The distinction that preserves the old lesson: the *project-relative* path is a real input
(module names, includes, output filenames) and stays everywhere; only the *mount prefix* is
noise and must go. Three parts, in order:
1. **Canonical sandbox layout.** Materialise inputs in the per-run sandbox at a fixed root
   rather than under the full `input:` path, so the mount prefix never reaches the tool's
   command line. Needs a survey of how `LocalFileSystemTool` lays paths out today.
2. **Prefix maps for what still leaks**: `-ffile-prefix-map`/`-fdebug-prefix-map` (clang),
   `-debug-prefix-map` (swiftc), mapping the sandbox root to a stable name.
3. **Mount-independent cache keys.** Strip the mount prefix from wire names in
   `buildCacheKeyPartFromOneInput`, keeping the project-relative remainder. Open design
   question: where a node learns its project root — likely the same channel as
   `outputFolder`.
Verification is a B-05-shaped test: build one tree at two mounts, require byte-identical
artifacts and equal cache keys. Do 1–2 before 3 — mount-independent keys with
mount-dependent outputs is exactly the wrong-hit bug reintroduced.

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

**B-10** `open` — **Publish only final products: packages are referenced from a formula,
not discovered.**
`libSemelCore.dylib` and friends appear in `output:` though they are internal. A product
is an intermediate iff something consumes it — roots of the DAG are the deliverables, and
nesting is *not* the test (it misclassifies `MyLibrary`, a sibling of `MyApp` consumed by
it). The root set is a fact about intent, so the user states it rather than the engine
inferring it.

Plan, agreed 2026-09-12, replacing the inferred-roots plan:
1. **Stop auto-discovering `Package.swift`.** `SwiftPackagePlugin` no longer answers
   `ProjectFinder`; only `.fmla` files create a `ProjectBuilder`. Dependency packages then
   have no builder of their own, so no separate artifacts, no `publishProducts` property,
   no publish-then-retract flap, and no ordering against B-50. Their targets still compile
   exactly as now — the consumer's formula names the same compiler specs and graphSpec
   matching shares the nodes.
2. **A formula references a package.** Grammar gains a `package <path>` reference to a
   `Package.swift`. `ProjectBuilder` resolves it by wiring a `SwiftFormulaConverter`
   spec on a new dynamic port keyed by package folder and returning pending until
   the converter's formula arrives — the same spec-and-wait pattern the converter
   uses for external manifests. The converter already emits one formula for the root and
   every dependency it can reach, so this is splicing, not new generation. The formula's
   own `product` definitions name that package's products.
3. **Dependency overrides live in the formula.** The converter skips dependencies resolving
   outside `input:` and stalls on missing local ones, and its own stall text admits the
   user cannot fix that from `Package.swift`. The formula is where a repository URL maps to
   a pushed path — SPM keeps the same fact out of band, in `Package.resolved` and mirrors.
   This is needed regardless of the artifact question and is why the formula must exist
   for package builds anyway.
4. **Products go beside the formula**, always. Delete the "inside the package folder"
   special case in `SwiftPackagePlugin` and its `ProjectBuilderTests` case. Settings follow
   the rule already in the converter's comments — the consumer owns the config — so the
   formula's folder does.
5. **Discoverability.** `ProjectFinder` still sees every manifest; report at idle any
   `Package.swift` that no formula references, so a pushed repo with no formula explains
   itself instead of building nothing silently.

Namespacing is the one design question to settle before step 2: two packages referenced
from one formula can define funcs of the same name, which one-formula-per-root avoids
today. Either restrict a formula to one `package` reference (the "master package" that
references the rest) or prefix imported names. Start with the restriction; it covers the
known cases and can be lifted later.

Granularity is per package, not per product: a dependency that also vends an executable
loses it. Acceptable until a real case shows up.

Previous plan, declined 2026-09-12: infer roots from converter-published dependency lists
unioned in `ProjectFinder`, flip a `publishProducts` property to replace the builder node,
and rely on B-50's settle diff to hide the flap. It worked, but it added a port, a plugin
protocol parameter, a property and an ordering constraint to approximate what one line of
formula states directly.

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
mismatch diffable and lets keys be recomputed offline. (Update: `codeVersion` was deleted, 
as this is not a reliable enough mechanism.)

**B-14** `open` — **No blob GC.**
Unreferenced objects accumulate in the object store with no collector. Not urgent.

**B-15** `open` — **Cache abstraction behind a client interface.**
Make the engine talk to the cache as though it were a separate server, without a socket or a
separate process yet. Groundwork for the Cache Server role (B-30) that can be exercised
entirely in-process.

## Performance

**B-25** `open` — **A folder manifest is still rebuilt on every child change.**
Each rebuild is O(children) and there are O(children) of them, so a single-folder push stays
quadratic no matter how cheap each rebuild gets — and it is 2 rebuilds per file, since both
`onChildAdded` and `onChildContentChanged` fire. The fix is to stop rebuilding per change:
mark the folder dirty and flush before the next processing pass. Deliberately not attempted
yet — manifest freshness is relied on between mutation and processing, so this is the one
change here that can actually break correctness rather than just speed.

**B-19** `open` — **`Folder.root(named:)` builds a graph spec on every call.**
`BUG:` at `Folder.swift` ("extremely slow. TODO cache"). Every `Folder.inputFileSystem` /
`outputFileSystem` does a `findOrCreateMatchingNode`, and those are called constantly. A
cache must key on the current `DatabaseLayer` identity, or it goes stale when the database
is swapped — which every test does. Not measured yet; measure before optimising.

**B-24** `open` — **`Folder.canBeDeleted` still instantiates one node per subfolder level.**
Mostly addressed: `everyChildCanBeDeleted` now reads pinned state per kind in one query and
stops at the first objection, so leaf children cost no instantiation at all. What remains is
the recursion — each unpinned subfolder is built as a `Folder` to descend into it, so a deep
tree still pays one node per level. Small next to what it replaced; possibly not worth
fixing. Verify against a deep tree before spending anything here.

## Server

**B-30** `open` — **`semelserv` with three roles.**
One binary, three modes, sharing a wire protocol:
1. **Cache Server** — see `docs/superpowers/specs/2026-08-15-semel-cache-server-design.md`.
   This is the multi-user story (FUTURE.md "Settled direction"): every developer's local
   engine reads and writes it, behind the existing local cache as the near tier.
2. **Remote Runner** — executes tool commands inside, or against, a container (B-03)
3. **Local Build Daemon** — the surviving part of
   `docs/superpowers/specs/2026-08-15-semel-client-server-design.md`. Wanted even with
   local building, because the point is a build that continues in the background regardless
   of which CLIs are open — local CLI to local daemon, one user, one graph. Do not write it
   for multiple users: that is the shared-build-server model the cache server superseded,
   and it is where the path authorisation and sync machinery came from. The artifact events
   CLIs subscribe to are B-50's settle diffs.

## Design, correctness and code quality

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
B-50 is exactly that move; this case needs no work of its own.

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
From a TODO at `SwiftCompiler.swift:169`, whose specific ask is already answered — the
setting does now live in a `semel.config` inside the input file system. What it was pointing
at does not.

`swift.sdkVersion` is *checked*, not *used*. `verifySDKVersion` compares the declared string
against what `xcrun` reports and fails loudly on a mismatch, which catches the wrong machine
but does not make the SDK an input. The path handed to `-sdk` still comes from
`resolveSDKPath()`, an `xcrun` call resolved once per process, and the thousands of headers
and stubs behind that path are never hashed, wired or named. Two machines with the same
declared SDK and different SDK contents produce identical cache keys and different
artifacts, silently.

So the invariant the TODO stated — every node input must exist inside the input file system or
be derived from it — is still not true of the largest input a compile has. Worth stating
somewhere as an invariant, since nothing in `AGENTS.md` currently does; that omission is
probably why it took a TODO to notice.

*Why this is not simply "hash the SDK".* A macOS SDK is on the order of a gigabyte across tens
of thousands of files. Hashing it per build is not free, and putting it in the input file
system as ordinary `StaticFile` nodes would put a graph node per header into the database.
B-03 is the intended answer — a container digest stands in for the whole environment, and
`sdk=26.5 (25F70)` becomes `image=sha256:…` — which makes this an argument for B-03 rather
than an independent piece of work.

Done (2026-09-12), the narrow half: the declared value is the version *and* the SDK build
number, `26.5 (25F70)`, as `xcrun --show-sdk-version` and `--show-sdk-build-version` report
them, so two builds of one SDK version no longer pass the same check. A bare version fails
with the full string to paste. What is left is the wide half above.

**B-48** `open` — **`clang.*.std` is one key for a whole package, whatever language a file is.**
`ClangCompilerConfiguration.std` is a single value fed from one `clang.compiler.std` key, and
every `ClangCompiler` node in a package selects the same prefix — so there is no way to say
`c17` for the `.c` files and `c++20` for the `.cpp` ones. It is applied only when the file
classifies as C++ (`ClangPreprocessor.language(for:)`), which is why a mixed project builds at
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

**B-50** `open` — **Report artifact changes at idle, as the difference between settles.**
The system is functional, so the internal steps are hidden and the user-visible story of a
push is: *the graph settled; these artifacts appeared, changed, disappeared*. Today the only
artifact report is `OutputFile` printing its own status transitions mid-flight — it reads
its previous output port to decide whether to print (the self-read B-43 wants dissolved),
reports intermediate mutations a functional system should hide, and formats differently
from the error report.

Semantics: only the diff between the last settle and this one. An artifact that went
`value → pending → same value` reports nothing. Appeared / content-changed / disappeared
only; error states stay with the existing idle error report.

Trigger — global idle, the same settle that drives `reportIdleTimeErrors`. Each engine is
single-user (FUTURE.md "Settled direction": local engines, shared cache), so the graph
does go quiet after a push and the settle is the natural report boundary. A per-subtree
quiescence trigger (reachability tags on the cascade, per-partition in-flight counters)
was designed on 2026-09-09 for a shared graph that never idles; that graph is superseded
and the design is not needed. Keep the reporter taking a path prefix anyway — it costs
nothing and keeps a subtree report possible for a local daemon serving several
worktrees — but do not build a second quiescence signal.

Mechanism — designed for thousands of artifacts, never O(all) on the steady path:
- An `ArtifactSnapshot` table (path, last-reported content hash) in the *same* database as
  the graph, deliberately: a client told "appeared" must find the artifact, so the report
  and the state it describes commit together. This is the durable "last conceptual
  snapshot".
- Candidates at settle come from the write path: a small locked in-memory set of touched
  `OutputFile` paths. Touched is not changed — `writePendingToAllOutputsOfNode` means every
  woken node touches — so each candidate is compared against its snapshot hash, which is
  what makes an identical rebuild silent. The first settle after launch reconciles the
  whole table once, since a restart loses the set.
- Disappeared is captured where `OutputFile` nodes die (`processPendingDeletions`); no row
  survives to be compared, so it is the one genuinely event-shaped case.
- Output goes through one reporter closure (test-capturable, like
  `unclaimedConfigKeyReporter`). `OutputFile.process` stops printing entirely, which
  dissolves the third B-43 case and closes the old two-formats complaint for artifacts the
  way `ErrorReport` closed it for errors.

Deliberately not built yet, but shaped for it: these settle diffs are the events `semelserv`
(B-30 role 3, the local daemon) will stream to subscribed CLIs — `(generation, path, kind,
hash)` with a retention window, full resync from the snapshot table for a client beyond the
window. A subscription is a path prefix, so a CLI opened in one worktree sees only that
worktree's artifacts.

Presentation at scale is the one open question: a cold build of a 10,000-file project
produces 10,000 appearances, and 10,000 lines is not a report. Decide list-vs-summarise and
the threshold when wiring the terminal reporter; the mechanism is indifferent to it.

## Not doing

**B-40** `dropped` — Subtree-scoped `reset`. Moot: users no longer share one graph.
**B-41** `dropped` — Scoping or privilege for `debug`. Moot for the same reason.

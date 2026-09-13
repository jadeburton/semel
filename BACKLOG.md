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

**B-10** `open` — **Packages are named by a formula, not discovered — two residuals.**
Done 2026-09-12: `Package.swift` creates no builder; a `.fmla` says
`include SwiftFormulaConverter(path: <.>).formula` — `include` merges the formula text any
node produces, and knows nothing about packages; the converter wires its own reader from
the path — only the formula's products are published and they land beside the formula,
included names may not clash with the formula's own, and every node of the build reads its
settings from the config beside the named package — so this tree keeps one `semel.config`,
not six. What remains:

1. **Dependency overrides in the formula.** The converter resolves a git dependency to
   `<root>/Dependencies/<name>` (the `semel-vendor` rule) and stalls when nothing is there;
   a formula cannot yet say "this URL is at that path". Needed the day a dependency has to
   come from somewhere the rule does not reach.
2. **Discoverability.** A pushed `Package.swift` that no formula names now builds nothing,
   silently. `ProjectFinder` sees every manifest and could report at idle the ones no
   builder's `includes` port reaches.

Granularity is per package, not per product: a dependency that also vends an executable
loses it. Acceptable until a real case shows up. The inferred-roots plan (converter
dependency lists unioned in `ProjectFinder`, a `publishProducts` property, B-50 hiding the
flap) was declined the same day: a port, a protocol parameter, a property and an ordering
constraint to approximate what one line of formula states.

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

**B-53** `open` — **`rm` of a large folder is still quadratic.**
B-25 made a push mark the folder dirty and rebuild its manifest once (3000 files: 45 s to
5 s), but `onChildDeleted` still rebuilds at once, because the folder's self-delete check
follows it — so a large `rm` rebuilds the parent manifest per deleted child, the way push
used to. Same fix shape if it ever matters: mark dirty, and move the self-delete check to
the flush.

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
   `docs/superpowers/specs/2026-08-15-semel-client-server-design.md`. Designed in
   `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md`; phase 1 of
   three (the `SemelProtocol` package) is built. Wanted even with
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

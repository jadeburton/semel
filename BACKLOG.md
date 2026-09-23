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

**B-100** `open` — **What the dictionary-order scan does not see.**
`DictionaryOrderTests` gates every `for … in <dictionary>`, `keys`/`values` walk and
two-binding closure over a dictionary in the scanned sources against an allowlist with a
reason per site. Outside its sight: `Array(someSet)` and any other set-to-sequence
conversion, which has the same per-process seed problem; a subject sorted two or more
lines away from its walk (the scan consults the adjacent line only), and the converse, an
adjacent `.sorted` that sorts some other receiver, which the scan takes as covering the
walk; and a dictionary passed to a function that walks it elsewhere. Also found by the audit and left alone:
`ClangIncludeFinder` appends each source's include list to its output with no separator,
so two sources on one port would run their last and first paths together — unreachable
through the generated spec, which gives every finder one source, but a hand-written
formula could reach it. To do: extend the scan to set conversions, or decide they are
covered by the two-process end-to-end diff and say so here; put a separator (or a
per-source structure) in the finder's output and a test with two sources on one port.

**B-05** `open` — **Environment-perturbation fuzzing for cache keys.**
Run a node twice varying something deliberately *not* in the key — `TMPDIR`, cwd, locale,
hostname, wall-clock. Any output difference means the key is under-specified. The systematic
version of how the SDK bug was found; belongs in the test suite, run once per node type.
Its home is `EndToEndRun`: an extra cold build with a perturbed environment, and the same
`TreeDiff` against the first.

**B-17** `open` — **`ToolDescriptor.recursiveHash` is designed but never populated.**
The slot exists on every tool descriptor and is read from
`properties["toolDescriptor.recursiveHash"]`, but nothing ever sets it, so it is always nil.
It is the intended place for a hash of the tool binary itself, which would close the last
gap in the cache-key audit: two different binaries reporting the same version string
currently share a cache key. Narrow, and B-03 subsumes it.

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
   `<root>/Dependencies/<name>` (the `semel-swift` rule) and stalls when nothing is there;
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

**B-81** `open` — **`build` reports what it published, not what it did.**
A cache hit and a full recompute print byte-identical output at the prompt — the same three
lines whether every node ran `processWithCatch` or every node used the cache — and that
distinction lives only in `semelserv`'s stdout, which a release build compiles out.
`BuildEngine.processSomeNodes` already counts scheduled and computed per batch and
`Cache.loadCachedOutputs` already knows a hit from a miss; carry those totals to the client
over the protocol as a one-line settle summary (e.g. `12 nodes scheduled, 3 computed, 9 from
cache, 0 errors`) instead of printing them through `Debug.log`. `docs/tutorial/first-node.md`
Part 2 reads the server's debug log for exactly this reason and should be rewritten around
the summary once it exists.

## Performance

**B-53** `open` — **`rm` of a large folder is still quadratic.**
B-25 made a push mark the folder dirty and rebuild its manifest once (3000 files: 45 s to
5 s), but `onChildDeleted` still rebuilds at once, because the folder's self-delete check
follows it — so a large `rm` rebuilds the parent manifest per deleted child, the way push
used to. Same fix shape if it ever matters: mark dirty, and move the self-delete check to
the flush. Also: `rm` opens no batch the way `push` does (`FilePlugin.handleRemove` versus
`handlePush`), so the engine drains repeatedly while the walk is still unpinning.

**B-74** `open` — **Nothing tests a large `rm`, and four things go wrong in one.**
Removing a prepared IceCubesApp from the input file system (2026-09-20) showed: the folder
and the products under `output:` listed as `[missing]` until settle, `debug` failing on a
graph of a few hundred nodes, and a wall of errors during the cascade. Nothing in the
suites exercises `rm` through the CLI, the largest deletion test removes a folder of two
files, and the end-to-end harness never removes anything after a build. Two tests are
owed, and they are the acceptance for the fixes:

1. A `SemelCore` scale test beside `FolderManifestRebuildTests`: push a few thousand files,
   `rm` the folder, assert the cost grows linearly and the folder node is gone after the
   collector runs. B-53's verification.
2. A `SemelEndToEndTests` step, or a `SemelCLITests` case over `InProcessConnection`: after
   a build, `rm` the build folder, `wait`, then `ls input:` and `ls output:` show nothing
   under it, no `[missing]` entry, and the idle error report is empty.

What the reproduction (C fixture grown to 1,019 nodes) found, for whoever writes them:
`[missing]` means only "exists and not pinned" (`InternalFileSystemLister.swift:38`), and an
`OutputFile` reads pinned from its *input* port, so an artifact whose input errored shows
the same word; both are collected at settle. `debug`'s dependency tree keeps its visited set
per node and so enumerates paths (one shared `StaticFile` visited 999 times), and the text
rides in the frame JSON under the 1 MiB cap, so past about 600 nodes the server refuses the
frame and the client sees a closed connection. Deleting one shared header produced 500
error entries at idle, 494 of them the identical unlabelled `ClangCompiler … inputValueInError`,
because only `.pending` blocks processing and errors propagate through every consumer;
deleting the whole project produced none, since everything was collected. The fixes are
separate items: the `debug` tree (B-94), the idle error report collapsing a cascade to its
cause, `[missing]` split into its states, the missing batch around `rm` (B-53), and
`ProjectBuilder`'s mid-flight printer (B-50).

**B-94** `open` — **`debug` on a few hundred nodes burns a minute of one core, then closes the connection.**
`d` against a prepared IceCubesApp graph runs `semelserv` at 100 % of one core for about a
minute and ends with `The operation couldn't be completed. (SemelCLI.ConnectionError error
2.)`, which is `ConnectionError.closed`: the server refused the reply frame. Two causes, both
recorded under B-74's reproduction: the dependency tree keeps its visited set per node, so a
`StaticFile` shared by a thousand consumers is visited a thousand times and the walk
enumerates paths rather than nodes; and the rendered text rides inside the frame JSON under
the 1 MiB cap, so past about 600 nodes the frame is rejected and the client sees a closed
socket. The single busy core is not a missing parallelism: the walk is exponential in the
sharing, and a global visited set makes it linear, after which one core is plenty. Fix: one
visited set for the whole walk, the text streamed as the frame body rather than embedded in
its JSON (or paged), and a client message for a refused frame that says what was too large
instead of "error 2". Acceptance: `debug` on the 1,019-node C fixture from B-74 returns in
well under a second.

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
   `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md` and built: the
   `SemelProtocol` package, the in-process split behind `RequestHandler` and
   `InProcessConnection`, and `semelserv` plus `SocketConnection`. Wanted even with
   local building, because the point is a build that continues in the background regardless
   of which CLIs are open — local CLI to local daemon, one user, one graph. Do not write it
   for multiple users: that is the shared-build-server model the cache server superseded,
   and it is where the path authorisation and sync machinery came from. The artifact events
   CLIs subscribe to are B-50's settle diffs. What remains of B-30 is roles 1 and 2.

**B-73** `open` — **A crashed or Ctrl-C'd client orphans its `semelserv`.**
The end-to-end harness stops every server it starts with SIGTERM, but only on the paths it
controls; a `semel` test process that crashes or is killed does not reach its own cleanup
and leaves the `semelserv` it started running. Two shapes fix it: put the server in the
client's process group, so a signal delivered to the group reaches both; or have `semelserv`
exit when its socket file disappears, which also covers a user who deletes the socket by
hand.

## Command line

What a user sees at the prompt. Found by using `semel` on IceCubesApp and the C fixture
(2026-09-23); the engine-side items these lean on are B-50 (artifact diff at idle) and B-81
(settle summary).

**B-95** `open` — **Nothing tells the user when the build is done and the artifacts are there.**
After `push` or `build` the prompt returns at once and the graph settles in the background;
the only way to know when to `cp` or `export` is to poll `errors` or `ls output:`, or to run
`wait`, which blocks with no indication of progress. Wanted: a live indicator redrawn in
place rather than scrolled, in two sizes. Minimal: one line with the number of pending
nodes, which may rise while the cascade is still generating work, and a final line when the
graph settles. Maximal: the active nodes listed, a dashboard. The data is already counted —
`BuildEngine.processSomeNodes` knows scheduled and computed per batch — so the work is a
protocol message carrying the counts on each batch and a terminal renderer; B-30 role 3's
subscription is the transport it grows into. Open, and to decide before building: whether
the indicator is opt-in or opt-out, and how the user keeps typing commands while it redraws
(a status line above the prompt, as `ninja` and `cargo` do, versus a mode entered with a
verb and left with a key).

**B-96** `open` — **`rm` says nothing about what it removed.**
`FilePlugin.handleRemove` prints only when the wildcard matched nothing; on any match it is
silent, so `rm *.*` in a folder of packages looks like a no-op when it removed the dotted
files and left the folders — `*` matches within one segment and `*.*` needs a literal dot,
as in a shell, so that outcome is correct and unannounced. The server already returns the
removed paths (`RequestHandler+Files.remove`). Print them, or a count with the folders
named; and when a pattern matched files but no folder, say so. `push` has the same silence
on success (`handlePush` prints only its errors) and takes the same fix.

**B-97** `open` — **A node's error message is shown in its debug form, with `\n` and quotes.**
A missing configuration prints as
`other(message: "Missing configuration. Add these to a semel.config …:\n\nclang.linker.target=…\n…")`,
one line, escaped newlines, the whole thing in quotes, and the user cannot paste it. Cause:
`Node.swift` interns a thrown error as `"\(error)"` (lines 239 and 399), and `NodeError` is
not `CustomStringConvertible`, so `.other(message:)` renders as its case description. The
client's `ErrorRecordRenderer` already prints a multi-line message as an indented block;
it never gets the chance. Fix: give `NodeError` a `description` that is the message for
`.other` and a sentence for each other case, and intern that. Then the configuration message
itself: the `=…` are the template's placeholders, not truncation, and `tools clang.linker`
prints the four `toolDescriptor.*` keys with the installed tool's real values as a
paste-ready block (`ToolNamespaceRenderer`), so the message should name that command for
those and list placeholders only for the keys that need the user's choice, `target` among
them.

**B-98** `open` — **A tool's own error is repeated without the setting that caused it.**
`ClangPreprocessor` failing with clang's `error: unknown target triple '…'` shows the user
clang's line and nothing else. The node knows which setting produced the flag
(`clang.preprocessor.target` → `-target`), where the value came from (which `semel.config`,
or prepare's template), and what values the installed toolchain accepts (`tools clang`
lists them). A tool failure whose stderr names an argument the node built from a setting
should say so: the key, the value, the file it was read from, and the command that lists
valid values. Applies to every tool node; start with `-target`/`-sdk`, the two a new user
gets wrong.

**B-99** `open` — **The CLI marks failure with ❌ and success with nothing.**
`ErrorRecordRenderer` opens every error with ❌; no positive event has a mark, so a screen
of output reads as all bad news or none. Use emoji judiciously and consistently: one for an
artifact appearing (B-50's reporter), one for a settle with no errors (B-81's summary), one
for a cache hit if the summary distinguishes it, and nothing else. Pin the set in the
renderer tests the way the ❌ format is pinned, so it cannot drift per command.

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

**B-61** `open` — **`wait` across connections.**
Two things a socket server must settle before `wait` is offered to more than one client: a
`wait` can block indefinitely while another session holds a batch open, since a batched
work signal is counted but not sent until `endBatch` (fails safe, never a false settle;
the limit is pinned by `test_waitBlocksWhileAnotherSessionHoldsABatchOpen`); and
`waitUntilIdleBlocking` parks the caller's thread, so a listener must not call the handler
from a cooperative-pool thread.

**B-84** `open` — **A root `swift build` keeps a stale plan across path-dependency source
changes.**
Adding or removing a source file in any of the path-dependency packages (`SemelNodeKit`,
`SemelSwift`, `SemelCore`, …) is invisible to a root `swift build` until `.build/debug.yaml`
is deleted:
SwiftPM does not re-plan, so adding a file gives "cannot find X in scope" against the
registration rather than the plan, and removing one gives "couldn't build … because of
missing inputs: <the file just deleted>" while leaving the previous binary linked with the
type it no longer has. `AGENTS.md`'s "Build and test" now carries the symptom and the fix
(`rm .build/debug.yaml`); this item is about whether SwiftPM or Semel's own build wrapping
can do better than a documented workaround.

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

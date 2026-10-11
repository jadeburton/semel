# Semel R1

## Planning and strategy

- Convert to client-server architecture and daemon

- Central cache server 

- Get it working with large swift package that has complicated dependencies and targets

  Done (2026-09-13): IceCubesApp's thirteen packages — five consumption roots, thirteen
  external packages including swift-cmark's C targets — build for the iOS simulator under
  one formula (`C1/icecubes/Packages/semel.fmla`): 1,886 files pushed in 8 s, a cold build
  of 271 cache entries in about 4.5 minutes wall clock for 25 minutes of tool time, five
  archives, no errors. Nodes are shared across the roots: 26 Swift compiler nodes for 26
  targets. What it took is in the commits from 5ffd0af to c31917e.

  The loop closed the same day (B-57 to B-59): on a fresh copy of the packages,
  `semel-swift prepare Packages --platform ios-simulator` found the five roots, vendored the
  thirteen dependencies and wrote a formula and config identical in substance to the
  hand-written ones; `semel 'base <repo>' 'build Packages --into out'`
  then produced the five archives in 17 s from the warm cache and exited 0.

  Next: the app itself. A spike on 2026-09-14 built a SwiftUI app for the simulator from a
  hand-written formula with no engine change — three products under `Hello.app/` — and it
  installed and launched. The design for resources and the Xcode project is in
  `docs/superpowers/specs/2026-09-14-semel-app-bundles-design.md` (B-63 to B-65).
  Parts 1 and 2 landed the same day: tree products, and the `SemelApple` nodes. HelloApp
  now carries an asset catalog (icon, image, accent color) and a two-language string
  catalog, its Info.plist is built from the project's file and actool's partial one, and
  the app shows the compiled image and the localized title in the simulator.

  2026-09-15: IceCubesApp itself, from its Xcode project. `XcodeProjectConverter` reads
  the project file and its xcconfig, evaluates the settings, walks the application's
  three synchronized folders and emits the bundle; every package the project references
  is included and consumed through its module and object trees. On a fresh copy of the
  repository — 5,616 files, thirty packages vendored with `xcodebuild
  -resolvePackageDependencies` — `build icecubes-app --into out` produced `Ice Cubes.app`
  (a 57 MB executable, Assets.car, two icon PNGs, nineteen `.lproj` folders, fonts and
  sounds, the Info.plist with actool's icon keys), with no errors, and `simctl install`
  plus `launch` showed the app's onboarding screen loading instance suggestions from the
  network. Three things fell out on the way: a symbolic link back up a package tree
  walked without end, an included formula's own includes were not followed, and a
  dependency only a test target uses was waited for. Later the same day the four
  extensions followed — each a bundle under `PlugIns/`, the simulator's plugin registry
  listing all of them — and `prepare` learned a folder holding a project. The loop for an
  app is now the same two commands as for a package tree: `semel-swift prepare <clone>
  --platform ios-simulator`, then `semel 'base <parent>' 'build <clone> --into out'`.

- Get it working with large c or c++ project

- Maybe, if at all technically possible, a tool to convert a makefile or cmake file to a Formula file. Or even a Node that does it. Technically this is trying to convert imperative code to functional, but a "pure" makefile can in fact be functional. Cmake still has add_xxx methods and a mess of a syntax.

- Make github repo public

- Remote execution of tools. Ideally in docker containers running wherever. (Note: if the runners are inside docker containers then we'd have to cross-copmpile for Ubuntu and every other supported platform, which is probably too much. Maybe better to run a docker container with args.)

- Periodic cache integrity check: randomly compare the cache with computed output and if they differ, reset the entire cache.

- Done (B-29): a Semel version marker in the database resets the graph on mismatch, and the
  schema is fingerprinted from `sqlite_master` against what the code would create — a
  mismatch stops the launch and names the file to delete. A hash over the Semel code was
  considered and declined: it would reset on every rebuild of Semel, comment changes
  included, so nobody developing Semel would ever see a cache hit.

- Rollback of all input file changes if any Node enters an error state as a result, thus guaranteeing the build is always green.

## Settled direction

- Multi-user: a full engine on each developer's machine, sharing a central **cache
  server** — decided 2026-08-15, see
  `docs/superpowers/specs/2026-08-15-semel-cache-server-design.md`. Each machine keeps its
  own graph, one user per graph; the existing local cache stays as the near tier in front
  of the remote one, so a local hit never pays a round trip. Deduplication across users
  happens at the *cache*, not at node identity: same content, same project-relative path,
  same settings → same cache key → one compilation, on whichever machine got there first.
  Prerequisites, in order: canonical sandbox layout plus
  `-ffile-prefix-map`/`-debug-prefix-map` so outputs are mount-independent (B-49 — every
  developer has a different checkout path); mount prefix stripped from cache-key wire
  names (the project-relative part stays — that distinction is the Cache.swift
  path-collision lesson); a shared cache with real eviction and GC (B-14, B-15, B-30
  role 1).

- Superseded: one shared graph holding every user as a subtree of a single input/output
  file system (`input:/jade/my-branch/src/…`, one node per path). Recorded here as settled
  on 2026-09-09 by mistake — it is the shared-build-server model the cache-server spec
  replaced, and it drags in path authorisation, per-user output subscriptions, working-copy
  sync and a graph that is never globally idle. None of that exists when each engine is
  local. The shape survives only as B-30 role 3: a *local* background daemon serving local
  CLIs.

- A fully content-addressed graph (immutable nodes, git-style blobs/trees/refs, graph
  doubling as its own cache — the Nix/Buck2 model) was considered for cross-user dedup and
  declined. It shares bookkeeping as well as compute, but every edit appends nodes forever
  where the mutable graph updates in place, and it moves incrementality out of the resident
  graph into an evaluation phase — against the core vision of a living graph that reacts to
  pushes. With local engines the bookkeeping is per machine anyway, so there is nothing
  left for it to buy.

- The core is agnostic and plugins extend it by registering — dependency inversion, not a
  list the core keeps (`AGENTS.md`, "Plugin"). Plugins are linked into `semelserv` today;
  the aim is a server that finds plugin dylibs and loads them without their living in this
  repository. Until then, nothing a plugin does may rely on being compiled in: it reaches
  the core only through what it registers in `SemelNodeKit`. What loading itself needs —
  plugin-qualified `kind`s, a dylib fingerprint in its types' cache keys, an ABI boundary,
  and a state for rows of an unloaded plugin's types — is listed in the formula preludes
  design (B-108), whose include providers are the first extension point written with it in
  mind.

## What the tutorial taught us

`docs/tutorial/first-node.md` (2026-09-21) was written by walking every step through
against the binaries, and it is read here as evidence about the design: wherever the
document has to explain, warn or apologise, the reason is in Semel. The correctness
principles hold up — hermetic input, identity by spec, no defaults — and the friction is
where a person pays for one of them by hand, or where the engine holds what the person
needs and has no channel to say it. Three items are filed (B-91 to B-93); the rest are
questions about settled decisions, recorded so they are argued rather than re-discovered.

- **The engine had no output channel (B-91, fixed).** The protocol carried products
  and errors, and everything else left through `Debug.log`, compiled out of a release
  build — so the tutorial's Part 2, the one that shows the work Semel does not do, needed
  three terminals, a debug build and two internal log lines. Each settle now reports its
  totals, cache hits apart from recomputations, and the tutorial reads them at the prompt.
  What is still unanswered is the question behind them: "why did this rebuild?" is the
  first thing anyone asks a build system whose promise is *never twice*, and the engine
  could say how many nodes ran but not which, or which wire woke them. `explain` now
  answers it from the last settle's record.

- **A missing file is a state nobody is told about (B-92, fixed).** A `StaticFile` nobody
  pushed publishes `noValue(.initializing)` — no value has ever been produced there, and
  with no inputs, nothing ever will. That is not a failure, so no report named it: the nodes
  below it publish `inputNotProduced` and were passed over too, and what a reader got was
  `[missing]` in `ls` and one `Error` beside the product. The tutorial's `push clang.cfg`
  step exists because `build` pushes one folder and the formula reaches outside it with
  `<../clang.cfg>`; forget it and every tool named a missing setting while nothing named the
  missing file. B-71 was this problem, fixed for one file; B-92 is the report line for all
  of them — `clang.cfg has not been pushed`, with the chain below it counted. What decides
  the one exception is the port, not the node's type: `ConfigMerger.override` declares that
  it reads an absent value as nothing to add, because an override file nobody wrote is the
  expected state. Every other port, the merger's own `base` and the filter's `input`
  included, is a port whose file the formula says must exist.

- **`reset` threw away the valuable state (B-93, fixed).** The graph is rebuildable from
  the input plus the cache, and the cache is content-addressed — but `reset` also deleted
  the cache, which was the only reason it cost a cold build of everything in the home.
  That cost is what made leaving the tutorial a fifty-line, order-dependent section: a
  graph that still holds a node of a type the server no longer links is a dead end (B-83),
  and the way out was expensive. `reset` keeps the cache, `reset --cache` is the command
  that discards it, and the graph a reset discards is copied aside rather than lost.

- **No defaults is right; a person paying for it by hand is not.** The configuration
  design (2026-08-30) argues this well and accepts "a real ergonomic cost". The guarantee
  needs the values declared in the input file system; it does not need a person to type
  them, and it does not need them in the same file as the project's intent. Tool
  version, SDK path and architecture are facts about the machine, and they change with
  it; `cStandard` and the deployment target are the project's, and belong in the
  checkout. One file holds both, which is why the end-to-end harness needs a `.template`
  with placeholders and why the reader adds seven lines by hand after being told not to
  write the file (`tools clang` now prints the machine half ready to paste, B-86; the
  project half is still typed). Swift has the right shape already (`prepare` writes the machine facts);
  `ConfigMerger` and "variants are files" mean a generated machine file merged with a
  checked-in project file fits the design as it is. Separately: every hand-written
  formula repeats `rawConfig()` / `config(prefix:)` / `ConfigFilter` wiring although the
  prefix is derived from the node's type name (`SettingNamespace`), so the engine already
  knows which slice a `ClangCompiler` wants.

- **A node type's identity is stored three ways.** A hand-assigned `kind` integer, the
  type name inside every stored `graphSpec`, and the schema fingerprint. Renaming a type
  already forces the database to be deleted (B-29), and `TypeRegistry` already looks
  types up by name; whether `kind` still earns its place is worth asking. Hand-assigned
  numbers collide across branches — the backlog IDs did exactly that in the same week.

- **Isolation is per user, work is per project.** B-40 (a scoped `reset`) was dropped as
  moot because users no longer share a graph; projects still do. Pushes are base-relative,
  so two folders both named `hello` under different bases land at the same `input:/hello`
  (read from `FilePlugin`, not run). "Extensible" in the README overstates what is
  possible: node types are compiled into the server and their identity lives in a
  long-lived database, so every experiment leaves something in the real graph. A
  throwaway home (`SEMEL_HOME`, or a `--home` flag on both binaries) would make the
  tutorial's clean-up "delete the folder".

- **The node API exposes the engine's internals.** `inputValues` is an unordered
  dictionary, so every author has to remember to sort (the tutorial does; B-04 is the
  same class of bug); a sorted list on the API would remove it. `.required` blocks on a
  pending wire but not on an errored one, so each node invents its own missing-value
  policy — `ConfigFilter` skips, `LineCounter` throws — where the descriptor could state
  it. Authors import `SemelDatabaseModels` for `NodeRecord`, repeat the `thisNode`
  boilerplate, and are pure only by discipline.

- **The 15 ms cache floor was a wall-clock decision (B-147, fixed).** Whether an entry
  existed depended on how long processing took, so a shared cache filled differently with
  machine speed and load, the tutorial's own node was never cached, and a compile woken
  with an unchanged key reran or hit depending on how long its earlier run had taken.
  Decided 2026-10-10: whether a type caches is a declared property of the type, never of
  the clock. The tutorial's node is now cached like any type that says nothing.

- **The easiest spelling in the formula language is the wrong one.** `%%f%%` names a wire
  after the mounted path and so puts the path into the product; `%%f.0%%` is the
  capture. The mistake was made in this tutorial's own spec and caught only by the
  two-home byte comparison. B-49 makes the tools mount-independent; a template can bring
  the mount path straight back.

## Features

Concrete features, held back while the work is stabilising; `BACKLOG.md` holds the bugs.
IDs come from the one sequence both files share, and status and removal when finished work
as `BACKLOG.md` describes — as does the `For Fable Only` tag: an item where choosing the
approach is most of the work, done by the most capable model and not delegated. `Not
doing` keeps the decisions that would otherwise be raised again.

### Hermeticity and determinism

**B-03** `open` `For Fable Only` — **Run tool execution in a container.**
`ToolRunner` runs inside a dedicated process wrapping a Docker container configured with
the toolchain, SDK and system libraries, reset between builds. The container digest then
*is* the environment: `sdk=26.5 (25F70)` becomes `image=sha256:…`, and "did we miss an
input?" stops being a question only an audit can answer. Also the natural home for the
Remote Runner role (B-30). What B-47 leaves here: the SDK reaches the graph as a
fingerprint of paths, sizes and mtimes, walked once per process — in every SDK-reading
tool's key and as `sdkFingerprint` in the machine file — which misses an edit that keeps a
file's size and mtime and an SDK changed under a running server; the image digest is the
content-addressed answer. The same for the tool binary, which is keyed on its bytes but
not woken when it changes under one version.

**B-49** `open` `For Fable Only` — **Tool outputs must not depend on where the inputs are mounted — residuals.**
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
   whose paths are root-relative, and every node that reads `baseFolderPath` has to follow:
   the clang preprocessor's `-I`, the Swift compiler's walk, `AssetCatalogCompiler` and
   `FolderTreeBuilder`. `Folder`'s `contentRoot` (B-26) is already path-independent, which
   is one shape "what `Folder` publishes" could take. `CacheKeyMountIndependenceTests`
   prove the wire-name half of the design; this value half is what remains for a real Swift
   graph.

### Swift package conversion

**B-06** `done` — **Lock vendored dependencies by content hash.**
Done 2026-09-28 (design: `docs/superpowers/specs/2026-09-28-semel-dependency-lock-design.md`).

*As built.* One lock per dependency, beside it — `Dependencies/GRDB.swift.semel-lock` —
so an update's diff touches the one file of the package that moved. The text is the one
sketched below plus a `fold` line naming the `FolderContentRoot` format the root was taken
under, so a lock the fold moved under reads as "cannot be compared" and not as "the tree
moved"; `content` and `fold` are required, `version`, `revision` and `origin` recorded when
the resolver said them. Reader, writer and a disk fold of a folder's content root live in
`SemelNodeKit` (`DependencyLock`, `FolderContentRoot.root(ofFolderAt:)`), where the converter
and `semel-swift` both reach them. `SwiftFormulaConverter` checks every package it reads
directly under `<root>/Dependencies` — the dependencies it reaches, and the package it
converts when an Xcode project's formula names one by its vendored folder: it demands the
lock `StaticFile` beside the manifest readers, and the folder's `contentRoot` once the lock
is there, on two dynamic ports; `DependencyLockCheck` compares them into a typed outcome, and
a mismatch is the converter's error naming the package, the lock, what it records, the
expected and the found root, and that `semel-swift prepare` rewrites the lock. A missing lock
is a notice, not an error — every tree vendored before this, and every one vendored by hand,
is in that state — posted once per conversion through `NodeNotice`, a hook in the node kit
the engine points at its own notices; an unlocked folder's root is not wired, so a tree
without locks is not woken by edits below its vendored folders. `prepare` writes the lock
beside each copy once all are in place, folding the copy on disk over what a push pushes —
`push`'s own lister, so no dot-names, and no folder without a file below it —
(`DependencyLockFoldTests` pushes such a tree through the engine and compares the roots),
with the version, revision and origin of the checkout's pin in `Package.resolved`. A link
inside its own folder — a vendored framework's `Versions/Current` — is folded as the link
it is on both sides since the fold's format 3 (B-77, 2026-09-29), and the test pushes a tree
holding file and folder links. Since B-146 (2026-10-10) the lock is also a write barrier
at `commit`, so a batch that moves a locked folder is refused before anything builds from
it, naming the paths of the batch that moved the root. What
remains: the root of a copy with a file removed from disk but not from `input:` differs
from a fresh lock with no word on which file — that file is in no batch, so the barrier
does not name it either. That the file stays is the rule, not a gap
(2026-10-04): a push only adds, and a removal is an `rm` — by hand, or by `semel-watch`,
which mirrors the disk with one (B-126); a lock `rm`'d from `input:` is named
as a deleted source on every report while the converter still wires it, as any removed
source a build reads is. The version is recorded and never checked against the manifest's
requirement, and that is a decision (2026-10-03): which version a copy should be is the
package manager's question, and the package manager is `prepare`, outside the engine. The
engine builds the files it was pushed. What makes rerunning `prepare` the habit is B-138.

The entry as it was filed:
`ISSUE:` in `SwiftFormulaConverter`'s dependency resolution. A `sourceControl` or registry
dependency resolves to `<root>/Dependencies/<name>` with nothing checking that what is
there is what was meant.

Approach: a recursive content hash over the vendored package's own folder in the input file
system — `input:/repo/Dependencies/GRDB.swift` — recorded and compared on every build.
Guarantees the dependency has not changed, without claiming to guarantee which version it is.

*What this does not need to fix.* Cache correctness is already guaranteed: a vendored
package's files are ordinary `StaticFile` nodes whose content hashes are wire values, and
`buildCacheKeyEntriesFromOneInput` puts every wire's key and value into the cache key. Adding
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
file, which still reaches the graph as an ordinary `StaticFile` and so participates in cache
keys with no special path — but **not inside the vendored folder**, for two reasons found
since. A lock in the folder is a child the folder's `contentRoot` folds, so recording the
root in the lock changes the root and it can never match; and `semel-swift prepare`
replaces each `Dependencies/<name>` wholesale when it vendors, which would erase it. Beside
the folder, one lock per dependency, or one file for all of them in `Dependencies/`:

    Dependencies/GRDB.swift.semel-lock
        content   sha256:abc…      enforced; a mismatch stops the build
        version   7.11.1           recorded only, never enforced
        origin    https://github.com/groue/GRDB.swift.git

Keeping an unenforced version line costs one line and answers two questions a hash cannot:
whether this is the library that was meant in the first place — a lock preserves a
first-time mistake forever — and whether a published advisory applies. Degrades gracefully:
absent → warn once, present and mismatched → fail.

The recursive content hash is there (B-26): a folder's `contentRoot` port carries a Merkle
root over everything under it, so `input:/repo/Dependencies/GRDB.swift`'s root is one port read — and it
is not qualified by the folder's path, so a lock survives the dependency being moved. What
remains for B-06 is recording that hash in a lock file and comparing it. Two notes for
whoever does: the fold is a stated text format with a version tag on its first line
(`FolderContentRoot`), so a recorded root that stops matching can be told from one the
format moved under; and a `contentRoot` wire is a real dependency, so the node that checks
the lock re-runs whenever anything under the vendored folder changes, which is the point.

**B-146** `done` — **A lock is a write barrier, and a batch is all or nothing.**
Done 2026-10-10 (design: `docs/superpowers/specs/2026-10-05-semel-locked-folders-design.md`,
whose "As built" says where this differs). A batch has a journal: `begin` opens one per
session (`BatchJournal`, SemelCore; nested begins share it), and every push, link push,
folder push and removal records, before it writes, what its path and each folder on the
way held — the node's own port rows, or nothing — once per path per batch, as rows of the
graph's `Metadata` table in the batch's own transaction (`withTransactionPerStep`). The
outermost `commit` runs `LockBarrier.commit`: the locked folders the journal's paths fall
under (from each path up, the first folder whose `<name>.semel-lock` holds a value in
`input:` as the batch left it; a lock path names its own folder too), the marks the batch
left flushed inside a savepoint, and each such folder's `pushedContentRoot` compared with
its lock's `content`. A lock taken away frees its folder; a lock that does not parse, or
was taken under another fold, refuses the batch, the first naming its line. On a refusal
the savepoint is rolled back, the journal replayed — what the batch made where nothing
stood goes, deepest first, and every other path's rows are written back, shallowest
first — and the folders folded back, so the pass the batch's one wake-up causes finds
nothing to do unless the batch had scheduled a consumer, which is then answered from the
cache. `commit` answers `ErrorResponse.batchRejected(folder:lock:expected:found:paths:)`
(protocol 25), with no batch left open; `expected` is a `LockExpectation` (a root, a root
under another fold, or an unreadable lock with its line), and `paths` are the batch's at or
below the folder, and the lock's own, whose rows it changed. A push, `rm`, link or folder
push outside a batch is a batch of one; a connection that closes with a batch open is
committed through the same check, its refusal logged. The client prints the refusal as a
statement and `lock:`/`expected:`/`found:`/`paths:` lines (since B-145 the condition
`ErrorCondition.batchRejected`, drawn by the error report's renderer);
`push` and `rm` no longer swallow their own commit's failure, and `build` stops after a
refused push with `Not built: the push was refused, and nothing was exported.`
`checkpoint [<name>]` records the input root's whole content root under a name, `latest`
by default, in `Metadata`; `checkpoints` lists them by name; `restore <name>` walks the
checkpoint's documents against the current ones down to where they differ, pushes files,
links and modes, makes folders and removes what the checkpoint lacks, in the session's
batch or one of its own, through the barrier, and waits for the one settle. The collector
keeps every object a checkpoint names. `semel-watch` asks which folders below the watched
ones are locked (`InputHoldings.lockedFolders(below:)`, one listing of `**/*.semel-lock`),
at launch, after a reconnection and after a batch that moved a lock; the filter leaves a
locked folder out unless an `--only` names it, a folder holding one is pushed by its
children, the launch line names them (`not watching the locked …, which change only with
their locks: semel-swift prepare vendors them again`), and a change to a lock mirrors and
pushes its folder in the lock's batch, so a re-vendor lands; a refused batch is the
interpreter's error and nothing is built or exported from it. Found on the way: a file
pushed back into a folder `rm` had taken, before the collector ran, failed with
`nodeNotFound`, its row still naming the folder's gone row; the push now adopts it into
the folder made again. Measured on GRDB.swift re-vendored from 7.10.0 to 7.11.1 (771
files, 266 changed, 246 gone; a debug build, a file graph): the whole commit — the flush
the next pass would have made, the lock lookup, the fold read — 117 ms, of which the
barrier's own lookup is 62 ms; the journal adds about 0.25 ms a path to the push, 995 ms
against 680 ms when every one of the copy's files is sent and 1,228 paths are journaled;
a refusal, replay and refold included, 522 ms. `BatchJournalTests` and `LockBarrierTests`
(SemelCore), `LockedFolderServerTests` (the refusal over a socket, a batch of one, nested
batches, a closing connection, a `wait` after a refusal), `CheckpointTests` (round trip,
listing, a restore across a lock change, the refusal at `push`, a restore answered from the
cache), `WatcherTests` (the locked folder left alone at launch and on an edit, a re-vendor
landing, a refused batch followed by a save that lands) and
`LockedFolderEndToEndTests` over `swift-binary-target-app` with a dependency `prepare`
vendors from a repository made on disk.

**B-10** `open` `For Fable Only` — **Packages are named by a formula, not discovered — one residual.**
Done 2026-09-12: `Package.swift` creates no builder; a `.fmla` says
`include SwiftFormulaConverter(path: <.>).formula` — `include` merges the formula text any
node produces, and knows nothing about packages; the converter wires its own reader from
the path — only the formula's products are published and they land beside the formula,
included names may not clash with the formula's own, and every node of the build reads its
settings from one config — beside the named package, or at the converter's `root:` when the
formula gives one (B-56) — so this tree keeps one `semel.config`, not six. Done
2026-09-28, discoverability: a plugin registers an `IncludableProjectPlugin` saying what an
`include` would build a file with — SemelSwift claims a pushed `Package.swift` not under a
`Dependencies` folder — `ProjectFinder` publishes the files claimed on its
`includableProjects` port, and after a settle with no errors the engine gives one notice
per file that no node reads: `input:/Packages/Foo/Package.swift is not named by any
formula; a formula's include SwiftFormulaConverter(path: <Foo>).formula builds it`, spelled
from the nearest folder above that holds a formula (`Semel.version` 0.1.11, for the new
port). Not claimed yet: an `.xcodeproj`, which a formula names the same way; and a
`Package.swift` nested in a package the user owns — a test fixture — is reported like any
other. What remains:

1. **Dependency overrides in the formula.** The converter resolves a git dependency to
   `<root>/Dependencies/<name>` (the `semel-swift` rule) and stalls when nothing is there;
   a formula cannot yet say "this URL is at that path". Needed the day a dependency has to
   come from somewhere the rule does not reach.

Granularity is per package, not per product: a dependency that also vends an executable
loses it. Acceptable until a real case shows up. The inferred-roots plan (converter
dependency lists unioned in `ProjectFinder`, a `publishProducts` property, the settle diff
hiding the flap) was declined the same day: a port, a protocol parameter, a property and an
ordering constraint to approximate what one line of formula states.

**B-55** `open` — **C targets in a Swift package: what the first case did not need.**
B-54 builds swift-cmark and CAtomic inside IceCubesApp's graph (39f27b1): a target with
C-family sources and no Swift gets a preprocessor and compiler per file, its public
headers go on every dependent Swift target's `inputModuleMapFolders`, and the objects link
into the product. Done 2026-09-28, held by the `swift-c-package` fixture, whose excluded
sources `#error` and whose sources `#error` without their define:

1. **Nested sources.** A target's language is read from its whole walked tree, SwiftPM's
   own rule (`PackageClangTarget`): a `.swift` anywhere in scope makes it Swift, else a
   C-family source anywhere makes it C. The top level alone got both directions wrong —
   a C target with its sources in subfolders went to `swiftc` with nothing to compile.
   `prepare` reads the tree the same way. Its objects are one for-each per target,
   `{f: '<t>/**/*.c', '<t>/**/*.cpp' except '<t>/Tests/**', '<t>/skip.c'}`: a `**/*.<ext>`
   per extension found under each source folder — the target, or the folders `sources:`
   lists, a listed file taken by name — and `exclude:` as the `except`, a folder as
   everything under it and a file as itself; an exclusion that removes no C-family
   source (`CMakeLists.txt`, cmark's `.re` grammars) is left out. `ProjectBuilder` no
   longer fails an `except` that empties a walk still on its way down, which stalled the
   walk for good when the only top-level source was an excluded one.
2. **Nested headers.** The preprocessor walks each `headerFolders` folder to the bottom on
   a `headerSubfolders` port of its own, as `SwiftCompiler` walks its sources (version 3):
   a header input is already placed at its input-file-system path, so the walk was all
   that was missing, and only the folders given stay `-I`s. Wiring every nested folder
   from the converter instead would have made each an `-I` — a search path SwiftPM does not
   give — and a second walk beside the one the converter already does.
3. **`publicHeadersPath`** names the header folder, `include` only its default, for the
   Swift importer's module map folder, the product's module tree and the preprocessor;
   `"."` is the target folder itself.
4. **`.define`**: unconditional ones from `cSettings` and `cxxSettings` are the
   preprocessor's `defines`, one `-D` each before `arguments`. A key of their own and not
   `arguments`, because a literal replaces the key it names in the settings under it, so
   the project's own `clang.preprocessor.arguments` would have vanished for every target
   with a define. The compiler gets none: it reads preprocessed text.
5. **Executables.** No `clang.linker` block: `swiftc` drives `ld` for C objects as for
   Swift ones, and a pure-C executable linked by `SwiftLinker` references `libSystem`
   alone. What was missing was that a product's *own* C target — a C executable's
   `main.c`, a library vending a C target — was never compiled: the walk started from
   the target's dependencies.
6. **A target at its package's root** (B-134, PLCrashReporter 1.12.2, NetNewsWire's pin
   `0254f94`): `path: ""`, `"."` or a path ending in `/` is the plain folder
   (`SPMTarget.folder(in:)`), where the converter asked for `…/plcrashreporter/` — a
   second node for the package folder's name, which the applier refused. `prepare`
   reads a target's `sources:` and `exclude:` too (`PackageSummary.Target`), where the
   whole root — its `Package.swift`, its tests' Swift — made the target Swift and the
   clang settings were never written.
7. **`.headerSearchPath`**, unconditional, is one more `headerFolders` folder of the
   target's own preprocessor, relative to the target; one naming no folder is left out,
   as clang passes over it. The fixture includes a header by it alone.
8. **A C target's resources** are a bundle as a Swift target's are,
   `<Package>_<Target>.bundle` in the product's `bundles_` tree (PLCrashReporter's
   `.process("Resources/PrivacyInfo.xcprivacy")`).
9. **What the link needs beyond the objects** (residuals 1 and 2 below, the linker half;
   2026-09-28). `LinkRequirements` in `SemelNodeKit` is its type — frameworks, libraries,
   the C++ runtime — written as settings of their own (`frameworks`, `libraries`,
   `cxxRuntime`), not `arguments`, so a project's `swift.linker.arguments` survives. The
   converter reads every target's `.linkedFramework` and `.linkedLibrary`, Swift and C
   alike, and whether a C target's sources hold C++ (`PackageClangTarget.compilesCxx`:
   `.cpp`, `.cc`, `.cxx`, `.mm`, `.C`); each product gets a `linking_<Product>()` func,
   a `SettingsLiteral` of the union over the targets it reaches, defined empty too so a
   consumer can name it. Its own linker is wired to it on a `linkRequirements` port
   (`SwiftLinker` v3, N settings wires, their union with its own settings), and so is an
   app's: `XcodeFormulaEmitter` wires `linking_P()` for every package product the target
   links (XcodeProjectConverter v7), where the product's objects arrive as a tree and say
   nothing about C++. `SwiftLinker` passes `-framework`, `-l` and one `-lc++`, none of
   them to an archive, whose requirements are its consumer's as SwiftPM leaves them;
   `ClangLinker` (v2) reads `frameworks` and `libraries` too, with the SDK's framework
   folder as `-F` since it links with no sysroot. A `.when(platforms:)` linker setting
   holds for the platform of `swift.linker.sdk` (default `macosx`), which the converter
   demands on a `linkerConfiguration` port only when some manifest has such a setting;
   one conditional on a configuration is not carried. SwiftFormulaConverter v10.
10. **Assembly** (residual 5, 2026-09-28). `.S` and `.s` count as a C target's sources
   (`PackageClangTarget.sourceExtensions`, and prepare's rule with it), so a target of
   assembly alone is a C target as SwiftPM counts it. A `.S` goes through the target's
   preprocessor with the C, as `assembler-with-cpp` with its defines and no `-std`; a
   `.s`, which has no preprocessing phase, is a for-each of its own into `ClangCompiler`
   straight from its `StaticFile`, as `assembler` (ClangPreprocessor v4, ClangCompiler
   v2). A standard is not asked of an assembly file.

The fixture holds 9 and 10: `CLib` links Foundation and, on macOS only, zlib (its C
calls `CFStringGetLength` and `zlibVersion`), names a library for Linux that would fail
the link if it were passed, has a `.cpp` with a function-local `std::string`, and a `.S`
and a `.s` whose symbols the Swift executable and the C one both call.

With these, all 58 of PLCrashReporter's C, C++, Objective-C and Objective-C++ sources
and its `.S` preprocess and compile inside a Swift package's graph (`sources:` two
folders, `exclude:`, `.headerSearchPath("Dependencies/protobuf-c")`, a define with an
empty value), and an executable depending on `CrashReporter` links, with Foundation and
libc++ (checked 2026-09-28 at NetNewsWire's pin `0254f94`, vendored by `prepare` into a
scratch package). What stopped it from Swift, 4 — `import CrashReporter` was `no such
module` — and 7 at run time are done since.

Left, each for the package that needs it (swift-nio and BoringSSL in B-78 are the likely
first):

1. **Conditional and other settings.** The linker half is done (9 above:
   `linkedFramework`, `linkedLibrary`, `.when(platforms:)` on them). Left: a
   `.when(platforms:)` `cSettings` or `cxxSettings` setting — a define, a header search
   path — is still not carried, though the platform it wants is now read for the linker's
   (`SwiftFormulaConverter`'s `linkerConfiguration`); nothing conditional on
   `.when(configuration:)` is carried, linker settings included, since a package is built
   in no configuration here; nor is `unsafeFlags`, for C or the linker. A define whose
   value holds a comma splits in two and one holding a quote ends the formula's string.
   Mac Catalyst builds against `macosx` and is read as `macos`
   (`SwiftFormulaConverter.swiftPMPlatformName(forSDK:)`).
2. ~~**C++ in a linked product.**~~ — done 2026-09-28 (9 above): the converter says a
   product reaches C++ in its `linking_<Product>()` settings, and `SwiftLinker` adds
   `-lc++` once. PLCrashReporter's `___gxx_personality_v0` and `___cxa_guard_*` resolve.
3. ~~**Nested public headers for Swift.**~~ Done (2026-09-28), with 4: a C target reaches
   a Swift one as a tree of its headers at every depth, where `inputModuleMapFolders`
   placed one level of the public folder.
4. ~~**No generated module map.**~~ Done (2026-09-28). A C target reaches every Swift
   target that depends on it, and its product's `modules_` tree, as one value:
   `headers<Target>()`, a `TreeBuilder` of every header of the target that `exclude:`
   leaves, at its path in the target under the target's name, with the public folder's
   module map beside them (`SwiftCompiler`'s `moduleTrees`, which puts each folder of the
   tree holding a `module.modulemap` on the import path). The whole target's headers and
   not the public folder's alone, because a public header may reach back into the target
   — NetNewsWire's `include/RSDatabaseObjC.h` is `#import "../FMDatabase.h"` — and
   `exclude:` is honoured because Zip's excluded `minizip/module/module.modulemap` would
   otherwise declare `Minizip` a second time. When the public folder holds no map, the one
   SwiftPM writes is a `ModuleMapWriter` (`SemelSwift`, kind 39): a source like
   `SettingsLiteral`, its properties the module's c99 name and `umbrellaHeader` or
   `umbrellaDirectory`, relative to the folder it sits in. Which one follows SwiftPM's
   `determineModuleMapType` over the folder's listing, which the converter already has
   (`PackageClangTarget.moduleMap`): the folder's own `module.modulemap`; `<Module>.h`
   with no folder beside it; `<Module>/<Module>.h` alone in the folder; else the folder
   as an umbrella directory. SwiftPM's two refusals — an umbrella header with folders
   beside it, a `<Module>` folder with company — get no map, and so no module, as there.
   SwiftFormulaConverter v11. Pinned by `SwiftFormulaConverterTests` (the rule case by
   case, PLCrashReporter's `CrashReporter.h`, Zip's `Minizip.h` under the Swift target
   that excludes it, a `publicHeadersPath` with an umbrella, a map of the target's own)
   and `ModuleMapWriterTests`; end to end by the `swift-c-package` fixture, whose `App`
   imports `ObjCKit` (an umbrella in `include` reaching back with `../`), `Shapes` (an
   umbrella in `publicHeadersPath: "public"`) and, through `Zipper`, `Squeeze` (an
   umbrella directory, nested in `Zipper`'s folder, beside an excluded module map that
   would break the build were it read).
5. ~~**Assembly.**~~ — done 2026-09-28 (10 above): PLCrashReporter's
   `Source/PLCrashAsyncThread_current.S` compiles and defines
   `plcrash_async_thread_state_current` for its link. BoringSSL's generated `.S` files
   are untried.
6. **Cost.** A preprocessor node takes every file under its target's folder, an excluded
   folder included, and every source of the target has one; a large excluded `Tests`
   costs wires, not correctness. A target at its package's root makes that the whole
   package: PLCrashReporter's preprocessors take its tests, tools, documentation and
   `.xcodeproj`, and the converter walks all of them for resources.
7. ~~**Objective-C without ARC.**~~ Done (2026-09-28), with clang modules, which every
   header of NetNewsWire's Objective-C targets needs (`@import Foundation;`). Both clang
   stages read `objectiveCARC` and `modules` (`ClangLanguageFeatures`), and the
   preprocessor `moduleName`; the node decides per file what each means, as it picks
   `cStandard` or `cxxStandard`: `-fobjc-arc` for Objective-C and Objective-C++, and
   `-fmodules` with `-fmodules-cache-path=.semel-derived/clang-module-cache` for
   Objective-C alone, with `-fmodule-name` in the preprocessor so the target's own headers
   stay text. SwiftPM enables modules for C too; here the compiler loading them again
   expands a module's self-referential macro a second time (11), which broke
   PLCrashReporter's C (`#define ts_64 uts.ts_64` made `thread.uts.uts.ts_64`), and only
   Objective-C can write `@import`, so C keeps the build it had.
   Both stages need both: the preprocessor evaluates `__has_feature(objc_arc)` (FMDB's
   retain macros) and loads the modules an `@import` names for their macros, and its
   output keeps each import, so the compiler loads the modules again — from the SDK,
   which is why `clang.compiler.sdkPath` is now a machine setting and is required when a
   source loads modules. The module cache is a folder of the sandbox
   (`ToolSandbox.derivedStateFolderName`): derived state that goes with the run, never an
   input or an output, and the objects are byte-identical at two sandbox paths with `-g`.
   The converter states the three as literals for a C target whose sources hold `.m` or
   `.mm`, never a plain C one (11). With modules the Objective-C objects autolink the
   frameworks they import (`LC_LINKER_OPTION -framework Foundation`). ClangPreprocessor v5, ClangCompiler
   v3, ClangIncludeFinder v4 (a quoted `#import` is listed as an `#include` is; an
   `@import` names a module and is passed over). Pinned by `ClangPreprocessorTests`,
   `ClangCompilerTests`, `ClangIncludeFinderTests` and `SwiftFormulaConverterTests`; end
   to end by `swift-c-package`'s `ObjCKit`, whose header opens `@import Foundation;`,
   whose source `#error`s without `__has_feature(objc_arc)` and synthesizes a `weak`
   property, which only ARC can; its `App` says a weak reference clears when run.
8. **No `SWIFTPM_MODULE_BUNDLE` for Objective-C.** SwiftPM generates a bundle accessor
   for a C-family target with resources; the converter builds the bundle (done 8) but
   generates no accessor, so a target that reads its bundle through the macro does not
   compile. PLCrashReporter does not use it.
9. **A search path above the target.** `.headerSearchPath("../Shared")` names a folder
   the converter's walk of the target never reaches, and `PackageClangTarget` leaves it
   out as it would a missing one.
10. **C++ from Swift.** A product needs the C++ runtime when a C target it reaches has
   C++ sources (9 above); a Swift target compiled with `.interoperabilityMode(.Cxx)`
   needs it too, and its `swiftSettings` are not read for it — nor is the mode passed to
   `swiftc` at all.
11. **Modules across a split preprocess and compile.** With modules, `-E` keeps every
   module import in its output — `@import`, and `#pragma clang module import` for an
   include of a header a module map covers — and the compiler imports them again. Two
   things follow. A module's macros come back to text already expanded, so a macro that
   names itself expands twice: the SDK's `#define ts_64 uts.ts_64` (`mach/arm/thread_status.h`)
   turned PLCrashReporter's C into `thread.uts.uts.ts_64` — compiling as
   `cpp-output` does not stop it — which is why modules are Objective-C's alone, where
   SwiftPM enables them for every language but C++. And an include of a C dependency's
   modular header becomes an import the compiler has no module map for (checked by hand:
   `#include "dep.h"` beside a `module.modulemap` preprocesses to
   `#pragma clang module import Dep`), so an Objective-C target including a C target's
   header fails, and a plain C target would if it had modules (cmark-gfm-extensions over
   cmark-gfm). NetNewsWire's two Objective-C targets depend on nothing and use no such
   macro. Wants the two stages joined for a source with modules, or the compiler given
   the header trees the preprocessor saw and the preprocessor handing on text with the
   includes inlined and the macros unexpanded (`-frewrite-includes`), which then needs
   the defines at compile time too.

**B-140** `done` — **`prepare` says what it built for, and refuses a `--platform` the files do not hold.**
Done 2026-10-05: the owner prepared a package tree with `semel-swift prepare <folder>`,
which defaulted to macOS, then ran it again with `--platform ios-simulator`; the
`semel.config` already there was kept, as `prepare` never overwrites it, the run printed
only a note after `Kept:`, and the build failed with "no such module UIKit". Every run now
opens its report with the platform, the SDK and the target the build will read —
`Platform: ios-simulator, SDK iphonesimulator 26.5, target arm64-apple-ios17.0-simulator
(semel.config written)`, or `(from the semel.config already there)` — read back from
`semel.config` after the run (`GeneratedFiles.target(inProjectConfig:)`, through the
config reader the engine uses), and for a project a `Converter: sdk …` line read from the
formula's `XcodeProjectConverter` (`converterSDK(inFormula:)`). `Platform` reads both back
as a platform, `init?(target:)` and `init?(sdkName:)`, over the one spelling
`target(deploymentVersion:)` writes. Before anything is vendored, copied or written,
`Preparation.run` takes what those files hold (`HeldPlatform`): with `--platform`, each
must be for it, else `PlatformConflict.flagDisagrees` names the file, the platform it
holds, the platform asked for and the remedy — delete the file, or omit `--platform` to
keep its platform; without the flag, their platform is the run's, the machine file is
written for it, and `macos` (`Preparation.defaultPlatform`) only when they hold none — a
config and a formula that disagree are `noOnePlatformHeld`. A second identical run still
changes nothing on disk but the machine file. `PrepareTests` hold the report for a fresh
write and a config already there, the error and that it writes nothing, a matching flag,
no flag, and a project formula for another SDK; `PlatformTests` the readers.

**B-138** `done` — **`prepare` notices a moved pin and re-vendors only that copy.**
Done 2026-10-04: `prepare` resolves as before, then `Vendoring.copyCheckouts` asks of each
checkout whether the copy under its name is what copying would make again
(`reasonToCopy`), cheapest first: a lock beside it that parses, taken under this fold,
recording the pin's version, revision and origin, recording the checksums the copy's
manifest names for its binary targets, and a copy that still folds to the lock's
`content`. A copy that passes is left with its lock, byte and date — no copy, no new lock,
no unzip — and one that fails is copied and locked as before, with the reason as a
`Vendoring.CopyReason` (`absent`, `lockMissing`, `lockUnreadable`, `foldChanged`,
`pinMoved`, `artifactsDiffer`, `contentDiffers`), each but the first two carrying the lock
that was there. A retagged release (the revision moved under its version) and another
origin under the same name are moved pins. The manifest's checksums come from the summary
`prepare` takes of every vendored package anyway, read once and kept for a copy left as it
was. `PrepareReport` carries `revendored` (name, reason, pin) and `unchanged` (names), and
`vendoringLines` renders them: one line per package copied — `GRDB.swift 6.29.3 → 7.0.0,
re-vendored`, the revision for a branch pin, the origin when that is what moved, the reason
when the pin did not — then `33 unchanged`. Measured on CodeEdit's thirty-four copies (808
MB): folding every copy against its lock takes 1.7 s on a first pass and 0.6 s warm, in a
debug build, so the pin is compared first only because it is free, and the second
`prepare` (34 unchanged) took 32 s against the first's 66 s — what is left is
`xcodebuild -resolvePackageDependencies` cloning into a fresh folder each run.
`VendoringTests` and `PrepareTests` hold each reason and the lines, and
`PrepareEndToEndTests` runs the binary over two git repositories made on disk: the second
run leaves `Dependencies` as it was and says `2 unchanged`, and a requirement moved to
1.1.0 copies that package alone. Still open: whether `build` should run `prepare`.

The entry as it was filed:
Decided 2026-10-03: checking a dependency's version against its manifest's requirement is
not the engine's job but the package manager's, and the package manager is `prepare`,
which runs SwiftPM's resolution outside the engine. So the converter does not check it
(B-06's lock records the version and no more), and the remedy for a bumped requirement
is to run `prepare` again. Today that re-vendors every copy, which is why nobody does it
between builds. What this asks for: `prepare` compares each pin SwiftPM resolved
(`Package.resolved`, or the project's) with the version, revision and origin the lock
beside the copy records, copies and re-locks only the packages whose pin moved, leaves
the others' folders and locks untouched so their content roots do not move and nothing
downstream rebuilds, and says what it did per package — `GRDB.swift 6.29.3 → 7.0.0,
re-vendored; 33 unchanged`. A copy whose lock is missing or whose root differs from its
lock is re-vendored too, since `prepare` is where a person asks for the copy to be made
right. With that, `prepare` is cheap enough to run before every build, and a script or the
watcher can run it; whether `build` should is a question for after it exists.

**B-122** `done` — **`prepare` writes no clang settings for a tree with C targets.**
Fixed 2026-09-27: `prepare` decided the tree's languages from a scan taken before
vendoring, so a C target that arrives with a dependency — swift-cmark under IceCubes — was
never seen on a fresh copy, while the 13 September tree, vendored long before, passed by
hand. The decision is now taken after vendoring, over the vendored packages too;
`PrepareTests` holds it to a Swift root whose dependency brings a C target, and the
nightly's `icecubes` run is what failed on it (the night after B-109 landed). The account
below is what was seen before the cause was found.
Seen 2026-09-27 on a fresh copy of the IceCubes packages: `semel-swift prepare Packages
--platform ios-simulator` vendored swift-cmark and swift-markdown's CAtomic, wrote the
formula, and wrote `semel.config` and `semel.machine.config` with the three `swift.*`
namespaces and nothing else — while the comment it writes into `semel.config` promises
"for the clang tools a language standard to start from", and B-119's third point assumes
`prepare` writes the `clang.*` namespaces when the tree has a C-family target. The first
build then failed on 70 clang nodes with the missing-settings report, and the loop it
names — add `clang.compiler.target` and the standards to the project file, run the
machine-file writer — is one `prepare` was meant to close. The 2026-09-13 tree at
`C1/icecubes/Packages` has the clang blocks, so either they were written by hand then or
the detection has regressed since; `PrepareTests` should hold a package with a C target to
a config carrying both `clang.preprocessor` and `clang.compiler`, project half and machine
half, and B-119's plan should be read against whichever answer this turns out to be.

**B-26** `open` `For Fable Only` — **Recursive content hash for a folder tree.**
Done 2026-09-25: a `Folder` publishes a Merkle root on a `contentRoot` port of its own —
the hash of a document with one line per child carrying its kind, what it holds and its name:
a file's line carries its content hash and a subfolder's carries that subfolder's root,
ordered by name as UTF-8 bytes then by kind, and framed by each name's length. A change
anywhere below moves every root above it, carried by the dirty mark folders already keep
for their manifests, so an edit costs one fold per ancestor and not one per folder. Not on the
manifest, and this is the load-bearing part: the manifest is what a folder's children are
called, `ProjectFinder` and the converters are wired to it, and folding content in would
re-run all of them on every keystroke. The root is path-independent where the manifest is
not, so two copies of one tree are comparable wherever they stand. Since 2026-09-29 (B-77,
`docs/superpowers/specs/2026-09-29-semel-links-in-trees-design.md`) a symbolic link that
stays inside its own folder is a line of its own kind, `link`, holding its target framed by
its length — never what it names, which is folded where it is — for a file link (its
target on its metadata) and a folder link (on the folder's `symbolicLink` port) alike; the
format is `semel-folder-content-root 3`, and the disk fold reads links the same way through
the same lister. What remains:

1. **`output:` is opaque to the fold.** Every product's line says `notFolded`, so an
   `output:` folder's root identifies its names and not its content. The blocker is not the
   extra query — a product's bytes are one more join away, on its input wire — but
   invalidation: nothing notifies a folder when a product below it changes, so a folded
   product hash would go stale without the folder ever being rebuilt. Fixing it means giving
   `OutputFile` the notification `StaticFile` has. Wanted the day anyone syncs *products* to
   a peer, or checks an `output:` tree for consistency; neither B-06 nor the
   client/server reconciliation, both of which read `input:`, needs it.
2. **`notFolded` for a kind that is not a product.** The fold reads `Folder` and
   `StaticFile` and answers `notFolded` for every other kind under a folder. Today that is
   only `OutputFile`; a new kind of child would want its own answer rather than this one.
3. **The fold makes the object store grow on the per-edit path** — collected since B-14
   (2026-09-27): each fold still interns its document, a couple of hundred kilobytes for
   a folder of 3,000 children, but the collector removes every document no port refers to
   at idle, so the growth is bounded by the collection threshold rather than by edits ×
   depth. Related, and still open: during a flush a folder can publish an
   intermediate root and then the settled one, so now that B-06 wires a `contentRoot` consumer
   that consumer is woken twice for one edit — correct, because the flush drains before the
   pass selects, but twice.

**B-135** `done` `For Fable Only` — **A subtree demanded in one round: a folder's subtree
manifest.**
A cold build's converters walked their folders a level per pass (B-108's `**`, B-77's map:
the Swift converter's `targetSubfolders`, `LocalPackageSearch`, the Xcode converter's
synchronized folders), and every pass was expensive (B-124, B-125): a converter's run
re-applies its demands, and each write of a converter puts its builder's status and so the
finder back to pending, the finder re-reading every folder's manifest. Measured on
2026-09-28, the IceCubes app's seventeen converters ran 159 times; on 2026-09-30, 140 times,
beside 14 runs of a finder wired to 1,670 folders (`BACKLOG.md`, Performance).

*The design.* A `Folder` publishes a third derived value beside `manifest` (its own
children, by name) and `contentRoot` (what everything below it hashes to): a *subtree
manifest*, the names, kinds and pinned state — and a folder link's target — of everything
below it at every depth, and no content (`FolderSubtreeManifest`, kind 43, on a
`subtreeManifest` port). Its document is the folder's own children, each subfolder's entry
carrying the hash of that subfolder's own subtree manifest: a Merkle tree of names. So one
value stands for the whole tree, and moves when a name moves anywhere below it, while a fold
reads only the folder's children — the content root's cost, where a document holding the
whole tree would have cost the tree at every ancestor on every change. Like the root it
names no path, so the same tree at two places is one value. It is kept the way the root is
(B-25, B-26): a third dirty mark set with the other two on every child change, a refold in
the flush after the manifests, from the manifest just rebuilt and one query for the
subfolders' hashes, a subtree manifest that moved marking the folder above, and a read of
the port refolding a marked folder. It is demanded by `GraphSpecNode.folderTree(at:)`
beside `folderManifest(at:)` and read back by `FolderSubtreeManifest.folderManifests(at:)`
as exactly the manifests a walk gathered, by path, so no consumer's reasoning about what it
found changes. The stop rules stay the reader's: a reader is asked before it descends into a
subfolder, and nothing below one it declines — a catalog, an `.lproj` a package search does
not look into, a hidden folder — is read.

*What it costs to keep.* A change of names anywhere below a folder refolds each ancestor's
subtree manifest once, over that ancestor's children: the depth of the tree, never its size.
An edit to a file's bytes marks its folder like any child change, and the refold finds the
same names, writes nothing and marks nothing above, so an edit costs one fold and wakes
nothing wired to a tree. Each refold interns a document of one folder's children, collected
at idle as roots are (B-14). A flush that runs while a cold push is still arriving
refolds the folder being pushed into, as it rebuilds that folder's manifest and root; the
subtree manifest's fold is the cheapest of the three, a decode of the manifest just rebuilt
and one query, and does not show in a `sample` of the server beside the other two
(`BACKLOG.md`, Performance).

*Why it is worth it.* A walk becomes one demand and one pass, however deep: the converter's
target folders, the builder's `**`, the synchronized folders a package search looks into and
a finder's whole input file system each arrive whole on the pass after they are asked for.
The fewer passes a converter makes, the fewer times it re-applies its demands and wakes the
builder and the finder; and the finder reads one wire where it read 1,670. A node that needs
the files as well — a compiler's sources, a preprocessor's header folders, a catalog — asks
for the tree with the files it can already see and has every file on the wire the pass
after: two passes for any depth, where it took one per level and one more.

*The price in wake-ups.* A consumer of a tree is woken by a new name anywhere below its
folder, including inside a catalog it does not read and, for the builder, below a `*`
pattern that reads one level. It then produces what it produced, and nothing downstream
moves; a consumer that must not be woken by a name three folders down asks for a manifest,
as a compiler asks for its folder's.

*As built* (2026-09-30). `Folder` (the port, the mark, the fold; `Semel.version` 0.1.14,
whose rebuild folds every preserved folder's tree and drops the wires a preserved node holds
into ports its type no longer has). `SwiftFormulaConverter` v15: `targetFolders` asks for
each target's tree and `targetSubfolders` is gone; a binary target's `semel-artifacts` is
read from its package's tree rather than walked. `XcodeProjectConverter` v14: the targets'
folders and every synchronized folder as trees, `LocalPackageSearch` answered from the
latter. `ProjectBuilder` v5: one tree per pattern's folder on `folderTrees`, where
`folders` held a manifest per level. `ProjectFinder` v3: `inputTree`, one wire, where
`folderManifest` and `watchedFolders` walked `input:`. And the nodes that read files:
`SwiftCompiler` v3 (`inputFolderTrees` for `inputSubfolders`), `ClangPreprocessor` v6
(`headerFolderTrees` for `headerSubfolders`), `AssetCatalogCompiler` v3 (`catalogTrees`),
`FolderTreeBuilder` v4 (`folderTree`) and `XCFrameworkSliceSelector` v3, each asking for the
tree of the folder a formula hands it, its static port still that folder's manifest, so no
formula changes. `FolderTreeWalk` keeps what they share and the level-by-level walk is gone
from it. Pinned by `FolderSubtreeManifestTests` in the engine (read back at every depth, a
declined folder not read, a ghost, one value at two paths, an edit folding one tree and
moving none, a new name folding one per ancestor, two hundred files folding each tree once,
the finder woken by a name and not by an edit) and in `SemelNodeKit`, `VersionMarkerTests`,
`ProjectBuilderTests`, `SwiftFormulaConverterTests` (a target whose resources are three
folders down converted in the passes a flat one takes), `PackageResourcesTests`,
`XcodeProjectConverterTests`, `SwiftCompilerTests` (a flat target still compiles on its
second run), `ClangPreprocessorTests`, `AssetCatalogCompilerTests`, `FolderTreeBuilderTests`
and `XCFrameworkSliceSelectorTests`. What remains:

1. **A compiler could be handed its tree by the formula.** Its folder arrives as a manifest
   on a static port, so its first run can only ask for the tree; a formula naming
   `Folder(path:).subtreeManifest` would save that run. It changes every emitted formula and
   fixture for one pass per compiler, which the compilers already run side by side.
2. **The flush after a cold push is now the longest wait before anything runs.** Rebuilding
   the manifests and folding the content roots of every folder a push marked takes 15–20 s
   of the IceCubes app's release cold build, each fold a join over the folder's children for
   its pinned states, its links and modes and its contents. The subtree manifest reads the
   manifest instead of the rows; the content root could share the manifest's reads the same
   way.

### Cache

**B-11** `open` `For Fable Only` — **Probe determinism at write.**
Occasionally run a node twice before caching and compare. A node that is not reproducible is
marked never-cacheable. Fixes the problem at source rather than detecting symptoms forever,
and answers the question a shared cache most needs answered: which tools are safe to share.

The probe is the detector for the next nondeterministic tool, not the fix (2026-09-29, B-89):
a node's outputs are a function of its inputs, so a node whose tool is not makes its output
deterministic inside the node before it publishes, as `AssetCatalogCompiler` does actool's
`Assets.car`, or fails. What the probe finds is a node to fix that way; marking it
never-cacheable would leave its varying output crossing a port.

**B-12** `open` `For Fable Only` — **Sampled re-verification of cache entries.**
Re-run entries and compare against what is stored. Must run *twice*, because a single re-run
cannot distinguish a bad cache from a non-deterministic tool. Weight by `cost × reuse`
rather than uniformly — `CacheEntry` keeps `cost` but no reuse count yet. On a shared cache, have each client ignore a small percentage of hits
and recompute: coverage is sampling-rate × fleet-size.

Also the store's side of the same question (from B-116, 2026-09-27): `DataObjectStore.read`
re-hashes what it returns, but the reads that feed tools go through `project(hash:to:)`, a
clone that verifies nothing — so a damaged object is caught when exported or read as text
and not when compiled against. Hashing every projected input would cost a pass per input
per tool run (about 1 GB/s); a sampled verification of stored objects is where that belongs.

**B-15** `open` `For Fable Only` — **Cache abstraction behind a client interface.**
Make the engine talk to the cache as though it were a separate server, without a socket or a
separate process yet. Groundwork for the Cache Server role (B-30) that can be exercised
entirely in-process.

**B-147** `done` — **Whether a node is cached is declared by its type, not decided by the clock.**
`saveCacheForAllInputsAndOutputs` stored an entry only for a run that took at least 15 ms,
timed from the start of processing to the moment the engine wrote the result — so the
wait for the writer counted, and the same graph cached different nodes under different
load. The engine is a time-free zone (AGENTS.md); this was the one decision inside it made
on a duration. It made the tutorial's `LineCounter` uncacheable, and it made B-47's
end-to-end test flaky (PR #180): a compile woken with the key it had hit or reran
depending on how long its earlier run had taken.

Decided 2026-10-10: the floor goes, and `NodeDescriptor.cachesOutputs` (default `true`)
says whether a type's results are stored and looked up. A type that declares `false` takes
no key, looks nothing up and writes nothing, even where an older Semel left a row under its
key. A type opts out when its work costs about what a lookup and a write cost, and what it
computes is worth nothing to another machine; a tool node always caches. The duration is
still stored as the entry's `cost`, which decides nothing here and is what a remote cache
will weigh a fetch against.

Measured before deciding, debug build, one machine, cold settle then a settle after a
comment edit in one source and one after undoing it — first with the floor (main), then
with no floor and every type cached, then with the opt-outs below:

| | floor | all cached | opt-outs |
|---|---|---|---|
| IceCubes Packages cold | 48–60 s, 216 entries | 58 s, 258 | 58 s, 212 |
| edit / undo | 3.0–4.7 s / 1.2–1.7 s | 2.9 / 0.9 s | 3.0 / 1.1 s |
| NetNewsWire Mac cold | 112 s, 482 written | 114–131 s, 1,011 written | 129–135 s, 430 written |
| edit / undo | 11.8 / 2.2 s | 10.7–11.3 / 3.6–4.8 s | 10.5–21.0 / 2.0–6.5 s |
| NetNewsWire entries kept | 500 (19.6 MB) | 500 (2.6 MB) | 432 (28.6 MB) |

The wall times are inside the noise: one Swift compile in the edit settle varies from 9 to
15 s between runs, and the cheap types' processing on the NetNewsWire edit settle is
0.1 to 0.3 s for 430 nodes. The object store is the same in all three (an entry holds hashes, not
bytes). What moves is the entries. Per node, a run of each type that opts out costs 0.06
to 1.6 ms, and its key, lookup and write 0.6 to 1.4 ms together, so caching it saves
nothing; and on NetNewsWire everything-cached writes 1,011 entries into a cache trimmed to
500 by age, so half of what a cold build wrote is evicted, the preprocessors' entries
written first among it — the 500 kept hold 2.6 MB of the 28.6 MB written. With
the floor the same eviction already happened at random: 482 entries written, which of the
cheap ones depending on load. Per type, NetNewsWire Mac's cold settle:

- `TreeFile`: 213 runs, 0.5 ms each; 213 entries. Opts out.
- `OutputFile`: 213 runs, 0.06 ms each; 213 entries. Opts out.
- `TreeBuilder`: 47 runs, 1 ms each (at most 8 ms); 1.9 KB an entry. Opts out.
- `TreeMerger`: 43 runs, 1.5 ms each (at most 20 ms, the app bundle's merge). Opts out.
- `ConfigMerger`: 40 runs, 0.9 ms each. Opts out.
- `FolderTreeBuilder`: 16 runs, 1.3 ms each (at most 5 ms). Opts out.
- `ConfigFilter`: 9 runs, 0.8 ms each. Opts out.
- `ProjectFinder`, the converters (`SwiftFormulaConverter`, which holds the lock check,
  and `XcodeProjectConverter`): not declared. They wrote no entry before and write none
  now, because the engine stores nothing for a node with no static input port, whatever
  it declares; `ProjectFinder` takes 50–200 ms a run, so whether that rule is right is
  its own question.
- `LineCounter`: keeps the default. It is the reference a node author copies, and the
  tutorial now shows its hit on an undo.

No `implementationVersion` moves: no type publishes anything different. The tutorial's
counts in Parts 2 and 4 and the cleanup were walked through again. What this leaves: the
500-entry limit is now reached by NetNewsWire's Mac app alone (430 entries), so two
projects in one home evict each other's compiles; the limit wants to be a size, or a
weight by `cost`, rather than a count. Closed by B-148 (2026-10-10): the limit is a size,
and eviction weighs `cost` per byte.

**B-148** `done` — **The cache is limited by size, not by count.**
The process cache was trimmed to 500 entries, oldest first, after every write. An entry
holds hashes, so a count says nothing about the disk it keeps, and NetNewsWire's Mac app
alone writes 430: two projects in one home evicted each other's compiles.

Done 2026-10-10:

- **What an entry costs.** The bytes of the objects in the store it alone holds. Which
  objects an entry holds is the collector's reading (B-14), shared rather than copied:
  its outputs' values and error documents, followed through tree manifests and
  content-root documents (`objects(inOutputValues:)`, `markDocuments`). An object several
  entries hold counts once in the total and in no entry's own size; an object the input
  file system holds (a value on a `StaticFile`'s port) counts nowhere, so a build that
  passes a pushed file on costs nothing.
- **A running total, kept in the graph.** `CacheObject` holds each object an entry holds
  with its size and how many entries hold it, `CacheEntryObject` links the two, and
  `CacheAccount` keeps the total, the limit and the settle ordinals. Every save and delete
  moves the total in its own transaction, so a trim reads rows and never the store. What
  the input file system holds is recounted at idle, one pass over the sources' ports and
  one over the cache's objects, rather than asked per object at write, where no index on
  a port's value would answer it; a push between two idles leaves the total off by the
  objects it shares with an entry until the next.
- **The limit is the home's.** `cache limit <size>` stores it in the graph's database,
  typed (`ByteCount`), the `K`/`M`/`G` suffixes read at the prompt only; `cache limit`
  prints it; `cache` lists every entry with its size, its cost and its key, largest
  first, under the total and the limit, and what the last trim evicted. The default is
  10 GB (binary).
- **What goes.** The trim runs at idle, after the reports and before the collector, which
  is then run whether or not the store has grown, so the evicted bytes come back at once.
  `CacheEvictionPolicy`: an entry a node records as the key its outputs came from
  (`NodeCacheKey`, written with every output) is never evicted — its objects are on the
  node's ports, so evicting it gives back nothing and costs the build the next time those
  inputs return. The rest go in two tiers, what the last settle that used the cache did
  not use before what it did, and within a tier the lowest recorded cost per byte first,
  so the bytes that stay hold the most build time: a linker's or a signer's large output
  that took a moment goes before a module's compile. An entry's weight is what it alone
  holds plus its share of what it holds with entries no node stands on, so two builds
  that produced the same bytes can both go; an entry of no weight is never evicted. Order
  by last use alone was the alternative, and it is the case this item exists for: it
  evicts an expensive compile because another project was built since. Use is counted
  in settles (`lastUse`, a settle ordinal) where the entry had a timestamp, so the clock
  left the cache; the cost is still a duration, and AGENTS.md's time-free invariant names
  eviction as the second place time enters the engine, after the collector's age margin.
- `debug <key>` shows the entry's type, cost, last settle and its own bytes. Protocol 27.

Measured with debug binaries, one home, cold builds one after the other (the end-to-end
clones of NetNewsWire, IceCubes' app and CodeEdit, prepared as the roster prepares them):

| | entries | cache | cold build |
|---|---|---|---|
| NetNewsWire (Mac) | 430 | 112.9 MB | 97 s |
| IceCubes (app) | 258 | 246.0 MB | 78 s |
| CodeEdit | 222 | 379.3 MB | 101 s |
| the three | 910 | 738.2 MB | |

The home's whole object store, sources and vendored packages included, was 1.7 GB. 10 GB
holds the three together thirteen times over, so it stays: liberal, and still a bound a
laptop notices.

- **Keeping the total current** cost, over those 910 entries and their 1,742 objects,
  318 ms of store reads (a stat and the first bytes of each object) and 641 ms of database
  writes — about a millisecond an entry, beside 276 s of building. The idle step (close the
  settle, recount what the sources hold, compare with the limit) took 6 ms after
  NetNewsWire and 47–58 ms with all three in the graph, most of it the recount over every
  source's ports.
- **The trim**, on NetNewsWire's entries once `rm netnewswire-mac` had left no node standing
  on them: a limit of 700 MB evicted 5 entries (51.7 MB: two signers, two linkers, an
  XCFramework slice) in under 20 ms at the prompt, the request included; 600 MB evicted
  692 entries (64.7 MB, 341 of them preprocessors) in 0.24 s and left the cache at 625 MB,
  over the limit by what the other two projects' nodes stand on, which it said. `cache`
  over 465 entries answered in 10 ms.

Residual: the recount at idle grows with the input file system and runs after every
settle; it could run only after a settle a push started. A cache over its limit with
nothing evictable is said only by the trim that got it there and by `cache`. And the
`rm` above woke 842 of NetNewsWire's nodes, which ran over their removed inputs and wrote
252 entries of errors before the collector took the nodes: a removal settles its
downstream before it deletes it, which costs a settle and entries no build will hit.
Closed by B-149 (2026-10-10): the removal runs the finder alone and writes no entry.

**B-149** `done` — **A removal ran everything below what it removed.**
`rm netnewswire-mac` after a cold build re-ran 842 of the project's nodes over the inputs
it had just removed and wrote 252 entries into the process cache, and only then deleted
them. A removal should delete what is removed, give everything downstream the state its
inputs stand in without running anything, delete what nothing holds, and settle once.

Measured first, debug binaries, NetNewsWire's Mac app (the end-to-end clone with its
overlay, `prepare --platform macos`) built cold into a fresh home, then `rm netnewswire-mac`
and `wait`: 22.6 s, of which the request was 7.0 s and the settle 15.2 s (a second run,
split); 843 nodes scheduled, 842 computed, 1 from the cache; `process` entered 842 times —
71 preprocessors, 71 compiles, 37 `ibtool`s, 23 Swift compiles, 21 package readers, 14
string catalogs, 213 `TreeFile`s and 213 `OutputFile`s among them — and 252 entries written,
every one of them the state a removed input stood in, before the collector took 4,508
nodes at idle. Four causes, each fixed:

- **The finder waited for what it holds.** `ProjectFinder` holds a builder for every
  formula on a dynamic port and never reads what a builder publishes, but a node waits for
  every port: the removal's cascade set the builder `pending`, so the finder that would let
  go of the removed project ran last, once everything below the builder had run.
  `NodeDescriptor.holdingInputPorts` names such a port; the engine neither waits for it nor
  wakes the node when it changes, and the finder declares `projectBuilders`. It was woken
  on every settle that reached a builder, for 50 to 200 ms a run on NetNewsWire, and is now
  woken only by the listings it reads: the tutorial's edit and undo each count one node
  fewer.
- **What a write let go of waited for idle.** The collector ran between passes only, so a
  builder the finder dropped was deleted after its downstream had settled.
  `collectReleasedNodes` runs it after any write that left a node with no consumer, before
  the pass starts anything else; a node collected while it computes has its result
  dropped. A cold build collects nothing this way: on NetNewsWire no node is let go of
  before idle.
- **A node ran over an input it could not have.** Every tool met a removed source through
  `expectValue`, inside `process`, after whatever it did first. The engine now asks first
  (`stateStoppingProcess`): a wire on a static port carrying `deleted` or `inputInError`
  gives the node the state `NoValueReason.thrownByAConsumer` names, written without a run,
  a key or an entry, and counted neither computed nor from the cache. A port that tolerates
  an absent value, a dynamic port — which the node has to run to let go of — and a value
  nobody has produced yet still run, and so does a node below a failure's own document: it
  may have a failure of its own to say, and the tutorial's first build names the compiler's
  and the linker's missing settings beside the preprocessor's in one report. The state is `inputInError`, as
  the table has always said for a removed source, rather than `inputNotProduced`: that one
  says an input never had a value, which a removed source had, and a report folds both
  onto the source it names as `has been removed`.
- **The removal was a commit per write.** `rm` deleted file by file, each port write, mark
  and journal row a transaction of its own; it is one transaction with a savepoint per
  match, as a push is, and each pass of the collector is one with a savepoint per node.

Two more it turned up. A Swift compile whose folder lost a source read the removed file's
value before its walk, so it was stopped before it could let go of the file and held it for
good: `rm` of one source broke its module until a `reset`. `SwiftCompiler` (7) leaves a
removed file to the walk, which demands the folder's files without it. And error results
were cached without distinction. Decided: a node's own failure stays cached — a compile
error is a function of its inputs as much as an object file, and replaying it spares the
run — while a result made only of carried states (`inputInError`, `inputNotProduced`) and a
run whose key holds a removed source are not stored (`isWorthStoring`): the first costs
nothing to say again, and the second names a state of the input file system that the next
push or collection leaves.

After, same machine and method:

| NetNewsWire Mac | before | after |
|---|---|---|
| `rm netnewswire-mac`, request | 7.0 s | 1.5 s |
| its settle | 15.2 s | 3.5 s |
| nodes scheduled / computed / from cache | 843 / 842 / 1 | 10 / 1 / 0 |
| `process` entered | 842 | 2 (the finder, twice) |
| cache entries written | 252 | 0 |
| `rm` of one Swift source (`ErrorLogNotification.swift`) | 2.9 s; 462 computed, 12 entries; the module held the removed file | 2.8 s; 12 computed, 2 entries (its compile's own error, the builder); the module compiles without it |
| cold build | 94.5 s, 852 computed, 430 entries | 95.1 s, 852 computed, 430 entries |

The finder runs twice in the removal's settle: once when the folder is unpinned, which
drops the builder, and once when the collector has taken the folder's node and the root's
listing loses its name. What is left of the settle's 3.5 s is the collector's 4,508
deletions and the idle reports. `RemovalSettleTests` (SemelCore) and
`RemovalEndToEndTests` (the C fixture through `semelserv`) hold it.

**B-121** `done` — **A cache entry spells out its upstream tree, once per wire.**
A `ProcessCacheEntry` holds the node's `inputWireSpecs` so that a hit can apply them
without running the node — and each wire's spec is the fully expanded tree above it.
Measured on the IceCubes packages tree (2026-09-27, after B-115): the two entries of the
project builder's export output hold 31 of the database's 34 MB. The spec for one linker
output is a tree of some 20,000 nodes, in which the settings chain — `ConfigMerger`,
`ConfigFilter`, `Configuration` — appears 2,668 times and each source file's `StaticFile`
twice. The trees B-115 put in place of text made this 2.5 times larger than it was
(6.8 MB an entry to 15.5 MB), and gzip takes the 15.5 MB to 0.2 MB: it is repetition, not
information. The rest of the cache — 223 entries — is 2.7 MB.

Wanted: an entry that stores each distinct spec once. B-115 gives every spec node an
identity that is a pure function of its tree, so an entry can carry a table of nodes by
identity with each node's wires naming their sources by identity, and the demanded trees
as references into it — the same folding the identity column already does in the graph.
Decoding rebuilds the trees, or better, `applySpecs` learns to walk the table and never
rebuilds them. Not a change to the cache key, which is over values, so every entry keeps
hitting; a change to the entry's encoding, which is a new field or shape on
`ProcessCacheEntry` and so a miss for what older code wrote, as AGENTS.md says.

Done (2026-09-27): `GraphSpecTable` in `SemelNodeKit` folds the demanded trees into one row
per distinct node, keyed by the identity the graph stores (`NodeIdentity.hash`), each row
naming its wires' sources by identity and output port; the demands are references into it.
`ProcessCacheEntry.specTable` replaces `inputWireSpecs`, so every older entry misses once;
the key does not move. On the IceCubes packages tree: the largest entry 15.6 MB → 179 KB
(218 rows), the cache 34.0 MB → 4.2 MB, the compact database 36.1 MB → 6.2 MB; the five
archives byte-identical; after a `reset` the second build answers 157 of 180 nodes from the
cache, as before, in 32 s where it took 61. Design and particulars:
`docs/superpowers/specs/2026-09-27-semel-cache-entry-spec-table-design.md`. Residual: the
small entries grew from 2.9 to 3.8 MB together, a 64-character identity costing more than
the short tree it names.

Done (2026-09-28), the other residual: the applier walks the table. `GraphSpecTableApplier`
finds each node by the identity its row is filed under (`select(identity:)`, nothing
hashed) or makes it from the row — the row checked against its key with one one-level
hash, its wires' sources found or made depth first — and a hit hands the writer the stored
table (`AppliedOutput`) where it had unfolded trees. There is one applier: a run's output
is folded once as it is written and the same table is what its entry stores, and a tree
given to `findOrCreateMatchingNode` is folded and applied the same way. On the same tree
(177 nodes now), two runs each: the second build after a `reset` 32.7 and 29.8 s → 13.2 and
11.7 s, and the cold build 83.6 and 81.4 s → 70.1 and 65.9 s, since a run's demands were
hashed level by level too; the archives byte-identical. Section "The table applier" in the
design above.

### Server

**B-30** `open` `For Fable Only` — **`semelserv` with three roles.**
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
   resync from the snapshot table for a client beyond it. None of that is built yet:
   `subscribe` takes no argument, and `ConnectionRegistry` delivers every event to every
   subscriber. What remains of B-30 is roles 1 and 2, the `.cache` and `.runner` roles a
   hello is refused today, and role 3's per-subscriber narrowing.

**B-137** `done` — **A reply too large for one frame was refused.**
Done 2026-10-01. Found when the owner removed a large tree with `rm` and was answered
`replyTooLarge`: a frame's JSON section is capped at 1 MiB, the cap is checked on the
declared length before anything is allocated and is not a number to raise, and `remove`,
`list` and `errors` carry the graph in their JSON. The decision: replies of unbounded size
stream — not a bigger limit, and not a move to the body, so that a reply's size is bounded
by nothing and a long operation shows progress as it runs. Flag bit 0 of the frame header,
reserved since the first design, now means "more frames follow for this correlation ID"
(`Frame.continues`, framing version 2, message set version 23). A streamed reply is the same
response case repeated, every frame but the last carrying the bit, and the lists of the
parts concatenate; no wrapper type, and the last may be empty or an error. The server's
`RequestHandler.handle` takes a `ReplyStream` per request; `ReplySlicer` measures each item's
encoded size — an error record's message has no bound, so a count per item would be unsafe —
and sends a part when the next item would pass the cap less a kilobyte for the envelope, so
a reply that fits one frame is the frame it was. `remove` streams as it deletes; `list` as it
reads its matches; `errors` once its report is folded. `SemelConnection.send(_:body:)` joins
the parts into one reply for every caller that wants the whole, and
`send(_:body:onPart:)` hands each part over as it arrives, which `rm` uses to count with
bounded memory and to say how far it has got. A connection that closes mid-stream reports
the reply as truncated, naming how many parts came (`IncomingReply`, `ReplyStreamError`).
`replyTooLarge` remains for one item larger than a frame and for a single-frame reply that
outgrows one.

### Command line

**B-136** `done` — **The base is remembered across launches.**
Done 2026-10-01: `base <path>` sets the session's base and writes it to `semel.base` in
the Semel home — a heading comment, then one `base <absolute path>` line, read strictly
(`RememberedBase`, in `SemelCLI`: only the prompt reads it). `semel` starts from it while
the directory exists, and the banner says so under the graph's line: `Base: /repo
(remembered)`, or `Base: /cwd`. A remembered directory that is gone, or a file that does
not read, is reported on one line and passed over, the file left as it is. `base --forget`
removes the file and keeps the session's base. A scripted run starts from it too; its own
`base` overrides and is remembered, and `base .` is how a script asks for where it runs.
`semel-watch` and `semel-swift prepare` take their directory as an argument and never
read it.

**B-126** `open` — **A file watcher that pushes as you save.**
Designed 2026-09-28: `docs/superpowers/specs/2026-09-28-semel-file-watcher-design.md`.
`semel-watch <base> [<folder> ...]`, a fourth client of `semelserv` in its own executable
target, observes a tree with FSEvents and runs the commands a person runs, in process
through `SemelCLI`: after two quiet seconds, one batch of `push` for every changed path
that exists and `rm` for every one that does not, then `commit`, so a save is a settle and
a `git checkout` is one batch. The prompt starts one with `watch <folder>` — `watch` alone
keeps B-95's meaning — and `unwatch` or `quit` stops it. What it watches is what a push would push (the lister's
rule), narrowed by `--only` and `--except` spelled as the for-each spells items (B-123),
with the export destination and `semel-out` always excepted so an export never becomes a
push. Starts with one batch mirroring the tree; `--into` exports after each clean settle as `build`
does. The stream and the disk are behind protocols, so the filter, the coalescer and the
batch planner are tested with hand-fed events. Left out of the first version: a rule file,
Linux, and reacting to what the settle built. Deletions made while no watcher ran are not
a push's to make — a push only adds, and a removal is an `rm` (decided 2026-10-04) — so the
watcher makes them itself, with `rm`, in its initial batch (1 below).

Shipped 2026-10-01, as designed, with the differences in the design's "As built": the
`SemelWatch` library (`WatchFilter`, `ChangeCoalescer`, `BatchPlanner`, `FileEvents`,
`Watcher`, `WatchConfiguration`), the `semel-watch` executable with its FSEvents adapter,
and `watch <folder>` / `unwatch` / `quit` at the prompt behind a `WatcherLauncher`. The
watcher follows the formula's inputs as `build` does and watches what the follow pushed;
a dot-named file is pushed only when the graph holds it or an `--only` names it exactly.
The end-to-end run (`WatchEndToEndTests`, the C fixture) measures 2.2 s from a save on
disk to the settle summary, two of them the quiet interval. What remains — the first
version's "not in it", the first done and the rest open:

1. ~~**Deletions the initial push cannot see.**~~ Done (2026-10-04), and decided: a push
   only adds — `push <folder>` and `build` never subtract, a removal is an explicit `rm`,
   and removals that must land with pushes are wrapped in `begin` … `commit` — so there
   is no "same fix for `build`". The watcher mirrors with `rm`: its initial push is an
   initial batch, `begin`, one `rm` of every path `input:` holds below a watched folder
   and the disk lacks, the push of each watched folder, `commit` — one settle. What it
   compares is what a push would push (the lister's rule, `--only`/`--except`, a dot-name
   when the graph holds it); a held path the filter excepts is kept and counted on the
   launch line, and nothing outside the watched folders is touched. A reconnection
   mirrors the same way. `--no-initial` skips the batch.
2. **A rule file.** The flags are the rule; reconsidered when a second project needs the
   same flags.
3. **Linux.** `inotify` is a second conformance of `FileEvents`, when Semel runs there.
4. **Watching the engine's side.** The watcher pushes; it does not run or restart what an
   export replaced. That is a runner, a different program.
5. **Sources behind a link out of the tree.** A push follows a link to a folder outside
   the base; FSEvents reports changes under the watched path only, so a save behind such
   a link reaches the graph at the next push of its folder, not at the save.
6. **The prompt's first report of a followed source.** A watcher the prompt started
   leaves the reports to the prompt's subscription, which is not held as `build` holds
   them: a formula's input outside the watched folder is reported missing once, then
   followed and settled again.

**B-95** `open` `For Fable Only` — **Build progress: a line at the prompt.**
Shipped: a `progress` event from the engine — the settle tally's running totals, the
pending count, the nodes computing now by type and name — drawn by the client as one
line redrawn in place while it is blocked in `wait`, `build` or the `commit` that ends a
batch, erased before the command prints. On at a terminal unless `SEMEL_PROGRESS=0`,
never into a pipe. Design and particulars:
`docs/superpowers/specs/2026-09-27-semel-build-progress-design.md`. What remains:

1. ~~**The dashboard**~~ — done 2026-09-28: `SEMEL_PROGRESS=full` draws the line and
   under it one line per running node — type, name cut from the left to fit, elapsed
   time stamped by the client from the first record naming the node — erasing every
   row it drew before each redraw, in one write, and capped at the terminal's height
   less two with an `and N more`; see the design's "As built". Item 3 remains.
2. ~~**A `watch` verb**~~ — done 2026-09-28: `watch` shows the line until a key is
   pressed, which leaves the settle running and says where it stood, or until the settle
   ends, which prints as a `wait` would; see the design's "As built".
3. **A status line at an idle prompt**, as `cargo` and `ninja` draw above nothing. The
   prompt is `readLine()` with no line editor, so this needs the client to own its input
   line — raw mode, cursor save and restore, a width to track — a project of its own.

**B-91** `done` — **The engine says what a settle did, not why.**
Done 2026-09-27 (design and "As built" notes:
`docs/superpowers/specs/2026-09-27-semel-explain-design.md`): the engine keeps the last
settle's record in memory — per node, whether it ran or the cache answered it, and per
wire that woke it, whether the value it brought differed from the one the port held when
the settle began — and `explain <path>` (`why`) walks upstream from a node through that
record and draws what ran, what the cache answered and which wires changed, down to the
pushed files. The tutorial's fourth experiment quotes it. A restart forgets the record,
and `explain` says so. The problem as it was filed:
`DaemonMessages` carry what was published, what failed, one settle's totals — scheduled,
computed, from cache, errors — and the artifact diff. What the engine knows about *why* —
which wire changed, which nodes ran and which came from the cache, node by node — leaves
through `Debug.log`, and a release build compiles that out. The per-node record half
exists: `SettleTally` keeps the ids of the nodes it computed and the ones it answered from
the cache, and throws them away at every settle once the totals are taken. What remains is
keeping that record and an `explain <product>` (or `why`) command that walks upstream from
a product to the wires whose values changed since the last settle and names them, reading
the same record. The totals say that four of ten nodes ran; only the record says which four.

**B-142** `done` — **Every error names the products it stops.**
Asked for 2026-10-09 by the owner: an error belongs to one node, and the person wants to
know which built artifacts that node keeps from being built.
Done 2026-10-09. `ProductReach` (SemelCore) walks the wires down from a failing node to
every `OutputFile` it reaches, memoised per node for the life of one report, so a cascade
of errors under one product walks the shared graph once; `nodeVisits` counts the nodes
entered. It stops at an `OutputFile`, which is the product, and at a `ProjectBuilder`:
reached through its `trees` port it is that tree product, by folder, since a tree that
failed has no manifest and so no entries; reached any other way — the formula file, an
include — it is every product the formula holds. An entry of a tree product (B-63) is
named with its tree's folder, read off the `TreeFile` on its input. A product that holds a
value is not stopped and is left out: a settings source nobody pushed that a merge reads
as nothing to add is reported, every product is downstream of it, and on IceCubes all five
archives were built regardless. `ErrorReport.namingProducts` fills `Entry.products` after
the fold, once per report, for the `errors` verb and the idle-time report alike; the
settle's error count, the same fold, walks nothing. `ErrorRecord.products` carries them,
non-optional, as `StoppedProduct`s (`path`, `treeFolder`), protocol version 24.
`errors [<product>]` takes a product as `cp` takes a path — `output:/…`, `-o`, or relative
to the current directory — or a tree product's folder, which matches every entry below
it, and the server filters (`DaemonRequest.errors(product:)`), the reply still streaming
(B-137); a product with no errors says `No errors stop <product>.`, and a path no product
stands at is `ErrorResponse.notAProduct` naming it (`ProductReach.isProduct`: an
`OutputFile` there, or a builder's `trees` wire of that name). The client's report
(`ErrorGroupRenderer`) heads each product's errors with `Stopping <product>:`, in path
order, a tree product as `<folder>/ (<entries>)`, then `Stopping no product:`; a record's
own lines are as they were. An error under several products is printed in full under the
first and as one line, `❌ <label> — see <first product>`, under each other: a base
package's failure stops all five IceCubes roots, and its paragraph five times over is the
same one fix at five times the length. The idle-time report after a settle and `build`'s
report go through the same renderer; `build` and `semel-watch`, refusing an export, say
`Not exported into <dir>: errors stop <products>.` (capped at twenty, with the count of
the rest), or that none of the errors stops a product. Measured on IceCubes' Packages
(2,677 nodes, 3,925 wires, a debug `semelserv`): a type error in `Models` folds 22
carriers under one compiler and the walk enters 23 nodes in 2.8 ms; a missing compiler
setting fails ten compilers whose walks share most of the graph, 36 nodes in 4.3 ms; the
widest, the machine file removed above every tool, enters all 179 build nodes in 17 ms.
Nothing is capped. `ProductReachTests` hold a node feeding two products, one feeding none,
a built product left out, a tree's entries and a tree with none, a builder's products and
the memo's visit count over a twenty-error cascade; `RequestHandlerTests` and
`ServerTests` the records, the filter and the refusal, over the socket too;
`EnginePluginTests` the grouped report, `errors <product>` and the export line;
`BuildCommandTests` and `WatcherTests` that line under a failed build and settle.

**B-145** `done` — **The error report is a timeless statement of what has no value, and why.**
Designed 2026-10-09 (`docs/superpowers/specs/2026-10-09-semel-error-report-design.md`, with
an "As built" addendum), done 2026-10-10. A failing node publishes an `ErrorDocument`
(SemelNodeKit, kind 44), interned and carried by `NoValueReason.error(documentHash:)`: the
`diagnostic` — `.tool(text:tool:)` as the tool wrote it, or `.engine(ErrorCondition)` —
`subject` (`target`, `product`, `package`, `resource`, `formula`, `project`, `source`) and
an optional `remedy`. `ErrorCondition` holds every engine condition that reaches a report,
each case with the values its sentence needs; `NodeError.other(message:)` is gone, every
site naming its case, and the typed errors of the engine, the converters and the Apple
nodes map to a condition (`ErrorConditionConvertible`) at the node that meets them. A node
names what its failure belongs to (`Node.errorSubject(input:)`); helpers build a document
from a tool's result (`failureDocument`, `asOutputNodeValue(tool:subject:)`), a condition
(`ErrorDocument.engine`) or several causes (`ErrorDocument.several`), so no node writes a
sentence. `SettingArgument` names the keys behind an argument a tool rejected, as the
remedy, where it appended advice. The engine renders nothing: `ErrorReport` gathers
documents, its default reporter is silent, and its error count is per cause, merged as the
client merges blocks (`ErrorDocument.mergeKey`). `ErrorRecord` carries the document, the
products from B-142 and the node's facts (`ErrorFacts`: type, ids, ports, carriers), one
record per document; `SemelProtocol` depends on `SemelNodeKit`, protocol version 26 (25 is
B-146's); `LockExpectation` moves to `SemelNodeKit` and its unreadable case carries the
typed `LockProblem`, so the lock barrier's refusal is `ErrorCondition.batchRejected` with
`lock:`, `expected:`, `found:`, `paths:` and `re-lock with:`, and `BatchRejectionRenderer`
goes. `Semel.version` 0.1.16, since a stored error port's hash named a sentence. Every node
type that processes and can fail bumps its `implementationVersion` (twenty-five, listed in
the pull request). The client draws every line (`ErrorReportRenderer`, `ConditionLines`),
and the report leads with products (the owner's decision, 2026-10-10): one heading per set
of products that share the same errors — `IceCubesApp.app:`, `libConversations.a,
libExplore.a, libLists.a and 2 more:` — three named by file name, the path under `output:`
only for two of one name, in path order of each heading's first product; under it each
error in full, in line-one order, or, printed under an earlier heading, its first line and
`(above)`; errors no product needs last, under `no product:`. A block is line one, the
diagnostic, `input:/` written as the path below the base; then the subject; then the remedy
(`re-lock with:`, `missing:`, `set:`, `register:`, `write with:`, `vendor with:`,
`delete:`). Causes come once each, two documents differing only in which subject of one
kind merging into one block; carriers are never listed. The summary line ends the report —
`1 error · 5 products without a value`, and after an export `· nothing exported`, `·
exported to <dir>` or `· 3 of 5 products exported`: `build --into` and the watcher's
`--into` export what has a value. `errors <product>` is that product's heading and errors
alone, or `<name> has a value.`; `--verbose` on `errors`, `build` and `watch` adds the
node, its ports and its carriers; colour at a terminal unless `NO_COLOR`. `ErrorDocumentTests`,
`ErrorRenderingTests` (a test per condition and per subject), `EnginePluginTests`,
`BuildCommandTests`, `SettleTimeErrorCountingTests`, `WatcherTests` and
`ErrorReportEndToEndTests` (the C fixture with an `#error`, line for line) pin it.

### Formula language

**B-108** `open` — **Formula preludes: built-in functions a plugin provides — residuals.**
Done 2026-09-25 (design and "As built" notes:
`docs/superpowers/specs/2026-09-25-semel-formula-preludes-design.md`): plugins intercept
include names through `FormulaIncludeProviders`; `include 'clang'` wires a `FormulaPrelude`
node the engine fills when it is created and at every start; func bodies are lexically
scoped with every parameter bound and usable in templates; dotted calls reach a prelude's
funcs under its namespace. `clang`, `swift` and `apple` preludes exist, and the `c`,
`tutorial` and `HelloApp` fixtures use them. What remains:

1. **Nested source folders** — done 2026-09-28. Folder patterns matched one level, so
   `sources: <src>` found `src/*.c` and not `src/lib/*.c`. A pattern is now matched segment
   by segment below the folder it names (`WildcardPath` in `SemelNodeKit`): `*` and `?` stay
   inside one name, and a `**` segment matches zero or more folders, so `<src/**/*.c>` is
   every `.c` at any depth under `src`, `src` included, and `<src/**>` every file under it.
   `ProjectBuilder` demands, on its `folders` port, each subfolder a pattern can reach —
   walked from the pattern's folder down with `FolderTreeWalk`, one level per pass, never
   into a hidden folder — and publishes no products until every one has arrived, so a
   linker never sees half a tree; expansions are sorted. (Since 2026-09-30 the pattern's
   folder is asked for as one tree, on `folderTrees`, and read down on the pass it
   arrives: B-135.) `except` goes through the same
   expander. A capture after a `**` reads the file's own name (it read the folder the `**`
   took), and the REPL's `**` means the same, a trailing one included. The `clang`
   prelude's `sources:` is read as `**/*.c`, `**/*.cpp`; objects are named by the source's
   full path, so a nested file's object carries its subpath and the flat fixtures build the
   nodes they built (`ClangPreludeTests`). Tried by hand on the `c` fixture with two
   sources moved to `src/lib/` and `src/lib/deep/`: all four hermeticity builds passed.
   The same try found a gap next door: `ClangIncludeFinder` joined a quoted include to the
   source's folder without resolving `..`, so `#include "../hello.h"` from `src/lib/`
   named `src/lib/../hello.h`, which is never a node, and the preprocessor failed. Fixed
   2026-09-28: the joined path goes through `Path.resolvingDotSegments`, and an include
   that climbs above `input:` is left out for clang to report (finder version 3).
2. **An app bundle as one product** — done 2026-09-28. `TreeBuilder` wrote every entry
   with the default mode, so an executable in a tree lost the bit that lets it launch, and
   HelloApp spelled its bundle as four products. A tree entry now carries the mode of the
   file it came from, read from a second wire: a node type names, on its descriptor, the
   port that carries the modes of the files on another (`fileMetadataInputPorts`,
   `input` → `fileMetadata` on `TreeBuilder` and `OutputFile`), and the spec is given one
   mode wire per file whose source publishes `fileMetadata` and is read at `output`
   (`GraphSpecNode.wiringFileMetadata()`, called by the formula resolver on every node it
   builds and by `ProjectBuilder` on each product). A wire and not a read of the source at
   process time, because the mode is then in the cache key and wakes the node like the
   bytes do; filled where the spec is built and not in the formula, because a func cannot
   pick a port off a value it was handed. `StaticFile` publishes the mode it was pushed
   with (push carried it and dropped it), so `FolderTreeBuilder` demands each file's mode
   beside its bytes (version 2) and a pushed file kept as a product keeps its mode
   (`Semel.version` 0.1.12, whose rebuild gives every preserved file the row). Export
   already applied an entry's mode through `TreeFile` and `OutputFile`. `apple.bundle(
   executable:, name:, infoPlist:, pkgInfo:, resources:)` merges a `TreeBuilder` over the
   single files with the resources tree, and HelloApp is one `product 'Hello.app/'`:
   byte-identical exports, `Hello.app/Hello` still 0755, which the harness now checks
   (`Project.executables`).
3. **An Xcode project's bundle as one product.** `XcodeFormulaEmitter` still writes a
   target's bundle as several products: the executable, the Info.plist and each plain
   resource on their own, the compiled resources as a tree, and an embedded extension as
   products under the app's `PlugIns/`. One tree is now possible — a `TreeBuilder` over the
   single files at their layout paths, the trees merged `under` `Contents/Resources` on
   macOS, each extension's tree merged `under` its `PlugIns/` path — but it rewrites most
   of the emitter's product text and its tests, and only the external IceCubes build
   proves it, so it was not folded into residual 2.

**B-123** `done` — **A for-each that says `except`.**
The for-each takes literal paths and wildcard patterns and nothing else, so "every `.c`
in this folder except the mains and the tests" can only be said by enumeration. Lua's
formula (`EndToEnd/Fixtures/external/lua/lua.fmla`, B-79) names its 32 library sources
one by one to leave out `lua.c`, `onelua.c` and `ltests.c` — faithful to Lua's own
makefile, which lists every object too, but every hand-written C formula will meet the
same case: fmt and simdjson keep tests and benchmarks beside the library, and a `test_*.c`
convention wants a negative pattern, not a positive list. Enumeration also fails
quietly the other way: a file added upstream is not compiled, where a glob would have
picked it up and a second main would have failed at link time, out loud.

Wanted: an `except` clause on the item list, taking the same literal-or-pattern items,
subtracted after wildcard expansion:

    {f: <*.c> except <lua.c>, <onelua.c>, <ltests.c>} "%%f%%.o": clang.compiled(file: f, settings: settings())

`forEachPrefix = '{' IDENT ':' items ('except' items)? '}'` in `FormulaParser`; the
resolver expands both lists through its `wildcardExpander` and removes the second set
from the first; a subtraction that leaves nothing is an error, as an empty item list is
(`forEachRequiresAtLeastOneItem`).
The enumerated form stays valid for the author who wants the makefile's exactness. The
Lua formula is rewritten with it in the same change, so the roster exercises it.

Done (2026-09-27), as specified: `except` is a keyword only after an item and before
another, so a func, parameter or wire of that name still parses. `WireDictEntry.forEach`
carries the `excluded` items; the resolver expands them through the same expander and
removes their paths from the items' expansion. The error is for an `except` that removes
every item it matched (`forEachExceptLeavesNothing`, naming them), not for an empty
result: the builder's first pass, before any folder manifest has arrived, expands every
pattern to nothing. An `except` item that matches nothing is silent, for the same reason
and because a project may keep an exclusion after upstream deletes the file.
`lua.fmla` says `<*.c> except <lua.c>, <onelua.c>, <ltests.c>`, and `liblua.a` and `lua`
came out byte-identical to the enumerated formula's.

### Configuration

**B-109** `open` — **Configuration: the machine's half and the project's half — residuals.**
Shipped: the configuration is two files. `semel.machine.config` holds the tool descriptors
and the machine settings each plugin declares (`ToolNamespace.machineSettingKeys`, answered
per `Platform`), written outside Semel by the toolchain's own tool (B-119) — `semel-clang`
for the clang namespaces, and `semel-swift prepare` for a Swift tree, each its own part of
one file (residual 5) — through one writer, `SemelMachineFile`; it is in `.gitignore`.
Each writes only the namespaces its formula selects (2026-09-28 for `semel-clang`: the
formulas below its folder that name the file, all four clang namespaces when none does),
read by `MachineFile.namespaces(selectedIn:)`, which follows a prelude func by func from
the calls a formula makes — `clang.executable` reaches no archiver — so a project that
archives nothing is not told on every build that the archiver's keys are unused. `semel.config` holds the project's choices, typed
once or written by prepare with the C standard under a comment naming it a choice, and
checked in. Every prelude func takes `settings` as a node and provides
`settings(project:machine:)`; `Configuration`'s port is `base` (`Semel.version` 0.1.7); the
unused-key report follows a file through mergers to its filters; the C fixtures commit a
project file each, the harness writes the machine file where it rendered the template, and
the tutorial's config section is `build`, `semel-clang`, `build`. Design:
`docs/superpowers/specs/2026-09-26-semel-configuration-two-files-design.md`. What remains:

1. **This repository's own `semel.config`** — done (2026-09-27, with B-78's self-build):
   the project's half only, two targets; `semel-swift prepare <checkout> --platform
   macos` writes the machine file, and the README says so. `SelfBuildConfigTests` now
   fails on a machine key in the project file, since the one it carried (`sdkVersion`,
   pinned to one SDK build) is what would have failed the self-build on any other
   machine.
2. **`target` split into its parts** (the spec's *Later*): a tool that took a platform and a
   deployment version and composed the triple with its own architecture would let the
   project file say nothing about the machine at all.
3. **One machine file for several platforms.** `--platform` on `semel-clang` and on
   `semel-swift prepare` is one platform per write; a project building for the simulator
   and for macOS wants both blocks, and the writers' answer — several flags, or every SDK
   the machine has — waits for the first project that needs two.
4. **The missing-source line when the file is not there** — done (2026-09-28). A plugin
   registers a typed `MachineFileWriter` per namespace (`command`, and the `rewriteFlags`
   that replace what it wrote: `--force` for `semel-clang`, none for `prepare`), where it
   registered a command line with a `<folder>` in it. The report of an unpushed
   `semel.machine.config` walks down from the file through the `ConfigMerger`s to the
   `ConfigFilter`s it feeds, looks up the writer of each prefix, and carries them typed on
   the item (`ErrorReport.SourceWriter`, `ErrorEntry.writers` on the wire, protocol 18),
   each with the file's folder relative to the base; both renderers write one line under
   the file's — `run semel-clang . to write it`, `… and semel-swift prepare . …` when both
   toolchains read it. A file of another name gets none: a writer writes that one file.
   `missingSource` is untouched, so `build` still follows the file once it is on disk.
5. **Two toolchains, one machine file** — done (2026-09-28). The file is one section per
   writer, each under the header it always had (`// Written by <writer> for --platform …`);
   `MachineFile.merging` reads the sections back, replaces the writer's own whole, takes
   the namespaces it writes out of the others (a namespace is written once), keeps the
   rest in place, and says what it did — `Added clang.compiler, … to <file>; kept
   swift.compiler, swift.linker from semel-swift prepare`. `semel-clang` leaves a file
   that holds every namespace its formulas select and nothing of its own they no longer
   do (so a formula selecting fewer is rewritten without `--force`, which is left for a
   toolchain update); `prepare` rewrites its part every run and prints what it kept. No
   fixture includes both `clang` and `swift`, so the proof is `ClangMachineFileTests` and
   `PrepareTests`, not an end-to-end run.
6. **A stale file names its fix** — done (2026-09-28). `ToolRunnerRegistry.tool` takes the
   node's namespace, and `ToolError.noMatchingToolFound` carries it with its writer: the
   message adds `clang.compiler.toolDescriptor.* names it; when that is
   semel.machine.config, written before the toolchain changed, 'semel-clang <folder>
   --force' rewrites it`. The file is not named for certain: the settings arrive merged,
   and a project file may pin a toolchain on purpose.

**B-120** `done` — **`Configuration` merges; only `ConfigMerger` should.**
`Configuration` is two things in one node: the way to put settings inline in a formula, as
its properties, and a merge of those properties over whatever arrives on its optional
`base` port. The second half is `ConfigMerger`'s job, with the same precedence — the
override wins — but weaker rules: `base` is optional, several wires on it merge in sorted
key order with no stated precedence, and an absent value is silently nothing. That is the
ambiguity `ConfigMerger`'s own comment says it exists to remove, so the graph has two merge
semantics, one explicit and one implicit. Decided 2026-09-27: keep a literal node, drop its
merging.

1. **`Configuration` becomes a pure source**: properties in, plain text out, no input port.
   Layering is always spelled out, in every prelude helper and in the converters and the
   Xcode emitter that render these nodes:

       ConfigMerger(base: [selected(settings, prefix)], override: [Configuration(moduleName: name)])

   One node more per module — about 15 on IceCubes' 2,630 — and one merge in one place.
2. **A name that says what it now is.** `Configuration` reads as *the* configuration; the
   node is some literal settings. Rename with the change, pre-v1, no shim.
3. **One wire per port.** All three settings nodes still merge several wires on one port in
   sorted key order. Make two wires on a port an error, so `ConfigMerger` is the only place
   in the graph where two sets of settings ever meet.

Not dropping the node altogether: the literals need a home. Every prelude uses them for
per-module facts — module name, output name, linkage, app icon — and the alternatives are
worse. Properties on the tool node itself would have each tool merge them over its
configuration port, moving the merge into every tool; a file per module defeats the point
of inline settings.

Done (2026-09-28), as decided. The node is `SettingsLiteral` — kind 9 kept — "some literal
settings", as a string literal is some literal text, where `Settings` alone would read as
*the* settings again and `InlineSettings` names where it is written rather than what it
is. It declares no input port and publishes its properties in `didCreate`, as
`FormulaPrelude` publishes its text: a source is never scheduled, and nothing it depends on
can change, since the properties are its identity. Having no static input port it is not
stamped with `projectRoot` either, so equal literals in two projects are one node. Every
place that wrote `Configuration(<literals>, base: [<selector>])` writes
`ConfigMerger(base: ['settings': <selector>], override: ['literals':
SettingsLiteral(<literals>).output])`, and with no literals the selector alone —
`GraphSpecNode.literals(_:over:)` is the tree for both, and `SettingsNodes` names the two
wires so the converters' text and the tree agree. A second wire on `ConfigFilter.input`,
`ConfigMerger.base` or `ConfigMerger.override` is `NodeError.severalWiresOnOneWirePort`,
naming the port and the wires, read through one `ProcessInput.settings(onPort:)` both
nodes share; no fixture or converter wired two. Bumped: `SwiftFormulaConverter` and
`XcodeProjectConverter` to 3 (they emit the new name and shape), `ConfigFilter` and
`ConfigMerger` to 2 (a two-wire entry the older code wrote holds a merge they now refuse),
and `Semel.version` to 0.1.10 for the reason 0.1.7 was: a stored literal node holds a wire
into a port its type no longer declares. The unused-key walk no longer passes through the
literal, which nothing flows through any more.

### Design, correctness and code quality

**B-43** `open` `For Fable Only` — **Formalise the nodes that break the dataflow rule, instead of leaving them
as back doors.**
A node's outputs are supposed to be a function of its inputs. Two types are not, and neither
says so — they simply reach around the model, which makes the exception look like an
oversight rather than a part of the architecture. A third, `OutputFile`, was, and is not any
more (below).

They break *different* rules, and one concept will not cover both.

*`StaticFile` — genuinely external.* No input ports, yet its output value arrives: the push
path writes its output port from outside. Same for user intent, "pinned" versus deleted.
B-108's `FormulaPrelude` is the same shape on purpose — a source the engine fills from what
the plugins provide — and is the case to design against alongside `StaticFile`. Candidate
fix: a fourth port kind, `.external(name)`, filled by the runtime rather than by a wire.
Purity then becomes universal — every node's output is a function of its declared input
ports, and what varies is only who fills them. `HermeticityTests` (B-02) enforce the part
that can be scanned for — no node launches a process or reads the environment — but not the
rule itself, which cannot be stated while these types' outputs arrive from outside by
design. An external port kind is what would let it be.

*`Folder.manifest` and `Folder.contentRoot` — not external at all.* Both are projections of
the graph itself: the set of child nodes with each child's pinned state, and the fold of
what they hold, read straight from the database. `onChildAdded`/`onChildContentChanged`/
`onChildDeleted` mark the folder dirty, and `Folder.flushDirtyManifests()` rebuilds both at
the start of each processing pass. The dependency is the parent-child
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

*A correction to our own comment.* `Folder`'s pinned port is called a "fake" output, and the
code that writes it is marked HACK, for storing state in an output. That is too harsh. Putting the state in an output port is what keeps it
inside the dataflow model: it can be wired, downstream nodes can see it, and it lands in cache
keys. A private state field would be invisible to all three. The fix is to declare what that
output means, not to invent a state slot beside the ports.

*A node whose type is gone keeps the rule (B-130).* A row of a kind the server no longer
links cannot run, and when woken publishes an error naming its kind on the ports it holds —
a function of its row, as a node whose `process` always throws is — so its readers carry it
and the report names it, rather than the push that woke it failing or the server refusing
the graph at launch. What it leans on: the collector deletes such a node once nothing reads
it without asking its type whether to keep it, because what `canBeDeleted` keeps is user
intent, and only the engine's own `StaticFile` and `Folder`, always linked, hold any. If an
external port kind lets a plugin declare a source of its own, a plugin's node could be held
by user intent too, and that has to be readable from the row — a pin on a port, as
`Folder`'s is — not asked of a type that may be gone.

*Cost to know before starting.* If either external inputs or structural dependencies become
declared, `StaticFile` and `Folder` become nodes the engine schedules and processes — which is
arguably more correct, since a push *is* an event that should run the node. But
`descriptor.hasInputs` is now the single answer to "does the graph process this node"
(`3a0d68e`), load-bearing at eight sites and pinned by `SourceNodeSchedulingTests`. The
distinction would have to become "wired inputs" rather than "inputs".

**B-44** `open` — **Naming: what is left after the 2026-09-12 sweep.**
Done: the `Tool` suffix is gone from the tool nodes, `ConfigSubset` is `ConfigFilter`,
`GraphShape` is `GraphSpec`, "expectation" is "spec" everywhere, and `searchKey` is
`graphSpec` (column included — an older database fails the B-29 schema check and has to be
deleted). The glossary and the naming rule live in `AGENTS.md`; the rename cost data moved
there too.

*Still open.* The config vocabulary — the configuration text format
(`ConfigurationText.swift`), `semel.config`, and a config namespace spelled
`settingNamespace` in the code — is several words circling one area. Not misleading, just
crowded; rename opportunistically, when already in the file. The node type that was
`Configuration` is `SettingsLiteral` (B-120).

*Decided, so it is not re-raised.* `isPinned` stays. *Pinned* means "cannot be moved" in
memory management, where the meaning here is "held alive by user intent rather than by
references" — a **GC root**. `isRooted` is more accurate only to a reader already thinking in
collector terms, and would read as "the root of the file system" to everyone else. Revisit
only if a real collector lands.

**B-124** `done` — **Reading a node's inputs cost one select per wire.**
Found 2026-09-28, when the nightly's cold build of the IceCubes app went from 340 s to
more than 1500 s over one night of merges. A `sample` of the server showed most of its
time under `Node.buildProcessInput`: `readFromInputPort` read the wires at a port and then
selected each wire's source port on its own, and every select is a round trip through the
serialised database — a queue hop, a savepoint and a statement of its own. The cost
follows the fan, and the widest fan in the graph is `ProjectFinder`'s: it watches the
manifest of every pinned folder of the tree, 1670 under IceCubes, and it is re-evaluated
every time the builder below it writes — which, with the converters demanding target
subfolders level by level (B-108) and locks and content roots (B-06), was 650 times in the
first sixteen minutes of that build. That is over a million port selects for one node
that produced its output 110 times, on a database every compute thread waits on; the
compilers did not start in earnest until then.
Now `OutputPortDataAccess.selectArriving(atNodeID:toSymbolID:)` answers a port in one
query, the wires joined with the ports they come from, and `readFromInputPort` reads that.
`InputPortReadScaleTests` pins one select per read at fans of 100 and 400, checks the
plan searches both tables through their indexes, and that a wire from a port with no row
is left out as before. `OutputPortDataAccess.selectCount` is the observable, beside
`WireDataAccess.selectCount` and `rowsRead`.
Seen beside it: that build created some 20,000 nodes and kept 10,000, which turned out to
be the loop B-125 describes, and `ProjectFinder` decodes 1670 manifests on each of its
real evaluations, a cost that follows the passes and is left for another day.

**B-125** `done` — **An include that cannot be read cut every include after it, and a
`..` in a resource rule made a file nothing could push.**
Found 2026-09-28 under B-124: with the reads made cheap, the IceCubes app build still did
not end. `semel check` named a compiler whose stored identity was not the one its wires
gave, a node that was gone a minute later; the converter for purchases-ios-spm had run 300
times and failed its lock check each time (B-06) with the same "found" root; fourteen of
the builder's seventeen includes were made, collected and made again every few seconds,
their compilers and settings chains with them. The loop, in order:
1. The manifest of purchases-ios declares `.copy("../Sources/PrivacyInfo.xcprivacy")` from
   a target at `Sources`. `PackageResources` joined it as spelled, so every converter that
   emitted RevenueCat's bundle asked for `StaticFile(path: '…/Sources/../Sources/
   PrivacyInfo.xcprivacy')`: the engine made a folder called `..` under `Sources` and a
   file in it nothing could push. A ghost, `not-produced` in the fold, so the package
   folder's content root was not the root `prepare` had recorded from the disk, and the
   lock check failed.
2. `FormulaFile.parse` returned at the first include whose text it could not read — the
   failed one is third of seventeen in the Xcode project's formula — so the builder's
   output named four includes, and `applySpecs` unwired the other thirteen. Nothing
   referred to their converters any more; the idle collector took them and everything
   below them, the ghost included.
3. With the ghost gone the root was the lock's again, the converter passed, the parse
   reached all seventeen includes, the thirteen were made again and emitted the ghost
   again — and round.
Fixed both. The parser goes on past an include it cannot read, so every include the texts
name is asked for and stays wired, and the products wait for all of them as before
(`FormulaParserTests.test_anIncludeNotYetAvailableStillAsksForTheIncludesAfterIt`;
`ProjectBuilder` v4). `PackageResources.fullPath` resolves a declared resource's dot
segments where it is joined to the target folder, so no `..` reaches a formula
(`PackageResourcesTests`, two cases; `SwiftFormulaConverter` v7). Either fix alone ends
the loop; the first is the one that matters, because any include that alternates
between a value and an error — a converter waiting on a folder, a lock that fails — would
have torn the graph down the same way.
With the loop gone the same build ended in 147 s and failed on four `TreeMerger`s: the
app merges `bundles_Account()` and `bundles_AppAccount()`, and each carries
`DesignSystem_DesignSystem.bundle/Assets.car`, because a product's tree of bundles
carries its dependencies' (B-77) and two products share one. The merger now places the
same entry — one path, one hash, one mode — from two trees once, and still refuses one
path with two contents or two modes (`TreeMergerTests`; `TreeMerger` v2). The cold build
then ended in 151 s with no errors and a clean `check`, and the second build in 17 s —
failing its export, because a vendored resource leaves read-only (B-108) and a write over
it is refused: `export` now replaces what an earlier export left, whatever its mode
(`ExportCommandTests`).
What remains: an include in error still leaves the build without products, which is
right, but the report names the converter's error and not that the project waited on
it; and the collector's tearing down of a subgraph a builder will demand again on its
next pass is a cost the builder could avoid by keeping the wires of includes it has
already named.

**B-141** `done` — **A port that takes one wire took whichever of two came first.**
Decided 2026-10-09 by the owner: the number of wires on an input port is validated, for
every node. Only the settings nodes refused a second wire (B-120); every tool node read
its one-wire ports through `ProcessInput.firstWire(onRequiredPort:)` or
`inputValues[port]?.first`, which is the first entry of a dictionary whose order is
seeded per process — a formula wiring two configurations to one compiler compiled
against one of them, and possibly the other in the next process.
Done 2026-10-09. A static port states how many wires it holds:
`NodeDescriptor.InputPort.required(_:_:)` and `.optional(_:_:)` take an `Arity`, `.one`
by default and `.many` for a port the node reads whole; a dynamic port holds as many as
its node demands. Declared `.many`, because their nodes read every wire: `ClangLinker`'s
`objectFiles` and `libraries`, `ClangArchiver`'s `objectFiles`, `ClangPreprocessor`'s
`headerFolders`, `ClangIncludeFinder`'s `sourceFile`, `SwiftCompiler`'s `inputFolder`,
`inputExtraSourceFiles`, `inputModules`, `inputModuleTrees`, `inputFrameworkTrees`,
`inputModuleMapFolders` and `headerTrees`, `SwiftLinker`'s `input`, `libraryFolders`,
`objectTrees`, `linkRequirements` and `frameworkTrees`, `AssetCatalogCompiler`'s
`catalogs`, `InfoPlistBuilder`'s `partials`, `TreeMerger`'s and `TreeBuilder`'s `input`
(and `TreeBuilder`'s `fileMetadata`), `FolderTreeBuilder`'s `folder`, and `LineCounter`'s
`input`. Every other static port is one wire.
Refused twice, at the two places that can name something useful. When the graph is
built, the applier asks the row's type before it makes the node, and a spec wiring
several sources to a one-wire port is `GraphSpecApplierError.severalWiresOnOneWirePort
(typeName:portName:wires:)`: no node is made, and the error lands on what applied the
spec — the formula's `ProjectBuilder`, where `errors` names it with the type, the port
and the wires. When a node reads, `ProcessInput.onlyWire(onRequiredPort:)` (the renamed
`firstWire`) and `onlyWire(onOptionalPort:)` throw `NodeError.severalWiresOnOneWirePort
(port:wires:)`, the wires sorted; every node reading a one-wire port goes through them, as
do the settings nodes' `settings(onPort:)` and the tool and SDK fingerprints of the cache
key, which no longer key on one of two configurations. `SwiftCompiler`'s own check of its
bridging header and the "nothing is wired to its … port" sentences of `CodeSigner`,
`StringCatalogCompiler`, `IBToolCompiler`, `XCFrameworkSliceSelector` and `TreeFile` are
gone into the same two calls.
Bumped, since a node that published a result for two wires now publishes an error:
`ClangCompiler` 4, `ClangPreprocessor` 8, `ClangLinker` 3, `ClangArchiver` 2,
`SwiftCompiler` 5, `SwiftLinker` 5, `SwiftPackageReader` 2, `CodeSigner` 4,
`StringCatalogCompiler` 2, `IBToolCompiler` 2, `InfoPlistBuilder` 4,
`AssetCatalogCompiler` 5, `XCFrameworkSliceSelector` 5, `ProjectBuilder` 6, `OutputFile` 2
and `TreeFile` 3. `ConfigFilter` and `ConfigMerger` already refused, so they keep theirs.
`ProcessInputTests` (SemelNodeKit) hold both readers and the declared arity,
`OneWirePortTests` (SemelCore) the refusal of a tree, a `.many` port taking two and the
`errors` record on the builder, and `ClangCompilerTests` a compiler given two
configurations or two sources, which throws naming them and runs nothing.

### End-to-end roster

Real-world projects for `EndToEnd/Tests/Projects.swift`, each chosen for something IceCubes
does not exercise. What is said about each project below is from memory of the project, not
from a clone: pin a commit, run `semel-swift prepare` — or, for a C or C++ project, which
has no converter, lay a formula over the clone (B-76) — and let the first failure list
correct the entry. The gap list a project produces is worth more than its eventual pass.

**B-76** `done` — **A roster source for a clone plus a hand-written formula.**
`Project.source` is `.fixture`, `.git(url:commit:subfolder:)` or `.repository`, and only
`prepare` writes a formula into a clone. A C or C++ project has no converter, so its `.fmla`
and `semel.config` have to be laid over the clone from the fixtures folder. Blocked B-79.

Done (2026-09-27): `.git(url:commit:subfolder:overlay:)` — `overlay` names a folder under
`EndToEnd/Fixtures` whose entries `materialise` copies over the checkout's subfolder once
the checkout is copied, each replacing the entry of its name. `configure` then writes the
machine file beside the subfolder, where the C fixtures' formulas read it too, so an overlaid
formula says `<../semel.machine.config>` like theirs. `RosterTests` pin that every overlay is
in the repository and is exactly one formula, which names that file, plus a `semel.config`,
and the walk for committed machine files covers it. First used by Lua (B-79). Since
extended to a project with a platform (`food-truck-mac`, B-77): there the overlay is
corrected copies of the checkout's own files, laid file by file with folders merged,
each required to replace a file the checkout has — or to be the output of a `.gyb`
template the checkout has beside it, a source the project generates before its build
(NetNewsWire's `SecretKey.swift`, B-77); `prepare` writes the formula and the
configs afterwards, so the pin for that kind is no formula, no config and no machine file.

**B-77** `open` — **More Xcode projects.** IceCubes is SwiftUI, synchronized folders, one
application target, simulator only, all library code in packages. In suggested order:

1. *apple/sample-food-truck* — done for the simulator (2026-09-27), in the roster as
   `food-truck`. Not the cheap data point it looked: the project is in the older form,
   every target a file list over groups, so the converter now resolves a file reference
   through its groups (`<group>` and `SOURCE_ROOT` levels, a group whose path is `.`),
   honours a build file's `platformFilters`, and expands a variant group into one
   `.lproj` file per language, kept under its language folder in the bundle; and its
   local package carries resources, so package resource bundles exist now (see B-80
   item 4): the Swift converter walks each target's folder, builds
   `<Package>_<Target>.bundle` from what SwiftPM's rules recognise and what the manifest
   declares, compiles the target with the `Bundle.module` accessor, and hands the app
   `bundles_<Product>()`. The `macosx` build is written too — a Mac bundle gets its
   `Contents/` layout, the Mac as actool's device and its own plist keys, pinned by
   `XcodeFormulaEmitterTests` — but the sample itself no longer compiles for the Mac
   with the current SDK: it guards ActivityKit with `canImport`, false on the macOS 13
   SDK it was written against and true on 26.5, so Xcode fails on it the same way. The
   Mac build is in the roster as `food-truck-mac`, over B-76's overlay:
   `Fixtures/external/food-truck-mac` holds the four files with the guard corrected to
   `canImport(ActivityKit) && !os(macOS)`, laid over the clone file by file before
   `prepare` — `lay` merges folders and, for a project with a platform, refuses a file
   the checkout lacks — and the bundle comes out whole, `Contents/MacOS`, an
   `AppIcon.icns`, the widget under `Contents/PlugIns`, through all four hermeticity
   builds. The bundle is signed ad-hoc since NetNewsWire's item 11 — the widget with its
   own entitlements, then the app with the app sandbox — and the export verifies deep and
   strict in every build; launched by hand (`open`, and the executable run directly), the
   app starts and stays up. Left as copies rather than compiled, said here rather than
   silently: a Core Data model, a Metal file listed among a target's resources (a xib
   and a storyboard are compiled since NetNewsWire's item 8); a listed source that is
   neither Swift nor C-family is refused by name (a listed C-family one is compiled since
   item 6). `prepare` no longer
   writes a project the `clang.*` blocks unless one of its local packages or vendored
   dependencies has a C-family target (with NetNewsWire, below); the string catalog
   compiler's machine block when no `.xcstrings` exists is still reported as unused
   keys on every build, noise worth silencing at the writer. A package *tree* with
   resources still wants the `apple.*` namespaces in its config, which `prepare` does
   not write for a tree.
2. *NetNewsWire* — `open`; the Mac app builds (2026-09-29) and is in the roster as
   `netnewswire-mac` (below, after the map), signed since 11, and launches since 18 (the
   rule for a synchronized folder's resources, below); the iOS app builds for the
   simulator, is in the roster as `netnewswire-ios` and launches since 20. Pinned
   at `b4361413fc1850110f9f42652f0f84e7a51e9d64` (main, 2026-09-23). The clone is not what
   this entry said from memory: there are no framework targets and no group-listed
   sources — the Mac and iOS apps, two Mac extensions (Share, and the Safari extension
   *Subscribe to Feed*), two iOS extensions and two test bundles, all on synchronized
   folders (`Mac`, `iOS`, `Shared`, `Widget`, `Tests`) with exception sets, and
   seventeen local packages under `Modules/`, most of them `.dynamic` library products.
   Three remote packages: Sparkle, Zip, PLCrashReporter (Tidemark comes transitively).

   *How its settings layer.* Every configuration — the project's and each target's — is
   based on a file in the synchronized `xcconfig` folder, written in Xcode 16's anchor
   form: `baseConfigurationReferenceAnchor` names the folder, `…RelativePath` the file;
   no configuration sets anything in `buildSettings`. The project's Debug file is
   `NetNewsWire_project_debug.xcconfig`, which includes `NetNewsWire_project.xcconfig`
   (the warnings, `SWIFT_VERSION = 6.2`, both deployment targets, and `#include?
   "../../SharedXcodeSettings/ProjectSettings.xcconfig"`, a developer's own file beside
   the clone) and then `common/NetNewsWire_debug_identifiers.xcconfig`
   (`BUNDLE_ID_SUFFIX = -DEBUG`), then extends: `GCC_PREPROCESSOR_DEFINITIONS = DEBUG=1
   SKIP_APP_GROUP_ACCESS=1 $(inherited)`, and replaces `OTHER_SWIFT_FLAGS` without
   `$(inherited)`, so the project file's upcoming-feature flags are overridden in both
   configurations, in Xcode too. The Mac app's `NetNewsWire_macapp_target.xcconfig`
   includes `common/NetNewsWire_codesigning_common.xcconfig` (the
   `CODE_SIGN_IDENTITY[sdk=macosx*]`/`[sdk=iphoneos*]`/`[sdk=iphonesimulator*]` triple,
   `ORGANIZATION_IDENTIFIER`, an empty `DEVELOPER_ENTITLEMENTS`, and `#include?
   "../../../SharedXcodeSettings/DeveloperSettings.xcconfig"`) and
   `common/NetNewsWire_macapp_target_common.xcconfig`, which includes
   `…mac_target_common`, which includes `…version` — three deep. The iOS app's and every
   extension's files have the same shape through `…ios_target_common`,
   `…macextension_common` and `…iOSextension_common`. Values end in `;` in places
   (`SDKROOT = macosx;`) and settings defined empty matter
   (`PRODUCT_BUNDLE_IDENTIFIER = $(ORGANIZATION_IDENTIFIER).NetNewsWire-Evergreen$(BUNDLE_ID_SUFFIX)`).
   No `[config=…]` or `[arch=…]` condition is used; only `[sdk=…]`.

   *As built.* `Xcconfig` parses a file into its lines in order — assignments with their
   conditions, in `[a=x][b=y]` or `[a=x,b=y]` form, and `#include`/`#include?` —
   dropping `//` comments and a trailing `;`. `XcconfigExpansion` follows the includes,
   beside the including file and then under the project folder, each file spliced in
   where it is named; it records every file it looked for, waits on one still pending
   while still finding the others, names a plain include found nowhere, and refuses a
   cycle. `XcodeBuildSettings` evaluates one ordered run of assignments — defaults,
   project xcconfig, project configuration, target xcconfig, target configuration — in
   which a later assignment overrides, `$(inherited)` is what the assignments before it
   gave (in the same file too), and `sdk`, `config`, `arch` (`arm64`) and `variant`
   (`normal`) conditions hold or not; `$(VAR)` references are resolved over the result as
   before. `XcodeProject` reads the anchor form and resolves a file reference through its
   groups. The converter demands each included file as one more `StaticFile` on its
   `xcconfigs` port, a level per pass, and the embedded extensions' files as well as the
   application's; a missing plain include is reported as a missing root is.
   `XcodeProjectFacts` answers `prepare`'s questions the same way from the disk, so
   `prepare --platform macos` now writes `arm64-apple-macosx15.0`. Pinned by
   `XcodeBuildSettingsTests` over copies of the project file and the whole `xcconfig`
   folder under `SemelApple/Tests/Fixtures/NetNewsWire`: the Mac app's bundle identifier
   `com.ranchero.NetNewsWire-Evergreen-DEBUG`, `MACOSX_DEPLOYMENT_TARGET` 15.0, the
   preprocessor definitions, the signing identity per SDK, Release, the iOS app for the
   simulator, and the Safari extension. Fixed on the way, because the Mac app would have
   compiled the widget's sources twice: a synchronized folder owned by several targets
   (`Shared`) lends nothing to its owners — an exception set naming an owner is that
   owner's exclusions.

   *What stops it*, in the order a `build --platform macos` from a fresh clone meets it.
   `prepare` vendors the four remote packages and writes the formula; the converter
   then converts the project (`converted NetNewsWire for macosx, Debug`, every value
   above in the plists), and the build stops at:

   1. ~~**Sparkle is a binary target**~~ Done (2026-09-29), as designed the day before
      (B-133 was the loop it once caused). `Dependencies/Sparkle/Package.swift` has one
      target, a `.binaryTarget(url:checksum:)` for an xcframework, which is now vendored,
      selected, compiled and linked against, and embedded. As built:

      - *`prepare` vendors the artifact.* Resolution downloads it and checks the zip
        against the manifest's `checksum`; `copyCheckouts` copies what it left under
        `<clones>/artifacts/<identity>/<Target>/` (`xcodebuild -resolvePackageDependencies`)
        or `.build/artifacts/<identity>/<Target>/` (SwiftPM's `resolve`, which also covers
        a root package's own binary targets) into the copy as
        `Dependencies/<Name>/semel-artifacts/<Target>/` — inside the package, so the lock
        written after it covers it, and not a dot-name. `prepare` downloads nothing. A
        `path:` zip in any package it reads, the tree's own or a vendored one, is unzipped
        with `ditto` into `semel-artifacts/<Target>/` before the locks are taken; a `path:`
        `.xcframework` is used where it is. The lock records each binary target's checksum
        on a new `artifacts` line (`artifacts  Sparkle=34b9…`), recorded like the version,
        never compared; its column widens only when the line is there, so every other lock
        reads as before. The folder name is `DependencyLock.artifactsFolderName`, one rule
        for both sides. `prepare` prints `Unzipped:` and `Artifact:` lines.
      - *The converter finds the xcframework* (v12). A new dynamic port,
        `binaryArtifactFolders`, asks for a `path:` `.xcframework` directly, and for a
        downloaded or zipped one walks down to it: the package folder, then
        `semel-artifacts` only if the package lists it, then `<Target>` only if that lists
        it — so nothing is demanded under a vendored package that is not there, which
        would be a ghost failing its lock (B-133). The walk is asked for with the target
        folders, before the lock is compared. The `.xcframework` in `<Target>` is taken by
        its suffix (Xcode leaves Sparkle's `CHANGELOG`, `LICENSE` and `bin/` beside it).
        Nothing there is `… is not vendored: nothing is at <folder>` naming `prepare`, a
        `path:` zip not unzipped says so, a `path:` folder that is not there names its path.
      - *`XCFrameworkSliceSelector`* (`SemelApple`, kind 40) reads the `Info.plist`
        (`AvailableLibraries`) and the Swift linker's settings — the `sdk` and the `target`
        triple the product is linked for, so no namespace of its own and the converter
        stays platform-blind — picks the slice for the platform (`ios` + `simulator` for
        the simulator, `ios` + `maccatalyst` for a `-macabi` triple), refuses one whose
        `SupportedArchitectures` lack the triple's, and walks the slice a level a pass,
        each file keeping its pushed mode. It publishes three trees: `frameworks`, a
        framework slice under its own name (`Sparkle.framework/…`); `libraries`, a static
        library slice's archive; `headers`, that slice's `HeadersPath`. A slice not filling
        one publishes it empty, so a formula wires all three without knowing which it is.
        A library slice that is not an `.a` is its error.
      - *The package's formula.* `slice<Target>()` names the selector; every product gains
        `frameworks_<Product>()` (a `TreeMerger` of its binary targets' `frameworks`,
        empty when it reaches none, as `bundles_<Product>()` is); `objects_<Product>()`
        carries the static archives beside the objects and `modules_<Product>()` their
        headers under the target's name. A product vending only binary targets — Sparkle's
        — gets these funcs and no linker. A Swift target reaching a binary one compiles
        with the slice on `frameworkTrees` and its headers on `moduleTrees`; the product's
        own linker, unless it writes an archive, takes `frameworkTrees`, the archives on
        `objectTrees` and `frameworksRunpath: '@loader_path'`.
      - *Compile and link.* `SwiftCompiler.frameworkTrees` merges the trees under
        `frameworks` and passes `-F frameworks` (the framework carries its own module
        map). `SwiftLinker.frameworkTrees` does the same and links each `*.framework` at the
        top of the merged tree by name, with `-rpath <frameworksRunpath>` only when there
        is one; an archive takes none.
      - *The emitter* (`XcodeProjectConverter` v8) names `frameworks_<Product>()` for every
        package product a target links, on its compiler and its linker, sets the runpath
        from the bundle layout (`@executable_path/../Frameworks` on the Mac,
        `@executable_path/Frameworks` on iOS), and lays the trees under the bundle's
        `Contents/Frameworks/` or `Frameworks/` — `BundleLayout.frameworksTree` — and on
        the Mac signed with the rest of the bundle (item 11).
      - *Pinned by* `SwiftFormulaConverterTests` (a remote target in and out of
        `semel-artifacts`, a vendored copy asked only for what it lists, a local
        `.xcframework`, a local zip, a Swift target compiling and linking against the
        slice, an `.artifactbundle`), `XCFrameworkSliceSelectorTests` (Mac, simulator,
        missing platform and architecture, a static library slice), `SwiftCompilerTests`
        and `SwiftLinkerTests` (`-F`, `-framework`, the runpath), `XcodeFormulaEmitterTests`
        (both layouts), `PrepareTests` (a `path:` zip unzipped and locked, a checkout's
        download copied by identity, the checksum on the lock, the summary),
        `DependencyLockTests`, `VendoredPackageSettleTests` (a live engine settles with the
        lock holding, with and without `semel-artifacts`), and end to end by the fixture
        `swift-binary-target-app`: `BinaryTargetFixture` builds a versioned
        `Tiny.framework` with `clang -dynamiclib` and `xcodebuild -create-xcframework` into
        the copy, a local package's product depends on it by `path:`, and the Mac app from
        the fixture's project comes out with `Contents/Frameworks/Tiny.framework`, loads
        `@rpath/Tiny.framework/Versions/A/Tiny` (`otool -L`) through
        `@executable_path/../Frameworks` (`otool -l`), and runs, printing the framework's
        greeting — through all four hermeticity builds.
      - *Still not built* (B-133's stable error, unchanged in form): a binary artifact that
        is not an `.xcframework` — an `.artifactbundle`, which holds a plugin's executables
        rather than a library — `binary target X of package P is not built (B-133): its
        artifact … is not an .xcframework`.

      Checked on the clone (2026-09-29, pinned commit, `prepare --platform macos` then
      `build`): `prepare` vendored Sparkle 2.9.5 with `semel-artifacts/Sparkle` and wrote
      its lock with the `artifacts` line; the build ran 1,025 nodes and stopped at item 4
      alone (`Account`: `cannot find 'SecretKey' in scope`, three errors in one node), no
      lock or binary target error. The selector chose `macos-arm64_x86_64`; its trees are
      wired to the app's compiler and linker (`frameworkTrees`, the linker's literal
      `frameworksRunpath: '@executable_path/../Frameworks'`) and to
      `NetNewsWire.app/Contents/Frameworks/`, which the export holds: `Sparkle.framework`,
      the universal `Versions/B/Sparkle` with its install name
      `@rpath/Sparkle.framework/Versions/B/Sparkle`, `Autoupdate` and `Updater.app`
      executable. A Swift file importing Sparkle compiles and links against that copy with
      `swiftc -F … -framework Sparkle`. With `SecretKey.swift` stubbed in the scratch clone
      only, the app's compiler runs: `AppDelegate.swift`'s `import Sparkle` resolves, and
      the errors are AppKit names the bridging header would bring (item 6), so the app's
      link is behind item 6. What remains:

      - ~~*A framework's links arrive as copies.*~~ Done (2026-09-29; design and as built in
        `docs/superpowers/specs/2026-09-29-semel-links-in-trees-design.md`). A push followed
        every symbolic link, `prepare`'s fold did the same, and a tree had no link entry, so
        a versioned framework was embedded with `Versions/Current` and every top-level link
        as a copy (Sparkle: 263 files), which `codesign` calls ambiguous. Now a link whose
        target stays inside its own folder — relative, never climbing above it, naming no
        dot-name — is pushed as a link, and any other is followed or refused as before. It is
        still stored as what it names, so nothing that reads bytes or walks folders changes
        (RevenueCat keeps two targets' sources behind folder links to siblings), and its
        target is recorded beside it: a file's on its `fileMetadata`, a folder's on a new
        `Folder.symbolicLink` port and in its parent's manifest. The fold has a `link` line
        (format 3), trees a link entry (`TreeManifestEntry.Content.symbolicLink`) kept only
        where it resolves inside the tree, `TreeFile`/`OutputFile` carry the target on
        `fileMetadata`, tools lay and read back links, the settle diff reports a link by what
        it holds, and `export` and `cp` write links (`ProtocolVersion` 19, `Semel` 0.1.13).
        `CodeSigner` signs the tree as it is. Pinned at every layer — the lister, the disk
        fold, `TreeManifestTests`, the engine's fold (`FolderMerkleRootTests`,
        `DependencyLockFoldTests` pushing a framework's links and comparing the two folds),
        the tree nodes, the slice selector, the signer with the real `codesign`, the server,
        the client's push and `cp`, the export — and end to end by `swift-binary-target-app`,
        whose export holds `Tiny.framework`'s five links as links and verifies with
        `codesign --verify --deep --strict`, and by `netnewswire-mac`, whose exported
        `NetNewsWire.app` — Sparkle, its XPC services and `Updater.app` inside — now
        verifies the same way (the roster checks it). `Vendoring` needed no change: `copyItem` and
        `ditto` keep a checkout's and an artifact's links. What remains: a push only adds, so
        a folder link replaced on disk by a folder stays a link in the graph until removed;
        `ls` shows a link as the file or folder it names.
      - ~~*The whole download is pushed.*~~ Done (2026-09-29, 19 below): `prepare` keeps
        only the `.xcframework` in `semel-artifacts/<Target>`.
      - *A package's own product* reaching a binary framework links with `@loader_path`,
        but the package's formula does not put the framework beside it as SwiftPM's build
        folder does, so such an executable built alone does not find it at run time.
      - *An extension* embeds its own products' frameworks under its own `Frameworks`
        rather than relying on the app's, as Xcode would; none of NetNewsWire's links one.
      - *A C target depending on a binary one* gets no `-F`: the clang nodes have no
        framework port. The `DebugSymbolsPath` dSYMs are not carried.
      - *A static library slice* is pinned by unit tests only; no fixture builds one.
   2. **PLCrashReporter** (`CrashReporter`, C and Objective-C at the package root). The
      folder collision is fixed, its 58 sources and its `.S` compile, and what depends on
      it links with Foundation and libc++ (B-134, B-55 done 6–10; checked 2026-09-28 on
      a scratch package that `prepare` vendored it into). B-55's residuals 4 and 7
      followed the same day — a generated module map for `import CrashReporter`, and ARC —
      so nothing of B-55 is known to stand in its way; the app's own `import
      CrashReporter` is behind 4 below on the clone.
   3. ~~**The local packages are not found.**~~ Done (2026-09-28). Xcode finds the
      seventeen packages under `Modules/` because `Modules` is a synchronized folder,
      owned by no target, holding package folders; the fifteen product dependencies
      (`Account`, `RSCore`, `RSCoreResources`, …) name no package, and Xcode finds each
      by name among the local packages. `XcodeProject` now reads every way a project
      declares one — a `wrapper` file reference resolved through its groups, an
      `XCLocalSwiftPackageReference`'s `relativePath` — and lists every synchronized
      folder, owned or not. `LocalPackageSearch` looks into each synchronized folder and,
      a pass later, each folder directly in it (not catalogs, `.lproj`s or hidden
      folders), and a folder holding a `Package.swift` is a package; the converter asks
      on its `folders` port, one level per pass, and a folder that is not there holds
      none. (Since 2026-09-30 it asks for each synchronized folder's tree, which answers
      for the folders in it on the same pass: B-135.) Every package found is included, as Xcode puts every one in the workspace, so
      a product is found by name among the funcs the included formulas define —
      `RSCoreResources` in `RSCore`'s. A local product with no local package at all is
      now the converter's error, naming the products and the folders looked in.
      `XcodeProjectFacts.localPackagePaths` finds the same packages on the disk for
      `prepare`, which lists them and decides the clang blocks over them and the vendored
      packages (a project with none gets none now). XcodeProjectConverter v5. Pinned by
      `XcodeProjectTests`, `XcodeProjectConverterTests` (the converter run pass by pass
      over the fixture's project file for the Mac, every `modules_`/`objects_`/`bundles_`
      call defined by an included package) and `PrepareTests`. The fixture does not copy
      the seventeen manifests — a `Package.swift` under this repository is one `prepare`
      would take for Semel's own — so `NetNewsWireModules` in the tests holds their
      products as `dump-package` read them at the pinned commit. Not looked for: a
      package deeper in a synchronized folder, a synchronized folder that is itself a
      package, a package behind a folder reference (`lastKnownFileType = folder`).

      Checked on a clone with Sparkle and PLCrashReporter replaced by stub packages (1
      and, before B-134 landed, 2 were in the way): `prepare` lists the seventeen, the formula resolves,
      and the build compiles the local packages (254 nodes, the extensions' bundles and
      every package resource bundle written) and stops at 5, 9 and three new ones, 12
      to 14; 4 is behind 5, `Account` never compiling.

   4. ~~**`SecretKey.swift` is generated before the build.**~~ Done (2026-09-29), as far
      as a hermetic build can: named, and for the roster provided. The template is
      `Modules/Secrets/Sources/Secrets/SecretKey.swift.gyb`, inside the `Secrets` package
      (which excludes it), not a synchronized folder; `Account` and `Shared/Article
      Extractor` reference `SecretKey`. The scheme's build pre-action,
      `"${PROJECT_DIR}/buildscripts/updateSecrets.sh"` (both shared schemes have it), runs
      gyb over every `.gyb` in the tree; the template reads six secrets from the
      environment and XORs each with a salt of 64 bytes from `os.urandom`, so what it
      writes depends on the machine twice over, and differs on every run even with no
      secrets. Semel runs no scheme action, and a gyb node would have to fix the salt,
      that is, write something the project never writes. So:
      - `prepare` says it: `XcodeProjectFacts.ungeneratedSources` finds every `.gyb` in the
        application's synchronized folders and the local packages whose output is not
        beside it, and `XcodeScheme` reads the shared schemes' build pre-actions — the
        ones whose script, or a script file of the project's it names, runs gyb. A fresh
        clone prints `Not generated: Modules/Secrets/Sources/Secrets/SecretKey.swift`, both
        pre-actions, and that Semel runs neither, where the build said only `cannot find
        'SecretKey' in scope`. Once the file is there, nothing.
      - The roster's overlay provides it: `EndToEnd/Fixtures/external/netnewswire` holds
        what the script writes with no secrets set — what a fresh clone builds as in Xcode
        — generated once and committed, its random salt fixed by that. `lay` now takes a
        file the checkout lacks when the checkout has its `.gyb` template beside it (the
        template pins the path as a replaced file does). The roster entry, when Sparkle
        builds (1), only has to name the overlay.
      Pinned by `XcodeProjectTests` (the fixture now holds the shared scheme, the script
      and the template) and `MaterialiseTests`.
   5. ~~**Objective-C in the packages.**~~ Done (2026-09-28). `RSDatabaseObjC` (FMDB) and
      `RSCoreObjC` open every header with `@import Foundation;` (or `AppKit`) and assume
      ARC; a C target with Objective-C is now preprocessed and compiled with modules and
      ARC (B-55's 7), and `RSDatabase` imports `RSDatabaseObjC` through the module map
      SwiftPM would write for its `include/RSDatabaseObjC.h`, whose `#import "../FMDatabase.h"`
      resolves because the header tree is the whole target's (B-55's 4).
   6. ~~**Objective-C in the app.**~~ Done (2026-09-29). `Mac/NSOpenPanel+Extras.m` and the
      bridging header `SWIFT_OBJC_BRIDGING_HEADER = Mac/NetNewsWire-Bridging-Header.h`,
      which imports it and `WKPreferencesPrivate.h`. The emitter now takes every C-family
      source (`.c`, `.m`, `.mm`, `.cpp`, …) of a target's synchronized folders less their
      exceptions, and a listed or borrowed one, through the shapes the package converter
      gives a C target: a `preprocess_<Target>(path)` func — a `ClangPreprocessor` over
      the target's synchronized folders as header folders, the nearest thing to Xcode's
      header map — and per source a `ClangCompiler` into the executable's linker, beside
      the Swift object; C++ or Objective-C++ adds the C++ runtime to the link
      requirements. The settings are Xcode's: ARC and modules when
      `CLANG_ENABLE_OBJC_ARC` and `CLANG_ENABLE_MODULES` say `YES` (the settings PR #132
      gave packages), the standards when `GCC_C_LANGUAGE_STANDARD` and
      `CLANG_CXX_LANGUAGE_STANDARD` state them, `GCC_PREPROCESSOR_DEFINITIONS` as
      `defines`, and the target's triple. The bridging header reaches `swiftc` as
      `-import-objc-header` from a `StaticFile` on a new `bridgingHeader` port of
      `SwiftCompiler`, with the target's other headers as `headers_<Target>()` — a tree,
      the shape `headers<Target>()` has for a package — on `headerTrees`, placed beside it
      under `objc/`, each of their folders a `-Xcc -I`, and the preprocessor definitions
      as `-Xcc -D`, as Xcode tells the importer. swiftc refuses a module interface for a
      module with a bridging header, so such a compile emits none. A listed C-family
      source is compiled now rather than refused. The generated `-Swift.h` is out of scope:
      nothing in the Mac app imports it (NetNewsWire's `.m` imports only its own header).
      What remains: the app's `.swiftmodule` records the bridging header's absolute
      sandbox path (nothing imports an app's module and it is no product, so no build
      compares it); no header map, so a quoted import of a target header in a folder no
      `-I` names is not found; assembly in an app target is not compiled. On the clone,
      the preprocessor and compiler for `NSOpenPanel+Extras.m` succeed and the app's Swift
      compile gets past the bridging header to 16 below. Pinned by
      `XcodeFormulaEmitterTests`, `XcodeProjectConverterTests` over the NetNewsWire
      fixture (which now holds the four files) and `SwiftCompilerTests`; end to end by
      `swift-hello-app`, whose SwiftUI view shows a string from an Objective-C class,
      compiled with ARC and modules and imported through a bridging header.
   7. ~~**Localized folders inside a synchronized folder are dropped.**~~ Done
      (2026-09-28). A `.lproj` is no longer compiled whole: the converter walks it like
      any folder (`LocalPackageSearch` still never looks into one), and the emitter
      places each file by `XcodeFormulaEmitter.resource(at:)` — a `.xcstrings` anywhere,
      `mul.lproj` included, through the string catalog compiler, whose tables land
      under their languages as the root catalog's do; any other resource in a language
      folder copied under it, `MainMenu/Base.lproj/MainMenu.xib` to
      `Contents/Resources/Base.lproj/MainMenu.xib` (compiled to `MainMenu.nib` there
      since 8), as Food Truck's variant groups are.
      On the clone all twenty-four `Base.lproj` xibs reach a bundle (twenty-three in the
      app, the Share extension's in its own, item 9) and the twelve `mul.lproj` catalogs
      come out as `es.lproj/<Name>.strings`. Pinned by `XcodeProjectConverterTests`
      over the NetNewsWire fixture.
   8. ~~**Interface Builder files are copied, not compiled.**~~ Done (2026-09-29).
      `IBToolCompiler` (`SemelApple`, kind 41, namespace `apple.ibToolCompiler`;
      XcodeProjectConverter v9) runs
      `ibtool --errors --warnings --notices --module <M> --target-device <d>…
      --minimum-deployment-target <v> --output-format human-readable-text --sdk <path>
      --compile out/<place>.nib <place>.xib` on one document, whose wire's key is its
      place in the bundle; the tree it publishes holds the compiled document at that
      place — a `.nib` file (or folder), or for a storyboard a `.storyboardc` folder of
      nibs, which is in reach and done the same way. `ibtool` is discovered like actool
      (its `--version` is the same plist under `com.apple.ibtool.version`); its namespace
      declares `sdkPath` as a machine setting, which `prepare` writes, and takes the
      deployment target and devices from the project's config, which `prepare` writes as
      it does actool's — only for a project whose application's targets hold a xib or a
      storyboard, as the clang blocks are now written only when a local or vendored
      package, or the application's own folders, hold C-family sources. The emitter
      classifies a `.xib` or `.storyboard` as `Resource.interfaceBuilder` at the place
      item 7 gives it and merges each compiler's tree into the bundle's resources. Not
      passed, as Xcode passes them: `--output-partial-info-plist` (no key of it is one a
      Mac app launches without) and `--auto-activate-custom-fonts`; not done, Xcode's
      separate `ibtool --link` of storyboards, which for one target is a copy.
      Reproducible, unlike actool (B-89): five NetNewsWire Mac xibs compiled three times
      each in fresh folders, and an iOS xib and two storyboards twice, came out
      byte-identical; `--sdk` and `--module` changed nothing in the Mac nibs tried (a
      class whose xib names `customModule` already records it). `IBToolCompilerTests`
      pins it on the fixture's `MainWindow.xib` with the real ibtool, and
      `swift-hello-app`'s `Base.lproj/Card.nib` through all four hermeticity builds. On
      the clone, all thirty-four of the app's xibs (twenty-three under `Base.lproj/`) and
      the Share extension's one come out as nibs; the two xibs that were left, a
      package's, are compiled since 17.
   9. ~~**A localized membership exception is read as a path.**~~ Done (2026-09-28). What
      Xcode means was established by building a project of its own (Xcode 26.6): an
      exception entry `/Localized/<folder>/<name>` in a synchronized folder's set is a
      localized resource as the navigator shows one — `<folder>/<lang>.lproj/<name>` in
      every language folder under `<folder>` of the synchronized folder, and, for an
      Interface Builder file, the string tables of its name there
      (`<lang>.lproj/<stem>.strings`, `.xcstrings`, `.stringsdict`); a file of the same
      stem and another type (`de.lproj/Thing.txt`) is not in it. The owner excluding it
      loses all of them; a target borrowing it gets all of them, placed as item 7
      places them. `XcodeProject.MembershipException` reads an entry as `.path` or
      `.localized(folder:name:)`; a `SynchronizedFolder` answers `excludes(_:)` (a path
      now also leaves out what is under it) and hands the compiler only its paths, and a
      target's `borrowed` entries keep their lending folder, so the converter walks
      `Mac/ShareExtension` for the extension and the emitter matches the entry against
      that folder's listing. The Share extension gets
      `Base.lproj/ShareViewController.xib`; the app, which excludes the same entry, does
      not. Pinned by `XcodeProjectTests` and `XcodeProjectConverterTests`.
   10. ~~**Folder references in the resources phase.**~~ Done (2026-09-28). A file
      reference whose type is `folder` is a `BuildFile.isFolderReference`, and the
      emitter copies it whole into the bundle's resources, under its own name, whatever
      kind of target lists it: `FolderTreeBuilder(under: 'Sepia.nnwtheme', folder: …)`
      merged into the resources tree. The rest of a resources phase is read for every
      target now too, not only one that lists its sources, less a file inside the
      target's own synchronized folders, which the folder already brings. The eight
      themes arrive whole (`Info.plist`, `stylesheet.css`, `template.html` each).
   11. ~~**Signing and entitlements.**~~ Done (2026-09-29), ad-hoc. What was there
      before: the linker's own ad-hoc signature on each arm64 executable — enough to run
      it, which is how `swift-binary-target-app` ran — with no Info.plist bound, no
      resources sealed and no entitlements, so `CODE_SIGN_ENTITLEMENTS =
      Mac/Resources/NetNewsWire.entitlements` (sandbox, app groups) reached nothing.
      As built:

      - *`CodeSigner`* (`SemelApple`, kind 42, namespace `apple.codeSigner`) runs
        `codesign --force --sign - --timestamp=none` over a bundle tree, the wire's key
        naming the bundle's folder (`NetNewsWire.app`), and publishes the signed tree. It
        finds every bundle holding code below the root (`.app`, `.appex`, `.framework`,
        `.xpc`; a SwiftPM resource bundle holds none and is sealed as resources) and signs
        them first, deepest first, in one run with `--preserve-metadata=entitlements` —
        an extension keeps what its own signer gave it, a vendor's XPC service the
        vendor's — then the bundle in a second run with `--entitlements`. `codesign` is
        discovered like the other Apple tools, its version the `PROJECT:codesign-…` stamp
        in its binary (it has no `--version` and ships with the system); the namespace
        declares `codesignAllocatePath` a machine setting, the toolchain's
        `codesign_allocate`, passed as `CODESIGN_ALLOCATE` as Xcode passes it — without
        it `codesign` takes `/usr/bin/codesign_allocate`, a shim to whatever
        `xcode-select` names, which no key would see. `prepare` writes that block for a
        Mac project only; the identity is the formula's. Files are laid writable, with
        their tree modes (`FileNameAndContent.mode`, new): `codesign` rewrites a
        `_CodeSignature/CodeResources` already there, and the store's objects are
        read-only. Each file comes back with its tree mode, a new signature with the
        default one.
      - *Ad-hoc only.* `identity` is a setting, and anything but `-` is refused by name.
        The emitter reads `CODE_SIGN_IDENTITY`; one naming a certificate — Food Truck's
        `Apple Development`, NetNewsWire's `Mac Developer` (Xcode's own default is `-`
        only for a target with no `DEVELOPMENT_TEAM`) — is said in the formula as a
        comment and signed ad-hoc. A real identity would be a certificate in a keychain
        the sandbox does not reach, with a timestamp no cache entry could hold: its own
        item when wanted.
      - *What an ad-hoc signature cannot carry is left out.* An entitlement a provisioning
        profile grants has the process killed at launch without one: an arm64 app signed
        ad-hoc with `com.apple.developer.icloud-services` exits on SIGKILL before it runs
        (macOS 26.6), and Xcode stops such a build for want of a team. So `CodeSigner`
        drops every `com.apple.developer.*` key, `application-identifier`,
        `keychain-access-groups` and `aps-environment` from an ad-hoc signature and names
        them on its info log; the sandbox, app groups, network access and the rest stay.
        NetNewsWire's Mac app loses its iCloud and push keys this way and keeps its
        sandbox, app group and Sparkle mach-lookup exceptions.
      - *The emitter* (XcodeProjectConverter v10): a `macosx` build no longer names each
        part of a bundle as a product. Every part is one tree, `bundle_<Target>()` — the
        files in a `TreeBuilder`, each keeping its mode, and the resources, the frameworks
        and each extension merged under their folders — signed by `signed_<Target>()`,
        and the app's product is `'<App>.app/' = signed_<App>().files`. Each extension is
        assembled and signed with its own entitlements before the app's tree embeds it.
        The entitlements file `CODE_SIGN_ENTITLEMENTS` names goes through
        `InfoPlistBuilder` with the target's settings, which resolves its `$(VAR)`s as
        Xcode does (`$(APP_GROUP_ID)`, `$(TeamIdentifierPrefix)` empty).
        `CODE_SIGNING_ALLOWED = NO` is an unsigned tree. The simulator's bundle is left as
        it was, products and unsigned.
      - *Reproducible* (B-89): two signings of one tree, each in its own sandbox and at
        different paths, are the same bytes, the cdhash too — no identity, no time with
        `--timestamp=none`, nothing of the sandbox. `CodeSignerTests` pins it with the
        real `codesign`. A signature seals what it signs, though: when actool writes an
        `Assets.car` differently (B-89), the bundle's `CodeResources` and the executable
        whose signature records it move with it, which the roster's new
        `mayDifferWithExempt` allowed only when an exempt file differed — until the
        catalog was published in canonical form and both went (B-89).
      - *A versioned framework whose links arrived as copies* — Sparkle's, the fixture's
        `Tiny.framework` — cannot be signed as it is: `codesign` finds real files at the
        framework's top and a `Versions/Current` folder and calls the bundle ambiguous,
        and a bundle holding a framework it cannot sign cannot be signed either. The
        signer first recognised the copies by the shape every versioned framework has and
        laid them as links in its sandbox, handing copies on again, so the export ran but
        did not verify as a whole. Since links travel in trees (item 1's first residual,
        2026-09-29), the tree holds the links, the signer lays it as it is and hands the
        links back (`ToolOutput.writeTreeLink`), `SigningLayout`'s recognition is gone
        (v2), and `swift-binary-target-app`'s export verifies deep and strict.
      - *Fixed on the way*: `InfoPlistBuilder` wrote the engine's `projectRoot` stamp into
        every plist as an entry (`projectRoot = input:/…`), in every Info.plist so far and
        now in the entitlements, where an unknown key had the Food Truck app killed at
        launch. It is not an entry now (v2).
      - *Pinned by* `CodeSignerTests` (the command lines, nested first, a tree's links laid
        and handed back as links, the profile-only keys left out, and a tiny app with a
        versioned framework signed twice by the real `codesign`, verified deep and strict
        with each bundle's entitlements), `LocalFileSystemToolTests` (a link and a mode
        laid, a link read back as one), `XcodeFormulaEmitterTests`,
        `XcodeProjectConverterTests` (each NetNewsWire Mac bundle's entitlements resolved,
        over copies of its three files), `PrepareTests`, and end to end by `food-truck-mac`,
        whose export verifies with `codesign --verify --deep --strict`, whose executable is
        signed as the bundle's with the sandbox entitlement, and which, launched by hand
        with `open`, starts.

      Not done: a loose helper executable inside a framework (Sparkle's `Autoupdate`) is not
      re-signed, keeping the vendor's signature, which holds while its bytes do; a signed
      iOS device build. The hardened runtime is signed with since 19.
   12. ~~**Zip's Swift target does not see its C target.**~~ Done (2026-09-28). The
      nesting was not the cause: `Minizip` (at `Zip/minizip`, inside the Swift target
      `Zip`'s folder, which excludes it) was already found as `Zip`'s C dependency, but its
      `include` holds the umbrella `Minizip.h` and no module map, so `no such module
      'Minizip'` was B-55's 4. With the map written, and the excluded
      `minizip/module/module.modulemap` kept out of the header tree, `Zip` compiles.
      `SwiftFormulaConverterTests` holds the layout, and `swift-c-package`'s `Squeeze`
      inside `Zipper` builds it end to end.
   13. ~~**An optional include inside the input file system is reported as missing.**~~
      Done (2026-09-28). The `xcconfigs` port of `XcodeProjectConverter` tolerates an
      absent value (`inputPortsToleratingAbsentValue`, as the Swift converter's
      `dependencyLocks`), so the idle report does not name an xcconfig nobody pushed;
      the converter itself names what is really missing — the root, a plain include
      found nowhere — as the cause of the settings left undefined, as before. The file
      stays demanded once known absent rather than dropped: the wire is what wakes the
      converter when the file is pushed later, and a dropped demand would leave the
      push unseen until something else re-ran it. The same tolerance covers the first
      of a plain include's two places when the file is in the second, which the report
      named too. Pinned by `XcodeProjectConverterTests`: absent, the conversion has no
      error and keeps the demand; present, its `ORGANIZATION_IDENTIFIER` reaches the
      bundle identifier.
   14. ~~**An Info.plist file may name any build setting.**~~ Done (2026-09-28). The
      emitter hands `InfoPlistBuilder` the target's whole evaluated settings, typed, as
      one JSON dictionary on a new `buildSettings` property: variables a `$(NAME)`
      resolves to, never entries — where the four it used to hand over were ordinary
      properties and so also keys of the plist (`PRODUCT_NAME` among them). Reading the
      plist's `$(…)` names instead would have meant demanding every target's plist
      before the formula could be written, for a smaller literal. `AppIdentifierPrefix`
      and `TeamIdentifierPrefix` default to empty in `XcodeBuildSettings`, with a note:
      Xcode takes them from the signing team, and an unsigned Xcode build
      (`CODE_SIGNING_ALLOWED=NO`) gives them empty too. The settings also gained what
      Xcode provides beneath every level — `DEVELOPMENT_LANGUAGE` from the project's
      `developmentRegion`, `PRODUCT_BUNDLE_PACKAGE_TYPE` from the product type — and
      `EXECUTABLE_NAME` as `$(PRODUCT_NAME)`, which the plists name as well. On the
      clone the three Mac plists build: `AppGroup` is
      `group.com.ranchero.NetNewsWire-Evergreen-DEBUG`, `AppIdentifierPrefix` empty.
      Pinned by `XcodeProjectConverterTests`, running the builder the formula names
      over the three plists, copied into the fixture under `Mac/`.
   15. ~~**A borrowed asset catalog is dropped.**~~ Done (2026-09-29). The iOS Share
      extension borrows `Resources/Assets.xcassets` from the `iOS` folder, and the emitter
      passed it over as not a copied resource. A borrowed `.xcassets` or `.icon` is now
      among the target's catalogs, compiled for it as one of its own folder's would be.
      Pinned by `XcodeProjectConverterTests` on the fixture's iOS Share extension for the
      simulator, driving the emitter for the extension; since 20 the converter builds the
      iOS app for the simulator, and `netnewswire-ios` compiles the catalog into the
      extension's bundle.
   16. ~~**A package target's upcoming features do not reach its compiler.**~~ Done
      (2026-09-29). Every local package's targets declare
      `.enableUpcomingFeature("NonisolatedNonsendingByDefault")` and
      `"InferIsolatedConformances"`, eight of them `.unsafeFlags(["-warnings-as-errors"])`,
      and the converter carried only `.swiftLanguageMode`; so `RSCore` compiled
      `UserApp.launchIfNeeded()` as plain `nonisolated` async and the app's Swift 6
      compile failed on `sending 'app' risks causing data races`. As built
      (`SwiftFormulaConverter` v13, `SwiftCompiler` v2):
      - *The settings, typed.* The converter reads each target's Swift settings into
        `SPMSwiftSetting` — an upcoming or experimental feature, a `.define`, the
        `unsafeFlags` list, a language mode — each with the platforms it holds for, and
        decides them for the platform being built as the linker settings are (PR #131):
        a `.when(platforms:)` entry makes the conversion ask for the linker's settings
        and take their `sdk`. One conditional on a configuration is not carried, as for
        a linker setting. Each kind reaches the compiler as a literal of its own —
        `upcomingFeatures`, `experimentalFeatures`, `defines` comma-joined, `unsafeFlags`
        a JSON list since a flag is free text and may hold a comma — and
        `SwiftCompilerConfiguration` writes `-enable-upcoming-feature X`,
        `-enable-experimental-feature X` and `-D X` after `-swift-version`, and the unsafe
        flags as they stand after the sources. Not carried yet, named at the decoder:
        `interoperabilityMode`, `defaultIsolation`, `strictMemorySafety`,
        `treatAllWarnings`, `treatWarning` (NetNewsWire uses none).
      - *A package's language mode.* With the features in, `RSWeb` stopped on `emitting
        module interface files requires '-language-mode'`, a warning made fatal by its
        `-warnings-as-errors`: SwiftPM compiles a target that declares no mode in its
        package's — the highest of the manifest's `swiftLanguageModes` this compiler has,
        or else the tools version's (6 from `swift-tools-version:6.0` on, 5 from 5.x,
        4.2 from 4.2) — and the converter passed nothing, which is swiftc's Swift 5.
        Every NetNewsWire package is `swift-tools-version:6.2`, so every one had been
        compiling in the wrong mode. `SPMManifest.languageMode` now decides it, and a
        target's own `.swiftLanguageMode` wins over it.
      - *No module interface.* Then `module interfaces are only supported with
        -enable-library-evolution`, the same way (and `ActivityLog`'s class shadowing its
        module, an interface-only warning): SwiftPM writes a `.swiftinterface` only with
        library evolution, nothing consumed the one `SwiftCompiler` wrote, so it writes
        none and has no `swiftinterface` port.
      Pinned by `SwiftFormulaConverterTests` (a manifest with each kind, decided for the
      Mac and the simulator, unconditional ones asking for no platform, the literals the
      compiler reads back, the package's mode from the tools version and
      `swiftLanguageModes`) and `SwiftCompilerTests` (the command line, a malformed
      `unsafeFlags`, no interface with or without a bridging header); end to end by
      `swift-my-app`, whose `MyLibraryTargetB` now needs its settings to compile: a
      bare-slash regex literal under `.enableUpcomingFeature("BareSlashRegexLiterals")`
      and a `.define` its source `#error`s without (both fail the fixture on the code
      before). The app's own `OTHER_SWIFT_FLAGS` and the rest of its Swift settings reach
      its compiler since 19.
   17. ~~**A package's xibs are copied into its resource bundle.**~~ Done (2026-09-29).
      `RSCore`'s `RSCoreResources` holds `WebViewWindow.xib` and
      `IndeterminateProgressWindow.xib`, which SwiftPM's `.process` rule compiles to nibs.
      `PackageResources` reads a `.xib` or `.storyboard` as `interfaceBuilder`, flattened
      as a processed file is (a `.copy` keeps it as the document; one inside an `.lproj`
      still travels with the folder, uncompiled), and the Swift converter (v14) names an
      `IBToolCompiler` for it in `bundle_<Target>()`, keyed by where it lands in
      `<Package>_<Target>.bundle`, over the root's `apple.ibToolCompiler` settings — the
      deployment target, devices and SDK the app's documents take — with the target's
      module as `module`. `prepare` writes ibtool's block for a project when a package
      it reaches holds a xib too. Pinned by `PackageResourcesTests` (the rules and the
      converter's bundle) and `PrepareTests`; no fixture holds a package with a xib, so
      nothing builds one end to end.

   Checked again (2026-09-28) after 7, 9, 10, 13 and 14, on a fresh clone pushed under
   its parent, with Sparkle and PLCrashReporter replaced by stub packages as before
   (their locks' `content` lines rewritten): 329 nodes, and the build stops at 5
   (`RSCoreObjC` and `RSDatabaseObjC`, `@import` with modules disabled, then no module
   `RSDatabaseObjC`) and 12 (`no such module 'Minizip'`) and nothing else; 4 and 6 are
   still behind 5. The report names no unpushed file. Everything the app's bundle
   needs from its resources is in the output: the Info.plists of the app and both
   extensions, `Assets.car`, `AppIcon.icns`, the twenty-four `Base.lproj` xibs,
   the twelve compiled catalogs, the themes, `NetNewsWire.sdef`.

   Checked again 2026-09-29, once 5 and 12 were done as well as 9, 13, 14 and B-55's
   1, 2 and 5, on a fresh clone with only Sparkle stubbed (1; its lock removed) and
   PLCrashReporter real: 497 nodes, one error. All 70 of the C-family preprocessors and
   compilers — PLCrashReporter's 58 sources and its `.S`, FMDB, `RSCoreObjC`, Minizip —
   succeed, as do the four `ModuleMapWriter`s (`CrashReporter`, `Minizip`,
   `RSDatabaseObjC`, `RSCoreObjC`) and 20 of the 21 Swift compilers, `RSDatabase`,
   `RSCore` and `Zip` among them. The one error is the next stop, 4: `Account` fails on
   `cannot find 'SecretKey' in scope`, and the app's compiler and link wait behind it,
   so `import CrashReporter` from the app is not reached yet.

   Checked again 2026-09-29, once 4, 6 and 8 were done, on a fresh clone in a scratch
   folder: `prepare` named the ungenerated `SecretKey.swift` and both schemes'
   pre-actions; with the `netnewswire` overlay laid and `prepare` run again it named
   nothing, and wrote the `apple.ibToolCompiler` and clang blocks. Sparkle was replaced
   after `prepare` by a stub package declaring the four names `AppDelegate` uses
   (`SPUUpdater`, `SPUStandardUserDriver` and their delegate protocols), its lock
   removed, so that the app's own compile is reached. 575 nodes, one failing: every
   package compiles, `Account` and `Secrets` included, the app's Objective-C
   preprocesses and compiles, the thirty-five nibs are written, and the app's Swift
   compile — past the bridging header — stops at 16. The link, and so `import
   CrashReporter` in the app, waits behind it. (Run before binary targets, 1, were
   merged; with them Sparkle needs no stub.)

   Not in the way: the seventeen `.dynamic` products, which the app embeds as frameworks,
   link statically into the executable as the emitter links every package's objects
   (only Sparkle's framework must be embedded); the script phases, of which the build
   numbers one is all comments, *Delete Unnecessary Frameworks* runs for Release only,
   and *Verify No Build Settings* checks the project file; `NetNewsWire.sdef`, which
   Xcode copies too.

   Checked again 2026-09-29, once 16 was done (with the package language mode and the
   module interface it brought out, above), on a fresh clone at the pinned commit with
   the overlay laid, `prepare --platform macos` and `build` on a fresh home: 1,103 nodes,
   no errors, about 100 s cold. Nothing after 16 stopped it: the app's link — Sparkle's
   framework, the Objective-C object, every package's `linking_` requirements (libz,
   libc++, `libsqlite3`, the frameworks) — the two extensions and the bundle's assembly
   needed no change. The export is `NetNewsWire.app`: an arm64 `Contents/MacOS/NetNewsWire`
   loading `@rpath/Sparkle.framework/Versions/B/Sparkle` through
   `@executable_path/../Frameworks`, the Info.plist with the Debug bundle identifier,
   `Assets.car`, `AppIcon.icns`, twenty-three `Base.lproj` nibs and the app's other
   nibs, the themes, `NetNewsWire.sdef`, the package bundles
   (`PLCrashReporter_CrashReporter`, `ActivityLog_ActivityLog`, `RSCore_RSCoreResources`),
   `Frameworks/Sparkle.framework`, and under `PlugIns` the Share extension (its
   executable, plist, `ShareViewController.nib`) and *Subscribe to Feed* (executable,
   plist). Unsigned then; signed since 11.

   *In the roster* as `netnewswire-mac` (`Projects.netNewsWireMac`,
   `ExternalProjectTests.test_netNewsWireBuildsTwiceForTheMac`): the pinned commit, the
   overlay `external/netnewswire` (4), `--platform macos`, the clone's root as the build
   folder, thirteen expected products across the app, the framework and both extensions,
   four of them required executable, everything under `NetNewsWire.app`, and the export
   inspected — `file` says arm64 executable, `otool -L` the Sparkle install name,
   `otool -l` the runpath (`AppInspection`, shared with `swift-binary-target-app`). One
   exemption, `Assets.car`, actool's (B-89), as for the other apps, since removed with the
   canonical catalog; no other file differed between the builds. All four hermeticity builds run — two cold builds, a second
   mount, a perturbed environment — in 528 s wall clock for the whole test, `prepare`
   included, each step well inside `buildTimeout` (10 min).

   *Signed* (2026-09-29, 11, 17): the roster run signs every bundle — Sparkle's
   `Updater.app`, XPC services and framework, both extensions with their own
   entitlements, then the app with the sandbox, app group and apple-events keys, its
   iCloud and push keys left out as an ad-hoc signature must — and
   `RSCore_RSCoreResources.bundle` holds `WebViewWindow.nib` and
   `IndeterminateProgressWindow.nib`. The export checks each executable is signed as its
   bundle's (`SignedBundleCheck.signedAsPartOfTheBundle`), and — since links travel in
   trees (1, 2026-09-29) — verifies the app as a whole with `codesign --verify --deep
   --strict`, Sparkle's `Versions/Current` and top-level links arriving as links; the
   roster run with that check passed through all four builds in 1,061 s. `mayDifferWithExempt` exempted the seals and the three executables when an
   `Assets.car` differed; in the run it did, and the app's `CodeResources` and executable
   differed with it, nothing else. Since B-89 the catalog is canonical and the roster
   exempts nothing. The test took 657 s. What made it possible: a tree
   product's builder demands one wire per file, each over the whole expression behind
   the tree, and the signed app is one tree of 369 files over the app's entire graph —
   the engine folded each copy again, and a first attempt spent over half an hour in one
   fold before the client gave up. `GraphSpecTable`'s fold now keeps the identity of
   every subtree it has folded (`GraphSpecTableTests.test_aSubtreeMetAgainIsFoldedOnce`),
   and a cold build by hand takes four minutes.

   *Launched by hand* (the executable run directly): past code signing — AMFI lets it
   run — it trapped in `MainWindowKeyboardHandler.init` on
   `Bundle.main.path(forResource: "GlobalKeyboardShortcuts", ofType: "plist")!`: the
   emitter took every `.plist` in a synchronized folder for an input (Info.plist-like)
   and copied none. 18 below.

   18. ~~**What Xcode copies from a synchronized folder.**~~ Done (2026-09-29,
      XcodeProjectConverter v11). The emitter's rule was a guess — a list of extensions
      that were "not resources", `.plist` and `.md` and `.xcconfig` among them. The rule
      below was established on Xcode 26.6 by building a project of its own with
      `xcodebuild` (a Mac app owning one synchronized folder of some sixty files of every
      kind, a framework target with public and private headers, an exception set, an
      `explicitFolders` entry, a build-phase exception set, then the same app for the
      simulator) and by building NetNewsWire itself at the pinned commit with
      `CODE_SIGNING_ALLOWED=NO`; it is the reference `XcodeFormulaEmitter` follows
      (`resource(at:)`, `folderRole(at:)`, `neverCopiedExtensions`).

      *The rule.* Every file under a `PBXFileSystemSynchronizedRootGroup` is a member of
      each target that owns the group, less the owner's `membershipExceptions`, plus
      what an exception set naming another target lends it. A member is then sorted by
      its type:
      - *Compiled*: `.swift`, `.c`, `.m`, `.mm`, `.cpp`/`.cc`/`.cxx` (sources phase);
        `.xib` and `.storyboard` (ibtool, to a `.nib`/`.storyboardc` at the document's
        place); `.xcstrings` (to `<lang>.lproj/<Table>.strings`/`.stringsdict` for each
        language with a translation); `.xcassets` and `.icon` folders (actool, to
        `Assets.car` and the icon). Not probed but compiled by a rule Xcode has, and so
        never copied either: assembly, Metal, lex/yacc, `.intentdefinition`,
        `.xcmappingmodel`, `.mlmodel`; a `.xcdatamodeld`, and a `.docc` catalog (no
        documentation build in a plain build; nothing of it reaches the bundle).
      - *Neither compiled nor copied*: headers (`.h`, `.hh`, `.hpp`, `.pch`), a module
        map, `.apinotes`, every `.entitlements` file — the one `CODE_SIGN_ENTITLEMENTS`
        names and any other — and `.exp` and `.inc`, which Xcode puts in the sources phase
        and warns "no rule to process file". In a framework target a header an exception
        set lists under `publicHeaders` goes to `Headers/`, under `privateHeaders` to
        `PrivateHeaders/`, any other nowhere; an app or extension copies no header.
      - *Copied, as the bytes they are*: everything else. A `.plist`, `.json`, `.html`,
        `.css`, `.js` (in a synchronized folder a `.js` is a resource, not a source), `.sdef`,
        `.rtf`, `.pdf`, `.icns`, `.png`, `.jpg`, `.ttf`, `.opml`, `.txt`, a Markdown file,
        an `.xcconfig`, a `.provisionprofile`, a `.gyb` template, `.def`, `.xctestplan`,
        `.storekit`, `.xcfilelist`, `.order`, scripts, a file of a type Xcode does not
        know (`.xyz`) or with no extension. A plist and a PNG are the same bytes in the
        Mac build (`CopyPlistFile`, `CopyPNGFile`); a `.strings`/`.stringsdict` is written
        again as UTF-16 (`builtin-copyStrings --outputencoding UTF-16`), which Semel does
        not do — `Bundle` reads either. A hidden file is copied too (`.gitkeep`), except
        what `builtin-copy` always leaves out (`.DS_Store`, `CVS`, `.svn`, `.git`, `.hg`);
        Semel's push takes no hidden file, so none reaches its bundle.
      - *The target's own Info.plist* (`INFOPLIST_FILE`), when no exception leaves it out,
        is copied too: on the Mac into `Resources/` with the warning "The Copy Bundle
        Resources build phase contains this target's Info.plist file", and on iOS, where
        it lands where the built plist goes, the build fails on "Multiple commands
        produce …/Info.plist". Semel never copies it: it is the plist's base.

      *Where a copied file goes.* Flat: under the bundle's resources (a Mac bundle's
      `Contents/Resources/`, an iOS bundle's root) by its name alone, whatever folders
      it sits in — `Shared/Resources/GlobalKeyboardShortcuts.plist` is
      `Contents/Resources/GlobalKeyboardShortcuts.plist`, `Sub/deep.json` is `deep.json`.
      A file in an `.lproj` keeps its language folder and loses everything above it:
      `Sub/en.lproj/Nested.strings` is `en.lproj/Nested.strings`. Two files flattening to
      one name are Xcode's "Multiple commands produce" error. A plain subfolder is a
      group — walked, even one with a dot in its name (`Code.group/Inner.swift` compiled,
      `Dotted.Name/inner.txt` copied flat). A folder Xcode takes as one item is copied
      whole, under its name, with what it holds laid out as it is: a `.bundle`, an
      `.rtfd`, and a folder the group names in `explicitFolders` (NetNewsWire's `xcconfig`
      group names `common`). Xcode asks the system whether a folder's extension is a
      package type: `.nnwtheme` became one on the machine once NetNewsWire had been built
      (and registered with Launch Services) — the probe's `Theme.nnwtheme` was copied
      whole — and is a group anywhere else. A hermetic build cannot ask, so Semel's list
      is `.bundle` and `.rtfd`; NetNewsWire's own themes are folder references in the
      resources phase (10), not in a synchronized folder, so nothing of it depends on this.

      *Exception sets.* `membershipExceptions` for the owner leaves out the named file,
      or a folder Xcode takes as one item with all it holds (a catalog, a bundle); an
      entry naming a plain folder leaves out nothing — with `ExcludedFolder` or
      `ExcludedFolder/` among the owner's exceptions, a Swift file under it was compiled
      and a text file under it copied. Semel does the same since 19 (it left out
      everything under such an entry). `/Localized/…` is 9's.
      `additionalCompilerFlagsByRelativePath` gives one source its own flags (the probe's
      `Helper.c` built with `-DPROBE_FLAG=7`) and changes nothing about resources; read
      since 19. A `PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet` puts a
      member into another build phase *as well* — the probe's `Copied.txt`, sent to a
      Copy Files phase for `Resources/Extra`, landed in both `Resources/` and
      `Resources/Extra/`; read since 19. A resources phase (a group-listed target) copies
      whatever it lists unless a compiler takes it, whatever its type.

      *As built.* `XcodeFormulaEmitter.resource(at:listedInResourcesPhase:)` sorts a file
      by the rule; `folderRole(at:explicitFolders:)` says whether a folder is a group, a
      catalog, copied whole (`FolderTreeBuilder(under:)` merged into the resources, as a
      folder reference is) or not built; the target's own `INFOPLIST_FILE` is skipped by
      path; `XcodeProject.SynchronizedFolder` reads `explicitFolders`; the converter no
      longer walks into a folder copied whole. The same for every bundle the formula
      writes, the extensions' too. Pinned by `XcodeFormulaEmitterTests` over a copy of the
      probe project — the files the bundle copies are exactly the thirty-seven Xcode
      copied, at Xcode's places; the folders copied whole; the rule file by file; the
      simulator's bundle with the Info.plist once — and `XcodeProjectConverterTests` over
      the NetNewsWire fixture with the clone's `Mac` and `Shared` files: each Mac bundle
      copies exactly what Xcode's build of the same commit copied (the app eighteen
      files, the four keyboard shortcut plists among them; the Share extension its icon
      and `SafariExt.js`; the Safari extension its toolbar icon). End to end by
      `swift-binary-target-app`, whose synchronized folder now holds a plist and, two
      folders down, a JSON file, which the app reads from its bundle at launch and
      prints (`HelloApp` is a hand-written formula, so it cannot show the emitter's rule),
      and by `netnewswire-mac`, which now expects the plists, the article view's files,
      `ContentRules.json` and the `.sdef`.

      *Compared with Xcode's bundle.* The export of a fresh clone built by Semel and the
      `NetNewsWire.app` `xcodebuild` built from the same commit hold the same files but
      for: the package products Xcode embeds as frameworks under `Contents/Frameworks`
      (Semel links them into the executable), Xcode's Debug `.debug.dylib` and
      `__preview.dylib`, `Contents/PkgInfo` (`APPL????`, which Semel writes since 19), the
      package resource bundles' layout (Xcode gives a Mac resource bundle `Contents/` with
      an `Info.plist`; Semel's are flat, which `Bundle` also reads), and the signatures.
      `Contents/Resources` lists the same forty-five entries, the `.lproj` folders
      holding the same files.

      *Launched* (2026-09-29, `open` on the export of a fresh clone, pinned commit,
      overlay, `prepare --platform macos`, `build`): it stays up — running after
      several minutes, no crash report — with two windows on screen, one 1319×882, the
      main window, and one 486×516, most likely Sparkle's second-launch prompt to check
      for updates automatically (its defaults say it has launched before; window titles
      were not readable from the session). The article view's web content processes
      started and loaded from the resources folder. The only error of the app's own is
      `OPML read from disk failed`, the first-run read of a `Subscriptions.opml` that is
      not there yet. The container had been made by the launch that trapped, which had
      already set `OnMyMac-imported` before trapping, so the default feeds were not
      imported this time and the sidebar's account is empty: that launch's leftovers,
      not the build. What would stop it next was not seen; not tried: a sync account,
      iCloud (its entitlements are left out of an ad-hoc signature, 11).

   19. ~~**The Mac app's leftovers.**~~ Done (2026-09-29, XcodeProjectConverter v12,
      `InfoPlistBuilder` v3, `CodeSigner` v2). What was established, and how, first: the
      pinned commit's `xcodebuild -showBuildSettings` for the Mac app and both extensions in
      Debug and Release, an `xcodebuild build` of the Mac app (its `swiftc` and
      `codesign`-less lines, `CODE_SIGNING_ALLOWED=NO`), and a second probe project built
      by Xcode 26.6 — a Mac app owning one synchronized folder whose owner's set gives
      `Helper.c` and `Flagged.swift` flags of their own and names the plain folder
      `Plain`, two sets naming copy-files phases, and the Swift settings below, signed
      ad-hoc with the hardened runtime (`XcodeProjectTests.exceptionProbe` holds it and
      what Xcode made of it).

      - *The target's own Swift settings.* NetNewsWire's files set, for all three Mac
        targets, `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG SKIP_APP_GROUP_ACCESS`
        (Debug only), `OTHER_SWIFT_FLAGS` — Debug's `-DDEBUG -DSKIP_APP_GROUP_ACCESS
        -Xfrontend -warn-long-function-bodies=800 -Xfrontend
        -warn-long-expression-type-checking=1000`, Release's `-DRELEASE`, each replacing
        the project file's two upcoming features without `$(inherited)` — and
        `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`; no `SWIFT_STRICT_CONCURRENCY`, no
        `SWIFT_UPCOMING_FEATURE_*`, no `OTHER_CFLAGS`. `XcodeSwiftSettings` turns the
        evaluated settings into what Xcode's `Swift.xcspec` says each gives: conditions,
        every `SWIFT_UPCOMING_FEATURE_*` (`YES` a feature, `MIGRATE` its `:migrate`), the
        experimental `DebugDescriptionMacro`, `SWIFT_STRICT_CONCURRENCY` (`targeted` a
        flag, `complete` the `StrictConcurrency` feature), `SWIFT_ENABLE_BARE_SLASH_REGEX`,
        `SWIFT_DEFAULT_ACTOR_ISOLATION`, `SWIFT_STRICT_MEMORY_SAFETY`, warnings as errors
        or suppressed, and `OTHER_SWIFT_FLAGS` split as Xcode splits a list; the ones
        Xcode conditions on a Swift version below 6 give nothing in Swift 6. Xcode's
        spec defaults that pass something unasked are among `XcodeBuildSettings`'
        defaults — `DebugDescriptionMacro` on, bare-slash regex on (below 6), the five
        features Approachable Concurrency stands for following it. The emitter hands them
        to `SwiftCompiler` as the literals a package's `swiftSettings` become since PR
        #137: `defines`, `upcomingFeatures`, `experimentalFeatures`, and the flags as
        `unsafeFlags`, a JSON list (conditions were `-D`s in `arguments` before). Each Mac
        compiler now gets what Xcode's `swiftc` line has: `-DDEBUG -DSKIP_APP_GROUP_ACCESS`,
        the Debug flags, `-enable-experimental-feature DebugDescriptionMacro`,
        `-warnings-as-errors` — and the probe's `-strict-concurrency=targeted
        -enable-bare-slash-regex`, its six upcoming features in Xcode's order. The other
        `SWIFT_ENABLE_*` settings are how Xcode builds (batch mode, explicit modules,
        testability, library evolution), not what the language is, and not carried.
        `OTHER_CFLAGS` reaches the target's C-family sources as `arguments` on both clang
        nodes, the compiler without a forced include (`-include`, `-imacros`), which the
        preprocessed text already holds; `GCC_PREPROCESSOR_DEFINITIONS` is split the same
        way now, quotes honoured. ISSUE: a C++ source takes `OTHER_CFLAGS`, not
        `OTHER_CPLUSPLUSFLAGS`; a flag holding a comma splits.
      - *`PkgInfo`.* Xcode writes one for an application (its package type's
        `GENERATE_PKGINFO_FILE = YES`, which `XcodeBuildSettings` now provides for an
        application) and none for an extension: NetNewsWire's app has `APPL????`, neither
        `.appex` has one. `InfoPlistBuilder` has a `pkgInfo` port, the built plist's
        `CFBundlePackageType` and `CFBundleSignature`, `????` for one missing or not a
        four-character code; the Info.plist is now `infoPlist_<Target>()` and the bundle
        takes `.plist` and, for an application, `.pkgInfo` at `Contents/PkgInfo` (an iOS
        bundle's root, beside its plist).
      - *The two exception kinds.* `XcodeProject` reads an owner's
        `additionalCompilerFlagsByRelativePath` (`SynchronizedFolder.compilerFlags`) and a
        borrower's (`Borrowed.compilerFlags`); such a C-family source gets a preprocessor
        func and a compiler of its own, the flags after `OTHER_CFLAGS`, as Xcode passes
        them after its common arguments. A Swift source's flags reach nothing: the probe's
        `-DPROBE_SWIFT_FILE_FLAG` was on no `swiftc` line. A set naming a copy-files phase
        is a `PhaseCopy` of the phase's target, and the emitter copies the file — a folder
        whole — where `dstSubfolderSpec` and `dstPath` say, as well as where its own type
        puts it (`BundleLayout.folder(forCopyDestination:)`: wrapper, executables,
        resources, frameworks, shared frameworks, shared support, plug-ins; the products
        folder or an absolute path is named in the formula as outside the bundle), which is
        the probe's bundle file for file. Fixed on the way: such a set names no target,
        and the owner's reading took a set with no target for its own, so `Copied.txt`
        would have been left out of the owner. ISSUE: a set naming a sources or resources
        phase is not read; none has been met.
      - *A plain folder in a membership exception* leaves out nothing under it, as in
        Xcode (the probe compiled `Plain/Under.swift` again): `SynchronizedFolder.excludes`
        leaves out what is under an entry only when the folder is one item to Xcode
        (`folderRole`), and `excludedPaths(folders:)` hands the Swift compiler no entry
        naming a group it walked. File entries and `/Localized/…` are as they were.
      - *Sparkle's download.* `Vendoring.keepOnlyTheXCFramework` leaves in
        `semel-artifacts/<Target>` only `<Target>.xcframework` (else the first by name,
        the one the converter takes) after a checkout's download is copied or a `path:`
        zip unzipped, and leaves a folder holding none as it is, for the converter to say
        what is there. Sparkle's `bin/`, `CHANGELOG`, `INSTALL`, `LICENSE` and
        `SampleAppcast.xml` are no longer pushed or locked; the lock's `content` is over
        the package and the framework.
      - *Hardened runtime.* `CodeSigner` takes a `hardenedRuntime` literal and signs the
        bundle with `-o runtime`, where Xcode's probe line puts it (`codesign --force --sign
        - -o runtime --entitlements …`); the emitter states it when `ENABLE_HARDENED_RUNTIME
        = YES`. NetNewsWire's Release sets it for the app; the Mac extensions' common file
        sets it in both configurations, so in Debug — the roster's — the app is signed
        without and both extensions with. The nested bundles a signer signs again keep
        their flags with their entitlements (`--preserve-metadata=entitlements,flags`, as
        Xcode keeps them when it signs what it embeds), or the app's signing would take an
        extension's hardened runtime away; Sparkle's own binaries, signed ad-hoc with the
        hardened runtime by their vendor, keep it too.
      - *Pinned by* `XcodeProjectTests` (the probe's sets read; a borrowed source's flags;
        a plain folder's entry), `XcodeFormulaEmitterTests` (the probe's bundle, the copy
        destinations, a folder copied whole into a tree already there, a source's own flags
        on clang and a Swift source's nowhere, the forced include, the Swift literals as
        Xcode's line, the hardened runtime, an iOS `PkgInfo`), `XcodeBuildSettingsTests`
        (the list splitting, each language setting against the spec, the literals, the
        defaults), `XcodeProjectConverterTests` over the NetNewsWire fixture (Debug's and
        Release's Swift settings on all three compilers, `PkgInfo` on the app alone, the
        hardened runtime per target and configuration), `InfoPlistBuilderTests`,
        `CodeSignerTests` (the command lines, and the real `codesign` keeping an
        extension's hardened runtime through the app's signing) and `PrepareTests` (a
        download's and a zip's extras dropped, the lock over what is left, an
        `.artifactbundle` folder untouched). End to end: `netnewswire-mac` now expects
        `Contents/PkgInfo`, and passed through all four hermeticity builds with the app and
        both extensions compiled under `-warnings-as-errors` and the Debug flags (1,208 s
        for the test, `prepare` included, whose copy held `semel-artifacts/Sparkle/` with
        `Sparkle.xcframework` alone); `food-truck-mac` passed too (142 s). The extensions' hardened runtime is not checked by the
        roster: the unit tests pin it, the real `codesign` among them.

   20. ~~**The iOS app.**~~ Done (2026-09-29, XcodeProjectConverter v13, SwiftLinker v4).
      The project's last target Semel did not build: the converter built the first
      application it found, which is the Mac app, whatever the SDK.

      - *Which application a build is for.* `XcodeProject.application(forSDK:named:settings:)`:
        the application whose `SDKROOT`, evaluated through `XcodeBuildSettings`, is of the
        SDK's platform family — `iphoneos` for an `iphonesimulator` build, `macosx` for a
        Mac one (`platformFamily(ofSDK:)`: a simulator SDK's family is its device SDK's) —
        or, with `SDKROOT = auto`, whose `SUPPORTED_PLATFORMS` names it. An application
        stating neither is taken for any platform when none states this one (only a
        hand-written project lacks `SDKROOT`). Two for one platform are an error naming
        both, and none an error naming each with what it builds for; the converter's
        `application` property picks one by name, which `prepare --application <target>`
        writes into the formula. The converter demands every application's xcconfig files
        first, chooses once they are in, and then the chosen one's extensions'; while they
        are in flight it already walks the one application there can be (the only one, or
        the one named), so the waits still overlap, and checks its platform once they are
        in. `XcodeProjectFacts` makes the same choice from the disk for every question
        `prepare` asks (deployment target, undefined references, the compiled sources, the
        ungenerated ones), which prints `application NetNewsWire-iOS for iphonesimulator`,
        and puts in place the xcconfig files of every application, since the choice reads
        them. Food Truck has two applications for every platform, `Food Truck` and `Food
        Truck All`, both multiplatform, so its two roster entries now name `Food Truck`
        (`Project.application`). Pinned by `XcodeBuildSettingsTests` (NetNewsWire's two
        apps by platform, the errors, a name, `auto`, an unstated platform, the families),
        `XcodeProjectConverterTests` (the simulator formula over the fixture: the iOS app,
        the Share and widget extensions under `PlugIns/`, the storyboards and Objective-C,
        nothing of the Mac app's) and `PrepareTests` (the platform's application and its
        deployment target, `--application` in the formula).
      - *What stopped it*, in the order a fresh clone with the overlay met it
        (`prepare --platform ios-simulator`: `IPHONEOS_DEPLOYMENT_TARGET` 17.0,
        `arm64-apple-ios17.0-simulator`, the `apple.*` blocks with ibtool's, clang's for the
        app's `SFSafariViewController+Extras.m`): only the choice above. With the iOS app
        chosen the first build ran 398 nodes with no error in 58 s cold and exported
        `NetNewsWire.app`. Nothing the entry expected needed a change: the settings of
        `…ios_target_common.xcconfig` and its `[sdk=iphonesimulator*]` conditions, the flat
        layout, the WidgetKit extension as an `.appex` under `PlugIns/`, the Share extension
        that owns no folder and borrows its sources, xibs and catalog from `iOS` (15), the
        `Base.lproj` storyboards compiled to `.storyboardc` (8) — `Main`, `LaunchScreenPhone`
        and `LaunchScreenPad`, which `UILaunchStoryboardName` and its `~ipad` name — the
        bridging header `iOS/NetNewsWire-iOS-Bridging-Header.h` (6), and the iOS plist
        keys, which the project's own `iOS/Resources/Info.plist` carries.
      - *Launched* (`simctl boot`, `install`, `launch`, an iPhone 17 on iOS 26.5): it
        started and stayed up, imported the default feeds and refreshed them — the Feeds
        list with Today, All Unread and each feed's unread count — and asked for
        notification permission; both extensions were registered (`pluginkit -m`). But it
        ran as an app built with an old SDK, in the look iOS keeps for one: every image
        Semel linked recorded its deployment target as the SDK it was built with
        (`LC_BUILD_VERSION`: `sdk 17.0`, where Xcode's says `sdk 26.5`; a Mac link said
        `sdk 15.0`). The swift driver links through clang with `--sysroot`, from which clang
        reads no SDK version, so ld is told none and takes the deployment target. The
        linker now also passes `-Xclang-linker -isysroot -Xclang-linker <SDK>`, from which
        clang reads `SDKSettings.json` and tells ld the version as it does for Xcode (an
        archive is not linked by ld and gets none). Launched again, the app has iOS 26's
        floating glass toolbar and buttons. Every app Semel linked had the stamp: the Mac
        NetNewsWire, Food Truck, IceCubes. Pinned by `SwiftLinkerTests` and by the roster
        entry, which checks each executable's `sdk`. Seen in the log and not Semel's to
        fix in an unsigned bundle: `NSUbiquitousKeyValueStore` initialised without the
        iCloud entitlement.
      - *Compared with Xcode's bundle* (`xcodebuild -scheme NetNewsWire-iOS -sdk
        iphonesimulator CODE_SIGNING_ALLOWED=NO`, same commit): the same files but for the
        package products Xcode embeds as frameworks (Semel links them in), the
        `.debug.dylib` and `__preview.dylib`, the resource bundles'
        `Info.plist`, the signature, and two things Semel does not do yet: the App Intents
        metadata (`Metadata.appintents`, `Base.lproj`/`en.lproj/nlu.appintents`, from
        `appintentsmetadataprocessor` and the NL training step over the app's `AppIntents`
        folder, so the app's Shortcuts actions are not registered), and an extension's
        standalone icons: Xcode gives actool `--standalone-icon-behavior all` for an app
        extension (`default` for an app), so its widget holds seventeen `AppIcon*.png` and
        its Share extension an `AppIcon1024x1024.png` where Semel's hold two and none.
        `NetNewsWire_iOSwidgetextension_target.xcconfig` is in both: the `xcconfig`
        folder's exception set lends it to the iOS app, which copies it as a resource.
      - *In the roster* as `netnewswire-ios` (`Projects.netNewsWireIOS`,
        `ExternalProjectTests.test_netNewsWireBuildsTwiceForTheSimulator`): the pinned
        commit, the `external/netnewswire` overlay, `--platform ios-simulator`, twenty-two
        expected products across the app and both extensions, three required executable,
        everything under `NetNewsWire.app`, and each executable checked to record the
        simulator SDK's version (`AppInspection.checkRecordsTheSDKVersion`). All four
        hermeticity builds, byte for byte with no exemption, in 270 s for the whole test,
        clone and `prepare` included (398 s on a second run on a busier machine, 249 s after
        rebasing onto 19, whose Swift flags the iOS app now compiles under too). The
        Food Truck entries (both now naming their application), `netnewswire-mac` and
        `icecubes-app` pass with the linker's new stamp.

   What remains for NetNewsWire: the iOS app's App Intents metadata and its extensions'
   standalone icons (20); a signed simulator or device build, with the entitlements an
   unsigned bundle lacks. (1's residual, a framework's links as copies, is done: links
   travel in trees.)
3. *CodeEdit* — `open`; the first slice landed (2026-10-01): the Mac app compiles, links,
   is signed, exports and stays up when launched, and it opens its welcome window as Xcode's
   build of the same commit does (16). Since the second slice the same day (5, 10 and 12
   below) it does so from a fresh clone with nothing stepped around: `prepare --platform
   macos`, then `build`, 914 nodes and no errors, the build following `.all-contributorsrc`
   by its path — and the export verifies with `codesign --verify --deep --strict`, holds
   `Sparkle.framework` alone under `Contents/Frameworks` (the grammars linked into the
   executable, 290 `tree_sitter_` symbols, no load command for them), and
   `.all-contributorsrc` and `Assets.car` under `Contents/Resources`; launched by `open`, it
   stays up. A second `build` of the unchanged clone pushes all 8,635 files as unchanged,
   the dot-file among them, and settles with no work. Pinned at `fa2aebd86373211c78626074b53ab75010767575` (main,
   2026-08-18, "macOS Tahoe Navigator, Inspector, and Utility Area"). The clone is not what
   this entry said from memory: the tree-sitter grammars are not C targets at all.

   *What the project is.* Four targets: the app `CodeEdit`, a Finder Sync extension
   `OpenWithCodeEdit` (`com.apple.product-type.app-extension`, embedded under `PlugIns`),
   and the unit and UI test bundles. Five synchronized folders: `CodeEdit` (the app's; an
   exception set leaves out its `Info.plist`, and a build-phase set sends
   `Features/Extensions/codeedit.extension.appextensionpoint` to a copy phase for
   `$(EXTENSIONS_FOLDER_PATH)`), `CodeEditTests`, `CodeEditUITests`, `Configs` and
   `OpenWithCodeEdit` — the last two owned by no target: the extension owns no folder and
   borrows `FinderSync.swift` and `Media.xcassets` from `OpenWithCodeEdit` through an
   exception set naming it. The app's resources phase lists a folder reference
   (`DefaultThemes`), `Package.resolved` from inside the `.xcodeproj`, and the hidden
   `.all-contributorsrc`; its sources phase lists `Documentation.docc` and four build files
   with no file at all (`(null) in Sources`). Two script phases (TODO/FIXME warnings and a
   `swiftlint:disable all` check, both greps over the sources, neither writing anything),
   an *Embed Frameworks* phase for `CodeEditKit` (a `.dynamic` product, linked statically
   here as every package product is), and a SwiftLint plugin run by the app through a
   target dependency on the product `plugin:SwiftLint`.

   *Settings.* Five configurations (Debug, Alpha, Beta, Pre, Release), each project and
   target configuration based on `Configs/<Name>.xcconfig` in the anchor form, each file
   three assignments (`CE_APPICON_NAME`, `CE_VERSION_POSTFIX`, `CE_COPYRIGHT`) that the
   project file and `CodeEdit/Info.plist` name in the `${…}` form. Swift 5 mode,
   `MACOSX_DEPLOYMENT_TARGET = 14.0`, the hardened runtime, `ENABLE_APP_SANDBOX`,
   `RUNTIME_EXCEPTION_ALLOW_JIT` and `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION` on the
   app, `GENERATE_INFOPLIST_FILE = NO` beside `INFOPLIST_KEY_*` settings Xcode therefore
   ignores, `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES`, and
   `CODE_SIGN_IDENTITY = -`. The entitlements files: the app's sandbox, user-selected
   files read-write, app-scope bookmarks, network client and an app group; the extension's
   the app group alone. `ASSETCATALOG_COMPILER_APPICON_NAME = ${CE_APPICON_NAME}` names
   `AppIconDev` in Debug, a set no catalog has: the icons are Icon Composer files in
   `ProductIcons/`, which the project does not reference, so Semel's bundle has no icon
   (what Xcode's has was not checked).

   *Packages.* The project references eighteen remote packages through twenty-two
   `XCRemoteSwiftPackageReference` objects (LanguageClient, LanguageServerProtocol,
   ZIPFoundation and CodeEditSourceEditor twice each, one of each pair not in
   `packageReferences`); `Package.resolved` pins thirty-four, all of which `prepare`
   vendors (808 MB). C-family targets the app reaches: tree-sitter's `TreeSitter`
   (`lib`, `sources: ["src"]`, `exclude:` its amalgamation `src/lib.c`,
   `.headerSearchPath("src")`, two defines, one with a value, `cLanguageStandard: .c11`),
   swift-glob's `FNMDefinitions`, and three Objective-C ones: CodeEditTextView's
   `CodeEditTextViewObjC` with its own `include/module.modulemap`, TextStory's `Internal`
   (`publicHeadersPath: "."`), LogStream's `ExternalAppLoggerHeaders`; GRDB 6's `CSQLite`
   is a system library whose module map brings a shim header. SwiftTreeSitter's
   `TestTreeSitterSwift` (a grammar's `parser.c` and `scanner.c`) is reached by its tests
   alone. *The grammars* are CodeEditLanguages' binary target `CodeLanguagesContainer`, a
   `path:` zip (33 MB) of an xcframework holding one *static* framework,
   `CodeLanguages_Container.framework` (arm64 and x86_64 archives, 375 MB unzipped, every
   grammar compiled in), with the queries as the package's `.copy("Resources")`. Binary
   targets besides: Sparkle 2.3.0's xcframework (by `url:`), and SwiftLintPlugin's
   `SwiftLintBinary` `.artifactbundle`, which only the plugin uses. Build-tool plugins: the
   one SwiftLint plugin, on the app and on the non-test targets of CodeEditKit,
   AboutWindow, WelcomeWindow, CodeEditTextView and CodeEditSourceEditor; none generates
   sources. No macros reach the app: swift-syntax 509.1.1 is there for
   swift-snapshot-testing's `InlineSnapshotTesting`, which only `CodeEditTests` links.

   *Plugins, decided.* Semel runs no package plugin: running one hermetically wants its
   executable built or taken from an `.artifactbundle`, a sandbox holding the target's files
   and a work folder, and the commands it returns each a node whose outputs a compile takes
   as sources — a design, not a fix. A target builds without its plugins, and the
   conversion says which by name, once, as a notice: `Build-tool plugins are not run
   (B-77): SwiftLint (SwiftLintPlugin) on CodeEditTextView. Each target builds without what
   its plugins would do.` — `SwiftFormulaConverter` from the targets' `pluginUsages`,
   `XcodeProjectConverter` from a target dependency on a `plugin:` product (and a
   `plugin:` product among a target's products is never linked). A target whose sources
   would come only from its plugins fails the conversion naming the target and the plugins,
   rather than reaching `swiftc` with nothing to compile (done 2026-10-01): a package's
   Swift target a product reaches that names plugins and holds no `.swift` file its
   `sources:` and `exclude:` keep (`SwiftPackageConversionError.sourcesOnlyFromPlugins`,
   Swift converter v20), and an Xcode target that runs plugins with no Swift or C-family
   source in its folders that its exceptions keep, none listed and none borrowed
   (`XcodeProjectError.sourcesOnlyFromPlugins`, Xcode converter v18, which now reports
   every error the emitter names as the formula's, with the pass's demands, as it reports
   the project's other errors). Pinned by `SwiftFormulaConverterTests` and
   `XcodeProjectConverterTests`. SwiftLint's plugin writes nothing the build uses, so
   CodeEdit loses nothing by it.

   *What stops it*, in the order a `build` of a fresh clone after `prepare --platform macos`
   met it (the Swift converter v16, the Xcode converter v15, `SwiftCompiler` v4,
   `ClangPreprocessor` v7):

   1. ~~**Products with no package.**~~ Done. The app names `CodeEditSourceEditor` through
      eight product dependencies and `SwiftTerm` through four, five and three of them
      with no `package` — left from when those were local packages — and the converter
      took each for a local package's and stopped: `CodeEdit links CodeEditKit,
      CodeEditSourceEditor, SwiftTerm from local packages, and the project has none`.
      Xcode finds a product by name in the whole package graph (`PACKAGE-PRODUCT:<name>`),
      so `XcodeProject` now takes a dependency naming no package as the remote package's
      product when another dependency of the project names that product with its package,
      and names each product once (the formula had one wire per dependency, eight for one
      product). Pinned by `XcodeProjectTests` over a fixture of CodeEdit's shapes.
   2. ~~**A documentation catalog in the sources phase.**~~ Done. `Documentation.docc` was
      refused as a source that is not Swift; a documentation catalog builds nothing a build
      uses (`RUN_DOCUMENTATION_COMPILER = NO` on the app), and is passed over.
      `XcodeFormulaEmitterTests`.
   3. ~~**A test-only dependency waited for.**~~ Done. CodeEditSourceEditor declares
      swift-custom-dump for its tests; Xcode never fetches it, and the converter waited for
      it for ever, because a target's `byName` dependency (`"CodeEditTextView"`) that is not
      a local target made it follow every dependency. A `byName` naming a package
      dependency by its identity or repository name is that dependency, as SwiftPM's
      resolution reads it; one naming none still follows them all.
      `SwiftFormulaConverterTests`.
   4. ~~**A target's own module map.**~~ Done. `CodeEditTextViewObjC` has its own
      `include/module.modulemap` covering the header its source includes; preprocessed
      with modules and `-fmodule-name`, clang wraps that header's text in `#pragma clang
      module begin/end CodeEditTextViewObjC`, and the compiler, handed the text alone,
      fails on it (`must specify '-fmodule-name'`, and with it `no module map available`).
      `ClangPreprocessor` now hands the target's own module on as the text it is, taking
      out the two pragmas and nothing else (another module's are kept). Pinned by
      `ClangPreprocessorTests`, and end to end by `swift-c-package`'s new `Smoothing`.
   5. ~~**A hidden file in the resources phase.**~~ Done (2026-10-01). `.all-contributorsrc`,
      which the About window's contributors list reads from the bundle, was never pushed:
      the lister left dot-names out whatever it was asked, so `push
      codeedit/.all-contributorsrc` said `no such file or directory` and the bundle, the
      signer and the product waited on it. *The rule:* a dot-named **file** is pushed when
      a path names it exactly — `push codeedit/.all-contributorsrc`, and so `build`'s follow
      of a missing source (B-110), which pushes the path the settle names — while `*`,
      `**`, a folder walk and a dot-named folder still take no dot-name
      (`ExternalFileSystemLister.hiddenFile(named:inDirectoryPath:)`, asked by the matcher
      only for a literal last segment). A checkout's `.git`, `.github` and `.swiftpm` stay
      where they are, and a vendored folder's fold and its lock are what they were: the
      lock is only over `Dependencies`, and `prepare`'s fold is told of no dot-name. *The
      fold:* a dot-file once pushed is in its folder's content root on the engine's side
      (a dot-file in the graph is in the root), so the push's fold of the disk
      (`FolderOnDisk`, B-132) is told which ones the server holds —
      `HeldFolderRoot.hiddenFiles`, read in the same snapshot as the roots by one more
      query, a range over the index on `(parentNodeID, name)` (`ProtocolVersion` 21) — and
      folds each it finds on disk. The roots agree, so an unchanged push of the folder
      sends nothing; an edited dot-file is sent again by a push of its folder; one gone from
      disk is reported and kept as any pushed file is; one nobody pushed (a ghost, or a
      file only on disk) is named by no root. Pinned by `ExternalFileSystemListerTests`,
      `FolderOnDiskTests`, `HeldTreeTests`, `ManifestPushScaleTests`, `BuildCommandTests`
      and `XcodeFormulaEmitterTests` (a listed dot-file is a `StaticFile` copied under its
      name), and end to end by `swift-binary-target-app`, whose resources phase lists
      `.greeterrc`: the build says `semel.fmla needs .greeterrc`, pushes it, and the
      exported app prints it, through all four builds.
   6. ~~**`package` declarations.**~~ Done. CodeEditTextView's `package(set) public var
      textStorage` needs `-package-name`, which SwiftPM passes to every target of a
      package: `SwiftCompiler` takes a `packageName` literal, which the Swift converter
      states (the manifest's name as a C99 identifier) for every package target.
      `SwiftCompilerTests`, `SwiftFormulaConverterTests`, and `swift-c-package`'s `App`
      calling `Zipper`'s `package` function.
   7. ~~**Swift inside a documentation catalog.**~~ Done. SwiftTreeSitter keeps a tutorial's
      `Package.swift` in `Sources/SwiftTreeSitter/Documentation.docc/Code/`, and the
      compiler took it: `no such module 'PackageDescription'`. A `.docc` folder is one item
      to SwiftPM and neither sources nor resources; `SourceScope` does not walk one and
      neither does the converter (`PackageResources.isWalked`). `SwiftCompilerTests`, and
      `swift-c-package`'s `Zipper.docc`.
   8. ~~**`SWIFT_PACKAGE`.**~~ Done. GRDB 6 imports its `CSQLite` shims `#if SWIFT_PACKAGE`
      and the SDK's `SQLite3` otherwise, which lacks `_registerErrorLogCallback`. SwiftPM
      defines `SWIFT_PACKAGE` for every Swift target and `SWIFT_PACKAGE=1` for every C one;
      the converter now does, first among each target's `defines`. `swift-c-package`'s
      Swift and Objective-C `#error` without it.
   9. ~~**A product the frameworks phase links.**~~ Done. `LanguageServerProtocol` and
      `LanguageClient` are in the app's *Frameworks* phase and not among its
      `packageProductDependencies`, and Xcode links from the phase: `no such module
      'LanguageServerProtocol'`. A target's products are both lists now.
   10. ~~**Generated asset symbols.**~~ Done (2026-10-01). `Color.amber`,
      `NSColor.folderBlue`, `ImageResource.gitHubIcon`: `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS`
      is `YES` by Xcode's default (`AssetCatalogCompiler.xcspec`) and
      `…_SWIFT_ASSET_SYMBOL_EXTENSIONS` is `YES` here, and actool writes
      `GeneratedAssetSymbols.swift`, which the app's compile takes as a source.
      `AssetCatalogCompiler` (v4) publishes it on a new port, `swiftAssetSymbols`. Not from
      the compile's own run, as first planned: on Xcode 26.6 actool given `--bundle-identifier`
      with `--generate-swift-asset-symbols` writes the Swift and compiles nothing — no
      `Assets.car`, no partial plist — and without it compiles and writes no Swift, so the
      node makes a second run over the same sandboxed catalogs once the compile succeeds,
      as Xcode's own `GenerateAssetSymbols` step is separate. The text is a function of the
      catalogs (B-89's invariant, checked over two runs with the colors made in opposite
      orders: symbols in name order, no path in it), so it is published as written; when
      the `Assets.car` of the compile cannot be made canonical, or either run fails, the port
      carries the error. The emitter (v17) writes the symbol literals from the settings —
      `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS`, `…_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS`
      (default `NO`), `…_GENERATE_ASSET_SYMBOL_FRAMEWORKS` (default `SwiftUI UIKit AppKit`;
      actool honours one framework alone and reads any longer list as all three) and
      `…_BUNDLE_IDENTIFIER` (default the product's) — and wires the port into the target's
      compiler as `'GeneratedAssetSymbols.swift'` among `extraSourceFiles`, so every Xcode
      target with a catalog compiles one, as Xcode does. Pinned by
      `AssetCatalogCompilerTests` (the second run's arguments, the port, an error when the
      catalog is not published, and the real actool over two orders), `XcodeFormulaEmitterTests`,
      and end to end by `swift-binary-target-app`, whose app prints its catalog's `Amber`
      through `NSColor.amber`. *Not built:* a package target's catalog (Xcode generates
      symbols for one too, under `#if SWIFT_PACKAGE` with `Bundle.module`); the Swift
      converter compiles none.
   11. ~~**A dependency conditional on the platform.**~~ Done. LanguageClient depends on
      ProcessEnv `.when(platforms: [.macOS])`; the condition, an object among the strings
      of `dump-package`'s array, failed the decoding of the whole entry, so the dependency
      was dropped on every platform and `#if canImport(ProcessEnv)` hid
      `DataChannel.localProcessChannel`. It is decoded now and held where its platforms
      hold — the conversion asks for the platform when a dependency is conditional, as for
      a setting; one conditional on a configuration alone is kept. `SwiftFormulaConverterTests`,
      and `swift-c-package`'s `Zipper`, which depends on `Squeeze` on macOS alone.
   12. ~~**A static framework is embedded.**~~ Done (2026-10-01). The app compiled and
      linked (887 nodes), and the signer failed on
      `Contents/Frameworks/CodeLanguages_Container.framework: Is a directory`: the slice is
      a framework whose binary is an archive, linked into the executable by `-framework` as
      it should be, and embedded as well, which Xcode does not do for a static framework.
      `XCFrameworkSliceSelector` (v4) now reads the framework's binary — the plist's
      `BinaryPath`, else `<Name>.framework/<Name>` — by its first bytes, and for a fat file
      each architecture's where the header puts them (`DataObjectStore.bytes(ofHash:at:count:)`,
      a few reads rather than the 375 MB), and decides the slice's kind, typed
      (`XCFrameworkLibraryKind`: dynamic framework, static framework, static library;
      `FrameworkBinary`: an `!<arch>` archive or relocatable object is static, a Mach-O
      dylib dynamic, a fat file of mixed kinds or anything else an error naming the
      binary). It publishes a fourth tree, `embeddedFrameworks`, the slice when it is a
      dynamic framework and empty otherwise; the Swift converter (v19) defines
      `embedded_<Product>()` over them beside `frameworks_<Product>()`, which still
      compiles and links against every framework (`-F`, `-framework`); the emitter lays
      `embedded_P()` under `Contents/Frameworks`, so a static framework is linked in and
      neither embedded nor signed. Pinned by `XCFrameworkSliceSelectorTests` (a hand-made
      fat-of-archives framework slice, `BinaryPath`, an executable and a missing binary as
      errors, the magic of `libtool -static` and `clang -dynamiclib` output),
      `SwiftFormulaConverterTests` and `XcodeFormulaEmitterTests` (the placement, Mac and
      iOS).
   13. ~~**A copy into the products folder.**~~ Done, before it could bite. The extension
      point goes to `dstSubfolderSpec = 16` (the products folder) at
      `$(EXTENSIONS_FOLDER_PATH)`, which the emitter took for a place outside the bundle
      and left out with a comment. A products-folder path that begins with a setting naming
      a folder of the bundle (`EXTENSIONS_FOLDER_PATH`, `CONTENTS_FOLDER_PATH`,
      `FRAMEWORKS_FOLDER_PATH`, …) is that folder: `Contents/Extensions`.
   14. ~~**The settings' entitlements.**~~ Done. Signed and exported, the app was killed at
      launch: `Library not loaded: @rpath/Sparkle.framework/… different Team IDs` — an app
      with the hardened runtime validates the libraries it loads, and Sparkle keeps its
      vendor's signature. Xcode signs with what the sandbox and hardened-runtime settings
      stand for as well as the file (`RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION` is
      `com.apple.security.cs.disable-library-validation`); the emitter now lays those over
      the file's entitlements — every Boolean and read-only/read-write setting of
      `CoreBuildSystem.xcspec`'s "App Sandbox & Hardened Runtime", with the keys Swift
      Build signs with. `XcodeFormulaEmitterTests`.
   15. ~~**`INFOPLIST_KEY_*` over a plist not generated.**~~ Done. Then the app exited at
      launch: `Unable to find class: CodeEdit.CodeEditApplication`. The project sets
      `INFOPLIST_KEY_NSPrincipalClass` to a class the app does not have, which Xcode
      ignores because `GENERATE_INFOPLIST_FILE = NO`; the emitter wrote it into the plist.
      It reads `INFOPLIST_KEY_*` only for a generated plist now (every roster project that
      sets one also sets `GENERATE_INFOPLIST_FILE = YES`). `XcodeFormulaEmitterTests`.
   16. ~~**No window.**~~ Diagnosed (2026-10-01): not Semel's. With 5, 10 and 12 stepped
      around, the export verifies with `codesign --verify --deep --strict` and, launched,
      stays up idle in its run loop with nothing to see. Xcode 26.6's build of the same
      commit, made in the same session (`xcodebuild build -scheme CodeEdit -configuration
      Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
      -skipPackagePluginValidation`; without the last flag Xcode stops at "Validate plug-in
      SwiftLint"), does exactly the same, and both open their welcome window. Asked from
      inside each process with lldb (Semel's export re-signed, for this alone, with
      `com.apple.security.get-task-allow` added to its own entitlements), `NSApp.windows`
      is one `SwiftUI.AppKitWindow`, identifier `welcome`, title "Welcome To CodeEdit",
      visible, frame 740×464 at (485, 333), occlusion state visible, on the active space —
      by `open`, run directly, with the saved state restored and with
      `-ApplePersistenceIgnoreState YES`, which takes `handleOpen`'s path. What made it look
      like no window is the session: `CGWindowListCopyWindowInfo` lists the window on screen
      at layer 0 with 0×0 bounds for both builds (and real bounds for a probe SwiftUI app's
      window, and for other apps'), `loginwindow` holds two on-screen windows over
      everything at layers 2001 and 2004, `screencapture` cannot make an image of the
      display, and `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` answers 0
      everywhere. So whether the welcome window is drawn on a display was not seen for
      either build; the two are indistinguishable at every level that could be asked.
      There is no `NSPrincipalClass` in Xcode's plist either (item 15), no sandbox denial,
      keychain or Sparkle prompt in the log (Sparkle's automatic checks are off in the
      container's defaults), and no crash report. Comparing the bundles file by file found
      what follows (17, 18, and below).
   17. ~~**The version of a plist not generated.**~~ Done. Xcode's app and extension say
      `CFBundleShortVersionString` 0.3.6, which their files state; Semel's said "Change in
      Info.plist" and 1.0, the targets' `MARKETING_VERSION`s, because the emitter laid the
      generated plist's identity keys over the project's file whatever
      `GENERATE_INFOPLIST_FILE` said. Over a file that is not generated Xcode adds the
      platform's keys (`CFBundleSupportedPlatforms`, `LSMinimumSystemVersion`,
      `DTPlatformName`, and the `DT…`/`BuildMachineOSBuild` keys Semel never writes) and
      leaves the identity and version to the file; the emitter does the same now, and a
      target with no file at all still gets the identity keys. Pinned by
      `CodeEditFixtureTests` over `SemelApple/Tests/Fixtures/CodeEdit` (the project file, the
      five `Configs` xcconfigs, the app's and the extension's plists and entitlements), the
      plists built by `InfoPlistBuilder` from what the emitter hands it. Xcode converter v16.
   18. ~~**A package's resource bundle laid out flat on the Mac.**~~ Done. Xcode embeds a
      package's bundle as a Mac bundle, `<Package>_<Target>.bundle/Contents/Info.plist`
      and `Contents/Resources/…`; Semel embedded the flat layout SwiftPM writes. Foundation
      reads a bundle with no `Contents/` by what is at its top, and CodeEditLanguages'
      bundle has a folder named `Resources` there — its `.copy("Resources")`, the grammars'
      queries — so it took the old layout whose resources are that folder:
      `Bundle.module.resourceURL` was `….bundle/Resources`, and `CodeLanguage`'s
      `resourceURL/Resources/tree-sitter-swift/highlights.scm` was not there, which is every
      language's highlighting gone. The Swift converter (v18) now also defines each
      product's bundles laid out for the Mac, `macBundles_<Product>()` — the same contents
      under `Contents/Resources/` beside an Info.plist with Xcode's keys less the `DT…`
      ones, the identifier the package's identity, `.<Target>.resources`
      (`grdb.swift.GRDB.resources`, as Xcode's) — and the emitter names those for a Mac
      bundle; a package's own products and an iOS bundle keep the flat layout.
      `SwiftFormulaConverterTests`, `PackageResourcesTests`, `XcodeFormulaEmitterTests`. On
      the rebuilt export, Foundation reads the grammars' bundle with
      `resourceURL` `Contents/Resources` and identifier
      `codeeditlanguages.CodeEditLanguages.resources`, and finds the Swift query.

   *Not in the way*, or not yet: the two script phases (greps whose output is warnings);
   the `(null) in Sources` build files; the SwiftLint `.artifactbundle`, which `prepare`
   vendors (117 MB) and the build pushes though no node reads it, and swift-syntax and
   swift-snapshot-testing, vendored for a test target; the 375 MB static framework, pushed
   and stored. On a fresh home a cold build (push included) is about two minutes; the
   tree-sitter C compiled with nothing new. Nothing stops it short of a signed export that
   verifies.

   *In the roster* (2026-10-01) as `codeedit` (`Projects.codeEdit`,
   `ExternalProjectTests.test_codeEditBuildsTwiceForTheMac`): the pinned commit with no
   overlay, `--platform macos`, the products this entry names — the executable, the plist
   and `PkgInfo`, `Assets.car`, `.all-contributorsrc`, the grammars' bundle's
   `Contents/Info.plist` and its Swift query under `Contents/Resources`, Sparkle, the
   extension's executable and plist — everything under `CodeEdit.app`, and on each export
   the bundle verified deep and strict, each of the three executables signed as part of
   it, Sparkle loaded by its install name through the runpath, `CFBundleShortVersionString`
   0.3.6 (17), and no `CodeLanguages_Container.framework` under `Contents/Frameworks` (12).
   Two builds, byte for byte with no exemption; not at a second mount nor perturbed, as for
   IceCubes: a cold build is 217 s and `prepare` 74 s over a warm SwiftPM cache, so the
   timeout is fifteen minutes a step. The whole test, clone and `prepare` included, passed
   in 571 s beside a nightly run on the same machine.

   *Left from the comparison with Xcode's bundle* (2026-10-01): Xcode embeds
   `ZIPFoundation_ZIPFoundation.bundle` holding only `PrivacyInfo.xcprivacy`, from a
   package whose manifest (tools version 5.0) declares no resources — Semel makes none,
   since its rules follow the manifest; nothing reads the bundle at run time. Xcode links
   `CodeEditKit`, a `.dynamic` product, as a framework under `Contents/Frameworks` where
   Semel links every package product statically, as decided. For item 12: Xcode does embed
   `CodeLanguages_Container.framework`, but as a 33 KB arm64 dynamic library in place of
   the archive, with its `Info.plist`, and no executable of the app loads it; Semel embeds
   nothing for a static framework, which loses nothing that runs. Xcode's own
   Debug build splits the executable into `CodeEdit` and `CodeEdit.debug.dylib` (and a
   `__preview.dylib`), its previews' layout, which Semel does not copy. Xcode signs a Debug
   build it is allowed to sign with `com.apple.security.get-task-allow`, which Semel does
   not add, so its export cannot be attached to by a debugger; the app group
   `$(TeamIdentifierPrefix)` in both entitlements files is an empty string in Semel's
   signature, as it is when Xcode does not sign.
4. *Sequel Ace* — `open`; the first slice (2026-10-11): the header-lookup walls and the
   framework targets are done, and with three things stepped around in the clone — the
   lex files and the Core Data model out of the sources phase (1), Firebase out of the
   app (12), one unbridged cast bridged (11) — every Objective-C and Swift source of the
   app and of both frameworks compiles, and the link fails on the lex scanners' symbols
   alone. A fresh clone stops at 1. Pinned at `1f2798da98d7cd8eef5cb5be97ce23de06733202`
   (main, 2026-10-09). Chosen for Objective-C header finding, which no roster project
   had asked for: NetNewsWire's Objective-C sits in synchronized folders beside the
   headers it includes.

   *What the project is.* One project, `sequel-ace.xcodeproj`, every target listing its
   files through groups (no synchronized folder): the app `Sequel Ace` (155 `.m`, 175
   `.swift`, 172 headers, all under `Source/`), `Unit Tests`, and two tools —
   `SequelAceTunnelAssistant`, which a copy-files phase (`dstSubfolderSpec = 6`) puts
   beside the app's executable, and `xibLocalizationPostprocessor`, which nothing the
   app builds runs. Two project references (`projectReferences`, `PBXReferenceProxy`):
   `Frameworks/SPMySQLFramework/SPMySQLFramework.xcodeproj`, whose `SPMySQL.framework`
   target is Objective-C with Swift beside it (`DEFINES_MODULE`, its own
   `MODULEMAP_FILE`, a Swift `import MySQLClient` through `SWIFT_INCLUDE_PATHS`, a
   headers phase with 24 public headers, and a copy-files phase putting the prebuilt
   `libmysqlclient.24.dylib`, `libssl.3.dylib` and `libcrypto.3.dylib` beside its
   executable, each already named `@loader_path/…`), and `Frameworks/QueryKit/QueryKit.xcodeproj`,
   plain Objective-C. A prebuilt, versioned `Frameworks/ShortcutRecorder.framework` with
   no module map. The app's frameworks phase: the SDK's `Cocoa`, `Quartz`, `QuickLookUI`,
   `Security`, `WebKit`, `libc++.tbd`, `libz.tbd`, `libicucore.dylib`, `libbz2.dylib`,
   the three frameworks, and five package products. Its *Copy Frameworks* phase embeds
   the three frameworks. One script phase (uploading dSYMs to Crashlytics in Release and
   Beta, a message otherwise): not Semel's business. The `libmysqlclient` folder holds
   the scripts that built the dylibs, an `.xcodeproj` the app does not reference.

   *Settings.* `GCC_PREFIX_HEADER = Source/Sequel-Ace.pch` on the project (it imports
   Cocoa and `SPConstants.h` for every source), `SWIFT_OBJC_BRIDGING_HEADER`,
   `SWIFT_OBJC_INTERFACE_HEADER_NAME = $(PROJECT_NAME)-Swift.h` (25 sources import
   `sequel-ace-Swift.h`), `ALWAYS_SEARCH_USER_PATHS = NO`, `FRAMEWORK_SEARCH_PATHS =
   $(SRCROOT)/Frameworks $(PROJECT_DIR)/Frameworks $(PLATFORM_DIR)/Developer/Library/Frameworks`,
   `LIBRARY_SEARCH_PATHS` naming the MySQL client's folder, `OTHER_LDFLAGS = -ObjC`, ARC
   and the hardened runtime, per-file `COMPILER_FLAGS` (`-fno-objc-arc` on
   `RegexKitLite.m`), `MACOSX_DEPLOYMENT_TARGET = 13.5`, Swift 5. The app's
   `HEADER_SEARCH_PATHS` is unset; the unit tests' is not. SPMySQL: `INSTALL_PATH =
   @executable_path/../Frameworks`, `DYLIB_*_VERSION`, `FRAMEWORK_VERSION = A`,
   `REEXPORTED_LIBRARY_NAMES = crypto.3 ssl.3`, `BUILD_LIBRARY_FOR_DISTRIBUTION = YES`.

   *Packages.* Five products through the project: FMDB, SnapKit, Alamofire,
   FirebaseAnalyticsCore and FirebaseCrashlytics; OCMock for the tests. `prepare
   --platform macos` resolves 17 packages and vendors them (957 MB; grpc-binary is 610
   MB of it), with nine binary artifacts (abseil, gRPC, BoringSSL, GoogleAppMeasurement,
   FirebaseAnalytics, FirebaseFirestoreInternal, …), in 56 s over a warm SwiftPM cache.

   *What stops it*, in the order met (Xcode converter v21, `SwiftCompiler` v8,
   `ClangPreprocessor`/`ClangCompiler` with new optional ports and no new version — no
   command line they wrote before changes):

   1. **Listed sources no node builds** — `open`. The sources phase lists
      `SPSQLTokenizer.l` and `SPEditorTokens.l`, which Xcode's lex rule turns into C, and
      `SPUserManager.xcdatamodel`, which `momc` compiles into the bundle; the converter
      refuses them by name (`unsupportedSources`, pinned by `SequelAceFixtureTests`).
      Next: a lex node (the toolchain's `lex`, `<name>.yy.c`, compiled through clang with
      the target's settings) and a `momc` node (also wanted by Mastodon, item 5). Without
      the scanners the link fails on `_yylex`, `_yy_scan_string`, `_yy_switch_to_buffer`,
      `_yyuoffset` and `_yyuleng`, which is where the stepped-around build stops.
   2. ~~**No prefix header.**~~ Done. `NSBeep`, `NSString`, `SPLog` undeclared in most of
      the app's sources: `GCC_PREFIX_HEADER` is forced into every C-family source,
      `-include`, on `ClangPreprocessor`'s new `prefixHeader` port. One outside the
      project (the tool's `$(SYSTEM_LIBRARY_DIR)/…/AppKit.h`) is said in the formula and
      left out.
   3. ~~**No header map.**~~ Done. A listed source found only headers in its own folder,
      where Xcode's header map finds every header of the project by name. The project's
      header references (`XcodeProject.headerPaths`, with a synchronized folder's headers)
      are one tree, `headers_<Target>()`, on `ClangPreprocessor.quoteHeaderTrees`, which
      places it under the project's folder and makes each folder of it holding a header
      an `-iquote`, sorted; `headerMapProduct` (a literal) makes each also reachable as
      `<Product>/Foo.h` through a link under `header-map/`, an `-I`. Links and not copies:
      first laid as a copied tree, QueryKit's `#import <QueryKit/QKQueryTypes.h>` and
      `#import "QKQueryTypes.h"` were two files to clang, and everything in the header was
      defined twice. A listed source's own folder is no longer a search path, so a
      preprocess places the headers rather than every file beside them. *ISSUE:* a header
      beside a listed source that the project does not reference is not found.
   4. ~~**`sequel-ace-Swift.h`.**~~ Done. `SwiftCompiler` writes the interface the
      `objectiveCHeaderName` literal names and publishes it on `objectiveCHeader`; the
      converter gives the settings `PROJECT_NAME`, and the emitter puts it on an `-I`
      (`derived-headers/`) by its name and under the product (SPMySQL's sources import
      `<SPMySQL/SPMySQL-Swift.h>`). swiftc writes the bridging header into it by the
      absolute path it read it from, the sandbox's — `#import "/private/var/…/objc/Source/
      Sequel-Ace-Bridging-Header.h"`, a different path every run, and one no preprocess
      can open — so the node rewrites that import to the header's file name, which the
      header map finds (the bridging header is in `headers_<Target>()` now), and refuses
      an interface that still names the sandbox (`toolOutputNamesItsSandbox`).
   5. ~~**A listed source's own flags.**~~ Done. `COMPILER_FLAGS` on a build file
      (`-fno-objc-arc` on `RegexKitLite.m`) reach its preprocessor and compiler after the
      target's, as an exception set's flags already did.
   6. ~~**Search-path settings.**~~ Done, though the app needs none: `HEADER_SEARCH_PATHS`
      and `USER_HEADER_SEARCH_PATHS` are header folders, a recursive `/**` every folder
      below it, `FRAMEWORK_SEARCH_PATHS` finds frameworks to compile against, and the
      converter walks each folder of the project they name (`XcodeSearchPaths`); entries
      outside the project are said in the formula. *ISSUE:* a user path is an `-I`, where
      Xcode searches it for quoted includes alone, and folders are searched in path order.
   7. ~~**The SDK's libraries.**~~ Done. `libz.tbd`, `libc++.tbd`, `libicucore.dylib`,
      `libbz2.dylib` in a frameworks phase are `-lz`, `-lc++`, `-licucore`, `-lbz2`; a
      library of the project's tree is linked by its file.
   8. ~~**`ShortcutRecorder.framework`.**~~ Done. A framework the frameworks phase names
      by a path in the project is the tree the push made of it, links kept
      (`FolderTreeBuilder`): compiled against (`-F` for Swift and both clang stages),
      linked by name, and embedded under `Contents/Frameworks` where a copy-files phase
      puts it.
   9. ~~**The framework targets of the referenced projects.**~~ Done. The app's
      `#import <SPMySQL/…>` and `import SPMySQL`: a `PBXReferenceProxy` in a frameworks
      phase is a `BuiltProduct` (the project, the product, the target), the converter
      demands each referenced project file on a new `subprojects` port (one nobody pushed
      is said in the formula not to be built), and the emitter builds a framework target
      with an emitter over its own project: its sources as the app's are, linked as a
      dynamic library with `-install_name` (`$(INSTALL_PATH)/<framework>/Versions/A/<name>`)
      and the `DYLIB_*_VERSION`s, and laid out versioned — `Versions/A` with the
      executable, the public and private headers, the module map `MODULEMAP_FILE` names,
      the Swift module, the generated interface, `Resources/Info.plist`, what the
      copy-files phase puts beside the executable — with `Versions/Current` and the links
      at the top made by `TreeBuilder`'s new `links` property. SPMySQL's Swift uses its
      Objective-C (`SPMySQLConnectionProxy`), so it imports it as the underlying module
      (`importsUnderlyingModule`), from a headers-only framework of the public headers and
      the module map on `-F`; its `@_implementationOnly import MySQLClient` finds the map
      `SWIFT_INCLUDE_PATHS` names, with the headers it names by `../../` laid where that
      reaches (`SwiftCompiler.includeTrees`). Pinned by `SequelAceFixtureTests` over the
      sub-project's own file, and `XcodeProjectConverterTests`. *ISSUE:* no Swift
      interface (`BUILD_LIBRARY_FOR_DISTRIBUTION`), no module map written for
      `DEFINES_MODULE` without `MODULEMAP_FILE`, `REEXPORTED_LIBRARY_NAMES` not passed, a
      referenced project's xcconfigs not read (Sequel Ace's name none).
   10. ~~**Package modules in Objective-C.**~~ Done. `@import FMDB;`: the products' module
      trees reach both clang stages on a `moduleTrees` port, merged under `modules/`, each
      folder holding a module map an `-I`, as the Swift compiler has them.
   11. **ARC's audited CF calls in preprocessed text** — `open`. SPMySQL's
      `SPMySQLStreamingResultStore.m:316` passes `(CFMutableArrayRef)rowArray` to
      `CFArrayAppendValue` with no `__bridge`, which ARC allows inside the SDK's
      `#pragma clang arc_cf_code_audited` regions; `clang -E` does not write that pragma
      out, so the compile of the preprocessed text refuses the cast. Reproduced outside
      Semel: the file compiles directly and with modules, and `-E` then `-c` fails. The
      split into two stages is what loses it (with modules the SDK's declarations come
      from the module and keep it). Next: the clang stages, not the project — modules for
      an Objective-C target that sets none, or `-frewrite-includes`. Stepped around with
      `__bridge` in the clone.
   12. **Firebase** — `open`, the Swift converter's. (a) GoogleUtilities,
      GoogleDataTransport and Crashlytics include `"Crashlytics/Crashlytics/Components/…h"`
      from the package's root, which their `.headerSearchPath("../..")` names and the
      converter does not put on the preprocessor's path; (b) Promises' `FBLPromises`
      leaves `#pragma clang module import FBLPromises` for its own headers in its own
      preprocessed text, and the compile fails `module 'FBLPromises' not found`; (c) not
      reached: nanopb's C, leveldb's C++, the binary xcframeworks. Stepped around by taking
      the two Firebase products out of the app with the two sources that use them
      (`SAAnalyticsConsentPolicy+Firebase.swift`, `ReportExceptionApplication.m`, the
      app's principal class) and two calls in `SPAppController.m`.
   13. **ibtool and actool here** — `open`, not Semel's. Every xib, the storyboard and the
      catalog fail `IBCurrentDirectoryPath … currentDirectoryPath is unexpectedly nil —
      Operation not permitted`; `xcrun ibtool --compile out.nib X.xib` fails the same way
      outside Semel, in any directory, under `launchd` as well, and succeeds with absolute
      paths — a state of this machine's Interface Builder tools on 2026-10-11, which
      every roster project with a catalog would meet. Stepped around for the compile with
      `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS = NO`, so the Swift does not wait for
      actool's symbols. Next: check on a machine whose tools work before blaming a node.
   14. **`SequelAceTunnelAssistant`** — `open`. A tool target of the project the app's
      copy-files phase puts beside its executable; only the application and its
      extensions are built, and the formula says the copy is not made. Next: a
      `com.apple.product-type.tool` target built and copied (its own entitlements, signed).

   *Not reached*: the link with the scanners, the Core Data model, signing with the
   sandbox entitlements and the nested frameworks (`SPMySQL`'s dylibs keep their
   vendor's signature), the export, launching. A cold build over a fresh home of the clone
   with 1, 11 and 12 stepped around and asset symbols off (13): 378 s, 1,318 nodes, with
   the CI runner busy on the same machine; it ends at the link (1) and at ibtool and
   actool (13). A fresh clone with nothing stepped around stops at 1 in 58 s, nearly all
   of it the push of 41,392 files. Not in the roster, so no `buildTimeout` yet; the next
   slice starts at 1 and 11.

   *Noticed on the way*: twice a `semelserv` started over a home a moment after
   `semel stop` — by `semel`'s autostart, and by `launchd` respawning a submitted job —
   died at once on `Could not record the name 'output' in the database`
   (`DatabaseVolumeError`), apparently while the old server still held the database; the
   next start over the same home was fine. Not chased.
5. *Mastodon iOS (official)* — IceCubes's domain with different structure: a Core Data
   `.xcdatamodeld` (wants a `momc` node), several extensions, generated-code build phases,
   a big local SDK package.
6. *Wikipedia iOS* — heavy Objective-C and Swift mixing, bridging headers, generated
   `-Swift.h`. An app target's Objective-C and its bridging header are built since
   NetNewsWire's 6, and the `-Swift.h` its Objective-C imports since Sequel Ace's 4.

Expected to surface: script build phases, framework and dynamic-library targets, Core
Data models. Non-synchronized groups surfaced with item 1 and are read; Objective-C in
the application target, and storyboards and xibs (`ibtool`), with item 2 (its 6 and 8),
and are built; framework targets of a referenced project with item 4 (its 9), and are
built, and a Core Data model with item 4 (its 1), and is not yet.

**B-78** `open` — **More Swift packages.**

1. *Semel itself* — done (2026-09-27): in the roster as `semel`, from a `.repository`
   source that copies the checkout less what is not the build — build folders, version
   control, the fixtures, an in-place `prepare`'s leavings — and nests it under its name.
   `prepare` vendors GRDB, writes the machine file and keeps the committed formula and
   project config; the four executables come out and match across every hermeticity
   build. It took two things: the converter mangles a target name into its module name
   as SwiftPM does (`semel-clang` compiles as `semel_clang`), and the root `semel.config`
   is the project's half only (B-109 residual 1). External rather than a fixture only
   because vendoring fetches GRDB.
2. *swift-nio* — what B-55 did first, at scale: `cSettings` `.define` values that matter,
   C sources in nested folders, header paths other than `include`, and executables
   (`NIOEchoServer` and the like) linking C targets. macOS, no macros. What B-55 leaves —
   conditional settings, `headerSearchPath`, a generated module map — is where it should
   fail now, if anywhere.
3. *swift-crypto*, or *Vapor* which brings it — BoringSSL is C, C++ and `.S` assembly in
   deep folders, the hardest C-in-a-package there is; Vapor adds a transitive graph of
   some thirty git dependencies, which tests the `Dependencies/<name>` rule and B-10
   residual 1. After swift-nio passes.
4. *A second project sharing dependencies with IceCubes* (Nuke, SwiftSoup,
   swift-collections at the same commits) — what cross-project cache hits look like, for
   the local-engines-plus-cache-server design.

**B-79** `open` — **Real C and C++ projects — one residual: `c-hello`.** The three projects
are in the roster (items below, all done 2026-09-27 to 2026-09-28): Lua, the SQLite
amalgamation and simdjson, each from a pinned clone with a formula laid over it (B-76).
What is left is the note that follows. The clang fixtures are a hello-world (twice:
`c` and `tutorial`) and an emulator of three `.cpp` files and eight headers. Needed B-76,
done. `c-hello` is subsumed by `tutorial` — identical sources, the same products plus
`lines.txt` — so when a real C project is pinned it is `c-hello` that goes, not the tutorial
fixture. `RosterTests.test_theTutorialFixtureSourcesMatchTheCFixture` compares the two
`src/` trees, though, so that test and the tutorial's "copy `EndToEnd/Fixtures/c`"
instruction move to `Fixtures/tutorial` at the same time as `c-hello`.

*Not done with Lua (2026-09-27), on purpose.* The tutorial copies `Fixtures/c` because it
is the starting point — a formula without `lines.txt`, which the reader adds while writing
`LineCounter`; pointing the copy at `Fixtures/tutorial` would hand over the finished formula
and make the tutorial's first builds fail on a node not yet registered. And Lua is external,
opt-in, while `c-hello` runs the prelude's C path on every push. `c-hello` goes when the
tutorial gets a starting-point fixture of its own, or when a real C project joins the
fixture tier.

1. *Lua 5.4* — done (2026-09-27): in the roster as `lua`, the `lua/lua` mirror at the
   commit `v5.4.7` names, with `Fixtures/external/lua` laid over it (B-76): `liblua.a` from
   the 32 library sources — every C file in the root, `lua.c`, `onelua.c` and `ltests.c`
   left out through the for-each's `except` (B-123) — and `lua` linked against it; both match across
   all four hermeticity builds. No `luac`: the mirror is the development tree and `luac.c`
   is added to the release tarballs only, so it cannot be built from a pinned commit. It
   surfaced two gaps in the clang nodes: nothing wrote a static archive — clang cannot,
   `swiftc -static` drives libtool — so `ClangArchiver` runs `libtool -static` under
   `ZERO_AR_DATE` in a namespace of its own, `clang.archiver`, that `semel-clang` writes and
   `clang.staticLibrary(sources:settings:)` selects; and no clang configuration read extra
   flags, so `arguments` is honoured by all three, comma-joined as the Swift nodes' is, for
   Lua's `-DLUA_USE_MACOSX` (the linker had appended its always-empty list twice). About 35
   files is right: 35 `.c`, of which 32 are the library.
2. *SQLite amalgamation* — done (2026-09-28): in the roster as `sqlite`, SQLite 3.53.4 from
   the `rhuijben/sqlite-amalgamation` mirror (a maintained fork of `azadkuh/`, whose last
   tag is 3.38.2) at the commit its `3.53.4` tag names — SQLite's own repository holds no
   amalgamation, its build generates one. The mirror's BSD-3-Clause LICENSE covers its
   CMake files; the sources are SQLite's, public domain by their header notice.
   `Fixtures/external/sqlite` archives `libsqlite3.a` from `sqlite3.c` alone (269,649
   lines, 9.5 MB) and links the `sqlite3` shell from `shell.c` against it, with SQLite's
   default options — no defines, so threadsafe, extension loading on, no readline — and
   both match across all four hermeticity builds. It surfaced one gap: the include
   finder reads quoted includes without evaluating a conditional, and the amalgamation
   names eight headers no checkout holds, each under an `#if` false here (`windows.h`,
   `mingw.h`, `_mingw.h`, a configure step's `sqlite_cfg.h`, `tclsqlite.h` under
   `SQLITE_TEST`, `sqlite3rtree.h` outside an amalgamation; `shell.c`'s `linenoise.h`, and
   `qrf.h` under a guard its own inlined copy defines), each a `StaticFile` nobody pushed,
   so the build stopped on eight "has not been pushed". The preprocessor now leaves a
   header whose file was never pushed out of the sandbox and lets clang judge — an
   `#include` it reaches fails as "file not found", the node's own error — and the
   finder lists no includes for one; both ports tolerate an absent value, so the report
   does not name them either, and both types are at `implementationVersion` 2. Size
   surfaced nothing: an entry holds object-store hashes, not bytes, so the compiler's
   entry for `sqlite3.c` weighs 648 bytes and the largest in the home is the
   `ProjectBuilder`'s at 8,457; the bytes are in the object store — the 9.5 MB source,
   3.07 MB preprocessed, a 1.54 MB object, 20 MB in all. Recorded costs on an M4: the
   compile 607 ms, the preprocessor 99 ms, the include finder over the 9.5 MB source
   97 ms; the whole test, four cold builds, 13.6 s. One oddity for the cache: the
   preprocessor's first pass over `sqlite3.c`, which only asks for the include lists and
   runs no clang, took 72 ms and so crossed the 15 ms floor and wrote an entry for the
   waiting state; harmless, since the key holds the absent lists, but a "not yet" pass
   is not work worth a row.
3. *simdjson* — done (2026-09-28): in the roster as `simdjson`, simdjson 4.6.11 from
   `simdjson/simdjson` at the commit its `v4.6.11` tag names, Apache-2.0 or MIT at the
   user's choice. The repository carries the single-header amalgamation in
   `singleheader/`, so that folder is the `.git` source's `subfolder` and the build folder:
   the checkout is copied whole, `Fixtures/external/simdjson` is laid over `singleheader`,
   and the machine file lands at the checkout's root, the formula's `../`.
   `libsimdjson.a` is archived from `simdjson.cpp` alone (2.76 MB, the library as one
   translation unit that inlines the header rather than including it) and
   `amalgamate_demo`, the folder's own demo, is linked against it from
   `amalgamate_demo.cpp`, which includes the 7.7 MB `simdjson.h`; C++17, no defines, no
   optimisation flag. Both match across all four hermeticity builds, and the demo parses
   the repository's `twitter.json` and finds the 793 documents in
   `amazon_cellphones.ndjson`. It surfaced no gap. The linker already adds `-lc++` for an
   object compiled from C++, so the linker's settings name no standard; the finder strips
   comments before it matches, so the `#include "simdjson.h"` in the header's own doc
   comment names nothing. The heavy templates cost little at `-O0`: a header's inline
   templates are instantiated only where used, so the library's object is 162 KB from a
   4.49 MB preprocessed file and the demo's, which instantiates the on-demand parser,
   294 KB from 5.10 MB; the archive is 178 KB and the demo 427 KB. Recorded costs on an
   M4: the compiles 285 and 420 ms, the preprocessors 140 ms each (227 ms in the first
   of the four builds), the include finder over the 7.7 MB header 132 ms, the link 30 ms;
   the archiver's run fell under the 15 ms floor and wrote no entry. The whole test, four
   cold builds, 11.1 s with the clone cached and 15.5 s with the fetch. The largest cache
   entry is again the `ProjectBuilder`'s, 8,986 bytes; a compiler's is about 660. One
   thing for the push: the build folder is pushed whole, so `singleheader.zip` (10.5 MB,
   the release download) and the amalgamation report are interned into the object store
   although no node reads them — a third of the home's 31 MB. Harmless here, and worth
   knowing for a folder that ships release archives. *fmt* was the alternative and would
   add nothing simdjson does not: a C++ library and a program over it through the same
   four nodes.

**B-80** `open` — **Projects that need macros.** The converter skipped `macro` and `plugin`
targets (`SwiftFormulaConverter.isCompilable`); since B-77 item 3 it names the build-tool
plugins a target uses as not run, where it dropped them unsaid. Since 2026-10-10 it builds
macros (items 1 and 3 below); build-tool plugins are still not run, as B-77 decided. These
are the acceptance tests, in rising cost:

1. *apple/sample-backyard-birds* — SwiftData's `@Model` comes from plugins shipped in the
   toolchain, so macro expansion is tested without building swift-syntax. Also widgets, a
   StoreKit configuration file, local packages.

   *Toolchain macros, landed 2026-10-10.* Nothing on the command line: the driver finds
   the toolchain's plugins (`lib/swift/host/plugins`, `@Observable`) through `-plugin-path`
   and the platform's (`Developer/usr/lib/swift/host/plugins`, `@Model`) through
   `-external-plugin-path` and the platform's `swift-plugin-server`, the platform found
   from `-sdk`, and the sandbox hides none of them. What was missing was the key: the
   compiler's fingerprint covered `swift-frontend` alone. A `ToolFinder` now names a
   companion fingerprint that `ToolDiscovery` folds into the descriptor's, and the
   compiler's covers everything under the toolchain's `lib/swift/host` and every
   platform's plugin folders and plugin server, each file by path, size and modification
   time as the SDK's fingerprint records it (`SwiftCompilerPlugins`). Discovery runs before
   `semelserv` listens: hashing the 85 MB by content (0.6 s from a cold copy on an M4,
   longer on a slow disk) kept a hosted runner's server from answering before the client
   that started it gave up; the walk takes 0.01 s. Accepted by the `swift-macro-app` fixture, whose
   app uses `@Observable` and `@Model`; the sample itself is not in the roster.
2. *swift-syntax* alone — no macro support needed to build it; a large pure-Swift build and
   a useful performance benchmark in its own right.
3. *swift-dependencies* or *swift-composable-architecture* — package-defined macros built
   from swift-syntax and run as compiler plugins.

   *Package macros, landed 2026-10-10* (Swift converter v23). A `macro` target is compiled
   as a library is, against the swift-syntax targets it reaches — an ordinary dependency,
   its C shims through the clang nodes — and linked with them by a `SwiftLinker` into an
   executable, `macroExecutable<Target>()`, a value of the graph and no product. Every
   Swift target that reaches the macro, through any chain of other targets, as SwiftPM
   hands a target the macros of its recursive dependencies, takes the executable on
   `SwiftCompiler.macroExecutables`, laid at `macros/<Module>` and loaded with
   `-load-plugin-executable macros/<Module>#<Module>`; a changed macro moves the key of the
   compiles that load it and of nothing else. What a product links and vends for import
   stops at a macro. A macro is built only in a build for macOS, where the compiler runs
   it: a package with one asks for the platform, and a macro a product reaches in a build
   for another is the conversion's error, `macroForAnotherPlatform`, naming it — building
   the macro and its swift-syntax for the Mac beside the platform's build is the work left
   for an iOS app with package macros. Nor does a formula consuming a package's products —
   an app through `XcodeProjectConverter` — get its macros yet: the product's public face
   has no `macros_<Product>()`, so an app expanding a package's macro fails to find it.
   Accepted by the `swift-macro-app` fixture, a package macro speaking the plugin
   protocol by hand, loaded two targets away and run, its executable byte-identical over
   the four hermeticity builds; and by `swift-dependencies` 1.17.0 in the roster, its
   `DependenciesMacrosPlugin` built from swift-syntax 603.0.2 (44 s cold).
4. *isowords* — one `Package.swift` with some ninety targets and heavy resources (audio,
   fonts): graph scale and `Bundle.module`. Pulls in TCA, so it waits for 3.

### Not doing

**B-40** `dropped` — Subtree-scoped `reset`. Moot: users no longer share one graph.
**B-41** `dropped` — Scoping or privilege for `debug`. Moot for the same reason.

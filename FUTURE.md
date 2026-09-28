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

- **The 15 ms cache floor is a wall-clock decision.** Whether an entry exists depends on
  how long processing took (`Cache.saveCacheForAllInputsAndOutputs`), so a shared cache
  fills differently with machine speed and load. Harmless to correctness, odd in a
  project built on determinism, and it made the tutorial's own node uncacheable. A
  declared per-type property would be predictable.

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
Remote Runner role (B-30).

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
with the version, revision and origin of the checkout's pin in `Package.resolved`. What
remains: a file removed from disk stays in `input:` (a push only adds), so the root then
differs from a fresh lock with no word on which file; a lock `rm`'d from `input:` is named
as a deleted source on every report while the converter still wires it, as any removed
source a build reads is; and the version is recorded, never checked against the manifest's
requirement (the converter's `ISSUE:`).

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

Left, each for the package that needs it (swift-nio and BoringSSL in B-78 are the likely
first):

1. **Conditional and other settings.** A `.when(platforms:)` or `.when(configuration:)`
   setting is not carried, nor `headerSearchPath`, `unsafeFlags`, `linkedLibrary`,
   `linkedFramework` or any `linkerSettings`. A define whose value holds a comma splits in
   two and one holding a quote ends the formula's string.
2. **C++ in a linked product.** SwiftPM adds `-lc++` when a product reaches a C++ source;
   `SwiftLinker` is not told, so a dylib or executable with a C++ target fails at link
   with the standard library's symbols undefined. It wants a linker key of its own, for
   the reason `defines` is one.
3. **Nested public headers for Swift.** `SwiftCompiler`'s `inputModuleMapFolders` places
   one level of the header folder (the product's module tree, a `FolderTreeBuilder`, is
   whole), so a module map naming `header "sub/x.h"` or an umbrella directory with
   subfolders fails from Swift while the C side builds.
4. **No generated module map.** SwiftPM writes one for a C target whose public headers
   have none — an umbrella `<Target>.h`, or the folder as an umbrella directory; the
   converter wires the folder as it is, so such a target is not importable from Swift.
5. **Assembly.** `.s` and `.S` sources are not compiled (BoringSSL).
6. **Cost.** A preprocessor node takes every file under its target's folder, an excluded
   folder included, and every source of the target has one; a large excluded `Tests`
   costs wires, not correctness.

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
not, so two copies of one tree are comparable wherever they stand. What remains:

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

### Cache

**B-11** `open` `For Fable Only` — **Probe determinism at write.**
Occasionally run a node twice before caching and compare. A node that is not reproducible is
marked never-cacheable. Fixes the problem at source rather than detecting symptoms forever,
and answers the question a shared cache most needs answered: which tools are safe to share.

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

### Command line

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
   linker never sees half a tree; expansions are sorted. `except` goes through the same
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
2. **An app bundle as one product.** `TreeBuilder` writes entries with the default mode;
   carrying each entry's mode would let `apple` build the whole bundle as one tree.

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
each required to replace a file the checkout has; `prepare` writes the formula and the
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
   builds. What no Mac build here does yet is sign: an arm64 executable needs at
   least an ad-hoc signature to launch, and Semel writes none, so the bundle is inspected
   rather than run. Left as copies rather than compiled, said here rather than
   silently: a storyboard, a xib, a Core Data model, a Metal file listed among a target's
   resources; a listed source that is not Swift is refused by name. Two things `prepare`
   writes for a project that a Swift-only one reports as unused keys on every build —
   the `clang.*` project blocks, and the string catalog compiler's machine block when no
   `.xcstrings` exists — are noise worth silencing at the writer. A package *tree* with
   resources still wants the `apple.*` namespaces in its config, which `prepare` does
   not write for a tree.
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
Objective-C in the application target, Core Data models, storyboards and xibs (`ibtool`).
Non-synchronized groups surfaced with item 1 and are read.

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

### Not doing

**B-40** `dropped` — Subtree-scoped `reset`. Moot: users no longer share one graph.
**B-41** `dropped` — Scoping or privilege for `debug`. Moot for the same reason.

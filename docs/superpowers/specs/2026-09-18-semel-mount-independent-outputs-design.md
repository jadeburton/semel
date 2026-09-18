# Mount-independent tool outputs

**Status:** approved design, not yet implemented. B-49. Plan: `docs/superpowers/plans/2026-09-18-semel-mount-independent-outputs.md`.

## 1. Why

A cache entry is worth sharing only if two machines that hold the same sources can agree
on the same key and be handed bytes they would have produced themselves. Every developer
mounts the same tree somewhere different, so anything a tool writes that names *where* the
tree is mounted turns identical work into two entries, and any key that ignores the mount
while the output embeds it turns a hit into another build's artifact. FUTURE.md makes
mount-independence the first prerequisite of the shared cache server
(`2026-08-15-semel-cache-server-design.md`), not an optimisation on top of it.

The same problem appears one scale down: two branches of one project checked out side by
side on one machine share nothing, and the end-to-end harness's two cold builds
(`2026-09-15-semel-end-to-end-testing-design.md`, Section 4, steps 5–6) diff two export
trees that were produced in two differently-named sandboxes.

The distinction this design turns on: a file's path **relative to its project** is a real
input — module names, include resolution, output filenames and diagnostics all derive from
it, and the cache is right to key on it. Everything *above* the project root is noise.

## 2. What reaches a tool today

### 2.1 The sandbox

`LocalFileSystemTool.execute` (`SemelNodeKit/Sources/SemelNodeKit/LocalFileSystemTool.swift`)
is the only `ToolRunner` that runs a real process.

- **Creation** (`:49`–`:58`): a fresh `.itemReplacementDirectory` per run, so the root is a
  new random path every time, removed on the way out (`:63`). `canonicalSandboxPath`
  (`:58`) is the same path with `/var/…` rewritten to `/private/var/…`, because tools that
  call `realpath()` print the resolved form and a caller matching against their output
  needs the form they will see.
- **Materialisation** (`:66`–`:84`): each `FileNameAndContent.filePath` is appended to the
  sandbox root and projected out of `DataObjectStore`. The path used is the *wire key*, and
  wire keys are input-file-system paths — `input:/c/src/hello.c` — not host paths. The
  sandbox therefore contains a literal directory named `input:`.
- **Working directory** (`:101`): the sandbox root. `HOME` and `TMPDIR` are set to it as
  well, and `PATH` is fixed (`:103`–`:107`).
- **Outputs**: `.semel-stdout` / `.semel-stderr` in the sandbox (`:125`–`:126`), then
  `expectedOutputFileNames` read back by sandbox-relative name (`:161`–`:169`) and each
  `expectedOutputFolders` walked, sorted, into tree entries (`:171`–`:195`).
- **Result**: `ToolExecuteResult(exitCode:sandboxPathUsed:)` carries
  `canonicalSandboxPath` back (`:197`). Its one consumer is
  `SwiftPackageReader.stripOutSandboxPaths` (`SemelSwift/Sources/SemelSwift/SwiftPackageReader.swift:141`,
  `:152`–`:170`), which rewrites sandbox-rooted absolutes in `dump-package` JSON back to
  relative form. Every other implementation is a test double returning
  `"/tmp/recording-tool-sandbox"`.

A tool invocation (`SemelNodeKit/Sources/SemelNodeKit/ToolRunner.swift:43`–`:54`) is
therefore: an argument list, an environment, a list of `(wire key, content hash)` inputs,
the names of the files and folders to collect, and a `ToolDescriptor` (`:10`–`:28`:
name, version, platform, architecture, and the never-populated `recursiveHash` of B-17)
that selects the runner.

### 2.2 What the nodes put on a command line

| Node | Absolute, host-derived | Sandbox-relative (project paths) |
|---|---|---|
| `ClangPreprocessor` (`SemelClang/…/ClangPreprocessor.swift:222`–`:263`) | `-isysroot <sdkPath>` (`:246`) | `-I .` (`:230`), `-I <manifest.baseFolderPath>` (`:234`), the source (`:250`), `-o <source>.p` (`:222`) |
| `ClangCompiler` (`…/ClangCompiler.swift:95`–`:119`) | none | the source (`:108`), `-o <source>.o` (`:95`, `:109`) |
| `ClangLinker` (`…/ClangLinker.swift:126`–`:178`) | `-L <sdkPath>/usr/lib` (`:136`) | `-L .` (`:133`), each object by wire key (`:157`), `-o output.dylib` (`:165`) |
| `SwiftCompiler` (`SemelSwift/…/SwiftCompiler.swift:374`–`:454`) | `-sdk <resolveSDKPath()>` (`:387`) | `-o <module>.o` / `.swiftmodule` / `.swiftinterface` (`:374`), `-I .` (`:415`), `-I modules` (`:422`), `-I <dir>` (`:428`, `:439`), each source by wire key (`:443`) |
| `SwiftLinker` (`SemelSwift/…/SwiftLinker.swift:200`–`:246`) | `-sdk <resolveSDKPath()>` (`:217`) | each object and library by wire key (`:226`, `:230`), `-o <outputName>` (`:233`) |

No node ever writes the sandbox root, and no node can: the sandbox is created inside
`execute`, after the arguments are built. Every project path is relative to the working
directory. The only absolutes are the SDK's, from `sdkPath` in a pushed config file or
from `xcrun` at run time.

### 2.3 Where the mount prefix goes

The client resolves `base` and pushes each file under its **base-relative** path
(`semel/CommandInterpreter/Plugins/FilePlugin.swift:121`–`:147`); the server prefixes
`input:`. The checkout path is consumed at that boundary and never enters the graph.
Confirmed on a built graph: no row of `Node.encodedProperties` in a C-fixture graph
contains `/Users`, `/tmp` or `/Applications`, and every wire name is of the form
`input:/c/src/hello.c`.

What *does* vary between two developers is where they point `base`. `base /repo` with
`build Packages` and `base /repo/Packages` with `build .` describe the same sources under
different `input:` paths. That is the residual prefix this design has to strip — not
`/Users/jade`.

### 2.4 Cache keys

`Node.buildCacheKeyPartFromOneInput` (`SemelCore/Sources/SemelCore/Cache.swift:15`–`:32`)
emits, per port, the sorted `(wire, value)` pairs as JSON. `buildCacheKeyFromAllInputs`
(`:45`–`:60`) prefixes the node's own type name, its `encodedProperties` as plain text and
its `cacheKeyMaterial` (`:37`–`:43`; the only implementer is `SwiftSDKFingerprint`), then
hashes the lot. The comment at `:23`–`:27` records the lesson that must survive: keying on
values alone once returned another file's build, because the wire key is the path and
tools embed it.

Two property-borne paths reach a key today: `ProjectBuilder.outputFolder`
(`SemelCore/Sources/SemelCore/Nodes/ProjectBuilder.swift:61`, rendered into the spec by
`ProjectFinder.swift:17`) and `OutputFile.path`. Nodes whose properties carry a path but
have no static input ports — `StaticFile`, `Folder` — are never cached at all
(`Cache.swift:68`, `:102`).

`outputFolder` is also the answer to "where would a node learn its project root": a
property written once by the plugin that creates the node, carried in `graphSpec`, and so
part of node identity.

### 2.5 What actually leaks, measured

Two experiments on this machine (macOS 26.6, Apple clang 21.0.0, Swift 6.3.3, Xcode 26.6).

**(a) One tree, two mounts, three builds.** The `C1/c` fixture was copied to
`/private/tmp/claude-501/b49/mountA` and to
`/private/tmp/claude-501/b49/mountB-with-a-much-longer-name`, and built three times, each
with its own `SEMEL_HOME`, `SEMEL_SOCKET` and export directory: mount A twice, mount B
once.

> `out1`, `out2` and `out3` are **byte-identical**, all three files (`hello`,
> `hello.dylib`, `config.txt`). `strings -a` finds no `/var/folders`, `/private`, `/Users`
> or `/tmp` in either binary. The dylib's `LC_ID_DYLIB` install name is `output.dylib` —
> the literal `-o` name from `ClangLinker.swift:165`. There is no debug map: nothing
> passes `-g`, so there are no `N_OSO` stabs and no DWARF.

So today's C path is already mount-independent, for the reason Section 2.3 gives and
because no debug information is generated.

**(b) The same sandbox layout, by hand, with `-g`.** Two sandboxes named `…-aaaa` and
`…-bbbbbbbbbbbbbbbbbb`, inputs materialised at `<sandbox>/input:/c/src/…`, cwd the sandbox
root, command lines copied from the nodes.

| Artifact | `-g` off | `-g` on | What differs |
|---|---|---|---|
| `hello.c.p` (preprocessed) | identical | — | `#` line markers carry the as-written relative path |
| `hello.c.p.o` (clang object) | identical | **differs at byte 65** | `DW_AT_comp_dir` = the sandbox root |
| `output.dylib` (clang link) | identical | **differs at byte 625** | `N_OSO` = `<sandbox>/input:/c/src/hello.c.p.o` |
| `G.o` (swift object) | identical | **differs at byte 65** | the sandbox root, and `-ffile-compilation-dir=<sandbox>` |
| `G.swiftmodule` | **differs at byte 15069** | **differs at byte 15069** | the sandbox root, in the serialized debugging options |

`G.swiftmodule` is the important row: it differs **with no `-g` anywhere**. A
`.swiftmodule` is a wire value, so every downstream `SwiftCompiler` that imports it gets a
different input hash and therefore a different cache key. That alone makes a Swift graph
unshareable between machines, and it is invisible in an export tree that only publishes
`.a` files.

`#file` and `__FILE__` expand to the path as written on the command line, which is already
project-relative; they were not a leak in any run.

**(c) Which flags close them.** Same two sandboxes, `-g` on throughout:

| Flag set | clang object | clang dylib | swift object | `.swiftmodule` |
|---|---|---|---|---|
| none | differs | differs | differs | differs |
| `-ffile-prefix-map=<sandbox>=/semel` | identical | differs | — | — |
| `-fdebug-compilation-dir=/semel` | identical | differs | — | — |
| … `+ -Xlinker -oso_prefix -Xlinker <sandbox>/` | identical | identical | — | — |
| … `+ -Xlinker -oso_prefix -Xlinker .` | identical | identical | — | — |
| `-file-compilation-dir /semel` | — | — | identical | differs |
| … `+ -Xfrontend -no-serialize-debugging-options` | — | — | identical | identical |
| `-file-compilation-dir /semel -module-cache-path mc` | — | — | **differs** | differs |

Two results decide the design. First, **`-oso_prefix .` works**: ld64 reads `.` as the
working directory, so the `N_OSO` stab becomes `input:/c/src/hello.c.p.o`. Second, a
sandbox-relative `-module-cache-path` makes things *worse*, because the relative path
resolves to the sandbox absolute and lands in the object.

Together with `-fdebug-compilation-dir` and `-file-compilation-dir` taking a literal, the
whole corrective flag set is **constant**. No node needs to know the sandbox path.

The one residual, unaffected by any of these: a Swift object with `-g` embeds the implicit
clang module cache entry, `/var/folders/<user>/C/clang/ModuleCache/…/_SwiftConcurrencyShims-….pcm`.
That is the per-user Darwin cache directory. It is stable on one machine and differs
between machines.

## 3. Canonical sandbox layout

**The sandbox root stays a fresh random directory.** A fixed absolute root would need a
mount namespace, which macOS does not offer unprivileged, and would serialise the
concurrent runs phase 1 depends on. Section 2.5 shows it does not need to be fixed: what
matters is that no tool can *observe* it.

The canonical layout is therefore three rules, promoted from habit to contract.

1. **Inputs are materialised at their wire key**, below the sandbox root, exactly as
   `LocalFileSystemTool.swift:66`–`:84` does. The wire key is an input-file-system path, so
   the root of the materialised tree is `input:` and the checkout prefix is already gone.
   Unchanged.
2. **The working directory is the sandbox root**, and **every path a node puts on a command
   line is relative to it**. This is the rule that keeps the random prefix off the command
   line, and it is what nodes already do; it becomes a documented invariant on `ToolRunner`
   rather than an accident of five node implementations agreeing.
3. **The sandbox root has one canonical name, `/semel`**, declared once in `SemelNodeKit`:

   ```swift
   /// The name a tool is told the sandbox root is called, so that a path it records
   /// names the build rather than the directory this run happened to get. Never a real
   /// directory: nothing resolves it, nothing creates it, and the tool never opens it.
   public enum ToolSandbox {
       public static let canonicalRootName = "/semel"
   }
   ```

   Nodes pass it as the value of `-fdebug-compilation-dir` and `-file-compilation-dir`
   (Section 4). It is a constant, so it is not a cache-key input.

**What does not change:** `DataObjectStore.project`, the output-file and output-folder
collection, the sorted tree walk, `.semel-stdout` / `.semel-stderr`, and the environment
(`HOME` and `TMPDIR` pointing at the sandbox root — a tool that writes there writes
somewhere that is deleted, and nothing carries those paths out).

**Escape hatch, if a node ever does need the real root.** `LocalFileSystemTool` substitutes
the literal token `{sandbox}` in every argument and environment value with the sandbox path
immediately before launch. Nothing needs it today — Section 2.5(c) shows the corrective
flag set is constant — and it is specified rather than built, so that the answer to "I need
an absolute path" is a documented substitution instead of a new API. Note that a remote
runner substitutes its own root, which is the point.

**`canonicalSandboxPath`.** It is a symlink normalisation, not a canonical *name*, and with
two meanings of "canonical" in one file the next reader will conflate them. Keep the
behaviour — `SwiftPackageReader` needs the `/private/var` form to match what SPM prints —
and rename the field on `ToolExecuteResult` from `sandboxPathUsed` to
`resolvedSandboxPath`, with the doc comment saying it is symlink-resolved and that it
exists so a caller can undo a path a tool wrote into its output.

## 4. Prefix maps for what still leaks

One flag set per node, all constants.

**`ClangCompiler`** adds:

```
-fdebug-compilation-dir=/semel
```

Measured: closes `DW_AT_comp_dir`. `ClangPreprocessor` needs nothing — `-E` emits no debug
information, and its `#` line markers already carry the as-written project-relative path,
which is what `ClangCompiler` then reads as `DW_AT_name`. `-ffile-prefix-map=<sandbox>=/semel` closes the same
leak and additionally rewrites absolute paths in `__FILE__` and in diagnostics, but it
needs the sandbox path, and no node puts an absolute sandbox path anywhere. Use
`-fdebug-compilation-dir`; if rule 2 of Section 3 is ever broken, `-ffile-prefix-map` with
`{sandbox}` is the fix, not a reason to break it.

**`ClangLinker`** and **`SwiftLinker`** add:

```
-Xlinker -oso_prefix -Xlinker .
```

Measured: the `N_OSO` debug-map stab becomes the object's sandbox-relative path. Stripping
is the alternative and is worse — it throws away the debug map a developer needs, to fix a
problem the prefix solves exactly.

**`SwiftCompiler`** adds:

```
-file-compilation-dir /semel
-Xfrontend -no-serialize-debugging-options
```

Measured: the first closes the object, the second closes the `.swiftmodule`.
`-no-serialize-debugging-options` has no driver spelling; passed bare it produces
`warning: save unknown driver flag … as additional swift-frontend flag`, so it goes through
`-Xfrontend`. What it stops serializing is the search-path set a consumer would use to
rebuild an implicit clang module. Semel gives every compile its own explicit `-I` flags
from its own wiring (`SwiftCompiler.swift:415`–`:439`), so the serialized copy is noise —
but it is the one flag here that changes what a consumer *can* do, and Section 8 keeps it
as a question.

Leak by leak, against Section 2.5:

| Leak | Closed by |
|---|---|
| `DW_AT_comp_dir` in a clang object | `-fdebug-compilation-dir=/semel` |
| `N_OSO` in a linked binary | `-Xlinker -oso_prefix -Xlinker .` |
| Sandbox root in a Swift object | `-file-compilation-dir /semel` |
| Sandbox root in a `.swiftmodule` | `-Xfrontend -no-serialize-debugging-options` |
| `__FILE__` / `#file` | nothing — already the project-relative path as written |
| dylib install name | nothing — `-o output.dylib` is a constant; a future `-install_name @rpath/<product>` is project-relative and was measured identical across sandboxes |

**Deliberate non-goals.**

- **SDK and toolchain absolute paths.** `-isysroot` and `-sdk` put `/Applications/Xcode….app/…`
  into DWARF and into module dependencies. That is machine identity, not mount identity: it
  is identical for two checkouts on one machine and different for two machines whatever
  this design does. Consequence: two machines on different Xcode versions must not share a
  Swift or clang cache entry, which is B-47's `SwiftSDKFingerprint` in the key, not a prefix
  map. Mapping the SDK to a fake prefix would make the outputs match while the inputs
  differ — the wrong-hit bug with extra steps.
- **The implicit clang module cache path in a Swift object.** Per-user, machine-stable,
  mount-independent. It does not affect either verification in Section 6. Consequence:
  Swift objects built with `-g` cannot be shared between machines until this is closed;
  Section 8 keeps it.
- **Diagnostics on the log ports.** They carry whatever the tool printed, which is
  project-relative under rule 2, but they are not normalised and are not claimed to be
  byte-identical across tool versions.

## 5. Mount-independent cache keys

**Invariant.** *A node's cache key names every input by its path relative to the project
root and by nothing above it.*

Section 2.3 says the mount prefix is not in a wire name; the project's position under
`input:` is. So `buildCacheKeyPartFromOneInput` strips the node's project root from each
wire key and keeps the remainder:

```
input:/repo/Packages/Timeline/Sources/Timeline/Row.swift   with projectRoot input:/repo/Packages
                                      → Timeline/Sources/Timeline/Row.swift
```

A wire key that does not start with the project root is used whole. That covers the
non-path wire names the graph already uses — `wire0`, `product`, `modules/…`, `extra/…` —
and it fails safe: an unexpected shape keeps more in the key, never less.

**Where a node learns its project root.** The same channel as `outputFolder`: a property,
written by the plugin that creates the node, carried in `graphSpec` and therefore part of
node identity. `ProjectFinder` already renders `ProjectBuilder(outputFolder: '…')`
(`ProjectFinder.swift:17`); `ProjectBuilder` renders `projectRoot: '<outputFolder>'` into
every node spec it emits, so a node has it from creation and never recomputes it — which is
what the static-topology invariant requires.

**One trap this creates.** `nodeCacheKey` hashes `thisNode.properties.asPlainText()`
wholesale (`Cache.swift:38`). Adding `projectRoot` as a property would put the very string
being stripped straight back into the key. The key computation must exclude it by name — a
declared `Node.cacheKeyExcludedProperties` defaulting to `["projectRoot"]`, not a heuristic
over values that look like paths. `OutputFile.path` and `ProjectBuilder.outputFolder` carry
the project root too; they are listed in Section 7 as residuals rather than fixed here,
because their outputs genuinely depend on where the products go.

*Alternative considered and rejected:* pass the root on `ProcessInput` instead of storing
it. A key must be recomputable from recorded material alone (B-13), and `ProcessInput` is
per run.

**Why this must come third.** A key that ignores the project prefix while an artifact still
embeds it hands machine B a binary built at machine A's path and calls it a hit. That is
`Cache.swift:23`–`:27`'s bug, reintroduced deliberately and across machines. Sections 3 and
4 must be true — and shown true by Section 6 — before a single character is stripped from a
wire name.

**What the lesson keeps.** The project-relative remainder stays in the key. Two files with
identical content at different project-relative paths still key differently, because their
outputs still differ.

## 6. Verification

**Same machine: the end-to-end harness.** `2026-09-15-semel-end-to-end-testing-design.md`
Section 4, steps 5–6, already builds each project cold twice into two fresh homes and
diffs the export trees byte for byte with `TreeDiff`. Its plan notes that a fresh random
sandbox per run may make linked binaries differ (plan Task 7). Sections 3 and 4 are the
answer to that note: with the corrective flags on and rule 2 holding, the diff passes.
There is no second harness.

**Two mounts: one more step in the same harness.** `EndToEndRun` gains a step between
"determinism" and "clean up", enabled per roster entry by `twoMounts: Bool` so a long
external project can opt out:

1. Materialise the prepared copy a second time, at a sibling directory whose name is a
   different length — `<root>/mount-b-longer-name/<name>` beside `<root>/<name>`.
2. Build it with a third fresh home into `out3`.
3. `TreeDiff.compare(out1, out3)` must be empty.

The differing name length matters: an embedded path that happened to be the same length
would hide inside a same-size diff.

**Equal cache keys: a unit test, not the harness.** The client cannot observe a key today,
and adding a protocol message to let it is a larger change than the assertion needs. The
direct check lives in
`SemelCore/Tests/SemelCoreTests/CacheKeyMountIndependenceTests.swift`: build one
`ProcessInput` with wire keys under `input:/a/proj/…` and another under
`input:/deeper/b/proj/…`, give the nodes the matching `projectRoot`, and assert
`buildCacheKeyFromAllInputs` returns the same hash — and, in the same file, that two
different project-relative paths still return different hashes, so the `Cache.swift`
lesson has a test rather than a comment.

**Regression discipline.** Each flag in Section 4 gets a node-level test asserting it is on
the command line, via the existing `RecordingToolRunner`. Those are cheap and they are what
stops a later edit dropping one silently; the export-tree diff is what catches a leak
nobody predicted.

## 7. Order and scope

**Order.**

1. Section 4's flags, plus Section 3's invariant written down and `sandboxPathUsed`
   renamed. Nothing depends on them, and (b)/(c) of Section 2.5 can be re-run against the
   real nodes the day they land.
2. The two-mounts step in the end-to-end harness, and the node-level flag tests.
3. `projectRoot` on nodes, the exclusion set, and the wire-name stripping in
   `buildCacheKeyPartFromOneInput`.

Steps 1 and 2 are independently useful: they make the harness's diff meaningful and they
are the prerequisite FUTURE.md names. Step 3 is the one that must not go first.

**Out of scope.**

- Remote execution and the cache server protocol (B-15, B-30).
- The SDK fingerprint in the key (B-47) and the tool binary hash (B-17). Both are about
  machine identity; both are needed before a shared cache is safe; neither is B-49.
- Depfiles. Nothing emits `-MD`/`-MF` today, and a depfile naming `input:/…` would be
  ambiguous to a Make-style parser.
- `-install_name` for dylib products.
- Normalising diagnostics on the log ports.

**What B-49 does not need to fix.** The mount prefix in wire names: it is not there. The
client resolves `base` and pushes base-relative paths, so `/Users/jade/…` never enters the
graph. B-49's part 3 is narrower than its title suggests — it strips the project's position
under `input:`, not the checkout path.

**Residuals after all three parts.**

- The clang module cache path in a `-g` Swift object (Section 4, non-goals).
- `OutputFile.path` and `ProjectBuilder.outputFolder` in their own nodes' keys. Both
  genuinely determine those nodes' outputs, so stripping them needs a separate argument;
  neither sits upstream of a compile.
- Anything a tool derives from `HOME`, `TMPDIR` or wall-clock. B-05's perturbation fuzzing
  is the systematic answer; the harness is its home.
- Tool versions still come from the machine (AGENTS.md, "Deliberate choices"), so two
  machines with different toolchains produce different bytes under keys that do not yet say
  so. B-17 and B-47.

## 8. Open questions

1. **`-Xfrontend -no-serialize-debugging-options` — safe in every graph?** It is what closes
   the `.swiftmodule`, and it is the only flag here that changes what a *consumer* of the
   module can do. Semel passes explicit `-I` flags per compile, so nothing should need the
   serialized set. *Recommendation:* turn it on, and let the IceCubes external project be
   the evidence — five roots over a real package graph with system-library module maps is
   the case that would fail. If it does, `-file-compilation-dir` alone plus accepting the
   `.swiftmodule` leak is the fallback, and it costs cross-machine sharing of Swift graphs.

2. **The clang module cache.** A fixed absolute `-module-cache-path` shared by every Semel
   run on every machine would make the embedded PCM path identical everywhere, at the cost
   of a writable directory outside the sandbox — a hole in the hermeticity the sandbox
   exists to provide. *Recommendation:* leave it, record it as a residual, and revisit it
   with explicit modules (`-explicit-module-build`), which removes the implicit cache rather
   than relocating it.

3. **Is `projectRoot` the right channel?** It makes the project's position part of node
   identity, so moving a project re-creates every node — which is already true of every
   path-bearing spec, but B-49 is the first change that makes it *deliberate*.
   *Recommendation:* accept it. The alternative, deriving the root from the longest common
   prefix of a node's wire keys, is implicit, fragile under a single-source target, and
   unrecomputable offline.

4. **Should the materialised root be `input:` or `input`?** A colon in a directory name is
   legal on APFS and clang handles it, but it looks like a URI scheme to anything that
   parses paths loosely, and a depfile would be ambiguous. Renaming it at materialisation
   time means the sandbox path and the wire key differ, which is a mapping every node would
   have to know. *Recommendation:* leave it, and revisit if depfiles are ever wanted.

5. **`{sandbox}` substitution: specify or build?** Specified in Section 3 and needed by
   nothing today. *Recommendation:* do not build it until a node needs it; the value now is
   that the answer exists and is not "add a new API".

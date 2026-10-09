# Semel
## A build system

[![CI](https://github.com/jadeburton/semel/actions/workflows/swift.yml/badge.svg?branch=main&style=flat-square)](https://github.com/jadeburton/semel/actions/workflows/swift.yml?style=flat-square) [![macOS 13+](https://img.shields.io/badge/macOS-13%2B-0078d7?logo=apple&logoColor=white&style=flat-square)](https://www.apple.com/macos/) [![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white&style=flat-square)](https://swift.org/) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)

Semel is a functional build system that optimizes for incremental build performance and robustness. Semel uses aggressive caching together with a fully hermetic, private filesystem that reduces the chance of corrupt files or versioning issues. 

The engine models a build as a persistent directed graph of **Nodes** (compilation steps, file sources, folders) connected by **Wires** (data dependencies). All graph state is persisted in a SQLite database via [GRDB](https://github.com/groue/GRDB.swift). When source files change, only the affected subgraph is reprocessed.

## Features

- **Swift language, SPM package and Xcode support** — compiles complete Xcode projects and SPM packages
- **Efficient, incremental builds** — content-addressed caching means unchanged nodes are never reprocessed
- **Powerful caching** — nothing is done twice. Semel: latin for once.
- **Full hermeticity** — all tools are locked-down to exact configured versions and all input source files and dependencies reside within the private filesystem
- **Interactive CLI** — inspect and drive builds from a shell-like command line, which can also be driven by scripts
- **Persistent graph** — the build graph survives restarts; the engine resumes from the last known state
- **Extensible** - Write your own Node types and use them in the graph — [the (WIP) tutorial](docs/tutorial/first-node.md)
- **Intuitive language** - A declarative language for describing build artifacts
- **Concurrent processing** — node inputs are read and computed in parallel
- **Clang support** — compiles C/C++ with full header dependency tracking. (Limited. Though the current development focus is on Swift, C/C++ support will improve with time.)

## Requirements

- macOS 13 or later
- Swift 5.9 or later 
- Xcode 26.6+ recommended

## Building

```sh
git clone <repo-url>
cd semel
swift build -c release
```

The build places five executables under `.build/release`: `semelserv`, the engine; `semel`, the CLI; `semel-swift`, a tool to prepare a Swift project/package for Semel, including placing SPM dependendencies; `semel-clang`, which adds a Semel configuration file to the C/C++ source directory; and `semel-watch`, which pushes a tree into the engine as you save.

## Usage

New here, and want to change Semel rather than only run it? Start with [the (WIP) tutorial](docs/tutorial/first-node.md): build something, watch the cache, write a node; [(WIP) Nodes and wires](docs/tutorial/nodes-and-wires.md) draws the model it rests on.

```sh
.build/release/semel
```

`semel` opens an interactive prompt against the engine, `semelserv`, which holds the graph
and does the work. When no engine is running, `semel` starts one — the `semelserv` beside
its own executable — and leaves it running for the next `semel`; `semel stop` ends it. Its
log is `semelserv.log` beside the graph. Everything the engine persists — the graph
database and the object store — lives under `~/Library/Application Support/semel`,
whatever directory it was launched from; the banner prints the database path, and the base
directory the session reads the disk from (`base`).
`SEMEL_HOME` moves that root and `SEMEL_SOCKET` the daemon's socket, which is how the
tests give each server a home of its own; `SEMEL_JOBS` is how many nodes it computes at
once — every running tool is a process — and is the core count unless set. The banner
prints all three. While `wait`, `build` or `commit` blocks at a terminal, one line shows
where the settle stands — nodes running, nodes pending, nodes done — redrawn in place and
erased before the settle summary prints; `watch` shows it after a bare `push` until a
key is pressed. `SEMEL_PROGRESS=full` makes it a dashboard: the same line, then one line
per node computing now — its type, its name, how long it has been running.
A pipe never sees either, and `SEMEL_PROGRESS=0` turns it off at a terminal. `help` lists the commands at the prompt:

### Navigation

| Command | Description |
|---------|-------------|
| `ls [path]` (`list`) | List nodes in the current directory |
| `cd [path]` | Change current directory |
| `pwd` | Print current location |

Use `-i` / `--input` or `-o` / `--output` flags to target the input or output file system:

```
ls -o
cd -i sources/
```

### File operations

| Command | Description |
|---------|-------------|
| `push <path> ...` | Push files or directories from disk into the input file system: several paths are one push and one report. A push only adds — a file gone from disk stays in `input:` until `rm` removes it; wrap the two in `begin` … `commit` to settle once. A push is a batch of its own, so one that changes a locked folder without its lock is refused whole — see [locked folders](#locked-folders) |
| `rm <path> ...` (`remove`) | Remove files or directories from the input file system: the one way a source leaves it |
| `cp [-i\|-o] <src> [dest]` (`copy`) | Copy a file out of the internal file system to disk |
| `export <folder> --into <dir>` | Copy every product under `<folder>` of the output file system into `<dir>`, keeping the tree below it |

Paths support wildcards (`*`, `**`, `?`):

```
push src/**/*.swift
rm build/**
```

### Build engine

| Command | Description |
|---------|-------------|
| `build <folder> [--into <dir>] [--no-follow] [--verbose]` | `push <folder>`, `wait`, `errors` in one word, then `export` — to `--into`, or to `semel-out/<folder>` under the base. With errors, the report ends with its summary line saying what became of the export: `nothing exported` when a product has no value, `exported to <dir>` when every product has one, and with `--into` the products that have a value are exported, `3 of 5 products exported`; the exit status is non-zero either way. Follows the formula's inputs within your tree: a source the settle reports as not pushed, such as the `semel.machine.config` beside the folder or a path dependency beside a package, is pushed with a line saying which formula asked, and the build waits again; `--no-follow` pushes the folder alone. `--verbose` adds the engine's facts under each error |
| `d` / `debug [<cache key>]` | Dump the full graph state; given a cache entry's key, dump instead the key material that entry was keyed on — the text whose sha256 is that key, so two machines that disagreed about a build diff two texts rather than two hashes |
| `n` / `nudge` | Force-reschedule all nodes for re-evaluation |
| `wait` | Block until the build has settled: every scheduled node processed, nothing asking for another pass |
| `watch` | Show the progress line without committing to a wait: until any key is pressed, which leaves the settle running and says where it stood, or until the settle ends, which prints its summary and `Settled.` as `wait` would. Needs a terminal on standard input; in a script it says so and returns |
| `watch <folder> [--into <dir>] [--only <pattern>]... [--except <pattern>]... [--verbose]` | Start a `semel-watch` for the session's base and that folder, as a child of the prompt: it pushes what you save, after two quiet seconds, and with `--into` exports what has a value after each settle, saying what it exported on the error report's summary line. Its lines interleave with the prompt's; the settle summaries and error reports are the prompt's own. One per session — a second replaces the first |
| `unwatch` | Stop the watcher `watch <folder>` started; `quit` stops it too |
| `e` / `errors [<product>] [--verbose]` | What has no value, and why: each cause once, in the order of its first line — the diagnostic as the tool wrote it, with `input:/` written as the path below the base so a terminal makes it a link; then what it belongs to (`target:`, `product:`, `package:`, `resource:`, `formula:`, `project:`, `source:`); `needed by:` and the products that have no value because of it, by file name, three named and the rest counted, a tree product by its folder; and, where the engine can state one, the thing to change (`re-lock with:`, `missing:`, `set:`, `register:`, `write with:`, `vendor with:`). What carries a failure downstream is never listed. The summary line ends it: `1 error · 5 products without a value`. Given a product (`output:/Packages/libModels.a`, `-o Packages/libModels.a`, or relative to the current directory) or a tree product's folder, the causes it has no value because of, under `libModels.a has no value because:`, filtered by the server; a product with none says `libModels.a has a value.`, and a path that is no product is an error naming it. `--verbose` adds the engine's facts under each cause: the node, its ports and how many nodes carry it. In colour at a terminal unless `NO_COLOR` is set |
| `explain <path>` (`why`) | Say why the last settle did what it did to a product (`output:/hello/hello`, `-o hello/hello`, or relative to the current directory): the nodes upstream of it that ran and the ones the cache answered, each with the wires whose values changed for it, down to the pushed files that changed. The record is the last settle's only, kept in memory: a restart forgets it, and `explain` says so |
| `check` | Walk the graph and report every invariant that does not hold — a wire whose endpoint is gone, a product nothing produces, a manifest disagreeing with its folder. Repairs nothing; `reset` is the repair. Ask it of a settled graph (`wait`, or after `build`): a node the engine is still wiring has no wires yet, and the reply says how many nodes were still scheduled |
| `collect` | Delete every object in the store that nothing refers to — no port, no cached build, no artifact snapshot, no archived graph, and no tree or content-root document that a referenced object is — and say how many went and how many stayed. The engine runs the same collection itself at idle, once after launch and then whenever the store has grown by 64 MB; an object younger than a minute is never collected |
| `t` / `tools [prefix] [--platform <p>]` | List the installed tools as config settings, one block per namespace, as this server's plugins found them; a prefix narrows it to namespaces starting with it (`tools clang`). A report only: the machine's half of the configuration is written outside Semel, by `semel-clang` or `semel-swift prepare` |
| `reset [--cache]` | Discard everything derived and rebuild it from the input file system, copying the discarded graph aside first; the cached builds are kept, so the rebuild is a pass of cache lookups, and `--cache` discards those too |

### Session

| Command | Description |
|---------|-------------|
| `base [path]` / `base --forget` | Show or set the external base directory `push`, `build` and `export` read the disk from. A base that is set is remembered in `semel.base` in the Semel home, and the next `semel` starts from it while the directory exists — the banner's `Base:` line says `(remembered)`; otherwise it starts from the current directory. `--forget` removes the file and leaves this session's base as it is |
| `begin` … `commit` | Hold the engine between several pushes so it settles once, on the `commit`, which also waits for that settle. Every `push` already does this for its own files; this is for a script whose tree arrives over several commands. `wait` refuses while a batch is open. The outermost `commit` refuses the whole batch, and puts `input:` back as it was before `begin`, when the batch changed a [locked folder](#locked-folders) without bringing the lock the folder then matches; no batch is open after a refusal |
| `checkpoint [<name>]` | Name the tree `input:` holds — its content root, one hash, `latest` unless a name is given — and print the hash. A checkpoint is a value, not a moment: two checkpoints of one tree are one hash, whenever they were taken, and nothing lists them by time. Kept in the graph's database; every object below it is already in the store, so recording one copies nothing |
| `checkpoints` | Every checkpoint, by name, with the hash it names |
| `restore <name>` | Make `input:` the checkpoint's tree again — files, links and modes pushed where they differ, what the checkpoint lacks removed — in one batch, through the locks like any other, and wait for the settle it causes, which every node downstream answers from the cache |
| `q` / `quit` / `exit` | Exit, stopping the watcher `watch <folder>` started |

Commands can be prefixed with `semel` (e.g. `semel ls`) for scripting.

Given arguments, the binary runs each one as a command line instead of opening the prompt,
and exits non-zero if any command reported an error — including an error a `wait` in this
run reported at settle, printed through the idle-time report rather than an explicit
`errors` (the daemon does not repeat that report across runs, so a bare `push`/`wait`
against a graph already broken the same way prints nothing) — which makes it a build step:

```sh
.build/release/semel 'base /path/to/repo' 'build Packages --into ./out'
```

A scripted run starts from the remembered base as the prompt does, and its own `base`
replaces it and is remembered in turn; a script that means the directory it runs in says
`base .` first.

To build as you save, watch the tree instead. `semel-watch` takes the base and the folders
`build` would take, mirrors them once — one batch that removes with `rm` what `input:`
holds below them and the disk no longer has, and pushes them — and from then on waits for
two quiet seconds after
each burst of saves — an editor's save, a `git checkout`, a generator's output — and runs
one `begin`, a `push` of what changed and an `rm` of what went, `commit`: one settle, and
its summary, per burst. It follows the formula's inputs as `build` does, and with `--into`
exports what has a value after each settle — after one with errors, the error report's
summary line says what it exported. `--verbose` adds the engine's facts under each error.
What it watches is what `push` would push;
`--only` and `--except` narrow that with the wildcards a for-each takes, and the export
folder and `semel-out` are never pushed. A [locked folder](#locked-folders) is not watched
unless an `--only` names it, and the launch line says which are locked and that
`semel-swift prepare` is how they change; a change to a lock brings its folder with it, so a
re-vendor lands in one batch. A batch the lock refuses at `commit` is reported as the error
it is, and nothing is built or exported from it; the next burst of saves is a batch of its
own. At the prompt, `watch Packages --into ./out` starts
one for the session's base; `unwatch` or `quit` stops it.

```sh
.build/release/semel-watch /path/to/repo Packages --into ./out --except 'Packages/**/Tests/**'
```

### Formulae

A .fmla, or formula file, declaratively describes one or more products and what each product comprises. Formula files describe build graph structure and identity but should avoid containing too much configuration; compiler arguments for example. Such configuration is kept in separate configuration files and referenced from formula files.

A *for-each* makes one wire per file: `{f: <*.c>} "%%f%%.o": …` iterates the paths the pattern matches, sorted, and literal paths may stand beside patterns. `*` and `?` match within one name, so `<src/*.c>` is the `.c` files in `src` and none below it; a `**` segment matches zero or more folders, so `<src/**/*.c>` is every `.c` file at any depth under `src`, `src` itself included, and `<src/**>` every file under it. A wildcard never enters a hidden folder or matches a hidden file; a folder written out before the first wildcard is taken as written. `%%f.0%%` is what the first `*` matched, in the file's own name when a `**` comes before it. The `clang` prelude's `sources:` folder is read with `**`, so `clang.executable(sources: <src>, …)` compiles `src/lib/*.c` too. An `except` clause takes the same kind of items and leaves out every path they match, so the files a folder should not contribute are named rather than all the others:

```
objectFiles: [{f: <*.c> except <lua.c>, <onelua.c>, <ltests.c>} "%%f%%.o": clang.compiled(file: f, settings: settings())]
```

### Building a Swift package

A formula names the package it builds:

```
// semel.fmla, beside Package.swift
include SwiftFormulaConverter(path: <.>).formula
```

`include` here names a node whose output is formula text, effectively pasting it into this formula file, so the included products are the file's
products and the included funcs can be called from further `product` definitions. The packages a package depends on are reached through it. Every node of the build,
dependencies included, reads its settings from the `semel.config` and `semel.machine.config` beside the root. A pushed `Package.swift` that no formula
includes builds nothing, and a settle with no errors says so once, naming the include that would build it.

The following includes multiple packages in the formula:

```
// Packages/semel.fmla
func package(p) = SwiftFormulaConverter(path: p, root: <.>).formula
include package(p: <Timeline>)
include package(p: <Explore>)
```

### Products that are folders

A product name may contain slashes, so a folder can be a set of products under one name: `product 'Hello.app/Hello'`, `product 'Hello.app/Info.plist'`. When a tool decides the file set itself — an asset catalog compiles to `Assets.car` plus one PNG per icon size — its node puts a *tree* on one port, a manifest of files with their content and modes, and a product named with a trailing `/` publishes every entry of it:

```
product 'Hello.app/' = AssetCatalogCompiler(...).files
```

The files appear once the tree has, the way a wildcard's matches appear once the folder has been read; two products at one path are an error. A folder that collects what several tools wrote takes one tree product, merged first:

```
product 'Hello.app/' = TreeMerger(input: ['assets': assets().files, 'strings': strings().files]).files
```

Files a formula names are put into a tree with `TreeBuilder`, each under its wire's name and with the mode of the file it came from — a linked executable stays executable, a pushed file keeps the mode it was pushed with — so a whole app bundle is one tree product. `include 'apple'` spells it:

```
product 'Hello.app/' = apple.bundle(
    executable: swift.executable(sources: <Sources>, name: 'Hello', settings: settings()),
    name: 'Hello',
    infoPlist: apple.infoPlist(base: <Info.plist>, catalog: <Assets.xcassets>, appIcon: 'AppIcon', settings: settings()),
    pkgInfo: <PkgInfo>,
    resources: apple.resources(catalog: <Assets.xcassets>, appIcon: 'AppIcon', strings: <Resources>, settings: settings())
)
```

### Building an Xcode project

An `.xcodeproj` is converted the way a package is: a formula names it, and the converter — an Apple platform node, not part of the engine — reads the project file and the xcconfig files it names, evaluates the build settings the way Xcode layers them, walks the application target's folders, and emits the formula for its bundle:

```
// semel.fmla, beside IceCubesApp.xcodeproj
include XcodeProjectConverter(path: <IceCubesApp.xcodeproj>, root: <.>, configuration: 'Debug', sdk: 'iphonesimulator').formula
```

### Dependencies

Semel never fetches anything: every file a build needs has to be inside the input file system, found by one rule. For a tree of Swift packages, the Swift conversion tool puts them there and writes what the build needs:

```sh
.build/release/semel-swift prepare path/to/Packages --platform ios-simulator
cd path/to && semel 'build Packages'        # products land in path/to/semel-out/Packages
```

The report starts with what the build is for, read back from the `semel.config` the build reads:

```
Platform: ios-simulator, SDK iphonesimulator 26.5, target arm64-apple-ios17.0-simulator (semel.config written)
```

`prepare` never overwrites `semel.config` or `semel.fmla`, so the platform is decided once. Without `--platform`, a `semel.config` already there decides it, and the line ends `(from the semel.config already there)`; with neither, it is `macos`. A `--platform` the files already there do not build for stops the run before anything is written, and the error names the file, the platform it holds and the remedy: delete it to write it for the platform asked for, or omit `--platform` to keep it. For a project, the formula's converter carries the platform as its `sdk:`, which a second line names (`Converter: sdk iphonesimulator (semel.fmla written)`) and which `--platform` must agree with too.

Beside each copy, `prepare` writes a lock — `Dependencies/GRDB.swift.semel-lock` — to check in with it. Its `content` line is the Merkle root of the vendored folder as Semel sees it once pushed, and every build compares the two: a dependency that has moved since it was vendored stops the build, naming the expected and the found hash, rather than being quietly rebuilt against. The `version`, `revision` and `origin` lines are recorded and never enforced by a build: which version a copy should be is the package manager's question, and `prepare` is where it is asked. To accept a change, run `prepare` again, or put the found hash on the `content` line. A vendored folder with no lock beside it builds, with a notice saying nothing checks it.

#### Locked folders

A folder is locked when a lock is in `input:` beside it — `Dependencies/GRDB.swift.semel-lock` beside `Dependencies/GRDB.swift`, the rule a build finds a lock by — and the lock is a write barrier. A batch that changes anything below a locked folder (a push, an `rm`, a link) lands only if it also brings the lock the folder then matches, or removes the lock; otherwise the outermost `commit` refuses it whole — every path it touched is put back, and nothing is built from it — and says why:

```
input:/Packages/Dependencies/GRDB.swift is locked, and the batch changed it without a lock it matches: the batch was not committed, input: is as it was before it, and no batch is open.
  lock:     input:/Packages/Dependencies/GRDB.swift.semel-lock
  expected: sha256:9c1f…
  found:    sha256:47d0…
  paths:    input:/Packages/Dependencies/GRDB.swift/GRDB/Core/Database.swift
  `semel-swift prepare` vendors the folder again and writes its lock with it; removing the lock unlocks the folder.
```

A push outside `begin` … `commit` is a batch of its own, so `push` and `build` are refused the same way, and `build` then stops with `Not built: the push was refused, and nothing was exported.` A lock that does not parse refuses the batch naming its line: a folder with a broken lock is locked shut, not open. `prepare` writes a copy and its lock together, so a `build` after it pushes both in one batch and lands. To change vendored code on purpose, take the lock out (`rm` it, and delete it from disk), which is a visible change to review; `prepare` puts the copy back as the lock describes it. `checkpoint` and `restore` go through the barrier too: a restore across a re-vendor brings the old lock back with the old copy.

A second `prepare` touches only what moved. SwiftPM resolves again, and each pin it chose is compared with the lock beside the copy: a copy whose lock records the same version, revision and origin, and whose folder still folds to the lock's `content`, is left as it is with its lock, so its root does not move and nothing built from it rebuilds. A pin that moved is copied and locked again, and so is a copy with no lock, a lock that does not parse, or a copy changed since its lock was written. The report says which, one line per package copied, then a count of the rest:

```
GRDB.swift 6.29.3 → 7.0.0, re-vendored
33 unchanged
```

Comparing costs little beside resolution itself: folding all thirty-four of CodeEdit's copies (808 MB) against their locks takes under two seconds.

## Architecture

```
semel-server/    semelserv — the composition root: registers the toolchains, starts the
                 engine, listens on the socket. One per user.
semel/           semel — the prompt; opens a connection to semelserv and nothing else
  CommandInterpreter/  SemelCLI: the REPL, its command plugins and renderers — the error
                       report's lines are drawn here, from the documents (ErrorReportRenderer)
  Server/              SemelServer: the engine behind one RequestHandler, sessions, events
  Transport/           SemelTransport: the Unix-socket listener and frame stream
semel-swift/     semel-swift — `prepare`: finds a tree's roots, vendors git dependencies,
                 writes semel.fmla and the two config files (SemelSwiftTool)
semel-clang/     semel-clang — writes semel.machine.config for the clang tools
                 (SemelClangTool)
semel-watch/     semel-watch — watches a tree with FSEvents and, after two quiet seconds,
                 runs the push and rm a person would type, through SemelCLI; one per tree
  Sources/SemelWatch/  SemelWatch: the filter, the coalescer, the batch planner, the loop
machine-file/    SemelMachineFile: the one writer of semel.machine.config, for both tools
```

The packages they link:

```
SemelCore/       The engine
  BuildEngine          Async process loop, batch scheduling, deferred deletion; +Reset, +Versioning
  Cache                Content-addressed cache of a node's outputs, keyed on type, properties and every input
  GraphSpec            A node's demand for an upstream subgraph, as text; GraphSpecApplier matches it against the graph
  FormulaParser        Reads .fmla text into a graph spec
  ErrorReport          Which failures the graph holds, as documents, at settle and on request
  ProductReach         Which products a failing node stops: the walk down its wires, once per report
  Nodes/
    StaticFile         Raw file content node
    Folder             Directory manifest node
    OutputFile         Publishes a built artifact
    ProjectFinder      Discovers project files
    ProjectBuilder     Orchestrates a full project build
    SettingsLiteral    Settings written into a formula, as a source
    ConfigFilter       Selects one node's settings out of a config file
    ConfigMerger       Lays one set of settings over another: the only place two meet
    TreeBuilder, TreeFile, TreeMerger   Trees of files on a port, and folder products
  Database             GRDB-backed persistence layer
SemelNodeKit/    Node-authoring API — no dependency on the engine
  Node                 Protocol for all build steps; wraps a NodeRecord
  NodeDescriptor       The ports a node type declares
  ConfigurationText    key=value per line, the shape settings travel in
  SettingNamespace     Where a node's settings live in a config file
  DataObjectStore      Content-addressed blob store
  TypeRegistry         Deserialises nodes by kind ID
  ToolDiscovery        The tools each toolchain declares, registered under the version found
  ToolRunner           Runs a tool in an isolated sandbox
  ToolSandbox          What a tool is allowed to know about the directory it runs in
  ErrorDocument        What a failing node publishes: the diagnostic, what it belongs to and
                       the remedy, as values a client renders; ErrorCondition, every engine
                       condition a report shows
  SemelPaths           Where the home, database, object store and socket live
SemelProtocol/   The wire protocol between semel and semelserv: typed requests and
                 responses, frames, and the connection a client holds. A frame's JSON is
                 capped at 1 MiB, so the replies that grow with the graph — `list`,
                 `remove`, `errors` — stream: several frames for one request, every one
                 but the last carrying flag bit 0, "more follows"
SemelSwift/      Swift toolchain node types
  SwiftCompiler          Compiles .swift → .o + .swiftmodule
  SwiftLinker            Links object files into an executable or library
  SwiftPackageReader     Reads Package.swift manifests
  SwiftFormulaConverter  Turns a package manifest into a formula
SemelClang/      Clang toolchain node types
  ClangCompiler          Compiles .c/.cpp → .o
  ClangLinker            Links Clang object files
  ClangArchiver          libtool over Clang object files → a static archive
  ClangPreprocessor      Preprocesses headers
  ClangIncludeFinder     Tracks #include dependencies
SemelApple/      Apple platform node types — what an app bundle needs beyond code
  AssetCatalogCompiler   actool over .xcassets and .icon folders → Assets.car + icons (a tree)
  StringCatalogCompiler  xcstringstool over an .xcstrings → one .lproj per language (a tree)
  InfoPlistBuilder       Merges base, partial plists and keys; resolves $(VAR)
  XcodeProjectConverter  Turns an .xcodeproj and its xcconfig into a formula for the app and its extensions
SemelExamples/   Nodes that exist to be read
  LineCounter            One `name: count` line per input wire — the tutorial's reference copy
SemelDatabaseModels/        GRDB schema models (NodeRecord, Wire, OutputPort, …)
```

## License

Released under the [MIT License](LICENSE).

The end-to-end roster builds other people's projects, fetched at test time and never
vendored here, with one exception: `EndToEnd/Fixtures/external/food-truck-mac` carries
four source files of Apple's Food Truck sample with one guard corrected, under Apple's
sample code license, which is beside them.

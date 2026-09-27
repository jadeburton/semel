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

The build places four executables under `.build/release`: `semelserv`, the engine; `semel`, the CLI; `semel-swift`, a tool to prepare a Swift project/package for Semel, including placing SPM dependendencies; and `semel-clang`, which adds a Semel configuration file to the C/C++ source directory.

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
whatever directory it was launched from; the banner prints the database path.
`SEMEL_HOME` moves that root and `SEMEL_SOCKET` the daemon's socket, which is how the
tests give each server a home of its own; `SEMEL_JOBS` is how many nodes it computes at
once — every running tool is a process — and is the core count unless set. The banner
prints all three. While `wait`, `build` or `commit` blocks at a terminal, one line shows
where the settle stands — nodes running, nodes pending, nodes done — redrawn in place and
erased before the settle summary prints; a pipe never sees it, and `SEMEL_PROGRESS=0`
turns it off at a terminal. `help` lists the commands at the prompt:

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
| `push <path>` | Push a file or directory from disk into the input file system |
| `rm <path>` (`remove`) | Remove a file or directory from the input file system |
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
| `build <folder> [--into <dir>] [--no-follow]` | `push <folder>`, `wait`, `errors` in one word, then `export` — to `--into`, or to `semel-out/<folder>` under the base — unless the build reported errors. Follows the formula's inputs within your tree: a source the settle reports as not pushed, such as the `semel.machine.config` beside the folder or a path dependency beside a package, is pushed with a line saying which formula asked, and the build waits again; `--no-follow` pushes the folder alone. Errors are reported once, one entry per cause |
| `d` / `debug [<cache key>]` | Dump the full graph state; given a cache entry's key, dump instead the key material that entry was keyed on — the text whose sha256 is that key, so two machines that disagreed about a build diff two texts rather than two hashes |
| `n` / `nudge` | Force-reschedule all nodes for re-evaluation |
| `wait` | Block until the build has settled: every scheduled node processed, nothing asking for another pass |
| `e` / `errors` | Show all current build errors |
| `check` | Walk the graph and report every invariant that does not hold — a wire whose endpoint is gone, a product nothing produces, a manifest disagreeing with its folder. Repairs nothing; `reset` is the repair. Ask it of a settled graph (`wait`, or after `build`): a node the engine is still wiring has no wires yet, and the reply says how many nodes were still scheduled |
| `collect` | Delete every object in the store that nothing refers to — no port, no cached build, no artifact snapshot, no archived graph, and no tree or content-root document that a referenced object is — and say how many went and how many stayed. The engine runs the same collection itself at idle, once after launch and then whenever the store has grown by 64 MB; an object younger than a minute is never collected |
| `t` / `tools [prefix] [--platform <p>]` | List the installed tools as config settings, one block per namespace, as this server's plugins found them; a prefix narrows it to namespaces starting with it (`tools clang`). A report only: the machine's half of the configuration is written outside Semel, by `semel-clang` or `semel-swift prepare` |
| `reset [--cache]` | Discard everything derived and rebuild it from the input file system, copying the discarded graph aside first; the cached builds are kept, so the rebuild is a pass of cache lookups, and `--cache` discards those too |

### Session

| Command | Description |
|---------|-------------|
| `base [path]` | Show or set the external base directory for `push` |
| `begin` … `commit` | Hold the engine between several pushes so it settles once, on the `commit`, which also waits for that settle. Every `push` already does this for its own files; this is for a script whose tree arrives over several commands. `wait` refuses while a batch is open |
| `q` / `quit` / `exit` | Exit |

Commands can be prefixed with `semel` (e.g. `semel ls`) for scripting.

Given arguments, the binary runs each one as a command line instead of opening the prompt,
and exits non-zero if any command reported an error — including an error a `wait` in this
run reported at settle, printed through the idle-time report rather than an explicit
`errors` (the daemon does not repeat that report across runs, so a bare `push`/`wait`
against a graph already broken the same way prints nothing) — which makes it a build step:

```sh
.build/release/semel 'base /path/to/repo' 'build Packages --into ./out'
```
### Formulae

A .fmla, or formula file, declaratively describes one or more products and what each product comprises. Formula files describe build graph structure and identity but should avoid containing too much configuration; compiler arguments for example. Such configuration is kept in separate configuration files and referenced from formula files.

### Building a Swift package

A formula names the package it builds:

```
// semel.fmla, beside Package.swift
include SwiftFormulaConverter(path: <.>).formula
```

`include` here names a node whose output is formula text, effectively pasting it into this formula file, so the included products are the file's
products and the included funcs can be called from further `product` definitions. The packages a package depends on are reached through it. Every node of the build,
dependencies included, reads its settings from the `semel.config` and `semel.machine.config` beside the root.

The following includes multiple packages in the formula:

```
// Packages/semel.fmla
func package(p) = SwiftFormulaConverter(path: p, root: <.>).formula
include package(p: <Timeline>)
include package(p: <Explore>)
```

### Products that are folders

A product name may contain slashes, so a bundle is a set of products under one folder name: `product 'Hello.app/Hello'`, `product 'Hello.app/Info.plist'`. When a tool decides the file set itself — an asset catalog compiles to `Assets.car` plus one PNG per icon size — its node puts a *tree* on one port, a manifest of files with their content and modes, and a product named with a trailing `/` publishes every entry of it:

```
product 'Hello.app/' = AssetCatalogCompiler(...).files
```

The files appear once the tree has, the way a wildcard's matches appear once the folder has been read; two products at one path are an error. A folder that collects what several tools wrote takes one tree product, merged first:

```
product 'Hello.app/' = TreeMerger(input: ['assets': assets().files, 'strings': strings().files]).files
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

## Architecture

```
semel-server/    semelserv — the composition root: registers the toolchains, starts the
                 engine, listens on the socket. One per user.
semel/           semel — the prompt; opens a connection to semelserv and nothing else
  CommandInterpreter/  SemelCLI: the REPL, its command plugins and renderers
  Server/              SemelServer: the engine behind one RequestHandler, sessions, events
  Transport/           SemelTransport: the Unix-socket listener and frame stream
semel-swift/     semel-swift — `prepare`: finds a tree's roots, vendors git dependencies,
                 writes semel.fmla and the two config files (SemelSwiftTool)
semel-clang/     semel-clang — writes semel.machine.config for the clang tools
                 (SemelClangTool)
machine-file/    SemelMachineFile: the one writer of semel.machine.config, for both tools
```

The packages they link:

```
SemelCore/       The engine
  BuildEngine          Async process loop, batch scheduling, deferred deletion; +Reset, +Versioning
  Cache                Content-addressed cache of a node's outputs, keyed on type, properties and every input
  GraphSpec            A node's demand for an upstream subgraph, as text; GraphSpecApplier matches it against the graph
  FormulaParser        Reads .fmla text into a graph spec
  ErrorReport          How a node's errors are written out, at settle and on request
  Nodes/
    StaticFile         Raw file content node
    Folder             Directory manifest node
    OutputFile         Publishes a built artifact
    ProjectFinder      Discovers project files
    ProjectBuilder     Orchestrates a full project build
    Configuration      Build configuration node
    ConfigFilter       Selects one node's settings out of a config file
    ConfigMerger       Lays one config file over another
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
  SemelPaths           Where the home, database, object store and socket live
SemelProtocol/   The wire protocol between semel and semelserv: typed requests and
                 responses, frames, and the connection a client holds
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

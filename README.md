# Semel
## A build system

[![CI](https://github.com/jadeburton/semel/actions/workflows/swift.yml/badge.svg?branch=main&style=flat-square)](https://github.com/jadeburton/semel/actions/workflows/swift.yml?style=flat-square) [![macOS 13+](https://img.shields.io/badge/macOS-13%2B-0078d7?logo=apple&logoColor=white&style=flat-square)](https://www.apple.com/macos/) [![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white&style=flat-square)](https://swift.org/) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)

Semel pro semper: once and for all. Semel is a functional build system that aggressively caches all stages of a build, together with a fully hermetic, private filesystem that reduces the chance of corrupt or missing files or versioning issues. 

The engine models a build as a persistent directed graph of **Nodes** (compilation steps, file sources, folders) connected by **Wires** (data dependencies). All graph state is persisted in a SQLite database via [GRDB](https://github.com/groue/GRDB.swift). When source files change, only the affected subgraph is reprocessed.

## Features

- **Incremental builds** — content-addressed caching means unchanged nodes are never reprocessed
- **Concurrent processing** — node inputs are read and computed in parallel; outputs are applied sequentially to avoid wire-deletion races
- **Swift & Clang support** — compiles `.swift` modules and C/C++ translation units with full header dependency tracking
- **Interactive REPL** — inspect and drive builds from a shell-like command line
- **Persistent graph** — the build graph survives restarts; the engine resumes from the last known state
- **Extensible** - Write your own Node types as a Swift package the server links, and put them into the graph — [the tutorial](docs/tutorial/first-node.md) does it in forty lines
- **Intuitive language** - A declarative language for specifying what Nodes are needed to derive a given product
- **No defaults** - Every tool a build runs is named in a config file down to its version, so a cached result means the same thing on every machine and after every upgrade
- **One graph per user, shared cache planned** - Each developer's machine runs its own engine over a private graph; a central cache server that lets them share compiled results is designed and not yet built (`FUTURE.md`, "Settled direction")

## Requirements

- macOS 13 or later
- Swift 5.9 or later (Xcode 15+)

## Building

```sh
git clone <repo-url>
cd semel
swift build -c release
```

The build places three executables under `.build/release`: `semelserv`, the engine;
`semel`, the prompt; and `semel-swift`, the Swift conversion tool.

## Usage

New here, and want to change Semel rather than only run it? Start with
[the tutorial](docs/tutorial/first-node.md): build something, watch the cache, write a node.

Start the engine — `semelserv` holds the graph and does the work — then the prompt:

```sh
.build/release/semelserv   # in one terminal
.build/release/semel       # in another
```

`semel` opens an interactive prompt against the running server. Everything the server
persists — the graph database and the object store — lives under
`~/Library/Application Support/semel`, whatever directory it was launched from; the banner
prints the database path. `SEMEL_HOME` moves that root and `SEMEL_SOCKET` the daemon's
socket, which is how the tests give each server a home of its own. Available commands:

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
| `d` / `debug` | Dump the full graph state |
| `n` / `nudge` | Force-reschedule all nodes for re-evaluation |
| `wait` | Block until the build has settled: every scheduled node processed, nothing asking for another pass |
| `build <folder> [--into <dir>]` | `push <folder>`, `wait`, `errors` in one word; given a destination, `export` too, unless the build reported errors |
| `e` / `errors` | Show all current build errors |
| `t` / `tools [prefix]` | List the installed tools as `semel.config` settings, one block per namespace, ready to paste; a prefix narrows it to namespaces starting with it (`tools clang`) |
| `reset` | Discard everything derived and rebuild from the input file system |

### Session

| Command | Description |
|---------|-------------|
| `base [path]` | Show or set the external base directory for `push` |
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

### Configuration

Semel has no defaults. Every tool a build runs is declared in a config file in the input
file system — `semel.config` beside a Swift package or Xcode project, `clang.cfg` or
whatever a hand-written formula names — down to the tool's version string, because the
version is part of what makes a cached result reusable. A tool given no setting fails and
names the key it wants and the file to put it in; a key nothing reads is reported once
the graph settles. Settings are keyed by namespace, `clang.compiler.target=…`, and each
node selects its own slice, so a change to one tool's setting leaves every other tool's
cache entries valid. `tools` prints the tool blocks for this machine ready to paste, and
`semel-swift prepare` writes the whole file for a Swift tree. The design is in
`docs/superpowers/specs/2026-08-30-semel-configuration-design.md`.

### Building a Swift package

A `Package.swift` is not built on its own. A formula names the package it builds, and only
a formula's products are published — so a dependency package, reached through the one the
formula names, produces no artifacts of its own:

```
// semel.fmla, beside Package.swift
include SwiftFormulaConverter(path: <.>).formula
```

`include` is the formula language's only notion here: it names a node whose output is
formula text and merges that text into the file, so the included products are the file's
products and the included funcs can be called from further `product` definitions. That
the node is a Swift package converter is the toolchain's business, not the language's.
The packages a package depends on are reached through it. Every node of the build,
dependencies included, reads its settings from the `semel.config` beside the named package.

A tree with several root packages puts one formula above them and names each with the
formula's folder as the build root, so their common dependencies are vendored and compiled
once and one config serves them all:

```
// Packages/semel.fmla
func package(p) = SwiftFormulaConverter(path: p, root: <.>).formula
include package(p: <Timeline>)
include package(p: <Explore>)
```

### Products that are folders

A product name may contain slashes, so a bundle is a set of products under one folder
name: `product 'Hello.app/Hello'`, `product 'Hello.app/Info.plist'`. When a tool decides
the file set itself — an asset catalog compiles to `Assets.car` plus one PNG per icon
size — its node puts a *tree* on one port, a manifest of files with their content and
modes, and a product named with a trailing `/` publishes every entry of it:

```
product 'Hello.app/' = AssetCatalogCompiler(...).files
```

The files appear once the tree has, the way a wildcard's matches appear once the folder
has been read; two products at one path are an error. A folder that collects what
several tools wrote takes one tree product, merged first:

```
product 'Hello.app/' = TreeMerger(input: ['assets': assets().files, 'strings': strings().files]).files
```

`export` copies the folder out as it is.

### Using a package from an app

A package's formula publishes its own products, and beside each product `P` it defines
two funcs any formula that includes it can call by the product's name: `modules_P()`,
the tree of every `.swiftmodule` behind the product, and `objects_P()`, the tree of every
object it links. An app imports and links the product without knowing its targets:

```
include SwiftFormulaConverter(path: <HelloKit>, root: <.>).formula

func compiled() = SwiftCompiler(..., moduleTrees: ['HelloKit': modules_HelloKit().files])
product 'Hello.app/Hello' = SwiftLinker(..., input: ['Hello.o': compiled().object],
                                        objectTrees: ['HelloKit': objects_HelloKit().files]).output
```

The trees are merged on the way in: a module or object two products share is one file.
`TreeBuilder` is what makes a tree out of named files, the counterpart of `TreeFile`.

### Building an Xcode project

An `.xcodeproj` is converted the way a package is: a formula names it, and the converter
— an Apple platform node, not part of the engine — reads the project file and the
xcconfig files it names, evaluates the build settings the way Xcode layers them, walks
the application target's folders, and emits the formula for its bundle:

```
// semel.fmla, beside IceCubesApp.xcodeproj
include XcodeProjectConverter(path: <IceCubesApp.xcodeproj>, root: <.>, configuration: 'Debug', sdk: 'iphonesimulator').formula
```

The emitted formula includes every package the project references — local ones as the
project's wrappers, remote ones under `Dependencies/` by repository name — compiles the
synchronized folders against the linked products' module trees, links their object
trees into the executable, compiles the asset and string catalogs, copies the plain
resources flat, and builds the Info.plist from the project's file, the generated keys
and actool's partial. The xcconfig a fresh clone lacks is an empty layer; a `$(VAR)` it
would have defined is then reported by the plist builder rather than shipped.

### Dependencies, and clone to build

Semel never fetches anything: every file a build needs has to be inside the input file
system, found by one rule. For a tree of Swift packages, the Swift conversion tool puts
them there and writes what the build needs:

```sh
.build/release/semel-swift prepare path/to/Packages --platform ios-simulator
.build/release/semel 'base path/to' 'build Packages --into ./out'
```

`prepare` finds every `Package.swift` under the folder, takes as roots the packages no
other one there depends on by path, runs `swift package resolve` on each root and copies
every git dependency, transitively, into `<folder>/Dependencies/<name>` — one flat folder,
one copy per package, named as SwiftPM names its checkouts (`Dependencies/GRDB.swift`).
That folder is the only place the converter looks for a git or registry dependency,
whichever package declared it; local path dependencies stay wherever the manifest says.
Then it writes `semel.fmla` (one `include` per root, all under one build root) and
`semel.config` for the platform — the namespaces the formula reads, the tools and
SDK this machine has, and a target at the highest deployment version the packages declare
(`macos` is the default platform).

A folder holding an `.xcodeproj` is a project: the project is the one root, its packages
— the ones it declares and the ones its local packages reach — are resolved through
`xcodebuild -resolvePackageDependencies` and vendored the same way, the formula names
`XcodeProjectConverter`, and the config's target carries the application's deployment
target. An xcconfig the project names but the repository does not ship is put in place from
the template beside it (`.template`, `.example`, `.sample` or `.dist`), or from a file named
with `--xcconfig <name>=<file>`; failing both, `prepare` says which settings are left
undefined so the file can be written by hand.

It is the same command every time: after cloning, and again after changing a dependency.
Each vendored copy is replaced, not merged; a formula or config already there is kept, so
edits survive, and a project that ships its own needs no `prepare` at all. Semel itself
knows nothing of Swift packages or Xcode projects; `semel-swift` is the Swift conversion
tool, and another toolchain gets one of its own if it needs one.

### Testing against real projects

`swift test` builds the fixtures under `EndToEnd/Fixtures` — a C program, a C++ one,
the tutorial's project, a Swift package with a path dependency and a SwiftUI app for the
simulator — through `semelserv`, `semel` and `semel-swift` together, each twice in two
fresh homes, and requires the two export trees to match byte for byte, static archives
included. `SEMEL_E2E_EXTERNAL=1 swift test --filter SemelEndToEndTests` adds the real
projects pinned in `EndToEnd/Tests/Projects.swift` — IceCubesApp's package tree, and the
app itself from its Xcode project — fetched once into `~/Library/Caches/semel/end-to-end`
(`SEMEL_E2E_CACHE` moves that); CI runs those nightly. `SEMEL_E2E_KEEP=1` keeps a run's
directory under `/tmp/semel-tests` for inspection.

## Architecture

Three executables, built from the root package:

```
semel-server/    semelserv — the composition root: registers the toolchains, starts the
                 engine, listens on the socket. One per user.
semel/           semel — the prompt; opens a connection to semelserv and nothing else
  CommandInterpreter/  SemelCLI: the REPL, its command plugins and renderers
  Server/              SemelServer: the engine behind one RequestHandler, sessions, events
  Transport/           SemelTransport: the Unix-socket listener and frame stream
semel-swift/     semel-swift — `prepare`: finds a tree's roots, vendors git dependencies,
                 writes semel.fmla and semel.config (SemelSwiftTool)
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
    ProductPresence    Which products exist, and what changed since the last pass
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

The engine runs a two-phase processing loop:

1. **Phase 1 (concurrent):** scheduled nodes read their inputs and compute outputs in parallel — no graph mutations occur
2. **Phase 2 (sequential):** computed outputs are written to the graph one at a time; cascades reschedule affected downstream nodes

## License

Copyright © 2026 Jade Burton. Released under the [MIT License](LICENSE).

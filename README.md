# Semel
## A build system

[![CI](https://github.com/jadeburton/build_system/actions/workflows/swift.yml/badge.svg?branch=main&style=flat-square)](https://github.com/jadeburton/build_system/actions/workflows/swift.yml?style=flat-square) [![macOS 13+](https://img.shields.io/badge/macOS-13%2B-0078d7?logo=apple&logoColor=white&style=flat-square)](https://www.apple.com/macos/) [![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white&style=flat-square)](https://swift.org/) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)

Semel pro semper: once and for all. Semel is a functional build system that aims to cache the shit out of your builds, together with a fully hermetic, private filesystem that greatly reduces the chance of corrupt or missing files or versioning issues. 

The same work is never done twice.

Isn't every build system meant to do that anyway? This project was born out of frustration with Apple's build system rebuilding files that definitely had not changed, and generally not scaling for very large project sizes.

The engine models a build as a persistent directed graph of **Nodes** (compilation steps, file sources, folders) connected by **Wires** (data dependencies). All graph state is persisted in a SQLite database via [GRDB](https://github.com/groue/GRDB.swift). When source files change, only the affected subgraph is reprocessed.

## Features

- **Incremental builds** — content-addressed caching means unchanged nodes are never reprocessed
- **Concurrent processing** — node inputs are read and computed in parallel; outputs are applied sequentially to avoid wire-deletion races
- **Swift & Clang support** — compiles `.swift` modules and C/C++ translation units with full header dependency tracking
- **Interactive REPL** — inspect and drive builds from a shell-like command line
- **Persistent graph** — the build graph survives restarts; the engine resumes from the last known state
- **Extensible** - Write a plugin and provide your own Node types that can be put into the graph
- **Intuitive language** - A declarative language for specifying what Nodes are needed to derive a given product
- **Shared cache over multiple users** - A server process combines all graphs to allow intrinsic reuse and caching

## Requirements

- macOS 13 or later
- Swift 5.9 or later (Xcode 15+)

## Building

```sh
git clone <repo-url>
cd semel
swift build -c release
```

The executable is placed at `.build/release/semel`.

## Usage

Start the engine:

```sh
.build/release/semel
```

The engine opens an interactive prompt. Everything it persists — the graph database and the
object store — lives under `~/Library/Application Support/semel`, whatever directory it was
launched from; the banner prints the database path. Available commands:

### Navigation

| Command | Description |
|---------|-------------|
| `ls [path]` | List nodes in the current directory |
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
| `rm <path>` | Remove a file or directory from the input file system |
| `cp [-i\|-o] <src> [dest]` | Copy a file out of the internal file system to disk |
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
| `build <folder>` | `push <folder>`, `wait`, `errors` in one word |
| `e` / `errors` | Show all current build errors |
| `t` / `tools` | List the installed tools as `semel.config` settings, one block per namespace, ready to paste |
| `reset` | Discard everything derived and rebuild from the input file system |

### Session

| Command | Description |
|---------|-------------|
| `base [path]` | Show or set the external base directory for `push` |
| `q` / `quit` / `exit` | Exit |

Commands can be prefixed with `semel` (e.g. `semel ls`) for scripting.

Given arguments, the binary runs each one as a command line instead of opening the prompt,
and exits non-zero if any command reported an error — which makes it a build step:

```sh
.build/release/semel 'base /path/to/repo' 'build Packages' 'export Packages --into ./out'
```

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

### Dependencies

Semel never fetches anything: every file a build needs has to be inside the input file
system. For a Swift package, `semel-vendor` puts them there:

```sh
.build/release/semel-vendor path/to/package-root
```

It runs `swift package resolve` and copies every git dependency, transitively, into
`<package-root>/Dependencies/<name>` — one flat folder, one copy per package, named as
SwiftPM names its checkouts (`Dependencies/GRDB.swift`). That folder is the only place the
converter looks for a git or registry dependency, whichever package declared it. Local path
dependencies stay wherever the manifest says. Run it again after changing a dependency;
each copy is replaced, not merged. For several packages under one build root, name the
shared folder: `semel-vendor --into Packages/Dependencies Packages/Timeline Packages/Explore`.

### Clone to build

For a tree of Swift packages that ships no formula, `init` does the whole conversion:

```sh
.build/release/semel-vendor init path/to/Packages --platform ios-simulator
.build/release/semel 'base path/to' 'build Packages' 'export Packages --into ./out'
```

It finds every `Package.swift` under the folder, takes as roots the packages no other one
there depends on by path, vendors the roots' closure into `Dependencies`, and writes
`semel.fmla` (one `include` per root, all under one build root) and `semel.config` for the
platform — every namespace the toolchains declare, the tools and SDK this machine has, and
a target at the highest deployment version the packages declare (`macos` is the default
platform). It never replaces a formula or config that is already there: a project that
ships its own has already decided, and needs no `init` at all. Semel itself knows nothing
of Swift packages; `semel-vendor` is the Swift conversion tool, and another toolchain gets
one of its own if it needs one.

## Architecture

```
semel/          CLI executable — REPL and command plugins
SemelCore/       Core library
  BuildEngine          Async process loop, batch scheduling, deferred deletion
  FormulaParser        Reads .fmla text into a graph spec
  Nodes/
    StaticFile         Raw file content node
    Folder             Directory manifest node
    OutputFile         Publishes a built artifact
    ProjectFinder      Discovers project files
    ProjectBuilder     Orchestrates a full project build
    Configuration      Build configuration node
    ConfigFilter       Selects one node's settings out of a config file
  Database             GRDB-backed persistence layer
SemelNodeKit/    Node-authoring API — no dependency on the engine
  Node                 Protocol for all build steps; wraps a NodeRecord
  ConfigurationText    key=value per line, the shape settings travel in
  SettingNamespace     Where a node's settings live in a config file
  DataObjectStore      Content-addressed blob store
  TypeRegistry          Deserialises nodes by kind ID
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
SemelDatabaseModels/        GRDB schema models (NodeRecord, Wire, OutputPort, …)
```

The engine runs a two-phase processing loop:

1. **Phase 1 (concurrent):** scheduled nodes read their inputs and compute outputs in parallel — no graph mutations occur
2. **Phase 2 (sequential):** computed outputs are written to the graph one at a time; cascades reschedule affected downstream nodes

## License

Copyright © 2026 Jade Burton. Released under the [MIT License](LICENSE).

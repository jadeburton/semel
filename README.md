# Semel
## A build system

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
cd build_system
swift build -c release
```

The executable is placed at `.build/release/semel`.

## Usage

Start the engine:

```sh
.build/release/semel
```

The engine opens an interactive prompt. Available commands:

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
| `e` / `errors` | Show all current build errors |

### Session

| Command | Description |
|---------|-------------|
| `base [path]` | Show or set the external base directory for `push` |
| `q` / `quit` / `exit` | Exit |

Commands can be prefixed with `semel` (e.g. `semel ls`) for scripting.

## Architecture

```
build_system/          CLI executable — REPL and command plugins
SemelCore/       Core library
  BuildEngine          Async process loop, batch scheduling, deferred deletion
  FormulaParser        Reads .fmla text into a graph shape
  Nodes/
    StaticFile         Raw file content node
    Folder             Directory manifest node
    OutputFile         Publishes a built artifact
    ProjectFinder      Discovers project files
    ProjectBuilder     Orchestrates a full project build
    Configuration      Build configuration node
    ConfigSubset       Selects one node's settings out of a config file
  Database             GRDB-backed persistence layer
SemelNodeKit/    Node-authoring API — no dependency on the engine
  Node                 Protocol for all build steps; wraps a NodeRecord
  ConfigurationText    key=value per line, the shape settings travel in
  SettingNamespace     Where a node's settings live in a config file
  DataObjectStore      Content-addressed blob store
  TypeRegistry          Deserialises nodes by kind ID
SemelSwift/      Swift toolchain node types
  SwiftCompilerTool    Compiles .swift → .o + .swiftmodule
  SwiftLinkerTool      Links object files into an executable
  SwiftPackageReaderTool  Reads Package.swift manifests
  SwiftFormulaConverter   Turns a package manifest into a formula
SemelClang/      Clang toolchain node types
  ClangCompilerTool    Compiles .c/.cpp → .o
  ClangLinkerTool      Links Clang object files
  ClangPreprocessorTool   Preprocesses headers
  ClangIncludeFinder   Tracks #include dependencies
SemelDatabaseModels/        GRDB schema models (NodeRecord, Wire, OutputPort, …)
```

The engine runs a two-phase processing loop:

1. **Phase 1 (concurrent):** scheduled nodes read their inputs and compute outputs in parallel — no graph mutations occur
2. **Phase 2 (sequential):** computed outputs are written to the graph one at a time; cascades reschedule affected downstream nodes

## License

Copyright © 2026 Jade Burton. Released under the [MIT License](LICENSE).

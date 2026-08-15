# Making the engine toolchain-agnostic: SemelNodeKit, SemelSwift, SemelClang

**Status:** design agreed, not yet implemented
**Date:** 2026-08-15

## Goal

`BuildSystemCore` should know nothing about Swift or C/C++. The nine toolchain node
functions move into their own packages, programming against a published node-authoring API
rather than against the engine.

This is the same work `FUTURE.md` calls *"plugin arch so that others (and ai) can add
toolchains like c++"*. Extracting Swift and Clang is also the best available test of that
API: they become its first two consumers, so any gap shows up immediately rather than being
discovered by the first outsider.

## Naming

`BuildSystem` is phased out in favour of `Semel`, opportunistically rather than in one
sweep. New modules take the new prefix; existing ones are renamed when they are being
touched for other reasons.

Two words are deliberately **not** used, because both already mean something else here:
*plugin* (`CommandPlugin` for CLI verbs, `ProjectBuilderPlugin` for project discovery) and
*toolchain* (`Toolchain.swift`, `ToolDescriptor` — tool discovery and versioning, not node
functions).

## Layout

```
DatabaseModels                        (→ SemelDatabaseModels, later)
      ↑
SemelNodeKit          what a node function programs against
      ↑           ↑             ↑
  SemelCore   SemelSwift   SemelClang
  (engine)    (nodes)      (nodes)
      ↑           ↑             ↑
      └───────────┴─────────────┘
                semel            composition root
```

The load-bearing arrow is the one that is **absent**: `SemelSwift` and `SemelClang` do not
depend on `SemelCore`. That is what makes the engine agnostic — not discipline, but the
inability to refer to them. The CLI composes.

## The API is smaller than expected

Measured rather than assumed. Across all nine toolchain nodes there is exactly one reach
into the graph:

```swift
guard extPath.hasPrefix(Folder.inputFileSystemName + "/") else { continue }
```

Every other occurrence of `thisNode` is the `init(thisNode:)` signature or a comment. By
contrast the engine's own nodes touch the graph constantly — Folder 11 times, StaticFile 6,
OutputFile 6, ProjectBuilder 4.

So toolchain nodes are already pure functions of `ProcessInput → ProcessOutput`, and
**`SemelNodeKit` does not need to expose graph access at all**. Reading and writing the
graph stays a privilege of the engine's own nodes.

### Moves to SemelNodeKit

| | |
|---|---|
| `NodeFunction`, `InputlessNodeFunction` | the protocol a node implements |
| `NodeFunctionDescriptor`, input-port cases | how a node declares its ports |
| `ProcessInput`, `ProcessOutput` | what `process` receives and returns |
| `NodeValue`, `NoValueReason` | already public |
| `DataObjectStore`, `DataToken`, `intern`/`resolve` | content-addressed storage; no graph knowledge |
| `FileNameAndContent` | |
| `ToolExecutor`, `ToolDescriptor`, `ToolExecutorRegistry`, `ToolOutput` | running an external tool |
| `FileMetadata`, `FileMetadataProvider` | |
| `Path` | |
| `NodeError` | |
| `PolyFactory`, `PolySerializable` | kind-tagged serialisation |
| `FolderManifest`, `FolderManifestEntry` | **currently inside `Folder.swift`** — a wire data format, not a node |
| the `input:` / `output:` name constants | **currently `Folder.inputFileSystemName`** — filesystem vocabulary, not Folder's internals |

The last two are the only genuine surprises: both are shared vocabulary that happens to
live inside a Core node today.

### Stays in SemelCore

`BuildEngine` and the process loop, the cache, `GraphShape*`, `Wire`, `NodeSupport`'s graph
access, `DatabaseLayer` wiring, and the engine's own nodes — `Folder`, `StaticFile`,
`OutputFile`, `ProjectBuilder`, `ProjectFinder`, `Configuration`, `ProductPresence`.

The cache hooks are an extension on `NodeFunction`; since the protocol moves to NodeKit,
the extension can stay in Core. Node authors never call them.

## Two seams to open

**Type registration.** `BuildEngine.registerTypes()` is a hardcoded list naming all nine
toolchain types. It becomes a public registration call, and each package exposes its own
`registerNodeTypes()` for the composition root to invoke.

**Project discovery.** `ProjectFinder` holds `private let projectBuilderPlugins` containing
`SwiftPackagePlugin`, which knows what `Package.swift` is and emits a `SwiftFormulaConverter`
expectation. That is toolchain knowledge inside the engine; it becomes a registry that
`SemelSwift` contributes to.

## Kind IDs need an allocation rule

`kind: UInt` is a single global numbering, and once types live in separate packages two of
them can claim the same number. `PolyFactory` already detects this —
`duplicateKind(kind:existing:duplicate:)` — but detecting a clash at launch is not the same
as preventing one.

Existing IDs must not change: `kind` is stored on every node row, so renumbering orphans
every existing database. Reserve forward instead:

```
0–99      SemelCore and SemelNodeKit   (currently 1, 3, 4, 6, 8)
100–199   SemelSwift                   (currently 20, 21, 23, 24 — left where they are)
200–299   SemelClang                   (currently in the same range — left where they are)
1000+     third-party packages
```

The existing numbers stay put and sit outside their nominal range. That is ugly and it is
still right: correctness of live databases beats tidiness of a table.

## Phasing

Each step keeps both suites green, and none is a point of no return.

1. **Create `SemelNodeKit`**, move the API types, make them public. `SemelCore` depends on
   it. Mechanical, no behaviour change, and the largest single step.
2. **Open the two seams.** Core stops hardcoding the type list and the discovery plugins.
3. **Move the Swift nodes** to `SemelSwift`, with their tests.
4. **Move the Clang nodes** to `SemelClang`, with their tests.
5. **Rename** `BuildSystemCore` → `SemelCore`, `DatabaseModels` → `SemelDatabaseModels`,
   when they are next being touched anyway.

## What proves it worked

`SemelCore` compiles with no reference to any Swift or Clang type, and its test suite
passes without those packages present. Anything less is discipline; that is a compiler
guarantee.

A second, softer test: adding a hypothetical third toolchain should require no change to
`SemelCore` at all — not a registration line, not a plugin entry.

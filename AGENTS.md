# Working on this repository

A graph-based incremental build engine — see README.md for what it does. This file is
about how to change it.

## Build and test

```sh
swift build                                  # builds everything the root package links, from the repo root
swift test --package-path SemelNodeKit       # the node-authoring API (~124)
swift test --package-path SemelProtocol      # the wire protocol (frame codec + messages) (~44)
swift test --package-path SemelSwift         # the Swift toolchain nodes (~135)
swift test --package-path SemelClang         # the C/C++ toolchain nodes (~44)
swift test --package-path SemelApple         # the Apple platform nodes: asset and string catalogs, Info.plist (~13)
swift test --package-path SemelCore    # the engine tests (~350)
swift test                                   # the CLI, transport, server and end-to-end fixture tests (~183)
SEMEL_E2E_EXTERNAL=1 swift test --filter SemelEndToEndTests   # plus the pinned external projects (minutes; needs the network)
```

The root package now links `SemelProtocol` through `SemelCLI` and `SemelServer`, so
`swift build` covers it; its own `swift test --package-path SemelProtocol` line is still
the only thing that runs its tests.

`swift test` at the root runs **only** the root package's test targets: `SemelCLITests`,
`SemelTransportTests`, `SemelServerTests` and `SemelEndToEndTests`. The engine and the
toolchains live in separate packages, so a green root-level run means almost nothing. Run
all seven.

**A toolchain package must not depend on the engine.** `SemelSwift` sees only
`SemelNodeKit`, which is what stops the engine acquiring knowledge of Swift by accident. If
you find yourself wanting to import `SemelCore` from a toolchain package, something
belongs in `SemelNodeKit` instead — that is how `FolderManifest`, the `input:`/`output:`
names and the configuration text format ended up there.

Nothing registers a toolchain automatically. `semel-server/main.swift` is the composition
root: it registers the toolchains, starts the engine and listens on
`SemelPaths.serverSocket`. `semel/main.swift` opens a socket to it and nothing else; start
`semelserv` first, or `semel` says so and exits. Tests point both at a temporary directory
with `SEMEL_HOME` and `SEMEL_SOCKET`.

`EndToEnd/Tests` is the one place the three executables are run together, as a user
runs them: `EndToEndRun` starts `semelserv` over a fresh home, drives `semel` and
`semel-swift` against it, and builds each project twice to compare the bytes.

A test that needs a node type but does not care which should use `SampleTool` from
`SampleNodes.swift` rather than reaching for a real toolchain node — that habit is what
tied the engine's cache and factory tests to Clang.

In Xcode, open **`Semel.xcworkspace`**, not the package. Opening `Package.swift` makes
`SemelCore` and `SemelDatabaseModels` read-only *dependencies*, and Xcode neither builds
nor lists the test targets of a dependency package — which is why the engine's tests could
not be run from the root package. The workspace holds all three as peers, so each gets its
own scheme and its own runnable tests. Run the `semelserv` scheme before the `semel`
scheme, or the client has no server to connect to.

## Naming of modules

Modules are `Semel`-prefixed. The old `BuildSystem` prefix is gone from every module name
and from the code entirely.

Two things still carry the old vocabulary and are a deliberate leftover: the root package
is named `semel` and the CLI's sources live in `semel/`. Renaming those
changes the repository's layout and the C1 fixtures that reference those paths, so it is a
wider job than a module rename.

Two words are taken and must not be reused for anything else. **Plugin** means a
`CommandPlugin` (a CLI verb) or a `ProjectBuilderPlugin` (project discovery). **Toolchain**
means tool discovery and versioning — `ToolDiscovery`, `ToolDescriptor`, and each package's
own `…ToolDiscovery` finders — not a set of node functions.

## Formatting

- Four spaces, never tabs.
- Opening brace on the same line as the declaration. There is not one Allman-style brace
  in the codebase; do not introduce the first.
- Do not chain if statements as in `else if`. Put the new if into curly braces or prefer a switch statement when possible.
- Code comments: one space after a period (.). US-English spelling.
- Align related things into columns when it aids reading — assignments in a group,
  argument labels in a multi-line call:

```swift
let fromNode = nodeByID[wire.fromNodeID]?.name ?? "?"
let toNode   = nodeByID[wire.toNodeID]?.name   ?? "?"

_ = try? database.wire.delete(comingFromNodeID: wire.fromNodeID,
                              fromSymbolID:    wire.fromSymbolID,
                              goingToNodeID:   wire.toNodeID,
                              toSymbolID:      wire.toSymbolID)
```

- `// MARK: -` to separate sections in any file long enough to need navigating.

## Naming

- **No single-character names** — not for variables, parameters, bindings, or loop
  counters. `let currentNode`, not `let n`. `for wire in wires`, not `for w in wires`.
  A few older places still break this — `FormulaParser` (`let c`, `let s`, `var i`),
  `ProjectBuilder`'s wildcard matcher (`let p`, `let t`), `NodeDescriptor`'s pattern bindings
  (`let n`). They are legacy, not licence; do not copy them, and tidy them if you are
  editing that code anyway.
- Spell words out. `nodeFunction`, `inputPortSpec`, `existingWiresByName` — not `nf`,
  `ips`, `ewbn`.
- `$0` in a short closure is fine. A closure long enough to want a name should have one.
- Node types that convert input to output are named as agents ending in "-er":
  `SwiftCompiler`, `ConfigFilter`, `ProjectBuilder`. No `Tool` suffix on the tool nodes —
  "tool" is the binary a node runs, not the node. `StaticFile`, `OutputFile` and
  `Configuration` are the deliberate exception: they convert nothing, they just *are*.
- Locals are named after their type in camelCase — a `NodeRecord` is `nodeRecord`, a `Node`
  is `node` — except where a name says *which* one (`toNode`, `fromNode`, `child`,
  `consumer`, `folder`), which is the divergence worth keeping. A `GraphSpecNode` local is
  `specNode`, never `graphSpec`: that name is the stored string on `NodeRecord`.
- Renaming costs more than the compiler shows. It verifies every type site and catches
  almost nothing else; the damage lands in prose and in compound identifiers. Comments have
  gone wrong three ways — concept read as type, SQL identifier read as a Swift path, grammar
  notation read as a type reference — and a substring match once turned `fromNodeFunction`
  into `fromNode`, colliding with a variable already named that. Inside a quoted string,
  prose must be left alone while `\(interpolations)` must be renamed, so no single rule gets
  both right. Budget a reading pass, not a sweep.

## Glossary

Semel borrows few names from other build systems on purpose: a borrowed name imports its
home semantics, and false familiarity is worse than unfamiliarity. Each term below gives
the nearest standard equivalent and how Semel's differs.

| Semel term | Nearest equivalent | How it differs |
|---|---|---|
| node | Bazel action, Nix derivation | Resident and reactive: it lives in the graph database and re-runs when a wire changes, rather than being re-derived each build. Not hermetic by construction (B-03). |
| wire | dependency edge | Named, typed by port, and carries a value (a content hash). Rewiring is how the graph changes; a push wakes a wire. |
| port | input/output declaration | Static ports are fixed by the node type; dynamic ports hold N named wires the node itself demands at process time. |
| spec (`GraphSpec`) | Nix derivation expression | A node's demand for an upstream subgraph, rendered as text: `Folder(path: 'input:/src').manifest`. Returned on `inputWireSpecs`; the engine finds or creates matching nodes. Nothing is evaluated — the spec is matched against the resident graph. |
| graphSpec (column) | — | The node's rendered `GraphSpec`, stored for matching; the same string a spec on an input port demands. Type names are embedded in it, so renaming a node type invalidates every stored one (bump `Semel.version`, B-29). |
| formula (`.fmla`) | BUILD file, Makefile | Declares products as expressions of nodes, functionally — no ordering, no commands. Also what a `Package.swift` is converted into. |
| product | Bazel target output | A published artifact: a formula product becomes an `OutputFile` in `output:`. Intermediates are not products (B-10). A product named with a trailing `/` is a *tree product*: every entry of the tree on its expression's port becomes an `OutputFile` under that folder (B-63). |
| tree (`TreeManifest`) | Bazel TreeArtifact, a directory output | N files on one port: a manifest of relative paths with content hashes and modes, interned like any value. A tool that decides its own file set (`actool`) fills one through `expectedOutputFolders`; `TreeFile(name:, tree:)` puts one entry back on a port of its own; `TreeMerger` makes several trees one, a collision being an error. |
| pinned | GC root | "Held alive by user intent rather than by references": a pushed file or folder. Unpinned nodes exist only while something depends on them. Not memory pinning. |
| `Folder`, `StaticFile`, `OutputFile`, `Configuration` | source file, output file | Nodes that *are* rather than convert (the "-er" exception). `StaticFile` and `Folder` are filled by the push path, not by wires (B-43). |
| cache entry | remote cache / action cache entry | Keyed on node type, properties and every input wire's name *and* value — the path is part of the key because tools embed it (B-49). Holds object-store hashes, not bytes. |
| tool vs node | — | A tool is a binary (`swiftc`) with a `ToolDescriptor`; a node (`SwiftCompiler`) is the graph step that runs it in a sandbox. Config namespaces name nodes (`swift.compiler`), and `toolDescriptor.*` under them names the tool. |
| config namespace | — | The dot-prefix a node's settings live under in `semel.config`, derived from the type name; a `ConfigFilter` selects it. No defaults, no inheritance. |

## Comments

- When a bug fix is made, keep code comments short and clear, or omit them entirely if the new code 
  is unlikely to make the reader wonder why it was done that way. Do not explain the history of the 
  bug (e.g. "before this change, this line...") 
- A brief background for why a bug was fixed can be included in the commit message if needed, 
  that's why history is not needed in code comments

- `///` doc comments on anything non-obvious, explaining **why**, not what. The code says
  what. Roughly a third of the comments here are doc comments and they carry the design
  reasoning — match that density.
- Where a decision looks wrong at first glance, say why it is right. The best comments in
  this codebase are the ones explaining what was tried and why it failed.
- `TODO:` / `BUG:` / `ISSUE:` for known gaps. Do not silently leave a gap unmarked.

## Maintaining backwards compatibility

- This software is not yet public. (Once it is, this rule will be removed.) This means 
  file formats and database schemas do NOT need to be migrated by the code, nor does it 
  need to tolerate or convert old formats; we can just break the format completely. 
  It is very important to keep database and serialization code clean and not have to 
  deal with old files.

## Types and errors

- `struct` unless reference semantics are genuinely needed — the ratio is about 60:8.
- `internal` by default. `public` only where another module really needs it.
- `guard` and early return over nested `if`. There are ~139 guards here; deep nesting is
  not the house style.
- Errors are enums with associated values carrying enough context to act on. An error
  that only says something failed is not finished.

## Invariants that are easy to break

These cost real debugging to learn. Violating one usually compiles fine.

**Static topology is node identity.** A node's `graphSpec` is written once at creation and
never recomputed. That is correct: static wiring and args are immutable, so different
static wiring means a *different node*, not the same node with a new key. Only `.dynamic`
ports are rewired after creation, and they are deliberately excluded from the spec. Never
rewire a static port, and never add a recompute pass.

**A formula can wire only a static port.** `.required` and `.optional` ports are named in
a graph spec and so in a formula; `.dynamic` ports hold wires the node itself demands at
process time and cannot be wired from outside. A port that a *generated* formula has to
fill — `ClangPreprocessor.headerFolders` — is therefore `.optional`, not `.dynamic`, even
though it holds N named wires; a port the node fills for itself from its own specs —
`SwiftFormulaConverter`'s package ports, wired from `path` — is `.dynamic`. Getting this
wrong fails at the first real formula with "port does not exist", not in any unit test.

**The cache key must cover everything that can change a node's output.** Including input
*identity*, not just input content — the wire key is the file's path and the tools embed
it. If you add anything that influences output, it belongs in the key.

**Never iterate a `Dictionary` into a command line.** Swift's iteration order is seeded per
process, so the same build would produce a different invocation each run. Sort first.
`ProjectBuilder` and `SwiftFormulaConverter` iterate dictionaries safely because they
accumulate into dictionaries; anything ordered must be sorted.

**Distinguish unrecoverable failures from node failures.** A failed compile belongs to one
node. A store that cannot be written belongs to the machine — conform it to
`UnrecoverableError` and it stops the build instead of being filed against whichever node
happened to hit it first.

**Force unwraps are being phased out.** `try!` is at zero; keep it there. Use
`node.requireID()` rather than `node.id!`. A force unwrap is only acceptable where failure
is genuinely impossible, and then it wants a comment saying why.

## Deliberate choices — do not "fix" these

- **Process-global singletons** (`DatabaseLayer.shared`, `BuildEngine.shared`,
  `DataObjectStore.shared`, `ToolRunnerRegistry.instance`, the symbol cache). Threading
  these through every `intern()` and every node function would cost far more plumbing than
  it saves. They are *swappable* instead, which is what makes them testable.
- **Tool versions come from the machine, not from a pinned list.** Each toolchain package
  declares, when it registers, how its tools are located (`xcrun --find`) and how each
  reports its version; `ToolDiscovery` registers what is found under that version. A node
  pinned to a version that is no longer installed is expected to fail when processed, with
  a message naming what is available. Do not add launch-time warnings about this.

## Tests

- Every test class inherits `SemelCoreTestCase`, which isolates the process-globals per
  test. If you override `setUpWithError`, call `super` first.
- Name tests `test_whatItDoes` — snake after the prefix, describing behaviour not method
  names. That is the dominant convention (~242 to 64).
- Prefer a real in-memory `DatabaseLayer()` over a mock. The only boundaries worth faking
  are process execution (`RecordingToolRunner`) and the object store.
- Never let a test write to the user's real object store. `TestGlobals.isolate()` handles
  this; do not bypass it.
- When adding a regression test for a bug already fixed, verify it actually fails against
  the pre-fix code. A test written after the fix that passes immediately has proved
  nothing.

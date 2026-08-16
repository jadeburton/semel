# Working on this repository

A graph-based incremental build engine — see README.md for what it does. This file is
about how to change it.

## Build and test

```sh
swift build                                  # builds everything, from the repo root
swift test --package-path SemelNodeKit       # the node-authoring API (~68)
swift test --package-path SemelSwift         # the Swift toolchain nodes (~62)
swift test --package-path SemelClang         # the C/C++ toolchain nodes (~27)
swift test --package-path SemelCore    # the engine tests (~247)
swift test                                   # the CLI tests only (~8)
```

`swift test` at the root runs **only** the `SemelCLI` tests. The engine and the
toolchains live in separate packages, so a green root-level run means almost nothing. Run
all five.

**A toolchain package must not depend on the engine.** `SemelSwift` sees only
`SemelNodeKit`, which is what stops the engine acquiring knowledge of Swift by accident. If
you find yourself wanting to import `SemelCore` from a toolchain package, something
belongs in `SemelNodeKit` instead — that is how `FolderManifest`, the `input:`/`output:`
names and the configuration text format ended up there.

Nothing registers a toolchain automatically. `semel`'s `main.swift` is the composition
root: it calls `SemelSwift.register()` and `SemelClang.register()`, and a binary that did
not would simply have no idea what a `Package.swift` is or how to compile a `.c` file.

A test that needs a node type but does not care which should use `SampleTool` from
`SampleNodes.swift` rather than reaching for a real toolchain node — that habit is what
tied the engine's cache and factory tests to Clang.

In Xcode, open **`Semel.xcworkspace`**, not the package. Opening `Package.swift` makes
`SemelCore` and `SemelDatabaseModels` read-only *dependencies*, and Xcode neither builds
nor lists the test targets of a dependency package — which is why the engine's tests could
not be run from the root package. The workspace holds all three as peers, so each gets its
own scheme and its own runnable tests.

## Naming of modules

Modules are `Semel`-prefixed. The old `BuildSystem` prefix is gone from every module name
and from the code entirely.

Two things still carry the old vocabulary and are a deliberate leftover: the root package
is named `build_system` and the CLI's sources live in `build_system/`. Renaming those
changes the repository's layout and the C1 fixtures that reference those paths, so it is a
wider job than a module rename.

Two words are taken and must not be reused for anything else. **Plugin** means a
`CommandPlugin` (a CLI verb) or a `ProjectBuilderPlugin` (project discovery). **Toolchain**
means tool discovery and versioning — `Toolchain.swift`, `ToolDescriptor` — not a set of
node functions.

## Formatting

- Four spaces, never tabs.
- Opening brace on the same line as the declaration. There is not one Allman-style brace
  in the codebase; do not introduce the first.
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
  `ProjectBuilder`'s glob matcher (`let p`, `let t`), `NodeDescriptor`'s pattern bindings
  (`let n`). They are legacy, not licence; do not copy them, and tidy them if you are
  editing that code anyway.
- Spell words out. `nodeFunction`, `inputPortSpec`, `existingWiresByName` — not `nf`,
  `ips`, `ewbn`.
- `$0` in a short closure is fine. A closure long enough to want a name should have one.

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

**Static topology is node identity.** A node's `searchKey` is written once at creation and
never recomputed. That is correct: static wiring and args are immutable, so different
static wiring means a *different node*, not the same node with a new key. Only `.dynamic`
ports are rewired after creation, and they are deliberately excluded from the shape. Never
rewire a static port, and never add a recompute pass.

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
  `DataObjectStore.shared`, `ToolExecutorRegistry.instance`, the symbol cache). Threading
  these through every `intern()` and every node function would cost far more plumbing than
  it saves. They are *swappable* instead, which is what makes them testable.
- **Tool versions come from the machine, not from a pinned list.** `DefaultTools` locates
  each tool with `xcrun --find` and registers it under the version it reports. A node
  pinned to a version that is no longer installed is expected to fail when processed, with
  a message naming what is available. Do not add launch-time warnings about this.

## Tests

- Every test class inherits `SemelCoreTestCase`, which isolates the process-globals per
  test. If you override `setUpWithError`, call `super` first.
- Name tests `test_whatItDoes` — snake after the prefix, describing behaviour not method
  names. That is the dominant convention (~242 to 64).
- Prefer a real in-memory `DatabaseLayer()` over a mock. The only boundaries worth faking
  are process execution (`RecordingToolExecutor`) and the object store.
- Never let a test write to the user's real object store. `TestGlobals.isolate()` handles
  this; do not bypass it.
- When adding a regression test for a bug already fixed, verify it actually fails against
  the pre-fix code. A test written after the fix that passes immediately has proved
  nothing.

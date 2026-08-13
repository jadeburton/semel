# Working on this repository

A graph-based incremental build engine — see README.md for what it does. This file is
about how to change it.

## Build and test

```sh
swift build                                  # builds everything, from the repo root
swift test --package-path BuildSystemCore    # the engine tests (~298)
swift test                                   # the CLI tests only (~8)
```

`swift test` at the root runs **only** the `BuildSystemCLI` tests. The engine lives in a
separate package, so a green root-level run means almost nothing. Run both.

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

- `///` doc comments on anything non-obvious, explaining **why**, not what. The code says
  what. Roughly a third of the comments here are doc comments and they carry the design
  reasoning — match that density.
- Where a decision looks wrong at first glance, say why it is right. The best comments in
  this codebase are the ones explaining what was tried and why it failed.
- `TODO:` / `BUG:` / `ISSUE:` for known gaps. Do not silently leave a gap unmarked.

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

- Every test class inherits `BuildSystemTestCase`, which isolates the process-globals per
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

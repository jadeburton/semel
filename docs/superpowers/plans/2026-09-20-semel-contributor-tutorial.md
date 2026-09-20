# Contributor Tutorial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A first tutorial for contributors — build the C fixture, watch the cache, write a node — with the finished node in the repository and an end-to-end fixture that fails when the tutorial stops being true.

**Architecture:** A new package `SemelExamples` beside `SemelApple` holds `LineCounter`, a pure node (no tool) that turns N named input wires into `name: count` lines. `semelserv` registers it like the toolchains. `EndToEnd/Fixtures/tutorial` is the state the tutorial ends in and joins the fixture roster. The tutorial itself is one Markdown file, walked through by hand against the built binaries so every output block in it is real.

**Tech Stack:** Swift 5.9, SwiftPM local packages, XCTest, the existing `SemelEndToEndTests` harness.

**Spec:** `docs/superpowers/specs/2026-09-18-semel-contributor-tutorial-design.md` — read it first; this plan argues from it.

## Global Constraints

- Work in a `.claude` worktree branched from `docs/contributor-tutorial` (it carries the spec); finish by PR to `Build-system`.
- `SemelExamples` depends on `SemelNodeKit` and `SemelDatabaseModels` only — never on `SemelCore` (AGENTS.md: a toolchain package must not depend on the engine).
- `LineCounter.kind` is `36`. Before using it, run `grep -rhn "let kind: UInt = " Semel*/Sources | sed 's/.*= //' | sort -n | tail -1` and confirm the answer is `35`; if it is higher, use the next number and substitute it everywhere below.
- The word *plugin* is never used for a node module (AGENTS.md reserves it for `CommandPlugin` and `ProjectBuilderPlugin`).
- Code comments are timeless statements: no "now", "today", "no longer", "after the split". Documents may narrate.
- Tests are named `test_whatItDoes`, describing behaviour.
- `swiftlint --strict` passes before every push.
- File headers follow the repository's: `//`, `//  Name.swift`, `//  Module`, `//`, then what the file is for.

## File map

| File | Responsibility |
|---|---|
| `SemelExamples/Package.swift` | The package; mirrors `SemelApple/Package.swift` |
| `SemelExamples/Sources/SemelExamples/LineCounter.swift` | The node |
| `SemelExamples/Sources/SemelExamples/SemelExamples.swift` | `register()` |
| `SemelExamples/Tests/TestSupport.swift` | `SemelExamplesTestCase`: isolates the object store |
| `SemelExamples/Tests/LineCounterTests.swift` | Unit tests |
| `Package.swift`, `semel-server/main.swift` | Link and register the package |
| `EndToEnd/Fixtures/tutorial/{hello.fmla,src/*}` | The tutorial's end state |
| `EndToEnd/Tests/Projects.swift`, `FixtureTests.swift` | Roster entry and its test |
| `.github/workflows/swift.yml`, `Semel.xcworkspace/contents.xcworkspacedata`, `AGENTS.md`, `README.md` | The new package everywhere packages are listed; choosing a `kind`; keeping the tutorial current |
| `docs/tutorial/first-node.md` | The tutorial |

---

### Task 1: The `SemelExamples` package and `LineCounter`

**Files:**
- Create: `SemelExamples/Package.swift`
- Create: `SemelExamples/Sources/SemelExamples/LineCounter.swift`
- Create: `SemelExamples/Sources/SemelExamples/SemelExamples.swift`
- Create: `SemelExamples/Tests/TestSupport.swift`
- Test: `SemelExamples/Tests/LineCounterTests.swift`

**Interfaces:**
- Consumes: `SemelNodeKit` — `Node`, `NodeDescriptor(inputPorts:outputPorts:)`, `ProcessInput.inputValues: [String: [String: NodeValue]]`, `ProcessOutput(outputValues:inputWireSpecs:)`, `NodeValue.expectValue() throws -> DataObjectHash`, `DataObjectHash.resolveAsString()`, `String.intern()`, `TypeRegistry.register(types:)`, `DataObjectStore.shared`. `SemelDatabaseModels` — `NodeRecord(id:kind:properties:)`.
- Produces: `public struct LineCounter: Node` with `static let kind: UInt = 36`, `static let inputPort = "input"`, `static let outputPort = "output"`; `public enum SemelExamples { public static func register() throws }`. Output format: one `name: count` line per input wire, sorted by wire name, joined by `\n`, no trailing newline.

- [ ] **Step 1: Write the package manifest**

`SemelExamples/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

// Nodes that exist to be read: the reference copies of what docs/tutorial builds by hand.
//
// Depends on SemelNodeKit and *not* on the engine, like the toolchain packages: a node
// author sees the node-authoring API and nothing else. Nothing a real build depends on
// belongs here.
let package = Package(
    name: "SemelExamples",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelExamples", targets: ["SemelExamples"]),
    ],
    dependencies: [
        .package(path: "../SemelNodeKit"),
        .package(path: "../SemelDatabaseModels"),
    ],
    targets: [
        .target(
            name: "SemelExamples",
            dependencies: [
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelDatabaseModels", package: "SemelDatabaseModels"),
            ],
            path: "Sources/SemelExamples"
        ),
        .testTarget(
            name: "SemelExamplesTests",
            dependencies: ["SemelExamples"],
            path: "Tests"
        ),
    ]
)
```

- [ ] **Step 2: Write the test support and the failing tests**

`SemelExamples/Tests/TestSupport.swift`:

```swift
//
//  TestSupport.swift
//  SemelExamplesTests
//
//  The same isolation the toolchain packages' tests use: a package that only needs the
//  node-authoring API swaps the process-globals a node can reach, and nothing more.
//

@testable import SemelExamples
import Foundation
import SemelNodeKit
import XCTest

/// Base class for every test here: no test writes to the user's object store.
class SemelExamplesTestCase: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: Self.temporaryStoreRoot())
        try SemelExamples.register()
    }

    private static func temporaryStoreRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-examples-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
```

`SemelExamples/Tests/LineCounterTests.swift`:

```swift
//
//  LineCounterTests.swift
//  SemelExamplesTests
//
//  One line of output per input wire. Each wire's line depends on that wire alone, which is
//  what lets the tutorial show an edit to one file changing one line of the product.
//

@testable import SemelExamples
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class LineCounterTests: SemelExamplesTestCase {

    private func count(_ wires: [String: NodeValue]) throws -> String {
        let node = try LineCounter(thisNode: NodeRecord(id: 1, kind: LineCounter.kind, properties: [:]))
        let output = try node.process(input: ProcessInput(inputValues: [LineCounter.inputPort: wires]))
        return try XCTUnwrap(output.outputValues[LineCounter.outputPort]).expectValue().resolveAsString()
    }

    func test_writesOneLinePerWireSortedByName() throws {
        let result = try count([
            "main.c": .value(try "a\nb\nc\n".intern()),
            "hello.c": .value(try "x\n".intern()),
        ])

        XCTAssertEqual(result, "hello.c: 1\nmain.c: 3")
    }

    /// A last line without a newline is still a line; an empty file has none.
    func test_countsAnUnterminatedLastLineAndNothingInAnEmptyFile() throws {
        let result = try count([
            "empty": .value(try "".intern()),
            "unterminated": .value(try "a\nb".intern()),
        ])

        XCTAssertEqual(result, "empty: 0\nunterminated: 2")
    }

    /// A count that silently omitted a file would be wrong, so an input without a value
    /// fails the node rather than being skipped.
    func test_aWireWithoutAValueFailsRatherThanBeingLeftOut() throws {
        XCTAssertThrowsError(try count([
            "hello.c": .value(try "x\n".intern()),
            "main.c": .noValue(reason: .pending),
        ]))
        XCTAssertThrowsError(try count([
            "hello.c": .value(try "x\n".intern()),
            "main.c": .noValue(reason: .error(messageDataObjectHash: try "did not compile".intern())),
        ]))
    }

    func test_noWiresIsAnEmptyOutputNotAnError() throws {
        XCTAssertEqual(try count([:]), "")
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `swift test --package-path SemelExamples`
Expected: a compile failure — `cannot find 'LineCounter' in scope`, `cannot find 'SemelExamples' in scope`.

- [ ] **Step 4: Write the node and `register()`**

`SemelExamples/Sources/SemelExamples/LineCounter.swift`:

```swift
//
//  LineCounter.swift
//  SemelExamples
//
//  Counts the lines of whatever is wired to it: one `name: count` line per input wire.
//
//  The smallest node that is still worth caching, and the reference copy of the one
//  docs/tutorial/first-node.md builds by hand. It runs no tool and reads no configuration,
//  so everything a node must have is here and nothing else is.
//
//  The names are the wire names, which the formula chooses. The node never sees a path
//  unless the formula hands it one as a name.

import SemelDatabaseModels
import SemelNodeKit

public struct LineCounter: Node {
    public static let kind: UInt = 36

    static let inputPort = "input"
    static let outputPort = "output"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(inputPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let wires = input.inputValues[Self.inputPort] ?? [:]

        // Sorted, because a dictionary's order differs from one process to the next and the
        // output is a value other nodes and the cache compare byte for byte.
        //
        // `expectValue()` throws on a wire that is pending or in error. A count that left a
        // file out would be a wrong answer that looks like a right one, so there is no
        // skipping here.
        var lines: [String] = []
        for name in wires.keys.sorted() {
            let text = try wires[name]!.expectValue().resolveAsString()
            lines.append("\(name): \(Self.lineCount(of: text))")
        }

        return .init(outputValues: [Self.outputPort: .value(try lines.joined(separator: "\n").intern())],
                     inputWireSpecs: [:])
    }

    /// Newline-terminated lines, plus a last line that has no newline.
    static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let newlines = text.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        return text.hasSuffix("\n") ? newlines : newlines + 1
    }
}
```

`SemelExamples/Sources/SemelExamples/SemelExamples.swift`:

```swift
//
//  SemelExamples.swift
//  SemelExamples
//
//  Nodes that exist to be read. A host that wants them calls `register()`; the engine
//  itself knows nothing of them.

import SemelNodeKit

public enum SemelExamples {

    /// Installs the example node types. No tools and no config namespaces: nothing here
    /// runs a tool.
    ///
    /// Idempotent, because a host may call it more than once and every test calls it again.
    public static func register() throws {
        try TypeRegistry.register(types: [
            LineCounter.self,
        ])
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `swift test --package-path SemelExamples`
Expected: `Executed 4 tests, with 0 failures`.

If `NodeRecord(id:kind:properties:)` does not compile, use the full initialiser the Apple tests use: `NodeRecord(id: 1, kind: LineCounter.kind, name: nil, properties: [:], scheduled: false, graphSpec: nil)`.

- [ ] **Step 6: Lint and commit**

Run: `swiftlint --strict`
Expected: no findings.

```bash
git add SemelExamples
git commit -m "SemelExamples: LineCounter, a pure node that counts the lines of what is wired to it"
```

---

### Task 2: Registered by the server, proven by a fixture

**Files:**
- Modify: `Package.swift` (the `dependencies:` list near line 25; the `semel-server` target's dependencies near line 102)
- Modify: `semel-server/main.swift:1-20` (imports) and `:68-70` (registration)
- Create: `EndToEnd/Fixtures/tutorial/hello.fmla`
- Create: `EndToEnd/Fixtures/tutorial/src/` (copies of `EndToEnd/Fixtures/c/src/*`)
- Modify: `EndToEnd/Tests/Projects.swift`
- Test: `EndToEnd/Tests/FixtureTests.swift`

**Interfaces:**
- Consumes: `SemelExamples.register()`, the formula type name `LineCounter` with input port `input` and output port `output` (Task 1).
- Produces: `Projects.tutorial` (name `"tutorial"`), a member of `Projects.fixtures`; the fixture folder `EndToEnd/Fixtures/tutorial`, which Task 4's document names as its end state.

- [ ] **Step 1: Write the failing end-to-end test**

In `EndToEnd/Tests/Projects.swift`, after `cHello`:

```swift
    /// The state docs/tutorial/first-node.md ends in: the C hello sources, and a formula
    /// that also counts their lines with `LineCounter` from SemelExamples. Reads the
    /// shared base config from `../clang.cfg`, so that needs its own push, as for `cHello`.
    static let tutorial = Project(
        name: "tutorial",
        source: .fixture(folder: "."),
        buildFolder: "tutorial",
        alsoPush: ["clang.cfg"],
        platform: nil,
        expectedProducts: ["hello", "hello.dylib", "config.txt", "lines.txt"],
        buildTimeout: fixtureTimeout)
```

and change the roster line to:

```swift
    static let fixtures: [Project] = [cHello, tutorial, cppEmu6502, swiftMyApp, swiftHelloApp]
```

In `EndToEnd/Tests/FixtureTests.swift`, add after `test_cHello`:

```swift
    func test_tutorial() throws        { try build(Projects.tutorial) }
```

and add `"tutorial"` to the `tested` set in `test_everyFixtureInTheRosterHasATestHere`.

- [ ] **Step 2: Create the fixture**

```bash
mkdir -p EndToEnd/Fixtures/tutorial
cp -R EndToEnd/Fixtures/c/src EndToEnd/Fixtures/tutorial/src
cp EndToEnd/Fixtures/c/hello.fmla EndToEnd/Fixtures/tutorial/hello.fmla
```

Append to `EndToEnd/Fixtures/tutorial/hello.fmla`:

```

// One wire per source file, named by the formula: `%%f.0%%` is what the `*` matched, so
// the names are `hello.c`, not the path the tree happens to be mounted at — a path in the
// name would be a path in the product.
product "lines.txt" = LineCounter(input: [{f: <src/*.c>} "%%f.0%%.c": StaticFile(path: f)])
```

- [ ] **Step 3: Run the test to see it fail**

Run: `swift build && swift test --filter SemelEndToEndTests.FixtureTests/test_tutorial`
Expected: FAIL. The build reports an error naming `LineCounter` as an unknown type (the server has not registered it), and `lines.txt` is missing from the export.

- [ ] **Step 4: Link and register the package**

In `Package.swift`, add to the top-level `dependencies:` after the `SemelApple` line:

```swift
        .package(path: "SemelExamples"),
```

and to the `semel-server` executable target's dependencies after its `SemelApple` product line:

```swift
                .product(name: "SemelExamples", package: "SemelExamples"),
```

In `semel-server/main.swift`, add `import SemelExamples` beside the other toolchain imports, and register it after `SemelApple`:

```swift
    try SemelSwift.register()
    try SemelClang.register()
    try SemelApple.register()
    try SemelExamples.register()
    try BuildEngine.start()
```

The comment above that block says "toolchains"; `SemelExamples` is not one (AGENTS.md: *toolchain* means tool discovery). Change the comment's first sentence to: `// Composition root: the engine knows no node packages, so this is where the ones this binary ships are installed.`

- [ ] **Step 5: Run the test to see it pass, then check the product by eye**

Run: `swift build && SEMEL_E2E_KEEP=1 swift test --filter SemelEndToEndTests.FixtureTests/test_tutorial`
Expected: PASS — both cold builds succeed and the two export trees match byte for byte. That second half is the check that no mount path reached `lines.txt`.

Find the kept run under `/tmp/semel-tests` and read `lines.txt` in its export. Expected exactly:

```
hello.c: 14
hello2.c: 12
main.c: 16
```

If the names come out as anything else (a bare `hello`, a full path), the `%%f.0%%` capture is not what the comment says: read the header comment of `SemelCore/Sources/SemelCore/FormulaParser.swift` (lines 28–42), fix the key template and the comment in `hello.fmla` together, and rerun.

- [ ] **Step 6: Run the whole root suite**

Run: `swift test`
Expected: all pass, including `test_everyFixtureInTheRosterHasATestHere`.

- [ ] **Step 7: Lint and commit**

Run: `swiftlint --strict`

```bash
git add Package.swift Package.resolved semel-server/main.swift EndToEnd
git commit -m "Register SemelExamples in semelserv; the tutorial's end state joins the fixture roster"
```

(`Package.resolved` only if it changed.)

---

### Task 3: The new package wherever packages are listed; choosing a `kind`

**Files:**
- Modify: `.github/workflows/swift.yml` (after the `Test SemelApple` step, line ~36)
- Modify: `Semel.xcworkspace/contents.xcworkspacedata`
- Modify: `AGENTS.md` — "Build and test" (line ~6), "Naming" or a new section before "Glossary", and "Tests" (line ~222)
- Modify: `README.md:21` (Features), `:40` (Usage), `:248` (Architecture)

**Interfaces:**
- Consumes: the package name `SemelExamples`, `LineCounter`, kind `36` (Task 1); the path `docs/tutorial/first-node.md` (Task 4 creates it; linking first is fine, both land in one PR).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: CI**

In `.github/workflows/swift.yml`, after the `Test SemelApple` step:

```yaml
      - name: Test SemelExamples
        run: swift test --package-path SemelExamples
```

- [ ] **Step 2: The workspace**

In `Semel.xcworkspace/contents.xcworkspacedata`, before the `SemelCore` `FileRef`:

```xml
   <FileRef
      location = "group:SemelExamples">
   </FileRef>
```

(`SemelApple` is also absent from the workspace. That is not this plan's to fix; mention it in the PR description.)

- [ ] **Step 3: `AGENTS.md` — the test command**

In the "Build and test" code block, after the `SemelApple` line:

```
swift test --package-path SemelExamples      # the tutorial's reference node (~4)
```

and change the sentence "Run all seven." to "Run all eight."

- [ ] **Step 4: `AGENTS.md` — choosing a `kind`**

Add a section immediately before `## Glossary`:

```markdown
## Choosing a `kind`

Every polymorphic type — every node type, and `FolderManifest` and `TreeManifest` beside
them — carries a hand-assigned `static let kind: UInt`. It is how a stored row or a decoded
value finds its Swift type again, and it is one flat number space across every package.

A new type takes the next number above the highest in the repository:

    grep -rhn "let kind: UInt = " Semel*/Sources | sed 's/.*= //' | sort -n | tail -1

Never a gap in the sequence: a gap may be a removed type whose rows are still in
someone's database, and giving its number to something else would bring those rows back
as the wrong type. Never reused, for the same reason. `TypeRegistry.register` refuses two
different types claiming one number, so a collision between two branches fails at start-up
rather than at some later decode — renumber the newer one.
```

- [ ] **Step 5: `AGENTS.md` — keeping the tutorial true**

Add to the end of the `## Tests` list:

```markdown
- `docs/tutorial/first-node.md` shows real commands and real output. A change to a REPL
  command's name or to output the tutorial quotes updates the tutorial in the same commit;
  `EndToEnd/Fixtures/tutorial` catches the node, the formula and the registration, and
  nothing catches the prose.
```

- [ ] **Step 6: `README.md`**

Line 21, replace the Extensible bullet:

```markdown
- **Extensible** - Write your own Node types in a package of their own and put them into the graph — [the tutorial](docs/tutorial/first-node.md) does it in forty lines
```

Directly under the `## Usage` heading, before "Start the engine:":

```markdown
New here, and want to change Semel rather than only run it? Start with
[the tutorial](docs/tutorial/first-node.md): build something, watch the cache, write a node.
```

In the Architecture block, after the `SemelApple/` group and before `SemelDatabaseModels/`:

```
SemelExamples/   Nodes that exist to be read
  LineCounter            One `name: count` line per input wire — the tutorial's reference copy
```

- [ ] **Step 7: Verify and commit**

Run: `swift test --package-path SemelExamples` (the CI line, run locally) — Expected: 4 tests pass.
Run: `grep -n "plugin" README.md` — Expected: only the Architecture line about the CLI's *command plugins*.

```bash
git add .github/workflows/swift.yml Semel.xcworkspace AGENTS.md README.md
git commit -m "Docs and CI: SemelExamples wherever packages are listed; how to choose a kind"
```

---

### Task 4: The tutorial

This task is a walk-through, not a transcription. The text below is the draft; every
fenced block marked `OUTPUT` is filled with what the command actually printed, trimmed to
the lines that matter, and any sentence the real behaviour contradicts is corrected to match
the behaviour — then say so in the PR description. If a step cannot be made to work as
written, stop and report it: that is a finding about the product, not about the prose.

**Files:**
- Create: `docs/tutorial/first-node.md`

**Interfaces:**
- Consumes: built `semel` and `semelserv` (`swift build`), `EndToEnd/Fixtures/c`, `SemelExamples` with `LineCounter` registered (Tasks 1–2), the `AGENTS.md` glossary and the "Choosing a `kind`" section (Task 3).
- Produces: `docs/tutorial/first-node.md`, which README links to.

- [ ] **Step 1: Set up the walk-through so it cannot touch real state**

```bash
swift build
export SEMEL_HOME="$(mktemp -d)/home"
export SEMEL_SOCKET="$SEMEL_HOME/semel.sock"
WORK="$(mktemp -d)"
mkdir -p "$WORK/playground"
cp -R EndToEnd/Fixtures/c "$WORK/playground/hello"
```

Start `.build/debug/semelserv` in one terminal (background process) with those two
variables set; run `.build/debug/semel` commands non-interactively from another, one
command line per invocation, e.g. `.build/debug/semel "base $WORK/playground" 'tools'`.
The tutorial's *reader* uses the default home and the interactive prompt; the variables are
only for this walk-through and do not appear in the document.

- [ ] **Step 2: Write the document from this draft**

`docs/tutorial/first-node.md`:

````markdown
# Your first node

Half an hour, in four parts: build a small C program with Semel, watch what is and is not
redone when things change, write a node type of your own, and use it in a build.

This is for someone who wants to work on Semel. If you only want your Swift project built,
the README's [clone to build](../../README.md#dependencies-and-clone-to-build) is two
commands. Words in *italics* are defined in the [glossary](../../AGENTS.md#glossary); they
are introduced here where they first do something.

Last walked through at commit `COMMIT`.

## Part 1 — Build something

```sh
git clone <repo-url> && cd semel
swift build
```

Two executables matter. `semelserv` is the engine: it holds the graph and does the work.
`semel` is the prompt you type at. Start the server in one terminal and leave it running:

```sh
.build/debug/semelserv
```

You will build a copy of one of the test fixtures, so nothing you do dirties the checkout:

```sh
mkdir ~/semel-playground
cp -R EndToEnd/Fixtures/c ~/semel-playground/hello
```

In a second terminal, start the prompt and tell it where your files are:

```
.build/debug/semel
> base ~/semel-playground
```

### The config

Semel has no defaults. Every tool a build runs is named in a config file, down to its
version, because the version is part of what makes a cached result reusable. That makes the
file the most tedious part of a first build, so do not write it — ask:

```
> tools
```

```OUTPUT
(the clang.preprocessor, clang.compiler and clang.linker blocks)
```

Save the three `clang.*` blocks as `~/semel-playground/clang.cfg`. The tools need three
more facts that are yours to decide. Add, with your own SDK path from
`xcrun --sdk macosx --show-sdk-path`:

```
clang.preprocessor.sdkPath=/path/printed/by/xcrun
clang.preprocessor.target=arm64-apple-macos14.0
clang.preprocessor.cStandard=c17
clang.compiler.target=arm64-apple-macos14.0
clang.compiler.cStandard=c17
clang.linker.sdkPath=/path/printed/by/xcrun
clang.linker.target=arm64-apple-macos14.0
```

### The build

```
> push clang.cfg
> build hello --into ./out
```

```OUTPUT
```

```sh
./out/hello
```

```OUTPUT
```

`push` copied your files into Semel's own *input file system* — the engine never reads your
disk during a build, only what was pushed. `build` is `push`, wait until the graph settles,
report errors, and copy the products out.

### What you just ran

Open `~/semel-playground/hello/hello.fmla`. It is a *formula*: it says what the products
are, as expressions, and nothing about order or commands.

```
func preprocessor(path) = ClangPreprocessor(
  configuration: [config(prefix: 'clang.preprocessor')],
  input: [path: StaticFile(path: path)]
)
```

`ClangPreprocessor(...)` and `StaticFile(...)` are *nodes*. The names before the colons —
`configuration`, `input` — are the node's input *ports*, and each `name: expression` inside
the brackets is a *wire*: a named connection carrying a value from one node's output to
another's input. A `func` is only a way not to write the same expression twice.

```
product "hello" = make(dynamicLibrary: 'false', glob: <src/*.c>)
```

A *product* is an expression whose value is published. Everything else is intermediate and
stays inside. `make` expands the glob into one compile chain per file:

```
 src/hello.c  ─ StaticFile ─ ClangPreprocessor ─ ClangCompiler ─┐
 src/hello2.c ─ StaticFile ─ ClangPreprocessor ─ ClangCompiler ─┼─ ClangLinker ─ product "hello"
 src/main.c   ─ StaticFile ─ ClangPreprocessor ─ ClangCompiler ─┘
 clang.cfg ─ StaticFile ─ ConfigFilter('clang.compiler') ─ … into every compiler
```

The graph is not rebuilt from the formula each time. It lives in a database, and nodes
react when a wire's value changes. Look at it:

```
> ls -o hello
```

```OUTPUT
```

## Part 2 — Watch it not work

The point of Semel is the work it does not do. Four experiments.

**1. Build again.**

```
> build hello --into ./out
```

```OUTPUT
```

Nothing ran: no wire changed, so no node was scheduled.

**2. Change one file.** Edit `~/semel-playground/hello/src/hello2.c` — change the text it
prints — and build.

```OUTPUT
```

One preprocess–compile chain reran, then both links, because both products take that
object. `hello.c` and `main.c` were not touched.

**3. Put it back.** Undo the edit and build.

```OUTPUT
```

Nodes were scheduled — a wire did change — and every one of them was a cache hit. A *cache
entry* is keyed on the node's type, its properties and the name and content of everything
wired to it; time appears nowhere. Being *rescheduled* and being *recomputed* are
different things, and most of Semel's speed is the gap between them.

**4. Change a setting only the linker reads.** Add a line to `clang.cfg`:

```
clang.linker.exampleSettingNobodyReads=1
```

`push clang.cfg`, build.

```OUTPUT
```

The compilers were woken and hit cache: each reads its settings through a `ConfigFilter`
that passes on only `clang.compiler.*`, so what reached them was byte-identical. The header
comment of
[`ConfigFilter.swift`](../../SemelCore/Sources/SemelCore/Nodes/ConfigFilter.swift) tells
this story in full, and it is seventy-five lines — read it now; it is the shape of the node
you are about to write.

`errors` shows what is wrong when a build fails. `debug` dumps the whole graph; it is a
lot, and worth seeing once.

## Part 3 — Write a node

`MyLineCounter`: whatever files are wired to it, it outputs one `name: count` line per
wire. No tool, no configuration — everything a node must have, and nothing else.

A finished copy is in
[`SemelExamples/Sources/SemelExamples/LineCounter.swift`](../../SemelExamples/Sources/SemelExamples/LineCounter.swift).
Write your own beside it as `MyLineCounter.swift`; two types in one module cannot share a
name, and the name is yours to choose anyway.

```swift
import SemelDatabaseModels
import SemelNodeKit

public struct MyLineCounter: Node {
    public static let kind: UInt = 37
```

`kind` is how a node stored in the database finds its Swift type again. It is a number you
assign by hand: the next one above the highest in the repository
([how to find it](../../AGENTS.md#choosing-a-kind)). If `37` is taken by the time you read
this, take the next.

```swift
    static let inputPort = "input"
    static let outputPort = "output"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(inputPort)],
        outputPorts: [outputPort]
    )
```

`thisNode` is the database row; `thisNode.properties` holds whatever plain values the
formula passed (`dynamicLibrary: 'true'` in Part 1). The descriptor declares the ports. One
input port can hold any number of named wires.

```swift
    public func process(input: ProcessInput) throws -> ProcessOutput {
        let wires = input.inputValues[Self.inputPort] ?? [:]

        var lines: [String] = []
        for name in wires.keys.sorted() {
            let text = try wires[name]!.expectValue().resolveAsString()
            lines.append("\(name): \(Self.lineCount(of: text))")
        }

        return .init(outputValues: [Self.outputPort: .value(try lines.joined(separator: "\n").intern())],
                     inputWireSpecs: [:])
    }

    /// Newline-terminated lines, plus a last line that has no newline.
    static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let newlines = text.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        return text.hasSuffix("\n") ? newlines : newlines + 1
    }
}
```

Four things to notice.

- A wire's value is not the file. It is a *hash*; `resolveAsString()` fetches the content
  from the object store, and `intern()` stores your output and hands back its hash. Values
  travel as hashes so that "did this change?" is always a cheap comparison.
- `expectValue()` throws when a wire is pending or in error, which fails this node.
  `ConfigFilter` skips such wires instead, and says why. For a count, a silent omission
  would be a wrong answer that looks right.
- `sorted()`, because a dictionary's order changes from one process to the next and your
  output is compared byte for byte. Non-deterministic output is a cache that never hits.
- `process` is a pure function of its input. It may not read the disk, the clock or the
  environment. A node that must — a compiler reads an SDK — says so through
  `cacheKeyMaterial`; see [`Node.swift`](../../SemelNodeKit/Sources/SemelNodeKit/Node.swift).

Register it, in `SemelExamples.swift`:

```swift
        try TypeRegistry.register(types: [
            LineCounter.self,
            MyLineCounter.self,
        ])
```

Node types are linked into the server — there is no loading at run time — so rebuild and
restart it: stop `semelserv`, `swift build`, start it again. The graph is in the database;
it is still there when the server comes back.

## Part 4 — Use it

Add one line to `~/semel-playground/hello/hello.fmla`:

```
product "lines.txt" = MyLineCounter(input: [{f: <src/*.c>} "%%f.0%%.c": StaticFile(path: f)])
```

`{f: <src/*.c>}` makes one wire per matching file. The string before the colon is the wire's
name, and `%%f.0%%` is what the `*` matched — so the wires are named `hello.c`, `hello2.c`,
`main.c`. The formula chooses the names; your node only ever sees what it is handed.

```
> build hello --into ./out
```

```sh
cat out/lines.txt
```

```OUTPUT
hello.c: 14
hello2.c: 12
main.c: 16
```

Now the experiments from Part 2, on your own node:

- Add a line to `hello2.c`, build: one line of `lines.txt` changes. Your node reran, and so
  did that file's compile chain; nothing else.
- Undo it, build: your node was scheduled and hit cache. You wrote no caching code.
- Add `src/extra.c` with one function in it, build: a fourth line appears, and the formula
  did not change. The glob is a node too — a `Folder` — and its value changed.

## Where next

Each of these is the smallest real example of something this tutorial left out.

| To learn | Read |
|---|---|
| A node that runs a tool: `ToolRunner`, tool discovery, a config namespace | [`StringCatalogCompiler.swift`](../../SemelApple/Sources/SemelApple/StringCatalogCompiler.swift) (85 lines) and [`SemelApple.swift`](../../SemelApple/Sources/SemelApple/SemelApple.swift) |
| A node whose output is a tree of files | [`AssetCatalogCompiler.swift`](../../SemelApple/Sources/SemelApple/AssetCatalogCompiler.swift) |
| A node that asks for more inputs while it runs (`inputWireSpecs`) | [`ClangIncludeFinder.swift`](../../SemelClang/Sources/SemelClang/ClangIncludeFinder.swift) |
| A node that emits formula text | [`SwiftFormulaConverter.swift`](../../SemelSwift/Sources/SemelSwift/SwiftFormulaConverter.swift) — large; read `XcodeProjectConverter.swift` first |
| What must never break, and what looks wrong but is deliberate | [`AGENTS.md`](../../AGENTS.md) |
| What needs doing | [`BACKLOG.md`](../../BACKLOG.md) |
````

- [ ] **Step 3: Walk Part 1 and Part 2, filling every `OUTPUT` block**

Run each command in the document in order against the playground from Step 1 (`$WORK/playground` in place of `~/semel-playground`). For each `OUTPUT` block paste what was printed, trimmed to at most ~12 lines, with `$WORK`-style temporary paths rewritten to the `~/semel-playground` form the reader will see.

Things to check rather than assume, correcting the prose to the behaviour:
- Whether `tools` prints `sdkPath`/`target`/`cStandard` or only the `toolDescriptor.*` lines; the list of lines the reader must add is exactly the keys `EndToEnd/Fixtures/clang.cfg.template` has and `tools` does not print.
- What `build` prints on a no-op, on a rebuild and on a cache-hit rebuild — whether the output distinguishes "recomputed" from "cache hit" at all. If it does not, find which command shows it (`debug`, or the server's log) and use that in experiments 2–4. If nothing shows it, say so in the PR description and add a backlog item: the tutorial's central claim should be observable from the prompt.
- Experiment 4: that an unread key under `clang.linker.` does not raise an unclaimed-key error (`UnclaimedConfigKeyReportingTests` suggests it may). If it does, change a real linker setting instead and rewrite the step.

- [ ] **Step 4: Walk Part 3 and Part 4 as the reader**

Create `SemelExamples/Sources/SemelExamples/MyLineCounter.swift` exactly as the document gives it, register it, rebuild, restart `semelserv`, add the product line, build, and confirm `lines.txt` reads as the document says. Run the three closing experiments and correct the prose to what happened.

Then remove the reader's node — it is not part of the repository:

```bash
rm SemelExamples/Sources/SemelExamples/MyLineCounter.swift
git checkout SemelExamples/Sources/SemelExamples/SemelExamples.swift
swift test --package-path SemelExamples
```

Expected: 4 tests pass, `git status` shows only `docs/tutorial/first-node.md`.

- [ ] **Step 5: Stamp, check the links, commit**

Replace `COMMIT` with `git rev-parse --short HEAD`. Check every relative link resolves:

```bash
grep -o "](\.\./[^)#]*" docs/tutorial/first-node.md | sed 's/](//' | sort -u | while read p; do test -e "docs/tutorial/$p" || echo "MISSING $p"; done
```

Expected: no output. Confirm no `OUTPUT` fence label and no `COMMIT` remain: `grep -n "OUTPUT\|COMMIT" docs/tutorial/first-node.md` prints nothing.

```bash
git add docs/tutorial/first-node.md
git commit -m "Tutorial: build, watch the cache, write a node"
```

---

### Task 5: Finish

- [ ] **Step 1: Everything, once more**

```bash
swift build
swift test --package-path SemelNodeKit
swift test --package-path SemelExamples
swift test --package-path SemelCore
swift test
swiftlint --strict
```

Expected: all pass, no lint findings.

- [ ] **Step 2: Mark the spec implemented**

In `docs/superpowers/specs/2026-09-18-semel-contributor-tutorial-design.md`, change the status line to `**Status:** implemented; see docs/superpowers/plans/2026-09-20-semel-contributor-tutorial.md for what differed from this text.` followed by a bullet per difference. Known before starting: the wire key is `%%f.0%%.c`, not `%%f%%` (the full value is a mounted path, which would make `lines.txt` differ between two homes); `TypeRegistry.register` already refuses a duplicate kind, so Section 6's open check is closed. Add whatever Task 4 found.

- [ ] **Step 3: Push and open the PR**

Push to `Build-system`, open a PR against `main`. The description lists what the walk-through corrected, that `SemelApple` is missing from `Semel.xcworkspace`, and any backlog item Task 4 raised, and ends with:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

# In-Process Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 2 of the daemon split: divide `semel` into a client half and a server half that talk only through `SemelProtocol`'s wire objects, while still running as one process.

**Architecture:** A new `SemelServ` library owns the engine behind one bottleneck, `RequestHandler.handle(_:body:session:)`. The CLI's `CommandContext` hands plugins a `SemelConnection` instead of the database and engine. `InProcessConnection` joins the two and runs every request and reply through the frame codec, so the socket in phase 3 changes nothing above it. `SemelCore` gains reporter closures so nothing it does reaches stdout directly, and its wildcard matcher moves down to `SemelNodeKit` so the CLI can walk the local disk without linking the engine.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest, macOS 13. Foundation `DispatchQueue`/`NSLock` for the handler's serialisation; no new third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md` — Sections 2 and 3 and the "Phase 2" bullets. Read them first. Phase 1 (`SemelProtocol`) is merged on `main`; phase 3 (sockets, two executables) is not this plan.

## Global Constraints

- Dependency direction, from the spec: `SemelCore ◀── SemelServ ──▶ SemelProtocol ◀── SemelCLI`. `SemelCore` never imports `SemelProtocol` or `SemelServ`. `SemelCLI` never imports `SemelCore` or `SemelServ` (after Task 10). `SemelProtocol` imports Foundation only.
- `SemelCLI` may import `SemelNodeKit` (for `Path`, `FileSystemName`, `FileMetadata`, and after Task 1 the wildcard matcher). `SemelNodeKit` links GRDB transitively through `SemelDatabaseModels`; that is accepted.
- The REPL must behave exactly as before at the end of phase 2: same commands, same printed text, same startup banner apart from the version coming from the server's `hello` reply.
- `InProcessConnection` must encode every request to a `Frame` and decode it before the handler sees it, and the same for every reply. Never pass a `Request`/`Response` value straight across.
- `SemelConnection.send` is synchronous and thread-safe; `onEvent` is a callback. The protocol has exactly those two members.
- Handler requests run on one serial queue. Events may be delivered from the engine's background thread.
- Every `print` the engine performs today goes through a `BuildEngine` reporter closure whose default still prints, so engine tests and the phase 2 process behave as before.
- Formatting (AGENTS.md): four spaces, brace on the declaration line, no `else if` chains (nest a block or use `switch`), `// MARK: -` in files long enough to navigate, aligned columns where they aid reading, US-English spelling in code comments. Comments never narrate history: no "today", "after the split", "no longer".
- Naming (AGENTS.md): no single-character names, words spelt out, `struct` unless reference semantics are needed, `internal` by default, `public` only where another module needs it. Errors are enums with associated values carrying enough context to act on.
- Tests: XCTest, `test_whatItDoes`. Engine tests inherit `SemelCoreTestCase`. CLI and server tests must never touch the user's real object store: set `DataObjectStore.shared` to a temporary directory in `setUpWithError` as the existing CLI tests do. Test files use the Xcode-style header (`//` / `//  Name.swift` / `//  TargetTests` / `//` / paragraph / `//`); source files use `// Name.swift` / `// Module` / `//` / paragraph.
- Two type names exist in both `SemelNodeKit` and `SemelProtocol`: `FileSystemName` and `ToolNamespace`. Task 4 renames the protocol's to `FileSystemKind` and `ToolNamespaceRecord`; after that no qualification is needed anywhere.
- Commit messages are imperative sentences (no conventional-commit prefixes), ending with exactly:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE`
- Test commands, all from the repository root: `swift test --package-path SemelNodeKit`, `swift test --package-path SemelCore`, `swift test --package-path SemelProtocol`, `swift test` (root: `SemelCLITests` and, after Task 4, `SemelServTests`), `swift test --package-path SemelSwift`, `swift test --package-path SemelClang`. Run the suites a task touches after each task; Task 10 runs all six.

---

## File structure

```
SemelNodeKit/Sources/SemelNodeKit/FileWildcardMatcher.swift    MOVED from SemelCore, minus InternalFileSystemLister
SemelNodeKit/Sources/SemelNodeKit/WildcardSegment.swift         MOVED from SemelCore
SemelNodeKit/Tests/FileWildcardMatcherTests.swift               MOVED from SemelCore/Tests
SemelCore/Sources/SemelCore/InternalFileSystemLister.swift      NEW: the graph-backed lister, extracted
SemelCore/Sources/SemelCore/ErrorReport.swift                   MODIFY: Entry, entry(...), lines(for:)
SemelCore/Sources/SemelCore/BuildEngine.swift                   MODIFY: errorReporter, noticeReporter, notice(_:)
SemelCore/Sources/SemelCore/DebugPrint.swift                    MODIFY: graphDescription() -> String
SemelCore/Sources/SemelCore/Nodes/OutputFile.swift              MODIFY: BuildEngine.notice
SemelCore/Sources/SemelCore/Nodes/ProjectBuilder.swift          MODIFY: BuildEngine.notice
SemelCore/Tests/SemelCoreTests/IdleErrorReportingTests.swift    NEW
SemelCore/Tests/SemelCoreTests/GraphDescriptionTests.swift      NEW
SemelProtocol/Sources/SemelProtocol/SemelConnection.swift       NEW: the two-member protocol
SemelProtocol/Sources/SemelProtocol/DaemonMessages.swift        MODIFY: two renames
Package.swift                                                   MODIFY: SemelProtocol dependency, SemelServ + SemelServTests targets
semel/Server/Session.swift                                      NEW  (SemelServ)
semel/Server/EventSink.swift                                    NEW
semel/Server/RequestHandler.swift                               NEW: dispatch, queue, hello, batch, engine verbs, events
semel/Server/RequestHandler+Files.swift                         NEW: list, pushFile, pushFolder, remove, fetch
semel/Server/InProcessConnection.swift                          NEW
semel/ServerTests/ServerTestSupport.swift                       NEW: engine + handler fixture
semel/ServerTests/RequestHandlerTests.swift                     NEW
semel/ServerTests/RequestHandlerFileTests.swift                 NEW
semel/ServerTests/InProcessConnectionTests.swift                NEW
semel/CommandInterpreter/CommandContext.swift                   MODIFY: connection instead of engine
semel/CommandInterpreter/CommandInterpreter.swift               MODIFY: init(connection:), connect(), event printing
semel/CommandInterpreter/Renderers.swift                        NEW: ErrorRecordRenderer, ToolNamespaceRenderer
semel/CommandInterpreter/Plugins/NavigationPlugin.swift         MODIFY
semel/CommandInterpreter/Plugins/FilePlugin.swift               MODIFY
semel/CommandInterpreter/Plugins/EnginePlugin.swift             MODIFY
semel/Tests/RecordingConnection.swift                           NEW: the fake connection
semel/Tests/EnginePluginTests.swift                             NEW
semel/Tests/NavigationPluginTests.swift                         NEW
semel/Tests/FilePluginTests.swift                               NEW
semel/Tests/FilePluginPathTests.swift                           MODIFY: run over InProcessConnection
semel/Tests/ToolsCommandTests.swift                             MODIFY: run over InProcessConnection
semel/main.swift                                                MODIFY: composition root
docs, BACKLOG.md, AGENTS.md                                     MODIFY in Task 10
```

Two deviations from the spec, recorded in Task 10:

1. The wildcard matcher moves to `SemelNodeKit` (the spec listed `SemelNodeKit` as unchanged). `push` walks the local disk with `FileWildcardMatcher` and `ExternalFileSystemLister`; both lived in `SemelCore`, and phase 3 has the CLI drop `SemelCore`. Only `InternalFileSystemLister` needs the graph, so only it stays.
2. `ErrorReport.lines` stays in `SemelCore` as well as gaining a copy in `SemelCLI`. Core's default `errorReporter` must still print something when no server routes it, and `ErrorReportTests` pins the format; the CLI cannot import Core. Two 25-line renderers of one format, each named as the other's twin.

---

### Task 1: Move the wildcard matcher to `SemelNodeKit`

**Files:**
- Move: `SemelCore/Sources/SemelCore/FileWildcardMatcher.swift` → `SemelNodeKit/Sources/SemelNodeKit/FileWildcardMatcher.swift` (without `InternalFileSystemLister`)
- Move: `SemelCore/Sources/SemelCore/WildcardSegment.swift` → `SemelNodeKit/Sources/SemelNodeKit/WildcardSegment.swift`
- Move: `SemelCore/Tests/SemelCoreTests/FileWildcardMatcherTests.swift` → `SemelNodeKit/Tests/FileWildcardMatcherTests.swift`
- Create: `SemelCore/Sources/SemelCore/InternalFileSystemLister.swift`

**Interfaces:**
- Produces (in `SemelNodeKit`): `FileWildcardEntryKind`, `FileWildcardEntry`, `FileWildcardMatcherInput`, `FileWildcardMatcher(input:)` with `findAllMatching(pathOrWildcard: Path) throws -> [FileWildcardEntry]` and the `String` overload, `ExternalFileSystemLister(rootDirectoryPath:)`. Unchanged signatures.
- Produces (in `SemelCore`): `InternalFileSystemLister(folder: NodeRecord)`. Unchanged signature.

- [ ] **Step 1: Move the two source files with git so history follows**

```bash
git mv SemelCore/Sources/SemelCore/FileWildcardMatcher.swift SemelNodeKit/Sources/SemelNodeKit/FileWildcardMatcher.swift
git mv SemelCore/Sources/SemelCore/WildcardSegment.swift    SemelNodeKit/Sources/SemelNodeKit/WildcardSegment.swift
git mv SemelCore/Tests/SemelCoreTests/FileWildcardMatcherTests.swift SemelNodeKit/Tests/FileWildcardMatcherTests.swift
```

- [ ] **Step 2: Extract `InternalFileSystemLister` back into Core**

Open the moved `FileWildcardMatcher.swift`. Cut everything from the line `// MARK: - InternalFileSystemLister` to the end of the file, and paste it into a new `SemelCore/Sources/SemelCore/InternalFileSystemLister.swift` with this header above it:

```swift
// InternalFileSystemLister.swift
// SemelCore
//
// The graph-backed side of the wildcard matcher. The matcher itself lives in SemelNodeKit
// so that a client can walk a real directory without linking the engine; this lister is
// the one input that needs `NodeRecord` and `Folder`, so it is the one part that stays.

import Foundation
import SemelDatabaseModels
import SemelNodeKit

```

In the moved `FileWildcardMatcher.swift`, change the header's second line from `// semel` to `// SemelNodeKit`, and delete the `import SemelNodeKit` line (the file is now inside that module). In the moved test file, change `@testable import SemelCore` to `@testable import SemelNodeKit` and the header's target line from `SemelCoreTests` to `SemelNodeKitTests`. If the test class inherits `SemelCoreTestCase`, change it to `XCTestCase` — the matcher tests use a temporary directory, not the engine's globals; if any test in the file references `InternalFileSystemLister`, stop and report NEEDS_CONTEXT (there should be none: `grep -c InternalFileSystemLister` on the file is 0).

- [ ] **Step 3: Build and test both packages**

Run: `swift test --package-path SemelNodeKit` and `swift test --package-path SemelCore`
Expected: both green. `SemelCore` compiles because it already imports `SemelNodeKit` everywhere the matcher is used (`BuildEngine.swift`, and the CLI plugins which import both). If `WildcardSegment.swift` used a Core-only symbol, the NodeKit build will say so; it should not — it has no imports at all.

- [ ] **Step 4: Run the CLI tests, since the plugins use the matcher**

Run: `swift test`
Expected: green, unchanged count. The plugins import `SemelNodeKit` already.

- [ ] **Step 5: Commit**

```bash
git add -A SemelCore SemelNodeKit
git commit -m "Move the wildcard matcher to SemelNodeKit, keeping only the graph-backed lister in Core

A client walks a real directory with the matcher and must not link the
engine to do it. InternalFileSystemLister is the one input that needs
NodeRecord, so it is the one part that stays.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 2: The engine reports through closures

**Files:**
- Modify: `SemelCore/Sources/SemelCore/ErrorReport.swift`
- Modify: `SemelCore/Sources/SemelCore/BuildEngine.swift` (the reporter region around lines 205–320)
- Modify: `SemelCore/Sources/SemelCore/Nodes/OutputFile.swift:148-150`
- Modify: `SemelCore/Sources/SemelCore/Nodes/ProjectBuilder.swift:184-187`
- Create: `SemelCore/Tests/SemelCoreTests/IdleErrorReportingTests.swift`

**Interfaces:**
- Produces: `ErrorReport.Entry` (`label: String`, `items: [ErrorReport.Item]`), `ErrorReport.Item` (`ports: [String]`, `message: String`), `ErrorReport.entry(forNodeID:ports:messages:database:) -> Entry`, `ErrorReport.lines(for entry: Entry) -> [String]`. The existing `ErrorReport.lines(forNodeID:ports:messages:database:)` keeps its signature and becomes `lines(for: entry(...))`.
- Produces: `BuildEngine.errorReporter: ([ErrorReport.Entry]) -> Void`, `BuildEngine.noticeReporter: (String) -> Void`, `BuildEngine.notice(_ line: String)` (static), `BuildEngine.reportIdleTimeErrors()` now `internal`.

- [ ] **Step 1: Write the failing test**

`SemelCore/Tests/SemelCoreTests/IdleErrorReportingTests.swift`:

```swift
//
//  IdleErrorReportingTests.swift
//  SemelCoreTests
//
//  The idle-time error report goes through a closure so that a server can carry it to a
//  client instead of it landing on whichever stdout the engine happens to have. The
//  default still prints; these tests install a capturing closure instead.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class IdleErrorReportingTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var captured: [[ErrorReport.Entry]] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.errorReporter = { [weak self] entries in self?.captured.append(entries) }
    }

    override func tearDown() {
        engine = nil
        captured = []
        super.tearDown()
    }

    private func makeFailingFile(path: String, message: String) throws {
        let nodeRecord = try NodeRecord.createNode(database: engine.database,
                                                   kind: StaticFile.kind,
                                                   properties: ["path": path],
                                                   graphSpec: nil)
        try nodeRecord.writeToOutputPort("output",
                                         value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
    }

    func test_aNewErrorReachesTheReporterAsAnEntry() throws {
        try makeFailingFile(path: "input:/a.c", message: "boom")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].map(\.label), ["StaticFile  'input:/a.c'"])
        XCTAssertEqual(captured[0][0].items, [ErrorReport.Item(ports: ["output"], message: "boom")])
    }

    func test_anErrorAlreadyReportedIsNotReportedAgain() throws {
        try makeFailingFile(path: "input:/a.c", message: "boom")

        engine.reportIdleTimeErrors()
        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
    }

    func test_nothingIsReportedWhenThereAreNoErrors() throws {
        engine.reportIdleTimeErrors()

        XCTAssertTrue(captured.isEmpty)
    }

    /// The lines the default reporter prints are the same lines `ErrorReport` has always
    /// produced, so an engine run without a server reads as before.
    func test_renderingAnEntryMatchesTheReportFormat() throws {
        let entry = ErrorReport.Entry(label: "StaticFile  'input:/a.c'",
                                      items: [ErrorReport.Item(ports: ["errorLog", "output"], message: "boom")])

        XCTAssertEqual(ErrorReport.lines(for: entry),
                       ["❌ StaticFile  'input:/a.c'", "   · errorLog, output: boom", ""])
    }

    func test_aNoticeReachesTheNoticeReporter() {
        var notices: [String] = []
        engine.noticeReporter = { notices.append($0) }

        BuildEngine.notice("output:/app: written")

        XCTAssertEqual(notices, ["output:/app: written"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path SemelCore --filter IdleErrorReportingTests`
Expected: compile failure — `errorReporter`, `ErrorReport.Entry`, `reportIdleTimeErrors` (private), `BuildEngine.notice` do not exist.

- [ ] **Step 3: Split `ErrorReport` into gathering and rendering**

In `SemelCore/Sources/SemelCore/ErrorReport.swift`, add these two types inside `public enum ErrorReport` (above `label`):

```swift
    /// One distinct message a node is carrying, and the ports carrying it.
    public struct Item: Equatable {
        public let ports:   [String]
        public let message: String

        public init(ports: [String], message: String) {
            self.ports   = ports
            self.message = message
        }
    }

    /// One node's errors, gathered but not yet rendered. The engine hands these to its
    /// reporter, and a server turns them into wire records; only the terminal turns them
    /// into lines.
    public struct Entry: Equatable {
        public let label: String
        public let items: [Item]

        public init(label: String, items: [Item]) {
            self.label = label
            self.items = items
        }
    }
```

Replace the whole `lines(forNodeID:ports:messages:database:)` function with these two, keeping its doc comment on `entry`:

```swift
    public static func entry(forNodeID nodeID: ObjectID,
                             ports: [OutputPort],
                             messages: Set<String>,
                             database: DatabaseLayer) -> Entry {
        let items = messages.sorted().map { message -> Item in
            let portNames = ports
                .filter { ((try? $0.dataObjectHash?.resolveAsString()) ?? "") == message }
                .map { $0.nameSymbolID.resolveSymbol() }
                .sorted()
            return Item(ports: portNames, message: message)
        }
        return Entry(label: label(forNodeID: nodeID, database: database), items: items)
    }

    /// The lines for one entry: a heading, then one line per item, or an indented block
    /// when a message spans lines. `SemelCLI` has a twin of this over the wire record; the
    /// two must stay identical, and `IdleErrorReportingTests` pins this one's output.
    public static func lines(for entry: Entry) -> [String] {
        var result = ["❌ \(entry.label)"]

        for item in entry.items {
            let portNames = item.ports.joined(separator: ", ")

            let body = item.message
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard !body.isEmpty else {
                result.append("   · \(portNames): (no details)")
                continue
            }

            if body.count == 1 {
                result.append("   · \(portNames): \(body[0])")
            } else {
                result.append("   · \(portNames):")
                result.append(contentsOf: body.map { "     \($0)" })
            }
        }

        result.append("")
        return result
    }

    public static func lines(forNodeID nodeID: ObjectID,
                             ports: [OutputPort],
                             messages: Set<String>,
                             database: DatabaseLayer) -> [String] {
        lines(for: entry(forNodeID: nodeID, ports: ports, messages: messages, database: database))
    }
```

`ErrorReportTests` keeps passing: the four-argument `lines` is unchanged in behaviour.

- [ ] **Step 4: Add the reporters to `BuildEngine`**

In `SemelCore/Sources/SemelCore/BuildEngine.swift`, directly below `unclaimedConfigKeyReporter`, add:

```swift
    /// Where the idle-time error report goes. Structured entries rather than lines, so a
    /// server can carry them to a client as records; the default renders and prints, so
    /// an engine with no server still reports to its own terminal.
    public var errorReporter: ([ErrorReport.Entry]) -> Void = { entries in
        entries.flatMap(ErrorReport.lines(for:)).forEach { print($0) }
    }

    /// Where one-line status notices go — an artifact written, a product deleted. Nodes
    /// reach it through `notice(_:)`, because a node has the process-wide engine and
    /// nothing else to hand a line to.
    public var noticeReporter: (String) -> Void = { print($0) }

    /// The one call a node makes to say something to the user. Falls back to printing when
    /// no engine is installed, which is only the case in tests that build nodes by hand.
    public static func notice(_ line: String) {
        (shared?.noticeReporter ?? { print($0) })(line)
    }
```

Change `reportUnclaimedConfigKeys`'s doc comment sentence "Internal rather than private so a test can call it directly" — leave as is. Change `private func reportIdleTimeErrors()` to `func reportIdleTimeErrors()` and replace its body's final loop so that it collects entries and calls the reporter once:

```swift
        // Only nodes with at least one newly-appearing message. Reporting an error that has
        // already been reported on every settle is how a report stops being read.
        var entries: [ErrorReport.Entry] = []
        for (nodeID, msgs) in current {
            let newMsgs = msgs.subtracting(lastReportedErrors[nodeID] ?? [])
            guard !newMsgs.isEmpty else { continue }

            entries.append(ErrorReport.entry(forNodeID: nodeID,
                                             ports: byNode[nodeID] ?? [],
                                             messages: newMsgs,
                                             database: database))
        }

        lastReportedErrors = current

        // Sorted so a report reads the same from run to run; `current` is a dictionary.
        if !entries.isEmpty {
            errorReporter(entries.sorted { $0.label < $1.label })
        }
```

Also route the unclaimed-key report through notices so a server sees it: change the default of `unclaimedConfigKeyReporter` from `{ print($0) }` to `{ BuildEngine.notice($0) }`. `UnclaimedConfigKeyReportingTests` installs its own closure, so it is unaffected.

- [ ] **Step 5: Route the two node print sites through `notice`**

`SemelCore/Sources/SemelCore/Nodes/OutputFile.swift:148-150`: replace `print("\(path): \(newDescription)")` with `BuildEngine.notice("\(path): \(newDescription)")`.

`SemelCore/Sources/SemelCore/Nodes/ProjectBuilder.swift:186`: replace `print("\(path): Deleted")` with `BuildEngine.notice("\(path): Deleted")`.

Then confirm nothing else in the engine prints outside the debug dump:

Run: `grep -n 'print(' SemelCore/Sources/SemelCore/*.swift SemelCore/Sources/SemelCore/Nodes/*.swift | grep -v DebugPrint.swift`
Expected: only the three default closures in `BuildEngine.swift` (`unclaimedConfigKeyReporter` no longer prints; `errorReporter`, `noticeReporter`, `notice`).

- [ ] **Step 6: Run the engine suite**

Run: `swift test --package-path SemelCore`
Expected: green, including the five new tests and the unchanged `ErrorReportTests`.

- [ ] **Step 7: Commit**

```bash
git add SemelCore
git commit -m "Report idle-time errors and notices through engine closures

The error report is gathered as entries and rendered separately, so a
server can carry entries to a client; the default still prints. Nodes
say things through BuildEngine.notice instead of print.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 3: The graph dump returns a string

**Files:**
- Modify: `SemelCore/Sources/SemelCore/DebugPrint.swift` (the `printAll` region, lines ~82–250)
- Create: `SemelCore/Tests/SemelCoreTests/GraphDescriptionTests.swift`

**Interfaces:**
- Produces: `BuildEngine.graphDescription() throws -> String`. `printAll()` is removed (its only caller was the CLI's `debug`, which Task 8 rewrites).

- [ ] **Step 1: Write the failing test**

`SemelCore/Tests/SemelCoreTests/GraphDescriptionTests.swift`:

```swift
//
//  GraphDescriptionTests.swift
//  SemelCoreTests
//
//  The debug dump is a string, not a side effect, so a server can send it to whichever
//  client asked. The content is a diagnostic and not pinned line by line; these tests
//  check that the sections are there and that a node shows up under its type.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class GraphDescriptionTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    func test_describesAnEmptyGraphWithItsSections() throws {
        let text = try engine.graphDescription()

        XCTAssertTrue(text.hasPrefix("BUILD GRAPH STATE ("), text)
        XCTAssertTrue(text.contains("OutputPort count: "), text)
        XCTAssertTrue(text.contains("- build tree"), text)
    }

    func test_listsANodeUnderItsTypeName() throws {
        _ = try NodeRecord.createNode(database: engine.database, kind: StaticFile.kind,
                                      properties: ["path": "input:/a.c"], graphSpec: nil)

        let text = try engine.graphDescription()

        XCTAssertTrue(text.contains("⬢ StaticFile #"), text)
        XCTAssertTrue(text.contains("name: 'input:/a.c'") || text.contains("graphSpec:"), text)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path SemelCore --filter GraphDescriptionTests`
Expected: compile failure, `graphDescription` does not exist.

- [ ] **Step 3: Convert the dump to build a string**

In `SemelCore/Sources/SemelCore/DebugPrint.swift`, add this small accumulator at the top of the file (after the imports):

```swift
/// Collects the lines of a diagnostic so the whole thing can be returned as one string.
/// Debug output must never be the thing that takes the process down, so nothing here
/// throws; a caller that cannot describe part of the graph appends what it can say.
final class TextBuffer {
    private(set) var lines: [String] = []

    func append(_ line: String = "") {
        lines.append(line)
    }

    var text: String { lines.joined(separator: "\n") }
}
```

Then, mechanically, in the `printAll` region:

- Rename `public func printAll() throws` to `public func graphDescription() throws -> String`; declare `let text = TextBuffer()` as its first line and `return text.text` as its last.
- Change `private func printSectionHeader(_ title: String)` to `private func appendSectionHeader(_ title: String, to text: TextBuffer)`, with `text.append(title)` and `text.append(String(repeating: "─", count: title.count))`; update its one call site to `appendSectionHeader("BUILD GRAPH STATE (\(allNodes.count) nodes)", to: text)`.
- Replace every `print(<expression>)` inside `graphDescription` with `text.append(<expression>)`, and every bare `print()` with `text.append()`. There are 16 in that function; do not change the strings.
- Change `func debugPrintTree()` to `func appendDependencyTree(to text: TextBuffer)`: `text.append("- build tree")`, `try projectFinder.appendDependencyTree(indentLevel: 1, to: text)`, and in the catch `text.append("- build tree (error: \(error))")`. Update the call at the end of `graphDescription` to `appendDependencyTree(to: text)`.
- In `extension NodeRecord`, rename `fileprivate func printDependencyTree(indentLevel: Int)` to `fileprivate func appendDependencyTree(indentLevel: Int, to text: TextBuffer)`; replace its four `print(...)` calls with `text.append(...)` and the recursive call with `dependencyNode.appendDependencyTree(indentLevel: indentLevel + 1, to: text)`.

`nudge()` and everything above `// MARK: printAll` are untouched.

The CLI's `EnginePlugin` still calls `printAll()` until Task 8 rewrites it. So that the root package keeps building in between, leave this one-line shim directly below `graphDescription()`, and Task 8 deletes it:

```swift
    /// Kept until the command plugins stop calling it (removed in the CLI split).
    public func printAll() throws {
        print(try graphDescription())
    }
```

After this, `grep -n 'print(' SemelCore/Sources/SemelCore/DebugPrint.swift` must show exactly that one line.

- [ ] **Step 4: Run the engine suite**

Run: `swift test --package-path SemelCore`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add SemelCore
git commit -m "Return the graph dump as a string instead of printing it

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 4: `SemelConnection`, two protocol renames, and the `SemelServ` targets

**Files:**
- Create: `SemelProtocol/Sources/SemelProtocol/SemelConnection.swift`
- Modify: `SemelProtocol/Sources/SemelProtocol/DaemonMessages.swift` (rename `FileSystemName` → `FileSystemKind`, `ToolNamespace` → `ToolNamespaceRecord`)
- Modify: `SemelProtocol/Tests/MessageJSONTests.swift` (the same two renames)
- Modify: `Package.swift`
- Create: `semel/Server/Session.swift`
- Create: `semel/Server/EventSink.swift`
- Create: `semel/ServerTests/SessionTests.swift`

**Interfaces:**
- Produces (SemelProtocol): `public protocol SemelConnection: AnyObject { func send(_ request: Request, body: Data?) throws -> (Response, Data?); var onEvent: ((Event) -> Void)? { get set } }`; `FileSystemKind` (`input`, `output`); `ToolNamespaceRecord`.
- Produces (SemelServ): `public final class Session` with `isSubscribed: Bool`, `openBatchDepth: Int` (read-only), `batchOpened()`, `batchClosed()`; `public protocol EventSink: AnyObject { func deliver(_ event: Event) }`.

- [ ] **Step 1: Rename the two clashing protocol types**

`SemelNodeKit` already has `FileSystemName` (the `input:`/`output:` root strings) and `ToolNamespace` (the registry entry). Any module importing both would have to qualify every mention. Rename in `SemelProtocol` while nothing links it: in `DaemonMessages.swift` change `public enum FileSystemName` to `public enum FileSystemKind` and its two uses (`list(fileSystem: FileSystemKind, …)`, `fetch(fileSystem: FileSystemKind, …)`), and `public struct ToolNamespace` to `public struct ToolNamespaceRecord` and its use in `DaemonResponse.tools(namespaces: [ToolNamespaceRecord])`. In `MessageJSONTests.swift` change the one `ToolNamespace(` construction to `ToolNamespaceRecord(`. The JSON is unaffected: neither type name appears on the wire.

Run: `swift test --package-path SemelProtocol`
Expected: 44 tests green.

- [ ] **Step 2: Write the connection protocol**

`SemelProtocol/Sources/SemelProtocol/SemelConnection.swift`:

```swift
// SemelConnection.swift
// SemelProtocol
//
// What a client holds: a thing that carries a request and returns the reply matched to
// it. Two members, on purpose. `send` is synchronous — it blocks the calling thread until
// its own reply arrives, and several threads may have sends outstanding at once, because
// the REPL, the command plugins and the engine's cache hooks are all synchronous and an
// async surface would push `async` through every one of them for a client that sends
// one request at a time. Request matching lives inside the conformers, so an async
// variant is a change to these two signatures and their conformers, never to a plugin.
//
// It lives here rather than in the CLI because the in-process conformer holds the
// server's request handler; a protocol owned by the CLI would force the CLI and the
// server to import each other.

import Foundation

public protocol SemelConnection: AnyObject {

    /// Blocks until the reply to this request arrives. Thread-safe.
    func send(_ request: Request, body: Data?) throws -> (Response, Data?)

    /// Called for every event the server pushes, from whatever thread the connection
    /// receives on. Nil discards events.
    var onEvent: ((Event) -> Void)? { get set }
}
```

- [ ] **Step 3: Wire the root package**

Replace `Package.swift` at the repository root with:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "semel",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(path: "SemelCore"),
        .package(path: "SemelNodeKit"),
        .package(path: "SemelProtocol"),
        .package(path: "SemelSwift"),
        .package(path: "SemelClang"),
    ],
    targets: [
        // The command interpreter lives in a library rather than the executable so it can
        // be imported by tests — an executable target with top-level code in main.swift
        // cannot be. It sees the wire protocol and the node kit, never the engine: that
        // is what lets it become a separate process later without changing.
        .target(
            name: "SemelCLI",
            dependencies: [
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
            ],
            path: "semel/CommandInterpreter"
        ),
        // The server half: owns the engine behind one request handler. No sockets here;
        // the listener arrives with the semelserv executable.
        .target(
            name: "SemelServ",
            dependencies: [
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
            ],
            path: "semel/Server"
        ),
        .executableTarget(
            name: "semel",
            dependencies: [
                "SemelCLI",
                "SemelServ",
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
                .product(name: "SemelSwift", package: "SemelSwift"),
                .product(name: "SemelClang", package: "SemelClang"),
            ],
            path: "semel",
            sources: ["main.swift"]
        ),
        .testTarget(
            name: "SemelServTests",
            dependencies: [
                "SemelServ",
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
            ],
            path: "semel/ServerTests"
        ),
        // The only place a test can see the converter and the engine at once. SemelSwift
        // deliberately does not depend on SemelCore, so nothing inside it can check that
        // the formula it emits is *complete* — only that it parses. This target can. It
        // also runs the plugins over a real engine through InProcessConnection.
        .testTarget(
            name: "SemelCLITests",
            dependencies: [
                "SemelCLI",
                "SemelServ",
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
                .product(name: "SemelSwift", package: "SemelSwift"),
                .product(name: "SemelClang", package: "SemelClang"),
            ],
            path: "semel/Tests"
        ),
    ]
)
```

`SemelCLI` keeps its `SemelCore` dependency until Task 10 drops it; the comment above it describes the end state.

- [ ] **Step 4: Write the failing session test**

`semel/ServerTests/SessionTests.swift`:

```swift
//
//  SessionTests.swift
//  SemelServTests
//
//  Per-connection state. The one rule worth a test: batches are counted, so a session
//  torn down mid-push can be unwound exactly as many times as it was opened.
//

@testable import SemelServ
import XCTest

final class SessionTests: XCTestCase {

    func test_startsUnsubscribedWithNoOpenBatch() {
        let session = Session()

        XCTAssertFalse(session.isSubscribed)
        XCTAssertEqual(session.openBatchDepth, 0)
    }

    func test_countsNestedBatches() {
        let session = Session()

        session.batchOpened()
        session.batchOpened()
        session.batchClosed()

        XCTAssertEqual(session.openBatchDepth, 1)
    }

    func test_closingBelowZeroIsIgnored() {
        let session = Session()

        session.batchClosed()

        XCTAssertEqual(session.openBatchDepth, 0)
    }
}
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `swift test --filter SessionTests`
Expected: compile failure, `Session` does not exist.

- [ ] **Step 6: Write `Session` and `EventSink`**

`semel/Server/Session.swift`:

```swift
// Session.swift
// SemelServ
//
// What the server remembers about one connection: whether it asked for events, and how
// many batches it has open. In one process there is exactly one; with a socket there is
// one per connection, and tearing it down unwinds its batches so a client killed
// mid-push cannot leave the engine's work signals suppressed forever.

import Foundation

public final class Session {

    public var isSubscribed = false

    public private(set) var openBatchDepth = 0

    public init() {}

    func batchOpened() {
        openBatchDepth += 1
    }

    /// A close without an open is a client bug, not a reason to underflow.
    func batchClosed() {
        openBatchDepth = max(0, openBatchDepth - 1)
    }
}
```

`semel/Server/EventSink.swift`:

```swift
// EventSink.swift
// SemelServ
//
// Where the handler puts an event. One method, so that the in-process connection can be
// the sink directly and the socket server can be a fan-out over its subscribed sessions
// without the handler knowing which it is talking to.

import Foundation
import SemelProtocol

public protocol EventSink: AnyObject {
    func deliver(_ event: Event)
}
```

- [ ] **Step 7: Run the tests**

Run: `swift test --package-path SemelProtocol` and `swift test --filter SessionTests`
Expected: protocol suite 44 green; session tests 3 green.

- [ ] **Step 8: Commit**

```bash
git add Package.swift SemelProtocol semel/Server semel/ServerTests
git commit -m "Add the SemelConnection protocol and the SemelServ target with its session

FileSystemName and ToolNamespace in the protocol are renamed to
FileSystemKind and ToolNamespaceRecord so they do not collide with the
node kit's types in modules that import both.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 5: `RequestHandler` — dispatch, hello, batches, engine verbs, events

**Files:**
- Create: `semel/Server/RequestHandler.swift`
- Create: `semel/ServerTests/ServerTestSupport.swift`
- Create: `semel/ServerTests/RequestHandlerTests.swift`

**Interfaces:**
- Consumes: `Session`, `EventSink` (Task 4); `BuildEngine.errorReporter`, `noticeReporter`, `graphDescription()` (Tasks 2–3); `ErrorReport.entry`, `ErrorReport.reportableMessage`.
- Produces: `public final class RequestHandler` with `init(engine: BuildEngine, database: DatabaseLayer, databasePath: String)`, `weak var eventSink: EventSink?`, `func handle(_ request: Request, body: Data?, session: Session) -> (Response, Data?)`, `func endSession(_ session: Session)`. Task 6 adds the file verbs in an extension and relies on the private helpers `rootFolder(_:)` and `HandlerFailure` defined here.

- [ ] **Step 1: Write the shared test fixture**

`semel/ServerTests/ServerTestSupport.swift`:

```swift
//
//  ServerTestSupport.swift
//  SemelServTests
//
//  A real in-memory engine behind a real handler. The only boundary faked anywhere in
//  these tests is the object store, redirected to a temporary directory so a test can
//  never write into the user's real one.
//

@testable import SemelCore
@testable import SemelServ
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

/// Records every event the handler delivers.
final class RecordingSink: EventSink {
    private(set) var events: [Event] = []

    func deliver(_ event: Event) {
        events.append(event)
    }
}

class RequestHandlerTestCase: XCTestCase {

    var engine:   BuildEngine!
    var database: DatabaseLayer!
    var handler:  RequestHandler!
    var session:  Session!
    var sink:     RecordingSink!

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-server-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        database = try DatabaseLayer()
        engine   = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        handler  = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        sink     = RecordingSink()
        handler.eventSink = sink
        session  = Session()
    }

    override func tearDown() {
        BuildEngine.shared = nil
        handler  = nil
        engine   = nil
        database = nil
        session  = nil
        sink     = nil
        super.tearDown()
    }

    /// Sends a daemon request and unwraps the daemon reply; fails the test on anything else.
    @discardableResult
    func daemon(_ request: DaemonRequest, body: Data? = nil,
                file: StaticString = #filePath, line: UInt = #line) throws -> (DaemonResponse, Data?) {
        let (response, replyBody) = handler.handle(.daemon(request), body: body, session: session)
        guard case .daemon(let daemonResponse) = response else {
            XCTFail("expected a daemon response, got \(response)", file: file, line: line)
            throw NSError(domain: "RequestHandlerTestCase", code: 1)
        }
        return (daemonResponse, replyBody)
    }

    /// Sends a daemon request and expects an error reply.
    func daemonError(_ request: DaemonRequest, body: Data? = nil,
                     file: StaticString = #filePath, line: UInt = #line) -> ErrorResponse? {
        let (response, _) = handler.handle(.daemon(request), body: body, session: session)
        guard case .error(let error) = response else {
            XCTFail("expected an error response, got \(response)", file: file, line: line)
            return nil
        }
        return error
    }
}
```

- [ ] **Step 2: Write the failing handler tests**

`semel/ServerTests/RequestHandlerTests.swift`:

```swift
//
//  RequestHandlerTests.swift
//  SemelServTests
//
//  The bottleneck between the wire and the engine, driven with typed messages against a
//  real in-memory engine. The file verbs have their own file; this one covers the
//  handshake, batches, the engine verbs and event routing.
//

@testable import SemelCore
@testable import SemelServ
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

final class RequestHandlerTests: RequestHandlerTestCase {

    // MARK: - Hello

    func test_helloIsAcceptedWithTheServerVersionAndDatabasePath() {
        let (response, _) = handler.handle(.hello(Hello(role: .daemon)), body: nil, session: session)

        XCTAssertEqual(response, .hello(.accepted(serverVersion: Semel.version, databasePath: "/tmp/test-graph.sqlite")))
    }

    func test_helloWithAnotherProtocolVersionIsRejectedNamingBoth() {
        let (response, _) = handler.handle(.hello(Hello(protocolVersion: 99, role: .daemon)), body: nil, session: session)

        XCTAssertEqual(response, .hello(.rejected(reason: .versionMismatch(client: 99, server: ProtocolVersion.current))))
    }

    func test_helloForARoleNotOfferedIsRejected() {
        let (response, _) = handler.handle(.hello(Hello(role: .cache)), body: nil, session: session)

        XCTAssertEqual(response, .hello(.rejected(reason: .roleNotOffered(role: .cache))))
    }

    // MARK: - Batches and subscription

    func test_batchesAreCountedOnTheSession() throws {
        try daemon(.beginBatch)
        try daemon(.beginBatch)
        try daemon(.endBatch)

        XCTAssertEqual(session.openBatchDepth, 1)
    }

    func test_endingASessionClosesItsOpenBatches() throws {
        try daemon(.beginBatch)
        try daemon(.beginBatch)

        handler.endSession(session)

        XCTAssertEqual(session.openBatchDepth, 0)
    }

    func test_subscribeMarksTheSession() throws {
        let (response, _) = try daemon(.subscribe)

        XCTAssertEqual(response, .ok)
        XCTAssertTrue(session.isSubscribed)
    }

    // MARK: - Engine verbs

    func test_resetAndNudgeAnswerOk() throws {
        XCTAssertEqual(try daemon(.reset).0, .ok)
        XCTAssertEqual(try daemon(.nudge).0, .ok)
    }

    func test_debugReturnsTheGraphDescription() throws {
        let (response, _) = try daemon(.debug)

        guard case .debug(let text) = response else {
            return XCTFail("expected debug text, got \(response)")
        }
        XCTAssertTrue(text.hasPrefix("BUILD GRAPH STATE ("), text)
    }

    func test_toolsListsEveryNamespaceEvenWhenNoToolIsInstalled() throws {
        ToolRunnerRegistry.instance = ToolRunnerRegistry()

        let (response, _) = try daemon(.tools)

        guard case .tools(let namespaces) = response else {
            return XCTFail("expected tools, got \(response)")
        }
        XCTAssertEqual(namespaces.map(\.namespace), ToolNamespaceRegistry.all.map(\.namespace))
        XCTAssertTrue(namespaces.allSatisfy { $0.descriptors.isEmpty })
    }

    func test_errorsReturnsOneRecordPerFailingNodeSortedByName() throws {
        try makeFailingFile(path: "input:/b.c", message: "second")
        try makeFailingFile(path: "input:/a.c", message: "first")

        let (response, _) = try daemon(.errors)

        XCTAssertEqual(response, .errors(records: [
            ErrorRecord(label: "StaticFile  'input:/a.c'", entries: [ErrorEntry(ports: ["output"], message: "first")]),
            ErrorRecord(label: "StaticFile  'input:/b.c'", entries: [ErrorEntry(ports: ["output"], message: "second")]),
        ]))
    }

    func test_errorsIsEmptyWhenNothingFailed() throws {
        XCTAssertEqual(try daemon(.errors).0, .errors(records: []))
    }

    // MARK: - Events

    func test_engineErrorReportsReachTheSinkAsRecords() throws {
        try makeFailingFile(path: "input:/a.c", message: "boom")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(sink.events, [
            .daemon(.errors(records: [ErrorRecord(label: "StaticFile  'input:/a.c'",
                                                  entries: [ErrorEntry(ports: ["output"], message: "boom")])])),
        ])
    }

    func test_noticesReachTheSink() {
        BuildEngine.notice("output:/app: written")

        XCTAssertEqual(sink.events, [.daemon(.notice(line: "output:/app: written"))])
    }

    // MARK: - Helpers

    private func makeFailingFile(path: String, message: String) throws {
        let nodeRecord = try NodeRecord.createNode(database: database, kind: StaticFile.kind,
                                                   properties: ["path": path], graphSpec: nil)
        try nodeRecord.writeToOutputPort("output",
                                         value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter RequestHandlerTests`
Expected: compile failure, `RequestHandler` does not exist.

- [ ] **Step 4: Write the handler**

`semel/Server/RequestHandler.swift`:

```swift
// RequestHandler.swift
// SemelServ
//
// The bottleneck. Everything a client can ask of the engine arrives here as a typed
// `Request` and leaves as a typed `Response`; nothing else in the server touches the
// graph on a client's behalf. In one process the in-process connection calls it; with a
// socket, the listener does. Either way the handler does not know.
//
// Requests are handled on one serial queue, which is the role the REPL thread plays
// against the engine's background task: GRDB's queue and the task-local transaction
// nesting already make that safe, so two clients issuing commands at once take turns.

import Foundation
import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol

public final class RequestHandler {

    let engine:   BuildEngine
    let database: DatabaseLayer

    private let databasePath: String
    private let queue = DispatchQueue(label: "semelserv.requests")

    /// Where events go. Weak, because the in-process connection is both the sink and the
    /// owner of this handler.
    public weak var eventSink: EventSink?

    public init(engine: BuildEngine, database: DatabaseLayer, databasePath: String) {
        self.engine       = engine
        self.database     = database
        self.databasePath = databasePath
        installReporters()
    }

    // MARK: - Entry point

    public func handle(_ request: Request, body: Data?, session: Session) -> (Response, Data?) {
        queue.sync { () -> (Response, Data?) in
            switch request {
            case .hello(let hello):
                return (.hello(answer(hello)), nil)
            case .daemon(let daemonRequest):
                return handleDaemon(daemonRequest, body: body, session: session)
            }
        }
    }

    /// Unwinds whatever the session left open, so a client that vanished mid-push cannot
    /// leave the engine's work signals suppressed.
    public func endSession(_ session: Session) {
        queue.sync {
            while session.openBatchDepth > 0 {
                engine.endBatch()
                session.batchClosed()
            }
        }
    }

    // MARK: - Hello

    private func answer(_ hello: Hello) -> HelloResponse {
        guard hello.protocolVersion == ProtocolVersion.current else {
            return .rejected(reason: .versionMismatch(client: hello.protocolVersion, server: ProtocolVersion.current))
        }
        guard hello.role == .daemon else {
            return .rejected(reason: .roleNotOffered(role: hello.role))
        }
        return .accepted(serverVersion: Semel.version, databasePath: databasePath)
    }

    // MARK: - Daemon dispatch

    private func handleDaemon(_ request: DaemonRequest, body: Data?, session: Session) -> (Response, Data?) {
        do {
            switch request {
            case .list(let fileSystem, let pattern):
                return (.daemon(try list(fileSystem: fileSystem, pattern: pattern)), nil)
            case .beginBatch:
                engine.beginBatch()
                session.batchOpened()
                return (.daemon(.ok), nil)
            case .endBatch:
                engine.endBatch()
                session.batchClosed()
                return (.daemon(.ok), nil)
            case .pushFile(let path, let mode):
                return (.daemon(try pushFile(path: path, mode: mode, body: body ?? Data())), nil)
            case .pushFolder(let path):
                return (.daemon(try pushFolder(path: path)), nil)
            case .remove(let pattern):
                return (.daemon(try remove(pattern: pattern)), nil)
            case .fetch(let fileSystem, let path):
                let (response, bytes) = try fetch(fileSystem: fileSystem, path: path)
                return (.daemon(response), bytes)
            case .errors:
                return (.daemon(.errors(records: try errorRecords())), nil)
            case .tools:
                return (.daemon(.tools(namespaces: toolNamespaces())), nil)
            case .reset:
                try engine.reset()
                return (.daemon(.ok), nil)
            case .nudge:
                try engine.nudge()
                return (.daemon(.ok), nil)
            case .debug:
                return (.daemon(.debug(text: try engine.graphDescription())), nil)
            case .subscribe:
                session.isSubscribed = true
                return (.daemon(.ok), nil)
            }
        } catch let failure as HandlerFailure {
            return (.error(failure.response), nil)
        } catch let error as NodeError {
            return (.error(.nodeError(description: "\(error)")), nil)
        } catch {
            // A store or database that is unusable belongs to the machine, not to this
            // request; the fatal handler halts the process rather than answering one
            // client with an error it would only retry.
            FatalErrors.check(error)
            return (.error(.nodeError(description: error.localizedDescription)), nil)
        }
    }

    // MARK: - Engine verbs

    private func errorRecords() throws -> [ErrorRecord] {
        let errorPorts = try database.outputPort.selectAllErrors()
        let byNode     = Dictionary(grouping: errorPorts, by: \.nodeID)

        let sortedNodeIDs = byNode.keys.sorted { first, second in
            let firstName  = (try? database.node.select(nodeID: first))?.name  ?? ""
            let secondName = (try? database.node.select(nodeID: second))?.name ?? ""
            return firstName < secondName
        }

        return sortedNodeIDs.map { nodeID in
            let ports = byNode[nodeID] ?? []
            let entry = ErrorReport.entry(forNodeID:  nodeID,
                                          ports:      ports,
                                          messages:   Set(ports.compactMap(ErrorReport.reportableMessage)),
                                          database:   database)
            return ErrorRecord(entry)
        }
    }

    /// The installed tools per namespace, unrendered; the client prints them as config
    /// text. A namespace whose tool is missing has no descriptors, which the client
    /// prints as a comment. Both sources are dictionaries, so the order is imposed here.
    private func toolNamespaces() -> [ToolNamespaceRecord] {
        let installed = ToolRunnerRegistry.instance.registeredDescriptors

        return ToolNamespaceRegistry.all.map { entry in
            let machineSettings = entry.machineSettings()
            let descriptors = installed
                .filter { $0.name == entry.toolName }
                .sorted { ($0.version, $0.platform, $0.architecture) < ($1.version, $1.platform, $1.architecture) }
                .map { descriptor in
                    ToolDescriptorRecord(name:            descriptor.name,
                                         version:         descriptor.version,
                                         platform:        descriptor.platform,
                                         architecture:    descriptor.architecture,
                                         machineSettings: machineSettings)
                }
            return ToolNamespaceRecord(namespace: entry.namespace, toolName: entry.toolName, descriptors: descriptors)
        }
    }

    // MARK: - Events

    /// The engine's reports become events. The closures capture the handler weakly so an
    /// engine outliving its handler (tests swap handlers) does not keep it alive.
    private func installReporters() {
        engine.errorReporter = { [weak self] entries in
            self?.eventSink?.deliver(.daemon(.errors(records: entries.map(ErrorRecord.init))))
        }
        engine.noticeReporter = { [weak self] line in
            self?.eventSink?.deliver(.daemon(.notice(line: line)))
        }
    }

    // MARK: - Shared helpers for the file verbs

    /// The root folder of one of the two virtual file systems.
    func rootFolder(_ fileSystem: FileSystemKind) throws -> NodeRecord {
        switch fileSystem {
        case .input:  return try engine.inputFileSystem
        case .output: return try engine.outputFileSystem
        }
    }
}

/// A failure the handler can name precisely, thrown from a verb and turned into the
/// matching `ErrorResponse` by the dispatcher.
enum HandlerFailure: Error {
    case pathNotFound(path: String)
    case notAFolder(path: String)
    case node(description: String)

    var response: ErrorResponse {
        switch self {
        case .pathNotFound(let path):     return .pathNotFound(path: path)
        case .notAFolder(let path):       return .notAFolder(path: path)
        case .node(let description):      return .nodeError(description: description)
        }
    }
}

extension ErrorRecord {

    /// The wire form of an engine entry. Mirrored rather than shared, because the
    /// protocol package must not import the engine.
    init(_ entry: ErrorReport.Entry) {
        self.init(label:   entry.label,
                  entries: entry.items.map { ErrorEntry(ports: $0.ports, message: $0.message) })
    }
}
```

Until Task 6 exists, the four file verbs must compile. Add these stand-ins at the bottom of the file, in an extension Task 6 replaces entirely:

```swift
// MARK: - File verbs (replaced in RequestHandler+Files.swift)

extension RequestHandler {

    func list(fileSystem: FileSystemKind, pattern: String) throws -> DaemonResponse {
        throw HandlerFailure.node(description: "list is not implemented yet")
    }

    func pushFile(path: String, mode: UInt16, body: Data) throws -> DaemonResponse {
        throw HandlerFailure.node(description: "pushFile is not implemented yet")
    }

    func pushFolder(path: String) throws -> DaemonResponse {
        throw HandlerFailure.node(description: "pushFolder is not implemented yet")
    }

    func remove(pattern: String) throws -> DaemonResponse {
        throw HandlerFailure.node(description: "remove is not implemented yet")
    }

    func fetch(fileSystem: FileSystemKind, path: String) throws -> (DaemonResponse, Data?) {
        throw HandlerFailure.node(description: "fetch is not implemented yet")
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter RequestHandlerTests`
Expected: every test green.

- [ ] **Step 6: Commit**

```bash
git add semel/Server semel/ServerTests
git commit -m "Add the request handler: hello, batches, engine verbs and event routing

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 6: `RequestHandler` — list, push, remove, fetch

**Files:**
- Create: `semel/Server/RequestHandler+Files.swift`
- Modify: `semel/Server/RequestHandler.swift` (delete the stand-in extension)
- Create: `semel/ServerTests/RequestHandlerFileTests.swift`

**Interfaces:**
- Consumes: `RequestHandler.rootFolder(_:)`, `HandlerFailure`, `InternalFileSystemLister` (Task 1), `FileWildcardMatcher`.
- Produces: the five verbs with the signatures the stand-ins declared.

- [ ] **Step 1: Write the failing tests**

`semel/ServerTests/RequestHandlerFileTests.swift`:

```swift
//
//  RequestHandlerFileTests.swift
//  SemelServTests
//
//  The file verbs against a real in-memory graph: what the CLI's push, ls, rm and cp
//  become once the graph is on the other side of a wire.
//

@testable import SemelCore
@testable import SemelServ
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

final class RequestHandlerFileTests: RequestHandlerTestCase {

    // MARK: - push

    func test_pushFileCreatesTheFileAndItsFoldersAndReportsChange() throws {
        let (response, _) = try daemon(.pushFile(path: "src/main.c", mode: 0o644), body: Data("int main() {}".utf8))

        XCTAssertEqual(response, .pushFile(didChange: true))
        let root = try engine.inputFileSystem
        XCTAssertNotNil(try root.childNode(path: Path("src")))
        XCTAssertNotNil(try root.childNode(path: Path("src/main.c")))
    }

    func test_pushingTheSameBytesTwiceReportsNoChange() throws {
        try daemon(.pushFile(path: "a.c", mode: 0o644), body: Data("x".utf8))

        let (response, _) = try daemon(.pushFile(path: "a.c", mode: 0o644), body: Data("x".utf8))

        XCTAssertEqual(response, .pushFile(didChange: false))
    }

    func test_pushFolderCreatesAPinnedFolder() throws {
        let (response, _) = try daemon(.pushFolder(path: "src/lib"))

        XCTAssertEqual(response, .ok)
        XCTAssertNotNil(try engine.inputFileSystem.childNode(path: Path("src/lib")))
    }

    // MARK: - list

    func test_listReturnsFilesAndFoldersWithSizeAndMode() throws {
        try daemon(.pushFolder(path: "src"))
        try daemon(.pushFile(path: "src/main.c", mode: 0o644), body: Data("int main() {}".utf8))

        let (response, _) = try daemon(.list(fileSystem: .input, pattern: "src/*"))

        XCTAssertEqual(response, .list(entries: [
            ListEntry(path: "src/main.c", kind: .file, size: 13, mode: 0o644, status: .none),
        ]))
    }

    func test_listOfAFolderPatternReturnsTheFolderItself() throws {
        try daemon(.pushFolder(path: "src"))

        let (response, _) = try daemon(.list(fileSystem: .input, pattern: "src"))

        XCTAssertEqual(response, .list(entries: [ListEntry(path: "src", kind: .folder, size: nil, mode: nil, status: .none)]))
    }

    func test_listOfNothingIsEmpty() throws {
        XCTAssertEqual(try daemon(.list(fileSystem: .input, pattern: "nope")).0, .list(entries: []))
    }

    // MARK: - remove

    func test_removeDeletesMatchingFilesAndNamesThem() throws {
        try daemon(.pushFile(path: "a.c", mode: 0o644), body: Data("a".utf8))
        try daemon(.pushFile(path: "b.c", mode: 0o644), body: Data("b".utf8))

        let (response, _) = try daemon(.remove(pattern: "*.c"))

        guard case .remove(let removed) = response else {
            return XCTFail("expected remove, got \(response)")
        }
        XCTAssertEqual(removed.sorted(), ["a.c", "b.c"])
        // A removed file lingers as a ghost with no content, which `list` reports as missing.
        let (listed, _) = try daemon(.list(fileSystem: .input, pattern: "*.c"))
        guard case .list(let entries) = listed else {
            return XCTFail("expected list, got \(listed)")
        }
        XCTAssertTrue(entries.allSatisfy { $0.status == .missing || $0.status == .error }, "\(entries)")
    }

    func test_removeOfNothingReturnsNoPaths() throws {
        XCTAssertEqual(try daemon(.remove(pattern: "nope")).0, .remove(removedPaths: []))
    }

    // MARK: - fetch

    func test_fetchReturnsTheBytesAndMode() throws {
        try daemon(.pushFile(path: "a.c", mode: 0o644), body: Data("hello".utf8))

        let (response, body) = try daemon(.fetch(fileSystem: .input, path: "a.c"))

        XCTAssertEqual(response, .fetch(mode: FileMetadata.defaultMode))
        XCTAssertEqual(body, Data("hello".utf8))
    }

    func test_fetchOfAMissingPathIsPathNotFound() {
        XCTAssertEqual(daemonError(.fetch(fileSystem: .input, path: "nope")), .pathNotFound(path: "nope"))
    }

    func test_fetchOfAFolderIsNotAFile() throws {
        try daemon(.pushFolder(path: "src"))

        XCTAssertEqual(daemonError(.fetch(fileSystem: .input, path: "src")),
                       .nodeError(description: "Object src is not a file"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RequestHandlerFileTests`
Expected: every test fails with `nodeError("… is not implemented yet")`.

- [ ] **Step 3: Write the file verbs**

Delete the stand-in extension at the bottom of `RequestHandler.swift` (from `// MARK: - File verbs (replaced …)` to the end). Create `semel/Server/RequestHandler+Files.swift`:

```swift
// RequestHandler+Files.swift
// SemelServ
//
// The file verbs: what push, ls, rm and cp do to the graph. Paths arrive absolute within
// the named file system and already resolved by the client, so `..` never reaches here.

import Foundation
import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol

extension RequestHandler {

    // MARK: - list

    func list(fileSystem: FileSystemKind, pattern: String) throws -> DaemonResponse {
        let root    = try rootFolder(fileSystem)
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: root))
        let matches = try matcher.findAllMatching(pathOrWildcard: Path(pattern))

        return .list(entries: try matches.map { try listEntry(for: $0, in: root) })
    }

    /// What `ls` shows for one match. A file's size and mode come from its value; a file
    /// with no value keeps the default mode and says why it has none, unless the match
    /// already says it is missing or unreferenced, which is the more useful word.
    private func listEntry(for match: FileWildcardEntry, in root: NodeRecord) throws -> ListEntry {
        var status = EntryStatus.none
        if match.isMissing {
            status = .missing
        } else {
            if match.isUnreferenced {
                status = .unreferenced
            }
        }

        guard case .file = match.kind else {
            return ListEntry(path: match.path.string, kind: .folder, size: nil, mode: nil, status: status)
        }

        var size: Int?    = nil
        var mode: UInt16? = nil

        if let fileNode = try root.childNode(path: match.path),
           let file     = try fileNode.nodeAsAny() as? FileType,
           let value    = try file.read() {

            switch value {

            case .value(let hash):
                size = hash.size()
                if let provider = file as? FileMetadataProvider,
                   let metadata = try? provider.readFileMetadata() {
                    mode = metadata.mode ?? FileMetadata.defaultMode
                } else {
                    mode = FileMetadata.defaultMode
                }

            case .noValue(let reason):
                mode = FileMetadata.defaultMode
                if status == .none {
                    switch reason {
                    case .pending: status = .pending
                    case .error:   status = .error
                    }
                }
            }
        }

        return ListEntry(path: match.path.string, kind: .file, size: size, mode: mode, status: status)
    }

    // MARK: - push

    /// Interns the bytes and stores them at `path` in the input file system, creating the
    /// folders on the way. Returns whether the content changed.
    ///
    /// TODO: `mode` is carried on the wire but not stored — `StaticFile` has no metadata
    /// port, and push has never preserved modes. Wire it through when it gains one.
    func pushFile(path: String, mode: UInt16, body: Data) throws -> DaemonResponse {
        let relativePath = Path(path)
        let root         = try engine.inputFileSystem

        _ = try root.ensureEntirePathExistsAsFolders(relativePath.deletingLastComponent ?? .empty, pinned: true)

        let fullPath      = Path(FileSystemName.input) / relativePath
        let graphSpecNode = try GraphSpecNode.parse("StaticFile(path: '\(fullPath.string)')")
        let (fromNode, _) = try graphSpecNode.findOrCreateMatchingNode()

        guard let staticFile = try fromNode.nodeAsAny() as? StaticFile else {
            throw HandlerFailure.node(description: "push: \(path): the graph holds a non-file node at this path")
        }

        let didChange = try staticFile.replaceContent([UInt8](body).intern())
        return .pushFile(didChange: didChange)
    }

    func pushFolder(path: String) throws -> DaemonResponse {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path(path), pinned: true)
        return .ok
    }

    // MARK: - remove

    /// Deletes every match in the input file system. Deletions that succeed stand even if
    /// a later one fails; the failures are reported together so the client can say which.
    func remove(pattern: String) throws -> DaemonResponse {
        let root    = try engine.inputFileSystem
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: root))
        let matches = try matcher.findAllMatching(pathOrWildcard: Path(pattern))

        var removedPaths: [String] = []
        var failures:     [String] = []

        for match in matches {
            guard let child = try root.childNode(path: match.path) else {
                failures.append("Child not found: \(match.path)")
                continue
            }
            guard let deletable = try child.nodeAsAny() as? UserDeletable else {
                failures.append("Child not deletable: \(match.path)")
                continue
            }
            try deletable.deleteInInputFileSystem()
            removedPaths.append(match.path.string)
        }

        guard failures.isEmpty else {
            throw HandlerFailure.node(description: failures.joined(separator: "\n"))
        }
        return .remove(removedPaths: removedPaths)
    }

    // MARK: - fetch

    /// A file's bytes and mode. The bytes travel in the frame body.
    func fetch(fileSystem: FileSystemKind, path: String) throws -> (DaemonResponse, Data?) {
        let root = try rootFolder(fileSystem)

        guard let fileNode = try root.childNode(path: Path(path)) else {
            throw HandlerFailure.pathNotFound(path: path)
        }
        guard let file = try fileNode.nodeAsAny() as? FileType else {
            throw HandlerFailure.node(description: "Object \(path) is not a file")
        }

        switch try file.read() {

        case .value(let hash):
            var mode = FileMetadata.defaultMode
            if let provider = try fileNode.nodeAsAny() as? FileMetadataProvider,
               let metadata = try provider.readFileMetadata() {
                mode = metadata.mode ?? FileMetadata.defaultMode
            }
            return (.fetch(mode: mode), Data(try hash.resolve()))

        case .noValue(let reason):
            throw HandlerFailure.node(description: "File \(path) has no content: \(reason)")

        case nil:
            throw HandlerFailure.node(description: "File \(path) has a nil value")
        }
    }
}
```

- [ ] **Step 4: Run the server tests**

Run: `swift test --filter 'RequestHandler'`
Expected: all handler tests green, including Task 5's. If `test_removeDeletesMatchingFilesAndNamesThem`'s second assertion fails because the removed entries are no longer listed at all (the engine may garbage-collect unreferenced ghosts immediately when no processing loop runs), replace that assertion with `XCTAssertTrue(entries.isEmpty || entries.allSatisfy { $0.status == .missing || $0.status == .error })` and say so in your report — the removal itself is what the test pins.

- [ ] **Step 5: Commit**

```bash
git add semel/Server semel/ServerTests
git commit -m "Add the handler's file verbs: list, pushFile, pushFolder, remove and fetch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 7: `InProcessConnection`

**Files:**
- Create: `semel/Server/InProcessConnection.swift`
- Create: `semel/ServerTests/InProcessConnectionTests.swift`

**Interfaces:**
- Consumes: `RequestHandler`, `Session`, `EventSink`, `SemelConnection`, `Frame.request/response/event`, `FrameEncoder`, `FrameDecoder`.
- Produces: `public final class InProcessConnection: SemelConnection, EventSink` with `init(handler: RequestHandler)`, `let session: Session`.

- [ ] **Step 1: Write the failing tests**

`semel/ServerTests/InProcessConnectionTests.swift`:

```swift
//
//  InProcessConnectionTests.swift
//  SemelServTests
//
//  The pretend socket. It must put every message through the real codec — the point of
//  running one process in phase 2 is that the wire is exercised by every CLI test before
//  a socket exists — and it must let several threads have requests outstanding at once.
//

@testable import SemelCore
@testable import SemelServ
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

final class InProcessConnectionTests: RequestHandlerTestCase {

    private var connection: InProcessConnection!

    override func setUpWithError() throws {
        try super.setUpWithError()
        connection = InProcessConnection(handler: handler)
    }

    override func tearDown() {
        connection = nil
        super.tearDown()
    }

    func test_aRequestGetsItsReplyAndBodyThroughTheCodec() throws {
        _ = try connection.send(.daemon(.pushFile(path: "a.c", mode: 0o644)), body: Data("hi".utf8))

        let (response, body) = try connection.send(.daemon(.fetch(fileSystem: .input, path: "a.c")), body: nil)

        XCTAssertEqual(response, .daemon(.fetch(mode: FileMetadata.defaultMode)))
        XCTAssertEqual(body, Data("hi".utf8))
    }

    func test_helloIsAnsweredLikeAnyRequest() throws {
        let (response, _) = try connection.send(.hello(Hello(role: .daemon)), body: nil)

        XCTAssertEqual(response, .hello(.accepted(serverVersion: Semel.version, databasePath: "/tmp/test-graph.sqlite")))
    }

    func test_eventsReachOnEventOnlyAfterSubscribing() throws {
        var received: [Event] = []
        connection.onEvent = { received.append($0) }

        BuildEngine.notice("before")
        _ = try connection.send(.daemon(.subscribe), body: nil)
        BuildEngine.notice("after")

        XCTAssertEqual(received, [.daemon(.notice(line: "after"))])
    }

    /// Two threads, each sending its own kind of request repeatedly, must each get only
    /// its own kind of reply back. The handler is serial; the connection must still keep
    /// callers apart.
    func test_interleavedSendsFromSeparateThreadsGetTheirOwnReplies() throws {
        let group = DispatchGroup()
        let lock  = NSLock()
        var mismatches = 0

        for kind in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                for _ in 0..<50 {
                    let request: Request = kind == 0 ? .daemon(.tools) : .daemon(.debug)
                    guard let (response, _) = try? self.connection.send(request, body: nil) else {
                        lock.withLock { mismatches += 1 }
                        continue
                    }
                    let matches: Bool
                    switch (kind, response) {
                    case (0, .daemon(.tools)): matches = true
                    case (1, .daemon(.debug)): matches = true
                    default:                   matches = false
                    }
                    if !matches {
                        lock.withLock { mismatches += 1 }
                    }
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(mismatches, 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter InProcessConnectionTests`
Expected: compile failure, `InProcessConnection` does not exist.

- [ ] **Step 3: Write the connection**

`semel/Server/InProcessConnection.swift`:

```swift
// InProcessConnection.swift
// SemelServ
//
// A connection with no socket. It encodes every request to a frame and decodes it again
// before the handler sees it, and puts every reply through the same pair, so that the
// codec and the message set are exercised by every command a client sends long before a
// real transport exists. Handing the typed values straight across would make this a
// function call with extra steps and prove nothing.
//
// It is also the handler's event sink: an event becomes a frame, is decoded, and reaches
// `onEvent` — the same path a socket client will see.

import Foundation
import SemelProtocol

public final class InProcessConnection: SemelConnection, EventSink {

    public let session = Session()

    public var onEvent: ((Event) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    private let handler: RequestHandler
    private let lock = NSLock()
    private var eventHandler: ((Event) -> Void)?
    private var nextCorrelationID: UInt64 = 1

    public init(handler: RequestHandler) {
        self.handler = handler
        handler.eventSink = self
    }

    // MARK: - SemelConnection

    public func send(_ request: Request, body: Data?) throws -> (Response, Data?) {
        let correlationID = lock.withLock { () -> UInt64 in
            defer { nextCorrelationID += 1 }
            return nextCorrelationID
        }

        let requestFrame  = try roundTrip(try Frame.request(request, correlationID: correlationID, body: body ?? Data()))
        let (response, replyBody) = handler.handle(try requestFrame.request(), body: requestFrame.body, session: session)
        let responseFrame = try roundTrip(try Frame.response(response, correlationID: correlationID, body: replyBody ?? Data()))

        return (try responseFrame.response(), responseFrame.body.isEmpty ? nil : responseFrame.body)
    }

    // MARK: - EventSink

    public func deliver(_ event: Event) {
        guard session.isSubscribed, let eventHandler = onEvent else {
            return
        }
        // An event that cannot be framed is a bug in this package, not something a client
        // can act on; dropping it here is what a socket would do too.
        guard let frame = try? roundTrip(try Frame.event(event)), let decoded = try? frame.event() else {
            return
        }
        eventHandler(decoded)
    }

    // MARK: - The pretend wire

    /// Bytes out, bytes in: exactly what a socket would carry.
    private func roundTrip(_ frame: Frame) throws -> Frame {
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(frame))
        guard let decoded = try decoder.next() else {
            throw FrameError.unsupportedVersion(Frame.version)
        }
        return decoded
    }
}
```

The `guard let decoded … else { throw FrameError.unsupportedVersion(…) }` branch is unreachable — a whole frame was just appended — but Swift needs a throw there; do not add a new error case for an impossible path.

- [ ] **Step 4: Run the server tests**

Run: `swift test --filter 'InProcessConnectionTests|RequestHandler|SessionTests'`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add semel/Server semel/ServerTests
git commit -m "Add InProcessConnection, the pretend socket that still runs the codec

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 8: The CLI talks to a connection

**Files:**
- Modify: `semel/CommandInterpreter/CommandContext.swift`
- Modify: `semel/CommandInterpreter/CommandInterpreter.swift`
- Create: `semel/CommandInterpreter/Renderers.swift`
- Modify: `semel/CommandInterpreter/Plugins/EnginePlugin.swift`
- Modify: `semel/CommandInterpreter/Plugins/NavigationPlugin.swift`
- Modify: `semel/CommandInterpreter/Plugins/FilePlugin.swift`
- Create: `semel/Tests/RecordingConnection.swift`
- Create: `semel/Tests/EnginePluginTests.swift`
- Create: `semel/Tests/NavigationPluginTests.swift`
- Modify: `semel/Tests/FilePluginPathTests.swift` (construct over `InProcessConnection`)
- Modify: `semel/Tests/ToolsCommandTests.swift` (construct over `InProcessConnection`)
- Modify: `SemelCore/Sources/SemelCore/DebugPrint.swift` (remove the `printAll` shim)

**Interfaces:**
- Consumes: `SemelConnection`, all `SemelProtocol` types; `InProcessConnection` and `RequestHandler` (Tasks 5–7) for the converted integration tests.
- Produces: `protocol CommandContext` with `connection`, session state, output; `CommandContext.request(_:body:) throws -> (DaemonResponse, Data?)`; `struct ServerError: Error, CustomStringConvertible`; `CommandInterpreter.init(connection:baseDirectory:)`, `CommandInterpreter.connect() throws -> (serverVersion: String, databasePath: String)`; `ErrorRecordRenderer.lines(for:)`, `ToolNamespaceRenderer.text(for:)`; `FileSystemForCommand.kind` and `.rootName`.

- [ ] **Step 1: Write the fake connection and the failing plugin tests**

`semel/Tests/RecordingConnection.swift`:

```swift
//
//  RecordingConnection.swift
//  SemelCLITests
//
//  A connection that answers from a script and remembers what it was asked, so a plugin
//  can be tested on what it sends and how it renders the reply, with no engine anywhere.
//

@testable import SemelCLI
import Foundation
import SemelNodeKit
import SemelProtocol

final class RecordingConnection: SemelConnection {

    private(set) var requests: [(request: Request, body: Data?)] = []
    var responses: [(response: Response, body: Data?)] = []
    var onEvent: ((Event) -> Void)?

    func send(_ request: Request, body: Data?) throws -> (Response, Data?) {
        requests.append((request, body))
        guard !responses.isEmpty else {
            return (.daemon(.ok), nil)
        }
        let scripted = responses.removeFirst()
        return (scripted.response, scripted.body)
    }

    /// Queue one daemon reply.
    func reply(_ response: DaemonResponse, body: Data? = nil) {
        responses.append((.daemon(response), body))
    }

    var daemonRequests: [DaemonRequest] {
        requests.compactMap { entry in
            if case .daemon(let request) = entry.request { return request }
            return nil
        }
    }
}

/// A `CommandContext` over a fake connection that captures output instead of printing it.
final class TestCommandContext: CommandContext {

    let connection: any SemelConnection
    var baseDirectory: String
    var currentFileSystem: FileSystemForCommand = .input
    var currentDirectoryPath: Path = .empty

    private(set) var messages: [String] = []
    private(set) var errors: [String] = []

    var allOutput: [String] { messages + errors }

    init(connection: any SemelConnection, baseDirectory: String = NSTemporaryDirectory()) {
        self.connection    = connection
        self.baseDirectory = baseDirectory
    }

    func outputMessage(_ message: String) { messages.append(message) }
    func outputError(_ message: String)   { errors.append(message) }
}
```

The old `TestCommandContext` at the bottom of `semel/Tests/FilePluginPathTests.swift` conflicts with this one; delete it from that file now. Step 10 converts the rest of that file in this same task, so the test target compiles again before this task's tests run.

`semel/Tests/EnginePluginTests.swift`:

```swift
//
//  EnginePluginTests.swift
//  SemelCLITests
//
//  errors, reset, nudge, debug and tools over a scripted connection: what each sends and
//  how it renders what comes back.
//

@testable import SemelCLI
import SemelProtocol
import XCTest

final class EnginePluginTests: XCTestCase {

    private var connection: RecordingConnection!
    private var context: TestCommandContext!

    override func setUp() {
        super.setUp()
        connection = RecordingConnection()
        context    = TestCommandContext(connection: connection)
    }

    private func run(_ verb: String) throws {
        try EnginePlugin().handle(verb: verb, tokens: [], context: context)
    }

    func test_errorsWithNoneSaysSo() throws {
        connection.reply(.errors(records: []))

        try run("errors")

        XCTAssertEqual(connection.daemonRequests, [.errors])
        XCTAssertEqual(context.messages, ["No errors."])
    }

    func test_errorsRendersRecordsUnderACount() throws {
        connection.reply(.errors(records: [
            ErrorRecord(label: "StaticFile  'input:/a.c'", entries: [ErrorEntry(ports: ["errorLog", "output"], message: "boom")]),
        ]))

        try run("errors")

        XCTAssertEqual(context.messages, [
            "2 errors across 1 node:\n",
            "❌ StaticFile  'input:/a.c'",
            "   · errorLog, output: boom",
            "",
        ])
    }

    func test_resetSendsResetAndAnnouncesTheRebuild() throws {
        try run("reset")

        XCTAssertEqual(connection.daemonRequests, [.reset])
        XCTAssertEqual(context.messages, ["Rebuild started."])
    }

    func test_debugPrintsTheTextItGetsBack() throws {
        connection.reply(.debug(text: "BUILD GRAPH STATE (0 nodes)"))

        try run("debug")

        XCTAssertEqual(context.messages, ["BUILD GRAPH STATE (0 nodes)"])
    }

    func test_toolsRendersEachNamespaceAsConfigText() throws {
        connection.reply(.tools(namespaces: [
            ToolNamespaceRecord(namespace: "c.compiler", toolName: "clang", descriptors: []),
            ToolNamespaceRecord(namespace: "swift.compiler", toolName: "swiftc", descriptors: [
                ToolDescriptorRecord(name: "swiftc", version: "6.0", platform: "macOS", architecture: "arm64",
                                     machineSettings: ["sdk": "/x"]),
            ]),
        ]))

        try run("tools")

        XCTAssertEqual(context.messages, ["""
            // c.compiler: no clang is installed on this machine

            swift.compiler.toolDescriptor.name=swiftc
            swift.compiler.toolDescriptor.version=6.0
            swift.compiler.toolDescriptor.platform=macOS
            swift.compiler.toolDescriptor.architecture=arm64
            swift.compiler.sdk=/x
            """])
    }

    func test_aServerErrorIsThrownForTheInterpreterToPrint() {
        connection.responses.append((.error(.nodeError(description: "wire missing")), nil))

        XCTAssertThrowsError(try run("nudge")) { error in
            XCTAssertEqual((error as? ServerError)?.description, "wire missing")
        }
    }
}
```

`semel/Tests/NavigationPluginTests.swift`:

```swift
//
//  NavigationPluginTests.swift
//  SemelCLITests
//
//  ls, cd and pwd over a scripted connection. The rules that stay client-side — a single
//  matched folder is listed by its contents, a path is resolved against the current
//  directory before it is sent — are what these pin.
//

@testable import SemelCLI
import SemelNodeKit
import SemelProtocol
import XCTest

final class NavigationPluginTests: XCTestCase {

    private var connection: RecordingConnection!
    private var context: TestCommandContext!

    override func setUp() {
        super.setUp()
        connection = RecordingConnection()
        context    = TestCommandContext(connection: connection)
    }

    private func run(_ verb: String, _ tokens: [String] = []) throws {
        try NavigationPlugin().handle(verb: verb, tokens: tokens, context: context)
    }

    func test_pwdPrintsTheCurrentLocation() throws {
        context.currentDirectoryPath = Path("src")

        try run("pwd")

        XCTAssertEqual(context.messages, ["input:/src"])
    }

    func test_lsListsTheCurrentDirectoryWithModesAndSizes() throws {
        connection.reply(.list(entries: [
            ListEntry(path: "main.c", kind: .file,   size: 120, mode: 0o644, status: .none),
            ListEntry(path: "lib",    kind: .folder, size: nil, mode: nil,   status: .none),
        ]))

        try run("ls")

        XCTAssertEqual(connection.daemonRequests, [.list(fileSystem: .input, pattern: "*")])
        XCTAssertEqual(context.messages, [
            "d---------         -  lib/",
            "-rw-r--r--       120  main.c",
        ])
    }

    func test_lsOfASingleFolderListsItsContents() throws {
        connection.reply(.list(entries: [ListEntry(path: "src", kind: .folder, size: nil, mode: nil, status: .none)]))
        connection.reply(.list(entries: [ListEntry(path: "src/a.c", kind: .file, size: 1, mode: 0o644, status: .pending)]))

        try run("ls", ["src"])

        XCTAssertEqual(connection.daemonRequests, [
            .list(fileSystem: .input, pattern: "src"),
            .list(fileSystem: .input, pattern: "src/*"),
        ])
        XCTAssertEqual(context.messages, ["-rw-r--r--         1  a.c  [pending]"])
    }

    func test_lsWithAnExplicitFileSystemIsRootRelative() throws {
        context.currentDirectoryPath = Path("src")
        connection.reply(.list(entries: []))

        try run("ls", ["-o", "*.o"])

        XCTAssertEqual(connection.daemonRequests, [.list(fileSystem: .output, pattern: "*.o")])
        XCTAssertEqual(context.messages, ["(empty)"])
    }

    func test_cdIntoAFolderChangesTheDirectory() throws {
        connection.reply(.list(entries: [ListEntry(path: "src", kind: .folder, size: nil, mode: nil, status: .none)]))

        try run("cd", ["src"])

        XCTAssertEqual(connection.daemonRequests, [.list(fileSystem: .input, pattern: "src")])
        XCTAssertEqual(context.currentDirectoryPath, Path("src"))
        XCTAssertEqual(context.messages, ["input:/src"])
    }

    func test_cdIntoAMissingFolderIsAnError() throws {
        connection.reply(.list(entries: []))

        try run("cd", ["nope"])

        XCTAssertEqual(context.currentDirectoryPath, .empty)
        XCTAssertEqual(context.errors, ["cd: nope: no such directory"])
    }

    func test_cdWithAFileSystemFlagGoesToItsRoot() throws {
        context.currentDirectoryPath = Path("src")

        try run("cd", ["-o"])

        XCTAssertEqual(context.currentFileSystem, .output)
        XCTAssertEqual(context.currentDirectoryPath, .empty)
        XCTAssertEqual(context.messages, ["output:"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'EnginePluginTests|NavigationPluginTests'`
Expected: compile failure (`TestCommandContext(connection:)`, `ServerError`, `ToolNamespaceRecord` rendering do not exist; `CommandContext` still requires `database`).

- [ ] **Step 3: Rewrite `CommandContext`**

Replace `semel/CommandInterpreter/CommandContext.swift` with:

```swift
// CommandContext.swift
// semel
//
// What a command plugin sees: the session's state, a way to print, and one connection to
// whatever holds the graph. Nothing here knows whether that is the same process or a
// socket away.

import Foundation
import SemelNodeKit
import SemelProtocol

protocol CommandContext: AnyObject {
    var connection: any SemelConnection { get }
    var baseDirectory: String { get set }
    var currentFileSystem: FileSystemForCommand { get set }
    var currentDirectoryPath: Path { get set }
    func outputMessage(_ message: String)
    func outputError(_ message: String)
}

/// A failure the server reported. Thrown by `request` so the interpreter prints it the way
/// it prints any command failure.
struct ServerError: Error, CustomStringConvertible {
    let response: ErrorResponse

    var description: String {
        switch response {
        case .pathNotFound(let path):          return "\(path): no such file or directory"
        case .notAFolder(let path):            return "\(path): not a directory"
        case .nodeError(let description):      return description
        case .roleNotOffered(let role):        return "the server does not offer the \(role.rawValue) role"
        case .malformedRequest(let description): return "the server could not read the request: \(description)"
        case .unrecoverable(let message):      return "the server stopped: \(message)"
        }
    }
}

extension CommandContext {

    var currentLocation: String {
        let fsName = currentFileSystem.rootName
        return currentDirectoryPath.isEmpty ? fsName : "\(fsName)/\(currentDirectoryPath)"
    }

    /// Sends one daemon request and unwraps the daemon reply. A server-reported failure
    /// becomes a thrown `ServerError`; any other kind of reply is a protocol bug.
    func request(_ request: DaemonRequest, body: Data? = nil) throws -> (DaemonResponse, Data?) {
        let (response, replyBody) = try connection.send(.daemon(request), body: body)
        switch response {
        case .daemon(let daemonResponse):
            return (daemonResponse, replyBody)
        case .error(let error):
            throw ServerError(response: error)
        case .hello:
            throw ServerError(response: .malformedRequest(description: "a hello reply to a daemon request"))
        }
    }

    /// Resolves a user-supplied path string relative to `base`, handling `..` and `.`.
    /// A leading `/` is treated as the root of the current internal file system.
    func resolve(_ pathStr: String, relativeTo base: Path) -> Path {
        let isAbsolute = pathStr.hasPrefix("/")
        var segments = isAbsolute ? [] : base.segments
        for seg in Path(isAbsolute ? String(pathStr.dropFirst()) : pathStr).segments {
            switch seg {
            case "..": if !segments.isEmpty { segments.removeLast() }
            case ".":  break
            default:   segments.append(seg)
            }
        }
        return Path(segments: segments)
    }

    /// Returns the portion of `path` after `base`, falling back to the full path string.
    func relativeName(_ path: Path, to base: Path) -> String {
        path.relative(to: base)?.string ?? path.string
    }
}

// MARK: - CommandPlugin

protocol CommandPlugin {
    /// The verb strings this plugin handles (e.g. `["ls", "list"]`).
    var verbs: Set<String> { get }

    /// Parse `tokens` (everything after the verb) and execute the command.
    func handle(verb: String, tokens: [String], context: any CommandContext) throws
}

extension CommandPlugin {
    /// Consume a required `-i`/`-o` flag. Defaults to `.input` when absent.
    func parseFileSystemFlag(tokens: [String]) -> (FileSystemForCommand, [String]) {
        guard let first = tokens.first else {
            return (.input, tokens)
        }
        switch first {
        case "-i", "--input":  return (.input,  Array(tokens.dropFirst()))
        case "-o", "--output": return (.output, Array(tokens.dropFirst()))
        default:               return (.input,  tokens)
        }
    }

    /// Consume an optional `-i`/`-o` flag, returning `nil` when absent so callers
    /// can distinguish an explicit choice from "use current file system".
    func parseOptionalFileSystemFlag(tokens: [String]) -> (FileSystemForCommand?, [String]) {
        guard let first = tokens.first else {
            return (nil, tokens)
        }
        switch first {
        case "-i", "--input":  return (.input,  Array(tokens.dropFirst()))
        case "-o", "--output": return (.output, Array(tokens.dropFirst()))
        default:               return (nil,     tokens)
        }
    }
}
```

- [ ] **Step 4: Rewrite `CommandInterpreter`**

Replace `semel/CommandInterpreter/CommandInterpreter.swift` with:

```swift
// CommandInterpreter.swift
// semel

import Foundation
import SemelNodeKit
import SemelProtocol

enum CommandInterpreterError: Error {
    case quit
}

/// A rejected handshake, with what the server said so the user can act on it.
public enum ConnectError: Error, CustomStringConvertible {
    case rejected(HelloRejection)
    case unexpectedReply

    public var description: String {
        switch self {
        case .rejected(.versionMismatch(let client, let server)):
            return "this semel speaks protocol version \(client) but the server speaks \(server)"
        case .rejected(.roleNotOffered(let role)):
            return "the server does not offer the \(role.rawValue) role"
        case .unexpectedReply:
            return "the server did not answer the handshake"
        }
    }
}

public final class CommandInterpreter: CommandContext {

    let connection: any SemelConnection
    var baseDirectory: String
    var currentFileSystem: FileSystemForCommand = .input
    var currentDirectoryPath: Path = .empty

    func outputMessage(_ message: String) { print(message) }
    func outputError(_ errorMessage: String) { print(errorMessage) }

    private let plugins: [any CommandPlugin]

    private lazy var verbMap: [String: any CommandPlugin] = {
        var map: [String: any CommandPlugin] = [:]
        for plugin in plugins {
            for verb in plugin.verbs { map[verb] = plugin }
        }
        return map
    }()

    public convenience init(connection: any SemelConnection,
                            baseDirectory: String = FileManager.default.currentDirectoryPath) {
        self.init(connection: connection,
                  baseDirectory: baseDirectory,
                  plugins: [NavigationPlugin(), FilePlugin(), EnginePlugin(), SessionPlugin()])
    }

    required init(connection: any SemelConnection,
                  baseDirectory: String,
                  plugins: [any CommandPlugin]) {
        self.connection    = connection
        self.baseDirectory = baseDirectory
        self.plugins       = plugins
    }

    // MARK: - Handshake

    /// Says hello, subscribes to events, and starts printing them. Returns what the banner
    /// needs. Events arrive on the connection's thread, which is where the engine used to
    /// print from when it shared a process with the REPL.
    public func connect() throws -> (serverVersion: String, databasePath: String) {
        let (reply, _) = try connection.send(.hello(Hello(role: .daemon)), body: nil)
        guard case .hello(let helloResponse) = reply else {
            throw ConnectError.unexpectedReply
        }
        switch helloResponse {
        case .rejected(let reason):
            throw ConnectError.rejected(reason)
        case .accepted(let serverVersion, let databasePath):
            connection.onEvent = { [weak self] event in self?.printEvent(event) }
            _ = try request(.subscribe)
            return (serverVersion, databasePath)
        }
    }

    private func printEvent(_ event: Event) {
        switch event {
        case .daemon(.errors(let records)):
            records.flatMap(ErrorRecordRenderer.lines(for:)).forEach { outputMessage($0) }
        case .daemon(.notice(let line)):
            outputMessage(line)
        }
    }

    // MARK: - Commands

    public func handleCommand(_ command: String) throws {
        var tokens = tokenize(command)
        guard !tokens.isEmpty else {
            return
        }
        if tokens.first == "semel" { tokens.removeFirst() }
        guard let verb = tokens.first else {
            return
        }
        let remaining = Array(tokens.dropFirst())

        do {
            guard let plugin = verbMap[verb] else {
                throw CommandParserError.unknownCommand(verb)
            }
            try plugin.handle(verb: verb, tokens: remaining, context: self)
        } catch CommandInterpreterError.quit {
            throw CommandInterpreterError.quit
        } catch let error as ServerError {
            outputError(error.description)
        } catch {
            outputError(error.localizedDescription)
        }
    }

    // MARK: - Tokenizer

    private func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in command {
            if char == "\"" {
                inQuotes.toggle()
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

enum FileSystemForCommand {
    case input
    case output

    /// The wire's name for this file system.
    var kind: FileSystemKind {
        switch self {
        case .input:  return .input
        case .output: return .output
        }
    }

    /// The root segment every path in it begins with.
    var rootName: String {
        switch self {
        case .input:  return FileSystemName.input
        case .output: return FileSystemName.output
        }
    }
}

enum CommandParserError: Error, LocalizedError {
    case unknownCommand(String)
    case missingArgument(command: String, expected: String)
    case tooManyArguments(command: String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let cmd):
            return "Unknown command: \(cmd)"
        case .missingArgument(let cmd, let expected):
            return "\(cmd): missing argument (\(expected))"
        case .tooManyArguments(let cmd):
            return "\(cmd): too many arguments"
        }
    }
}
```

The tokenizer keeps its existing `else if` chain: it is untouched code, not new, and AGENTS.md says to tidy such things only when editing that code.

- [ ] **Step 5: Write the renderers**

`semel/CommandInterpreter/Renderers.swift`:

```swift
// Renderers.swift
// semel
//
// How structured replies become text. These are the client's twins of renderers the
// engine keeps for its own terminal: `ErrorRecordRenderer` matches `ErrorReport.lines`
// line for line, and both sides' tests pin the format so they cannot drift apart.

import Foundation
import SemelProtocol

enum ErrorRecordRenderer {

    /// A heading, then one line per distinct message naming the ports that carry it, or
    /// an indented block when a message spans lines. Ends with a blank line.
    static func lines(for record: ErrorRecord) -> [String] {
        var result = ["❌ \(record.label)"]

        for entry in record.entries {
            let portNames = entry.ports.joined(separator: ", ")

            let body = entry.message
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard !body.isEmpty else {
                result.append("   · \(portNames): (no details)")
                continue
            }

            if body.count == 1 {
                result.append("   · \(portNames): \(body[0])")
            } else {
                result.append("   · \(portNames):")
                result.append(contentsOf: body.map { "     \($0)" })
            }
        }

        result.append("")
        return result
    }
}

enum ToolNamespaceRenderer {

    /// The installed tools as the settings a `semel.config` needs — one block per
    /// namespace that names the tool, so choosing a toolchain version is a paste. A
    /// namespace whose tool is missing prints as a comment, so the whole output is safe
    /// to paste and still says what is absent.
    static func text(for namespaces: [ToolNamespaceRecord]) -> String {
        var blocks: [String] = []

        for namespace in namespaces {
            guard !namespace.descriptors.isEmpty else {
                blocks.append("// \(namespace.namespace): no \(namespace.toolName) is installed on this machine")
                continue
            }

            for descriptor in namespace.descriptors {
                var lines = [
                    "\(namespace.namespace).toolDescriptor.name=\(descriptor.name)",
                    "\(namespace.namespace).toolDescriptor.version=\(descriptor.version)",
                    "\(namespace.namespace).toolDescriptor.platform=\(descriptor.platform)",
                    "\(namespace.namespace).toolDescriptor.architecture=\(descriptor.architecture)",
                ]
                for key in descriptor.machineSettings.keys.sorted() {
                    lines.append("\(namespace.namespace).\(key)=\(descriptor.machineSettings[key]!)")
                }
                blocks.append(lines.joined(separator: "\n"))
            }
        }

        return blocks.joined(separator: "\n\n")
    }
}
```

- [ ] **Step 6: Rewrite `EnginePlugin`**

Replace `semel/CommandInterpreter/Plugins/EnginePlugin.swift` with:

```swift
// EnginePlugin.swift
// semel
//
// Handles: d / debug, n / nudge, e / errors, reset, t / tools

import Foundation
import SemelProtocol

final class EnginePlugin: CommandPlugin {

    let verbs: Set<String> = ["d", "debug", "n", "nudge", "e", "errors", "reset", "t", "tools"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "d", "debug":  try handleDebug(context: context)
        case "n", "nudge":  _ = try context.request(.nudge)
        case "e", "errors": try handleErrors(context: context)
        case "reset":       try handleReset(context: context)
        case "t", "tools":  try handleTools(context: context)
        default:            break
        }
    }

    // MARK: - debug

    private func handleDebug(context: any CommandContext) throws {
        guard case .debug(let text) = try context.request(.debug).0 else {
            return
        }
        context.outputMessage(text)
    }

    // MARK: - tools

    private func handleTools(context: any CommandContext) throws {
        guard case .tools(let namespaces) = try context.request(.tools).0 else {
            return
        }
        if namespaces.isEmpty {
            context.outputMessage("No toolchains are registered.")
        } else {
            context.outputMessage(ToolNamespaceRenderer.text(for: namespaces))
        }
    }

    // MARK: - reset

    private func handleReset(context: any CommandContext) throws {
        _ = try context.request(.reset)
        context.outputMessage("Rebuild started.")
    }

    // MARK: - errors

    private func handleErrors(context: any CommandContext) throws {
        guard case .errors(let records) = try context.request(.errors).0 else {
            return
        }

        if records.isEmpty {
            context.outputMessage("No errors.")
            return
        }

        let errorCount = records.reduce(0) { $0 + $1.entries.reduce(0) { $0 + $1.ports.count } }
        let nodeCount  = records.count

        context.outputMessage("\(errorCount) error\(errorCount == 1 ? "" : "s") across " +
                              "\(nodeCount) node\(nodeCount == 1 ? "" : "s"):\n")

        for record in records {
            ErrorRecordRenderer.lines(for: record).forEach { context.outputMessage($0) }
        }
    }
}
```

`errorCount` counts ports carrying a reportable message; a port carrying only the `initializing` placeholder is no longer counted, which is a small, deliberate change — the placeholder was never printed either.

- [ ] **Step 7: Rewrite `NavigationPlugin`**

Replace `semel/CommandInterpreter/Plugins/NavigationPlugin.swift` with:

```swift
// NavigationPlugin.swift
// semel
//
// Handles: cd, pwd, ls / list

import Foundation
import SemelNodeKit
import SemelProtocol

final class NavigationPlugin: CommandPlugin {

    let verbs: Set<String> = ["cd", "pwd", "ls", "list"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "cd":
            let (folder, remaining) = parseOptionalFileSystemFlag(tokens: tokens)
            try handleCd(folder: folder, path: remaining.first, context: context)
        case "pwd":
            context.outputMessage(context.currentLocation)
        case "ls", "list":
            let (folder, remaining) = parseOptionalFileSystemFlag(tokens: tokens)
            try handleList(folder: folder, pathOrWildcard: remaining.first, context: context)
        default:
            break
        }
    }

    // MARK: - Listing

    /// One `list` request, unwrapped.
    private func list(_ pattern: Path, in fileSystem: FileSystemForCommand,
                      context: any CommandContext) throws -> [ListEntry] {
        guard case .list(let entries) = try context.request(.list(fileSystem: fileSystem.kind, pattern: pattern.string)).0 else {
            return []
        }
        return entries
    }

    // MARK: - cd

    private func handleCd(folder: FileSystemForCommand?, path: String?,
                          context: any CommandContext) throws {
        if let folder {
            context.currentFileSystem = folder
            context.currentDirectoryPath = .empty
        }

        if let path, !path.isEmpty {
            let newPath = context.resolve(path, relativeTo: context.currentDirectoryPath)

            if !newPath.isEmpty {
                let matches = try list(newPath, in: context.currentFileSystem, context: context)

                guard matches.count == 1, matches[0].kind == .folder else {
                    context.outputError("cd: \(path): no such directory")
                    return
                }
            }

            context.currentDirectoryPath = newPath
        }

        context.outputMessage(context.currentLocation)
    }

    // MARK: - ls

    private func handleList(folder: FileSystemForCommand?, pathOrWildcard: String?,
                            context: any CommandContext) throws {

        let targetFS = folder ?? context.currentFileSystem
        let base: Path = folder != nil ? .empty : context.currentDirectoryPath

        let results: [ListEntry]
        let displayBase: Path

        if let pattern = pathOrWildcard {
            let fullPattern = base.isEmpty ? Path(pattern) : base / pattern

            if fullPattern.containsWildcard {
                let staticSegs = fullPattern.segments.prefix(while: {
                    !$0.contains("*") && !$0.contains("?") && $0 != "**"
                })
                displayBase = Path(segments: Array(staticSegs))
                results = try list(fullPattern, in: targetFS, context: context)
            } else {
                let initial = try list(fullPattern, in: targetFS, context: context)
                if initial.count == 1, initial[0].kind == .folder {
                    displayBase = Path(initial[0].path)
                    results = try list(displayBase / "*", in: targetFS, context: context)
                } else {
                    displayBase = fullPattern.deletingLastComponent.map { Path(segments: $0.segments) } ?? .empty
                    results = initial
                }
            }
        } else {
            let pattern = base.isEmpty ? Path("*") : base / "*"
            displayBase = base
            results = try list(pattern, in: targetFS, context: context)
        }

        if results.isEmpty {
            context.outputMessage("(empty)")
            return
        }

        let sorted = results.sorted {
            if $0.kind != $1.kind { return $0.kind == .folder }
            return $0.path.lowercased() < $1.path.lowercased()
        }

        for entry in sorted {
            let name = context.relativeName(Path(entry.path), to: displayBase)

            var statusNote = ""
            switch entry.status {
            case .none:         break
            case .missing:      statusNote = "  [missing]"
            case .unreferenced: statusNote = "  [unreferenced]"
            case .pending:      statusNote = "  [pending]"
            case .error:        statusNote = "  [error]"
            }

            if entry.kind == .folder {
                context.outputMessage("\(Self.modeString(0, isDirectory: true))  \(Self.noSize)  \(name)/\(statusNote)")
                continue
            }

            let modeStr = Self.modeString(entry.mode ?? 0)
            let sizeStr = entry.size.map { String(format: "%8d", $0) } ?? Self.noSize

            context.outputMessage("\(modeStr)  \(sizeStr)  \(name)\(statusNote)")
        }
    }

    private static let noSize = "       -"

    private static func modeString(_ mode: UInt16, isDirectory: Bool = false) -> String {
        String([
            isDirectory ? Character("d") : Character("-"),
            mode & 0o400 != 0 ? "r" : "-",
            mode & 0o200 != 0 ? "w" : "-",
            mode & 0o100 != 0 ? "x" : "-",
            mode & 0o040 != 0 ? "r" : "-",
            mode & 0o020 != 0 ? "w" : "-",
            mode & 0o010 != 0 ? "x" : "-",
            mode & 0o004 != 0 ? "r" : "-",
            mode & 0o002 != 0 ? "w" : "-",
            mode & 0o001 != 0 ? "x" : "-",
        ] as [Character])
    }
}
```

- [ ] **Step 8: Rewrite `FilePlugin`**

Replace `semel/CommandInterpreter/Plugins/FilePlugin.swift` with:

```swift
// FilePlugin.swift
// semel
//
// Handles: push, rm / remove, cp / copy

import Foundation
import SemelNodeKit
import SemelProtocol

final class FilePlugin: CommandPlugin {

    let verbs: Set<String> = ["push", "rm", "remove", "cp", "copy"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "push":
            guard let path = tokens.first else {
                throw CommandParserError.missingArgument(command: "push", expected: "pathOrWildcard")
            }
            try handlePush(externalPathOrWildcard: path, context: context)

        case "rm", "remove":
            guard let path = tokens.first else {
                throw CommandParserError.missingArgument(command: "rm", expected: "pathOrWildcard")
            }
            try handleRemove(pathOrWildcard: path, context: context)

        case "cp", "copy":
            let (folder, remaining) = parseOptionalFileSystemFlag(tokens: tokens)
            guard remaining.count >= 1 else {
                throw CommandParserError.missingArgument(command: "cp",
                                                         expected: "pathOrWildcard [destinationPath]")
            }
            try handleCopy(folder: folder, pathOrWildcard: remaining[0],
                           destinationPath: remaining.count >= 2 ? remaining[1] : nil,
                           context: context)

        default:
            break
        }
    }

    // MARK: - push

    private func handlePush(externalPathOrWildcard: String, context: any CommandContext) throws {
        // The matcher is rooted at baseDirectory, and Path drops a leading slash, so an
        // absolute path would silently be reinterpreted as relative and match nothing.
        // Say so instead of doing nothing.
        guard !externalPathOrWildcard.hasPrefix("/"), !externalPathOrWildcard.hasPrefix("~") else {
            context.outputError("push: \(externalPathOrWildcard): only paths under \(context.baseDirectory) can be pushed")
            return
        }

        // Resolve the user-supplied wildcard relative to the internal current directory
        // so that "push *.c" from "src/a" reads baseDirectory/src/a/*.c and stores
        // the files at input:/src/a/*.c.  `resolve` also folds away "." and "..".
        let effectiveWildcard = context.resolve(externalPathOrWildcard,
                                                relativeTo: context.currentDirectoryPath)

        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: context.baseDirectory))
        let entries = try matcher.findAllMatching(pathOrWildcard: effectiveWildcard)

        guard !entries.isEmpty else {
            context.outputError("push: \(externalPathOrWildcard): no such file or directory")
            return
        }

        // Decide the whole work list before pushing any of it, so a file that is matched
        // twice is still pushed once. A wildcard reaching into subdirectories matches a
        // directory *and* the files inside it, and pushing a directory means pushing its
        // contents — so both readings arrive at the same file. Pushing as we matched would
        // report the second arrival as "[no change]" against a file nothing had changed,
        // which makes the report describe the matching rather than what happened.
        var alreadyQueued = Set<String>()
        var work: [FileWildcardEntry] = []
        for entry in entries {
            for expanded in try expand(entry, baseDirectory: context.baseDirectory) {
                if alreadyQueued.insert(expanded.path.string).inserted {
                    work.append(expanded)
                }
            }
        }

        // One batch around the whole push, so the engine coalesces its work signals.
        _ = try context.request(.beginBatch)
        defer { _ = try? context.request(.endBatch) }

        try work.forEach { entry in
            try pushOne(entry, baseDirectory: context.baseDirectory, context: context)
        }
    }

    /// A matched entry, plus everything pushing it implies.
    ///
    /// A directory stands for itself and every file beneath it: a bare `push src` has no
    /// wildcard enumerating its contents, so without this it would create an empty folder.
    private func expand(_ entry: FileWildcardEntry,
                        baseDirectory: String) throws -> [FileWildcardEntry] {

        guard case .folder = entry.kind else {
            return [entry]
        }

        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: baseDirectory))

        let contents = try matcher.findAllMatching(pathOrWildcard: entry.path.string + "/**/*")
            .filter {
                if case .file = $0.kind {
                    return true
                } else {
                    return false
                }
            }

        return [entry] + contents
    }

    private func pushOne(_ entry: FileWildcardEntry, baseDirectory: String,
                         context: any CommandContext) throws {

        let relativePath = entry.path

        switch entry.kind {

        case .file:
            let absolutePath = (baseDirectory as NSString).appendingPathComponent(relativePath.string)

            // The matcher listed this file a moment ago, but it can be deleted or made
            // unreadable in between — that is a report-and-continue, not a crash.
            let fileContent: Data
            do {
                fileContent = try Data(contentsOf: URL(fileURLWithPath: absolutePath))
            } catch {
                context.outputError("push: \(relativePath): \(error.localizedDescription)")
                return
            }

            let mode = Self.mode(ofFileAt: absolutePath)

            guard case .pushFile(let didChange) = try context.request(.pushFile(path: relativePath.string, mode: mode),
                                                                       body: fileContent).0 else {
                return
            }
            context.outputMessage("Push file: \(relativePath) \(didChange ? "" : "[no change]")")

        case .folder:
            // Just the folder. Its contents are separate entries in the work list, put
            // there by `expand`, so that a file reachable both directly and through its
            // folder is still pushed once.
            context.outputMessage("Push folder: \(relativePath)")
            _ = try context.request(.pushFolder(path: relativePath.string))
        }
    }

    /// The file's permission bits, or the default when they cannot be read.
    private static func mode(ofFileAt absolutePath: String) -> UInt16 {
        let attributes  = try? FileManager.default.attributesOfItem(atPath: absolutePath)
        let permissions = attributes?[.posixPermissions] as? NSNumber
        return permissions.map { UInt16(truncatingIfNeeded: $0.intValue) } ?? FileMetadata.defaultMode
    }

    // MARK: - rm

    private func handleRemove(pathOrWildcard: String, context: any CommandContext) throws {
        let base = context.currentDirectoryPath
        let fullPattern: Path = base.isEmpty ? Path(pathOrWildcard) : base / pathOrWildcard

        guard case .remove(let removedPaths) = try context.request(.remove(pattern: fullPattern.string)).0 else {
            return
        }

        if removedPaths.isEmpty {
            context.outputError("rm: \(pathOrWildcard): no such file or directory")
        }
    }

    // MARK: - cp

    private func handleCopy(folder: FileSystemForCommand?, pathOrWildcard: String,
                            destinationPath: String?, context: any CommandContext) throws {
        // An explicit -i/-o names a file system the current directory does not belong
        // to, so the source pattern is root-relative in that case (same rule as `ls`).
        let targetFS   = folder ?? context.currentFileSystem
        let base: Path = folder != nil ? .empty : context.currentDirectoryPath

        // `resolve` folds away "." and "..", and treats a leading "/" as the root of
        // the internal file system.
        let fullPattern = context.resolve(pathOrWildcard, relativeTo: base)

        // The destination is an external OS path, so it follows the same rules as every
        // other external path the user types: "~" expands, relative is relative to the
        // process working directory.
        let externalDest = ExternalPathSanitizer.expandPartialPath(destinationPath ?? ".")

        guard case .list(let entries) = try context.request(.list(fileSystem: targetFS.kind, pattern: fullPattern.string)).0 else {
            return
        }

        guard !entries.isEmpty else {
            context.outputError("cp: \(pathOrWildcard): no such file or directory")
            return
        }

        for entry in entries where entry.kind == .file {
            do {
                try copyOneFile(entry, from: targetFS, destinationPath: externalDest, context: context)
            } catch {
                context.outputError("cp: \(entry.path): \(error)")
            }
        }
    }

    private func copyOneFile(_ entry: ListEntry, from fileSystem: FileSystemForCommand,
                             destinationPath: String, context: any CommandContext) throws {
        let (response, body) = try context.request(.fetch(fileSystem: fileSystem.kind, path: entry.path))

        guard case .fetch(let mode) = response, let body else {
            context.outputError("File \(entry.path) has no content")
            return
        }

        let path      = Path(entry.path)
        let finalPath = destinationPath + "/" + (path.lastComponent ?? path.string)
        try body.write(to: URL(fileURLWithPath: finalPath))
        chmod(finalPath, mode_t(mode))
        context.outputMessage("File written: \(finalPath)")
    }
}
```

`ExternalPathSanitizer` is unchanged. `SessionPlugin` is unchanged (it imports only `SemelNodeKit` and Foundation).

- [ ] **Step 9: Remove the `printAll` shim from Core**

Nothing calls it any more. Delete the three-line `printAll()` shim Task 3 left below `graphDescription()` in `SemelCore/Sources/SemelCore/DebugPrint.swift`, then:

Run: `grep -n 'print(' SemelCore/Sources/SemelCore/DebugPrint.swift` — expected: no output. Then `swift test --package-path SemelCore` — expected: green.

- [ ] **Step 10: Convert the two existing integration test files to run over the real engine through the codec**

In `semel/Tests/FilePluginPathTests.swift`, each test class's `setUpWithError` builds a `DatabaseLayer`, a `BuildEngine`, and `TestCommandContext(database:baseDirectory:)`. In every class in the file, replace that construction with:

```swift
        let database = try DatabaseLayer()
        let engine   = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        let handler  = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        connection   = InProcessConnection(handler: handler)
        context      = TestCommandContext(connection: connection, baseDirectory: externalRoot.path)
```

adding `private var connection: InProcessConnection!` beside `context` in each class, `connection = nil` in each `tearDown`, and `import SemelServ` and `import SemelProtocol` at the top. Wherever a test reached into the graph through `context.database` or `context.inputFileSystem`, use `BuildEngine.shared.database` and `BuildEngine.shared.inputFileSystem` instead (`database` is internal to `SemelCore`; keep `@testable import SemelCore`). Wherever a test asserted on `context.messages` or `context.errors`, the strings are unchanged. Do not change what any test asserts.

In `semel/Tests/ToolsCommandTests.swift`, replace the last line of `setUpWithError` (`context = TestCommandContext(database: database, baseDirectory: NSTemporaryDirectory())`) with:

```swift
        let handler = RequestHandler(engine: BuildEngine.shared, database: database, databasePath: "/tmp/test-graph.sqlite")
        connection  = InProcessConnection(handler: handler)
        context     = TestCommandContext(connection: connection, baseDirectory: NSTemporaryDirectory())
```

add `private var connection: InProcessConnection!`, `connection = nil` in `tearDown`, and `import SemelServ` / `import SemelProtocol`. `runTools()` and every assertion stay as they are: the rendered text is produced by `ToolNamespaceRenderer` from records the handler built out of the same registries, so it must be identical.

- [ ] **Step 11: Build and run the root suite**

Run: `swift build` then `swift test`
Expected: the root package builds; `SemelCLITests` (new plugin tests, the two converted files, the formula and configuration tests that never used the plugins) and `SemelServTests` all green.

- [ ] **Step 12: Commit**

```bash
git add SemelCore/Sources/SemelCore/DebugPrint.swift semel/CommandInterpreter semel/Tests
git commit -m "Give the command plugins a connection instead of the engine

CommandContext hands out a SemelConnection; plugins keep parsing, path
resolution and formatting, and send a request for the graph work.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 9: File plugin tests over the fake connection

**Files:**
- Create: `semel/Tests/FilePluginTests.swift`

**Interfaces:**
- Consumes: `RecordingConnection`, `TestCommandContext(connection:baseDirectory:)` from Task 8.

- [ ] **Step 1: Write the failing file plugin tests**

`semel/Tests/FilePluginTests.swift`:

```swift
//
//  FilePluginTests.swift
//  SemelCLITests
//
//  push, rm and cp over a scripted connection: what each sends, with what body, and how
//  it reports. The disk side is real (temporary directories); the graph side is the fake.
//

@testable import SemelCLI
import SemelNodeKit
import SemelProtocol
import XCTest

final class FilePluginTests: XCTestCase {

    private var connection: RecordingConnection!
    private var context: TestCommandContext!
    private var externalRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        externalRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        connection = RecordingConnection()
        context    = TestCommandContext(connection: connection, baseDirectory: externalRoot.path)
    }

    private func write(_ relativePath: String, _ text: String) throws {
        let url = externalRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func run(_ verb: String, _ tokens: [String]) throws {
        try FilePlugin().handle(verb: verb, tokens: tokens, context: context)
    }

    // MARK: - push

    func test_pushSendsAFileWithItsBytesInsideOneBatch() throws {
        try write("a.c", "int main() {}")
        connection.reply(.ok)
        connection.reply(.pushFile(didChange: true))
        connection.reply(.ok)

        try run("push", ["a.c"])

        XCTAssertEqual(connection.daemonRequests, [.beginBatch, .pushFile(path: "a.c", mode: 0o644), .endBatch])
        XCTAssertEqual(connection.requests[1].body, Data("int main() {}".utf8))
        XCTAssertEqual(context.messages, ["Push file: a.c "])
    }

    func test_pushOfAFolderSendsTheFolderThenItsFiles() throws {
        try write("src/a.c", "a")
        connection.reply(.ok)
        connection.reply(.ok)
        connection.reply(.pushFile(didChange: false))
        connection.reply(.ok)

        try run("push", ["src"])

        XCTAssertEqual(connection.daemonRequests, [.beginBatch, .pushFolder(path: "src"),
                                                   .pushFile(path: "src/a.c", mode: 0o644), .endBatch])
        XCTAssertEqual(context.messages, ["Push folder: src", "Push file: src/a.c [no change]"])
    }

    func test_pushOfAnAbsolutePathIsRefusedWithoutSendingAnything() throws {
        try run("push", ["/etc/hosts"])

        XCTAssertTrue(connection.requests.isEmpty)
        XCTAssertEqual(context.errors, ["push: /etc/hosts: only paths under \(externalRoot.path) can be pushed"])
    }

    func test_pushOfNothingIsAnError() throws {
        try run("push", ["nope.c"])

        XCTAssertTrue(connection.requests.isEmpty)
        XCTAssertEqual(context.errors, ["push: nope.c: no such file or directory"])
    }

    // MARK: - rm

    func test_rmSendsThePatternRelativeToTheCurrentDirectory() throws {
        context.currentDirectoryPath = Path("src")
        connection.reply(.remove(removedPaths: ["src/a.c"]))

        try run("rm", ["*.c"])

        XCTAssertEqual(connection.daemonRequests, [.remove(pattern: "src/*.c")])
        XCTAssertTrue(context.allOutput.isEmpty)
    }

    func test_rmOfNothingIsAnError() throws {
        connection.reply(.remove(removedPaths: []))

        try run("rm", ["nope"])

        XCTAssertEqual(context.errors, ["rm: nope: no such file or directory"])
    }

    // MARK: - cp

    func test_cpListsThenFetchesEachFileAndWritesIt() throws {
        connection.reply(.list(entries: [
            ListEntry(path: "src/a.c", kind: .file, size: 1, mode: 0o644, status: .none),
            ListEntry(path: "src",     kind: .folder, size: nil, mode: nil, status: .none),
        ]))
        connection.reply(.fetch(mode: 0o755), body: Data("hello".utf8))

        try run("cp", ["src/*", externalRoot.path])

        XCTAssertEqual(connection.daemonRequests, [
            .list(fileSystem: .input, pattern: "src/*"),
            .fetch(fileSystem: .input, path: "src/a.c"),
        ])
        // The destination goes through ExternalPathSanitizer, which resolves symlinks, and
        // the temporary directory is one on macOS (/var → /private/var).
        let destination = (externalRoot.path as NSString).resolvingSymlinksInPath
        let written     = destination + "/a.c"
        XCTAssertEqual(try String(contentsOfFile: written), "hello")
        let permissions = try FileManager.default.attributesOfItem(atPath: written)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        XCTAssertEqual(context.messages, ["File written: \(written)"])
    }

    func test_cpFromTheOutputFileSystemIsRootRelative() throws {
        context.currentDirectoryPath = Path("src")
        connection.reply(.list(entries: []))

        try run("cp", ["-o", "app", externalRoot.path])

        XCTAssertEqual(connection.daemonRequests, [.list(fileSystem: .output, pattern: "app")])
        XCTAssertEqual(context.errors, ["cp: app: no such file or directory"])
    }
}
```

`test_pushSendsAFileWithItsBytesInsideOneBatch` asserts mode `0o644`: files written with `String.write` get the process umask's default, which is `0o644` on a stock macOS. If your umask differs the assertion fails on the mode; in that case `chmod` the file to `0o644` in `write(_:_:)` after writing and say so.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter FilePluginTests`
Expected: the tests fail on their assertions, or the file fails to compile if a helper name is wrong — either way, no test passes yet. (The plugin code exists since Task 8; these tests are new coverage of it, so this step guards against a test that passes by accident. If every test passes on the first run, read each assertion once more and confirm it is asserting the plugin's real behaviour, then move on.)

- [ ] **Step 3: Run the whole root suite**

Run: `swift test`
Expected: `SemelCLITests` and `SemelServTests` green.

- [ ] **Step 4: Commit**

```bash
git add semel/Tests/FilePluginTests.swift
git commit -m "Test the file plugin over a fake connection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

### Task 10: The composition root, the dependency drop, all six suites, and the record

**Files:**
- Modify: `semel/main.swift`
- Modify: `Package.swift` (remove `SemelCore` from `SemelCLI`)
- Modify: `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md` (status line; two deviations)
- Modify: `BACKLOG.md` (B-30 role 3)
- Modify: `AGENTS.md` (the "Build and test" note about `SemelProtocol`)

- [ ] **Step 1: Rewrite `main.swift` as the composition root for one process**

Replace `semel/main.swift` with:

```swift
//
//  main.swift
//  semel
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import SemelCore
import SemelCLI
import SemelNodeKit
import SemelProtocol
import SemelServ
import SemelSwift
import SemelClang

var commandInterpreter: CommandInterpreter?

func main() throws {
    // Composition root: the engine knows no toolchains, so this is where the ones this
    // binary ships are installed. Before start(), so discovery sees them on its first pass.
    try SemelSwift.register()
    try SemelClang.register()

    try BuildEngine.start()

    // The server half and the client half, joined in one process by a connection that
    // still puts every message through the wire codec. The process-wide engine and
    // database are resolved once, here, and handed to the handler.
    let handler    = RequestHandler(engine: BuildEngine.shared,
                                    database: DatabaseLayer.shared,
                                    databasePath: SemelPaths.database.path)
    let connection = InProcessConnection(handler: handler)
    let interpreter = CommandInterpreter(connection: connection)

    let server = try interpreter.connect()
    print("Semel \(server.serverVersion) (C) 2026 Jade Burton. All rights reserved.")
    print("Graph: \(server.databasePath)")

    commandInterpreter = interpreter
    while let line = readLine(), receiveUserInput(line: line) {
    }
}

func receiveUserInput(line: String) -> Bool {
    do {
        try commandInterpreter?.handleCommand(line)
        return true
    } catch {
        return false
    }
}

#if !UNIT_TESTING
try main()
#endif
```

The banner prints after the handshake rather than before it, so the version shown is the server's. Nothing else about startup changes.

- [ ] **Step 2: Drop `SemelCore` from `SemelCLI`**

In `Package.swift`, remove the line `.product(name: "SemelCore", package: "SemelCore"),` from the `SemelCLI` target's dependencies only. Then:

Run: `grep -rn 'import SemelCore\|import SemelServ' semel/CommandInterpreter`
Expected: no output. If any file still imports `SemelCore`, it is using something from the engine and the split is not complete: find what, and report it rather than putting the dependency back.

- [ ] **Step 3: Run all six suites**

```bash
swift test --package-path SemelNodeKit
swift test --package-path SemelCore
swift test --package-path SemelProtocol
swift test
swift test --package-path SemelSwift
swift test --package-path SemelClang
```

Expected: every suite green, no warnings. Record each suite's `Executed N tests` line in your report.

- [ ] **Step 4: Run the REPL once by hand**

Run: `printf 'pwd\nls\ntools\nerrors\nquit\n' | swift run semel 2>&1 | head -40`
Expected: the banner with the version and graph path, `input:` for `pwd`, a listing or `(empty)`, the tools blocks, `No errors.` or an error report, and a clean exit. Paste the output into your report.

- [ ] **Step 5: Record phase 2 in the spec, backlog and AGENTS.md**

In `docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md`:

- Change the status line to: `**Status:** phases 1 and 2 implemented; phase 3 not yet started`
- In "Module layout", change the `SemelNodeKit          unchanged` line to `SemelNodeKit          gains the wildcard matcher and its external lister from SemelCore`, and add to the `SemelCore` line's description `; InternalFileSystemLister keeps the graph-backed lister`.
- Under "Changes to `SemelCore`", after item 3, add a fourth item:

```
4. **The wildcard matcher moves to `SemelNodeKit`.** `push` walks the local disk with
   `FileWildcardMatcher` and `ExternalFileSystemLister`, and the CLI must do that without
   linking the engine. Only `InternalFileSystemLister` needs `NodeRecord`, so only it stays.
```

- In item 1 of that list, replace "Rendering entries to lines moves to `SemelCLI`, the only place lines are printed after the split." with: "Rendering entries to lines is duplicated: `ErrorReport.lines(for:)` stays in Core for the default reporter and is pinned by `ErrorReportTests`, and `ErrorRecordRenderer` in `SemelCLI` renders the wire record identically, because the CLI cannot import Core and the protocol package must not render."

In `BACKLOG.md`, entry B-30, role 3: change "phase 1 of three (the `SemelProtocol` package) is built." to "phases 1 and 2 of three are built: the `SemelProtocol` package, and the in-process split behind `RequestHandler` and `InProcessConnection`."

In `AGENTS.md`, the "Build and test" block: the line beneath it added in phase 1 says `SemelProtocol` is built only by its own line until phase 2 links it. Change it to say the root package now links `SemelProtocol` through `SemelCLI` and `SemelServ`, so `swift build` covers it, and its own test line is still the only thing that runs its tests. Also add to the composition-root paragraph ("Nothing registers a toolchain automatically…") one sentence: `main.swift` also builds the `RequestHandler` and the `InProcessConnection`; the CLI never sees the engine directly.

- [ ] **Step 6: Commit**

```bash
git add semel/main.swift Package.swift docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md BACKLOG.md AGENTS.md
git commit -m "Compose the CLI and the server in one process, and record phase 2 as built

The CLI no longer links the engine; main.swift joins the halves with an
InProcessConnection that runs every message through the codec.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TkBRg1H4w61n6ucfHR43RE"
```

---

## Self-review notes

- **Spec coverage.** Section 2: `RequestHandler` (Tasks 5–6), `Session` and its teardown (4–5), serial queue (5), reporter routing and `EventSink` (2, 5), the three Core changes (2–3), unrecoverable errors via `FatalErrors.check` in the handler (5). Section 3: `CommandContext` on `SemelConnection` (8), the plugin table (8), startup `hello` + `subscribe` (8, 10), `InProcessConnection` through the codec (7), `SemelConnection` in `SemelProtocol` (4). Phase 2 bullets: all six. Testing section: handler tests including `pathNotFound`, batch teardown and reporters-to-sink (5–6); connection tests with interleaved threads and events (7); plugin tests against a fake (8–9).
- **Deviations from the spec**, both recorded in Task 10: the matcher move to `SemelNodeKit`; the duplicated error renderer.
- **Behavioural changes to the REPL**, all small: the banner's version is the server's; `errors`' count excludes ports carrying only the `initializing` placeholder; `rm` reports "Child not found/not deletable" as one error after applying the deletions that succeeded (as before) rather than interleaved; `push` sends the file's real permission bits (the server does not store them yet, marked `TODO`).
- **Type consistency**: `FileSystemKind`/`ToolNamespaceRecord` renamed in Task 4 and used by that name in 5–9; `ErrorReport.Entry`/`Item` (2) consumed by 5; `RequestHandler.init(engine:database:databasePath:)` used identically in 5, 7, 9, 10; `TestCommandContext(connection:baseDirectory:)` used in 8 and 9; `ListEntry(path:kind:size:mode:status:)` label order matches the protocol package.
- **Build order**: the root package builds at the end of every task. Task 3 leaves a one-line `printAll()` shim so `EnginePlugin` keeps compiling until Task 8 rewrites it and removes the shim; Task 8 also converts the two existing integration test files in the same commit, so the CLI test target never has a half-converted `TestCommandContext`.

# End-to-End Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build real projects through `semelserv`, `semel` and `semel-swift` together, from a fresh checkout, twice, and prove the products are present and byte-identical.

**Architecture:** A new root-package test target, `SemelEndToEndTests` under `EndToEnd/Tests`, drives the three executables that `swift test` builds beside it. A roster of `Project` values names each project; one harness, `EndToEndRun`, materialises a copy under a short `/tmp` root, configures it the way a user would (a rendered `clang.cfg` or `semel-swift prepare`), builds it cold twice in two fresh homes, checks the expected products, and diffs the two export trees. Fixtures live in `EndToEnd/Fixtures` and run on every `swift test`; external projects are pinned by commit, fetched into a cache, and run only when `SEMEL_E2E_EXTERNAL=1`.

**Tech Stack:** Swift 5.9 package, XCTest, Foundation `Process`, the three executables of the root package, git, `xcrun`, GitHub Actions on macOS.

**Spec:** `docs/superpowers/specs/2026-09-15-semel-end-to-end-testing-design.md`

## Global Constraints

- Everything new lives under `EndToEnd/` at the repository root: `EndToEnd/Fixtures/` and `EndToEnd/Tests/` (spec §2).
- **No fixture commits a `semel.config`, and the C fixtures commit `clang.cfg.template`, not a `clang.cfg`** (spec §2). Both carry machine values.
- The run root is `/tmp/semel-tests/<8 hex>/`; a Unix-domain socket path is limited to 103 bytes, and sockets live under the root (spec §4.1).
- Timeouts: **two minutes** for a fixture, **fifteen** for IceCubes (spec §3).
- Environment variables, read only by the end-to-end target: `SEMEL_E2E_EXTERNAL=1`, `SEMEL_E2E_CACHE` (default `~/Library/Caches/semel/end-to-end/`), `SEMEL_E2E_KEEP=1` (spec §5).
- IceCubes is `https://github.com/Dimillian/IceCubesApp.git` at `3dc60a80a66db2c3a92c517b38398246ef4ea1b9`, subfolder `Packages` (spec §3).
- `C1` is not read by anything in the repository (spec §2).
- Repository rules (AGENTS.md, memory): work in a `.claude` worktree and finish by PR; run `swiftlint --strict` before pushing; code comments are timeless, never "today", "no longer", "after the split".
- The hermeticity scan (`SemelCore/Tests/SemelCoreTests/HermeticityTests.swift`) covers node-side packages only; the new target and the new support target are not node-side, and neither is added to its allowlist.

## Where the code has moved since the spec was written

The spec is dated 2026-09-15. Read these before any task:

- `SemelServTests` is now `SemelServerTests` (PR #10). The spec's "the way `SemelServTests` depends on `semel-server`" means `SemelServerTests`.
- B-64 and B-65 have landed. `swift-hello-app` does **not** skip; the spec's "skips with a message naming B-64" is void.
- `prepare` (PR #11) now writes only the config namespaces the formula it writes reads. A **kept** formula, such as the hand-written `swift/HelloApp/semel.fmla`, selects `apple.assetCatalogCompiler` and `apple.stringCatalogCompiler`, which `prepare` would not write for a tree of packages. Task 3 teaches `prepare` to read the namespaces a kept formula selects. Without it the HelloApp fixture cannot be configured by `prepare`.
- `swift-my-app` has a path dependency `../MyLibrary` that sits **beside** the build folder. `build swift/MyApp` pushes only `swift/MyApp`, so the converter would wait forever for `input:/swift/MyLibrary`. The roster gains `alsoPush: [String]`, folders pushed before the build (spec §3 left this project "confirmed when the roster is written"; this is the confirmation).
- `swift-my-app`'s expected product is `MyApp` (the executable product in `MyApp/Package.swift`).
- A tool's sandbox is a fresh random directory per run (`LocalFileSystemTool.swift:49`), so any absolute path a tool embeds in its output differs between the two cold builds. Task 7 says what to do when the diff finds one.

## File structure

```
Package.swift                                   MODIFY: SemelTestSupport target; SemelServerTests depends on it; SemelEndToEndTests target
.swiftlint.yml                                  MODIFY: include EndToEnd/Tests and semel/TestSupport
.gitignore                                      MODIFY: generated files under EndToEnd/Fixtures
semel/TestSupport/ProductsDirectory.swift       NEW  (SemelTestSupport): where the executables are, beside a test bundle
semel/TestSupport/ManagedProcess.swift          NEW  (SemelTestSupport): launch, capture, terminate, wait with timeout; socket wait
semel/ServerTests/SemelservExecutableTests.swift MODIFY: use SemelTestSupport instead of its private copies
semel-swift/Library/GeneratedFiles.swift        MODIFY: namespaces(selectedIn:)
semel-swift/Library/Preparation.swift           MODIFY: a kept formula's namespaces join the config
semel/Tests/PrepareTests.swift                  MODIFY: the kept-formula test
EndToEnd/Fixtures/clang.cfg.template            NEW: the C1 base config with two placeholders
EndToEnd/Fixtures/c/, cpp/, swift/HelloApp/, swift/MyApp/, swift/MyLibrary/   NEW: copied from C1, stripped
EndToEnd/Tests/Project.swift                    NEW: the value type
EndToEnd/Tests/Projects.swift                   NEW: the roster
EndToEnd/Tests/EndToEndEnvironment.swift        NEW: the three environment variables, the Fixtures path
EndToEnd/Tests/EndToEndFailure.swift            NEW: the error a failed step throws, with its evidence
EndToEnd/Tests/ClangConfigTemplate.swift        NEW: renders clang.cfg.template
EndToEnd/Tests/ServerSession.swift              NEW: one semelserv, started and stopped
EndToEnd/Tests/TreeDiff.swift                   NEW: compares two export trees
EndToEnd/Tests/CloneCache.swift                 NEW: a pinned commit, fetched once
EndToEnd/Tests/EndToEndRun.swift                NEW: the harness
EndToEnd/Tests/RosterTests.swift                NEW
EndToEnd/Tests/TreeDiffTests.swift              NEW
EndToEnd/Tests/MaterialiseTests.swift           NEW
EndToEnd/Tests/FixtureTests.swift               NEW
EndToEnd/Tests/ExternalProjectTests.swift       NEW
.github/workflows/swift.yml                     MODIFY: a comment on the root test step
.github/workflows/end-to-end.yml                NEW: nightly
AGENTS.md, README.md, BACKLOG.md                MODIFY (Task 11)
docs/superpowers/specs/2026-09-15-semel-end-to-end-testing-design.md   MODIFY: status line
```

Test files in `EndToEnd/Tests` end in `Tests.swift`; the harness files do not, so a reader can tell the two apart in one listing. Everything in the target is `internal`; only the support target is `public`.

---

### Task 1: The shared process helper, `SemelTestSupport`

The spec (§4, "Shared code") moves the subprocess launch with the two environment variables, the socket wait and the products-directory lookup out of `SemelservExecutableTests` into a helper both targets use. Two test targets cannot share a source file, so the helper is a small library target with no XCTest dependency.

**Files:**
- Modify: `Package.swift`
- Create: `semel/TestSupport/ProductsDirectory.swift`
- Create: `semel/TestSupport/ManagedProcess.swift`
- Modify: `semel/ServerTests/SemelservExecutableTests.swift`
- Modify: `.swiftlint.yml`

**Interfaces:**
- Produces:
  - `ProductsDirectory.beside(bundleURL: URL) -> URL`
  - `ProductsDirectory.executable(named: String, besideBundleAt: URL) -> URL`
  - `final class ManagedProcess` with `init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?)`, `commandLine: String`, `start() throws`, `isRunning: Bool`, `output: String`, `terminationStatus: Int32`, `waitForExit(timeout: TimeInterval) -> Int32?`, `terminate()`, `kill()`
  - `SocketWait.wait(forSocketAt: String, timeout: TimeInterval) -> Bool`

- [ ] **Step 1: Add the target to Package.swift**

In `Package.swift`, after the `SemelTransport` target and before `SemelTransportTests`, add:

```swift
        // What a test needs to run one of this package's executables as a subprocess:
        // where the binary is, a launch that captures output without blocking, a stop
        // with a timeout, and the wait for a socket file. A library rather than a test
        // target because two test targets cannot share a source file, and Foundation
        // only, so it never pulls XCTest into a product.
        .target(
            name: "SemelTestSupport",
            path: "semel/TestSupport"
        ),
```

In `SemelServerTests`' dependencies add `"SemelTestSupport",` after `"SemelTransport",`.

- [ ] **Step 2: Write ProductsDirectory.swift**

```swift
//
//  ProductsDirectory.swift
//  SemelTestSupport
//
//  `swift test` builds a package's executables into the same directory as its test
//  bundles, so a test finds a binary by looking beside its own bundle.
//

import Foundation

public enum ProductsDirectory {

    /// The directory holding `bundleURL`'s bundle and the executables built beside it.
    public static func beside(bundleURL: URL) -> URL {
        bundleURL.deletingLastPathComponent()
    }

    /// The executable `name` built beside the bundle at `bundleURL`. Whether it exists is
    /// the caller's question: a test skips when it does not, naming the path.
    public static func executable(named name: String, besideBundleAt bundleURL: URL) -> URL {
        beside(bundleURL: bundleURL).appendingPathComponent(name)
    }
}
```

- [ ] **Step 3: Write ManagedProcess.swift**

```swift
//
//  ManagedProcess.swift
//  SemelTestSupport
//
//  One subprocess with its output kept: stdout and stderr on one pipe, read as it
//  arrives so a process that prints thousands of lines never blocks on a full pipe, and
//  a wait with a deadline so a hung process fails a test instead of hanging it.
//

import Foundation

public final class ManagedProcess {

    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var collected = Data()

    /// The launch, as a shell would show it, for a failure message.
    public let commandLine: String

    public init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = pipe
        process.standardError  = pipe
        commandLine = ([executable.path] + arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }).joined(separator: " ")
    }

    public func start() throws {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                return
            }
            self.lock.lock()
            self.collected.append(data)
            self.lock.unlock()
        }
        try process.run()
    }

    public var isRunning: Bool { process.isRunning }

    public var terminationStatus: Int32 { process.terminationStatus }

    /// Everything the process has written so far, both streams interleaved as they came.
    public var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: collected, as: UTF8.self)
    }

    /// The last `count` lines of `output`, for a failure message.
    public func outputTail(_ count: Int = 40) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
    }

    /// Waits up to `timeout` for the process to exit. Returns its status, or nil when it
    /// is still running at the deadline. Reads what is left on the pipe once it has
    /// exited, so `output` is complete when this returns a status.
    public func waitForExit(timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        collected.append(rest)
        lock.unlock()
        return process.terminationStatus
    }

    /// SIGTERM.
    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    /// SIGKILL, for a process that ignored SIGTERM.
    public func kill() {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}

public enum SocketWait {

    /// Polls for the socket file `semelserv` creates when it is ready to accept.
    public static func wait(forSocketAt path: String, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
```

- [ ] **Step 4: Rewrite SemelservExecutableTests to use the helper**

Replace the whole file with:

```swift
//
//  SemelservExecutableTests.swift
//  SemelServerTests
//
//  The binary, as a subprocess, with SEMEL_HOME and SEMEL_SOCKET pointing into a
//  temporary directory so it never opens the user's graph or socket. What is pinned:
//  it comes up and answers hello, a second instance is refused, and SIGTERM stops it
//  cleanly with the socket file gone.
//

import Foundation
@testable import SemelCLI
import SemelProtocol
import SemelTestSupport
import XCTest

final class SemelservExecutableTests: XCTestCase {

    private var home: URL!
    private var socketPath: String!
    private var processes: [ManagedProcess] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: the socket lives under the home, and a Unix-domain socket path
        // is limited to 103 bytes on macOS.
        home = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        socketPath = home.appendingPathComponent("semelserv.sock").path
    }

    override func tearDown() {
        for process in processes where process.isRunning {
            process.terminate()
            _ = process.waitForExit(timeout: 10)
        }
        processes = []
        try? FileManager.default.removeItem(at: home)
        home = nil
        super.tearDown()
    }

    private var binary: URL {
        ProductsDirectory.executable(named: "semelserv", besideBundleAt: Bundle(for: Self.self).bundleURL)
    }

    private func launch() throws -> ManagedProcess {
        let process = ManagedProcess(executable: binary, arguments: [],
                                     environment: ["SEMEL_HOME": home.path, "SEMEL_SOCKET": socketPath])
        try process.start()
        processes.append(process)
        return process
    }

    func test_startsAnswersHelloRefusesASecondInstanceAndStopsOnSigterm() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path),
                          "semelserv is not built beside the test bundle at \(binary.path)")

        let server = try launch()
        XCTAssertTrue(SocketWait.wait(forSocketAt: socketPath), "the server never created \(socketPath!)")

        let client = try SocketConnection.connect(to: socketPath)
        let (reply, _) = try client.send(.hello(Hello(role: .daemon)), body: nil)
        guard case .hello(.accepted(_, let databasePath)) = reply else {
            return XCTFail("expected an accepted hello, got \(reply)")
        }
        XCTAssertEqual(databasePath, home.appendingPathComponent("graph.sqlite").path)

        let second = try launch()
        XCTAssertEqual(second.waitForExit(timeout: 30), 1)
        let secondText = second.output
        XCTAssertTrue(secondText.contains("already running"), secondText)
        // It never printed a banner, which means it never opened the first instance's graph.
        XCTAssertFalse(secondText.contains("Graph:"), secondText)

        client.close()
        server.terminate() // SIGTERM
        XCTAssertEqual(server.waitForExit(timeout: 30), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }
}
```

- [ ] **Step 5: Add the folder to swiftlint**

In `.swiftlint.yml` under `included:`, `semel` already covers `semel/TestSupport`. Nothing to add for this task; `EndToEnd/Tests` is added in Task 4.

- [ ] **Step 6: Run the server tests**

Run: `swift test --filter SemelservExecutableTests`
Expected: `Executed 1 test, with 0 failures`.

Run: `swift test --filter SemelServerTests`
Expected: all pass (the count was 19 before this task; it must not drop).

- [ ] **Step 7: Lint and commit**

Run: `swiftlint --strict --quiet` — expected: no output.

```bash
git add Package.swift semel/TestSupport semel/ServerTests/SemelservExecutableTests.swift
git commit -m "Add SemelTestSupport: the executable lookup, a managed subprocess and the socket wait, shared by the server tests and the end-to-end target"
```

---

### Task 2: The fixtures, copied from C1 and stripped

**Files:**
- Create: `EndToEnd/Fixtures/clang.cfg.template`
- Create: `EndToEnd/Fixtures/c/` (from `C1/c`)
- Create: `EndToEnd/Fixtures/cpp/` (from `C1/cpp`, keeps its own `clang.cfg` overlay: it holds only `cxxStandard=c++17`, no machine value)
- Create: `EndToEnd/Fixtures/swift/HelloApp/`, `swift/MyApp/`, `swift/MyLibrary/` (from `C1/swift/...`)
- Modify: `.gitignore`

**Interfaces:**
- Produces: the tree Task 4's roster names and Task 5 copies. The formulas keep their `<../clang.cfg>` reference, so the base of a fixture run is the `Fixtures` copy.

- [ ] **Step 1: Copy the trees**

From the repository root (the paths below assume `C1` is the sibling of the repository, `../C1`; adjust if it is elsewhere):

```bash
mkdir -p EndToEnd/Fixtures/swift
rsync -a --exclude .DS_Store --exclude .build --exclude Dependencies --exclude semel.config ../C1/c/  EndToEnd/Fixtures/c/
rsync -a --exclude .DS_Store --exclude .build --exclude Dependencies --exclude semel.config ../C1/cpp/ EndToEnd/Fixtures/cpp/
rsync -a --exclude .DS_Store --exclude .build --exclude Dependencies --exclude semel.config ../C1/swift/HelloApp/  EndToEnd/Fixtures/swift/HelloApp/
rsync -a --exclude .DS_Store --exclude .build --exclude Dependencies --exclude semel.config ../C1/swift/MyApp/     EndToEnd/Fixtures/swift/MyApp/
rsync -a --exclude .DS_Store --exclude .build --exclude Dependencies --exclude semel.config ../C1/swift/MyLibrary/ EndToEnd/Fixtures/swift/MyLibrary/
```

- [ ] **Step 2: Write the template**

`EndToEnd/Fixtures/clang.cfg.template` is `C1/clang.cfg` with the two machine values replaced. The C++ fixture's `cpp/clang.cfg` overlays `cxxStandard` on it. Write exactly:

```
// The base config of the C fixtures, rendered to `clang.cfg` beside this file by the
// end-to-end harness: `${CLANG_VERSION}` is the first line of `clang --version` and
// `${MACOS_SDK_PATH}` is `xcrun --sdk macosx --show-sdk-path`. Both are facts about the
// machine that runs the test, which is why the rendered file is never committed.
//
// Values are literal: everything after the first `=` is the value, quotes included. So no
// quotes here — `name="clang"` would ask for a tool called `"clang"`.
//
// toolDescriptor.recursiveHash is deliberately absent rather than empty. Absent means nil,
// which is what the tool registry holds; `recursiveHash=""` would be a two-character string
// and would not match.
//
// The toolDescriptor block is repeated per node on purpose: there is no inheritance, so each
// node's settings are complete where they are written and no reader has to work out which
// of several files won.

clang.preprocessor.toolDescriptor.name=clang
clang.preprocessor.toolDescriptor.version=${CLANG_VERSION}
clang.preprocessor.toolDescriptor.platform=macOS
clang.preprocessor.toolDescriptor.architecture=arm64
clang.preprocessor.sdkPath=${MACOS_SDK_PATH}
clang.preprocessor.target=arm64-apple-macos14.0
clang.preprocessor.cStandard=c17

clang.compiler.toolDescriptor.name=clang
clang.compiler.toolDescriptor.version=${CLANG_VERSION}
clang.compiler.toolDescriptor.platform=macOS
clang.compiler.toolDescriptor.architecture=arm64
clang.compiler.target=arm64-apple-macos14.0
clang.compiler.cStandard=c17

clang.linker.toolDescriptor.name=clang
clang.linker.toolDescriptor.version=${CLANG_VERSION}
clang.linker.toolDescriptor.platform=macOS
clang.linker.toolDescriptor.architecture=arm64
clang.linker.sdkPath=${MACOS_SDK_PATH}
clang.linker.target=arm64-apple-macos14.0
```

- [ ] **Step 3: Strip what must not be committed, and verify**

```bash
find EndToEnd/Fixtures \( -name semel.config -o -name .DS_Store -o -name clang.cfg -path '*/Fixtures/clang.cfg' \) -print
```
Expected: no output. (`EndToEnd/Fixtures/cpp/clang.cfg` is the overlay and stays; the `-path` clause excludes only a base `clang.cfg` at the Fixtures root.)

```bash
ls EndToEnd/Fixtures EndToEnd/Fixtures/c EndToEnd/Fixtures/swift EndToEnd/Fixtures/swift/HelloApp
```
Expected: `clang.cfg.template c cpp swift`; `hello.fmla src`; `HelloApp MyApp MyLibrary`; `Assets.xcassets HelloKit Info.plist PkgInfo Resources Sources semel.fmla`.

- [ ] **Step 4: Ignore what a run would generate if anyone ran it in place**

Append to `.gitignore`:

```
# End-to-end fixtures: what the harness renders or prepares in its /tmp copy, kept out
# in case anyone runs prepare in the tree itself
EndToEnd/Fixtures/clang.cfg
EndToEnd/Fixtures/**/semel.config
EndToEnd/Fixtures/**/Dependencies/
```

- [ ] **Step 5: Commit**

```bash
git add EndToEnd/Fixtures .gitignore
git commit -m "Add the end-to-end fixtures: the C, C++ and Swift projects from C1, stripped of machine values and build output"
```

---

### Task 3: `prepare` writes the namespaces a kept formula selects

`swift/HelloApp/semel.fmla` is hand-written and kept by `prepare`; it selects `apple.assetCatalogCompiler` and `apple.stringCatalogCompiler`, which the package-tree set does not include. `prepare` reads the kept formula's `prefix: '…'` literals and adds them.

**Files:**
- Modify: `semel-swift/Library/GeneratedFiles.swift`
- Modify: `semel-swift/Library/Preparation.swift:49-98` (`run`)
- Test: `semel/Tests/PrepareTests.swift`

**Interfaces:**
- Produces: `GeneratedFiles.namespaces(selectedIn formula: String) -> [String]` (sorted, unique).

- [ ] **Step 1: Write the failing tests**

In `PrepareTests.swift`, after `test_everyNamespaceAConverterReadsIsDeclaredByAToolchain`, add:

```swift
    /// A formula already there is kept, and it may select namespaces the converter's
    /// formula would not — a hand-written app formula compiles catalogs. The config
    /// carries what the kept formula selects too, read from its `prefix: '…'` literals.
    func test_theConfigCarriesTheNamespacesAKeptFormulaSelects() throws {
        try write("App/HelloKit/Package.swift")
        try write("App/semel.fmla", """
            func settings(prefix) = ConfigFilter(prefix: prefix, input: ['config': StaticFile(path: <semel.config>).output]).output
            include SwiftFormulaConverter(path: <HelloKit>, root: <.>).formula
            func assets() = AssetCatalogCompiler(configuration: ['config': settings(prefix: 'apple.assetCatalogCompiler')])
            func strings() = StringCatalogCompiler(configuration: ['config': settings(prefix: 'apple.stringCatalogCompiler')])
            """)

        let report = try Preparation.run(folder: folder("App"), platform: .iosSimulator, steps: steps())

        XCTAssertEqual(report.kept.map(\.lastPathComponent), ["semel.fmla"])
        let config = try String(contentsOf: folder("App").appendingPathComponent("semel.config"), encoding: .utf8)
        XCTAssertTrue(config.contains("apple.assetCatalogCompiler.toolDescriptor.name=actool"), "got:\n\(config)")
        XCTAssertTrue(config.contains("apple.stringCatalogCompiler.toolDescriptor.name=xcstringstool"), "got:\n\(config)")
        XCTAssertTrue(config.contains("swift.compiler.toolDescriptor.name=swiftc"), "the package set is still there, got:\n\(config)")
    }

    func test_namespacesSelectedInFormulaTextAreTheDistinctPrefixLiterals() {
        let formula = "a(prefix: 'swift.compiler') b(prefix: 'clang.linker') c(prefix: 'swift.compiler') ConfigFilter(prefix: prefix, x)"

        XCTAssertEqual(GeneratedFiles.namespaces(selectedIn: formula), ["clang.linker", "swift.compiler"])
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter PrepareTests`
Expected: compile error, `namespaces(selectedIn:)` not found.

- [ ] **Step 3: Implement**

In `GeneratedFiles.swift`, after `projectNamespaces`, add:

```swift
    /// The namespaces a formula's text selects, from its `prefix: '…'` literals: what a
    /// hand-written formula names in `ConfigFilter(prefix: 'swift.compiler', …)` or through
    /// a func of its own, `settings(prefix: 'apple.assetCatalogCompiler')`. A prefix passed
    /// as a parameter is not a literal and does not count. Sorted, each once.
    public static func namespaces(selectedIn formula: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"prefix:\s*'([A-Za-z][A-Za-z0-9.]*)'"#) else {
            return []
        }
        let matches = pattern.matches(in: formula, range: NSRange(formula.startIndex..., in: formula))
        return Set(matches.compactMap { Range($0.range(at: 1), in: formula).map { String(formula[$0]) } }).sorted()
    }
```

In `Preparation.run`, change `let namespaces: [String]` to `var namespaces: [String]`, and after the `if let project … } else { … }` block and before the `guard let deploymentVersion` line, add:

```swift
        // A formula already there is kept, and it may select namespaces the one written
        // here would not — a hand-written app formula compiles catalogs. What it selects
        // joins the config, so the file is not the one thing prepare left it to write.
        let formulaFile = folder.appendingPathComponent(GeneratedFiles.formulaFileName)
        if let kept = try? String(contentsOf: formulaFile, encoding: .utf8) {
            namespaces = Array(Set(namespaces).union(GeneratedFiles.namespaces(selectedIn: kept))).sorted()
        }
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter PrepareTests`
Expected: all pass (32 tests: the 30 there were, plus 2).

- [ ] **Step 5: Lint and commit**

Run: `swiftlint --strict --quiet` — expected: no output.

```bash
git add semel-swift/Library/GeneratedFiles.swift semel-swift/Library/Preparation.swift semel/Tests/PrepareTests.swift
git commit -m "prepare writes the namespaces a kept formula selects, read from its prefix literals"
```

---

### Task 4: The test target, the roster and the environment

**Files:**
- Modify: `Package.swift`
- Modify: `.swiftlint.yml`
- Create: `EndToEnd/Tests/Project.swift`
- Create: `EndToEnd/Tests/Projects.swift`
- Create: `EndToEnd/Tests/EndToEndEnvironment.swift`
- Create: `EndToEnd/Tests/RosterTests.swift`

**Interfaces:**
- Produces:
  - `struct Project { name, source: Source, buildFolder, alsoPush: [String], platform: String?, expectedProducts: [String], buildTimeout: TimeInterval, expectDeterministic: Bool }` with `enum Source { case fixture(folder: String); case git(url: String, commit: String, subfolder: String) }`
  - `enum Projects { static let cHello, cppEmu6502, swiftMyApp, swiftHelloApp, icecubes: Project; static let fixtures: [Project]; static let external: [Project]; static let all: [Project] }`
  - `enum EndToEndEnvironment { static var runsExternal: Bool; static var keepsRoots: Bool; static var cacheDirectory: URL; static var fixtures: URL; static var testBundle: URL }`

- [ ] **Step 1: Add the target**

In `Package.swift`, after `SemelCLITests`, add:

```swift
        // Real projects through the three binaries together: the fixtures under
        // EndToEnd/Fixtures on every run, pinned external projects on opt-in
        // (SEMEL_E2E_EXTERNAL=1). Depending on the executable targets is what makes
        // `swift test` build them beside the test bundle, where the harness finds them.
        .testTarget(
            name: "SemelEndToEndTests",
            dependencies: [
                "SemelTestSupport",
                "semel",
                "semel-server",
                "semel-swift",
            ],
            path: "EndToEnd/Tests"
        ),
```

In `.swiftlint.yml` under `included:`, add `  - EndToEnd/Tests` after `  - semel`.

- [ ] **Step 2: Write Project.swift**

```swift
//
//  Project.swift
//  SemelEndToEndTests
//
//  One project the harness builds: where it comes from, what to build, how to configure
//  it, and what must come out. Adding a project to the roster is adding one of these.
//

import Foundation

struct Project {

    enum Source {
        /// A folder under `EndToEnd/Fixtures`, `"."` for the whole tree. The base of the
        /// run is the copy of the whole `Fixtures` tree, whatever the folder.
        case fixture(folder: String)
        /// A repository at one commit; `subfolder` is the folder under the checkout that
        /// the build folder is relative to, `"."` for the checkout itself. The base of
        /// the run is the copy of the subfolder's parent, so a tree of packages builds
        /// with `Dependencies` beside it.
        case git(url: String, commit: String, subfolder: String)
    }

    let name: String
    let source: Source
    /// The argument to `build`, relative to the base.
    let buildFolder: String
    /// Folders pushed before the build, relative to the base: a path dependency that
    /// lives beside the build folder rather than under it.
    var alsoPush: [String] = []
    /// For `semel-swift prepare --platform`; nil means no prepare.
    let platform: String?
    /// Relative to the export directory; every one must exist and be non-empty.
    let expectedProducts: [String]
    let buildTimeout: TimeInterval
    /// Whether the two cold builds are required to match byte for byte. False only for
    /// a project whose tools embed a per-run path (B-49), with a comment saying which.
    var expectDeterministic: Bool = true
}
```

- [ ] **Step 3: Write Projects.swift**

```swift
//
//  Projects.swift
//  SemelEndToEndTests
//
//  The roster. Fixtures run on every `swift test`; external projects on opt-in.
//

import Foundation

enum Projects {

    static let fixtureTimeout: TimeInterval = 120

    static let cHello = Project(
        name: "c-hello",
        source: .fixture(folder: "."),
        buildFolder: "c",
        platform: nil,
        expectedProducts: ["hello", "hello.dylib", "config.txt"],
        buildTimeout: fixtureTimeout)

    static let cppEmu6502 = Project(
        name: "cpp-emu6502",
        source: .fixture(folder: "."),
        buildFolder: "cpp",
        platform: nil,
        expectedProducts: ["emu6502"],
        buildTimeout: fixtureTimeout)

    /// MyLibrary is a path dependency beside MyApp, so it is pushed first: `build`
    /// pushes only its own folder, and the converter waits for a folder nobody pushed.
    static let swiftMyApp = Project(
        name: "swift-my-app",
        source: .fixture(folder: "."),
        buildFolder: "swift/MyApp",
        alsoPush: ["swift/MyLibrary"],
        platform: "macos",
        expectedProducts: ["MyApp"],
        buildTimeout: fixtureTimeout)

    static let swiftHelloApp = Project(
        name: "swift-hello-app",
        source: .fixture(folder: "."),
        buildFolder: "swift/HelloApp",
        platform: "ios-simulator",
        expectedProducts: ["Hello.app/Hello", "Hello.app/Info.plist", "Hello.app/PkgInfo", "Hello.app/Assets.car"],
        buildTimeout: fixtureTimeout)

    static let icecubes = Project(
        name: "icecubes",
        source: .git(url: "https://github.com/Dimillian/IceCubesApp.git",
                     commit: "3dc60a80a66db2c3a92c517b38398246ef4ea1b9",
                     subfolder: "Packages"),
        buildFolder: "Packages",
        platform: "ios-simulator",
        expectedProducts: ["libConversations.a", "libExplore.a", "libLists.a", "libNotifications.a", "libTimeline.a"],
        buildTimeout: 15 * 60)

    static let fixtures: [Project] = [cHello, cppEmu6502, swiftMyApp, swiftHelloApp]
    static let external: [Project] = [icecubes]
    static let all: [Project] = fixtures + external
}
```

- [ ] **Step 4: Write EndToEndEnvironment.swift**

```swift
//
//  EndToEndEnvironment.swift
//  SemelEndToEndTests
//
//  The three environment variables this target reads, and where things are. Nothing
//  else in the repository reads these.
//

import Foundation

enum EndToEndEnvironment {

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// `SEMEL_E2E_EXTERNAL=1`: run the external projects. Off, they report as skipped, so
    /// a plain `swift test` is fast and offline.
    static var runsExternal: Bool { environment["SEMEL_E2E_EXTERNAL"] == "1" }

    /// `SEMEL_E2E_KEEP=1`: keep a run's root and print its path.
    static var keepsRoots: Bool { environment["SEMEL_E2E_KEEP"] == "1" }

    /// `SEMEL_E2E_CACHE`: where pinned checkouts are kept between runs.
    static var cacheDirectory: URL {
        if let path = environment["SEMEL_E2E_CACHE"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("semel/end-to-end", isDirectory: true)
    }

    /// `EndToEnd/Fixtures`, found from this source file: the tests run from the
    /// repository, and the fixtures are part of it.
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EndToEnd/Tests
            .deletingLastPathComponent()   // EndToEnd
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// Short on purpose: sockets live under it, and a Unix-domain socket path is limited
    /// to 103 bytes.
    static func newRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
```

- [ ] **Step 5: Write RosterTests.swift**

```swift
//
//  RosterTests.swift
//  SemelEndToEndTests
//

import XCTest

final class RosterTests: XCTestCase {

    func test_namesAreDistinct() {
        XCTAssertEqual(Set(Projects.all.map(\.name)).count, Projects.all.count)
    }

    func test_everyFixtureFolderAndItsFormulaAreInTheRepository() {
        for project in Projects.fixtures {
            let folder = EndToEndEnvironment.fixtures.appendingPathComponent(project.buildFolder, isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "\(project.name): no \(folder.path)")
            let formulas = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".fmla") } ?? []
            XCTAssertEqual(formulas.count, 1, "\(project.name): expected one formula in \(folder.path), found \(formulas)")
        }
    }

    func test_noFixtureCommitsAConfig() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: EndToEndEnvironment.fixtures.path))
        let configs = enumerator.compactMap { $0 as? String }.filter {
            $0.hasSuffix("semel.config") || $0 == "clang.cfg"
        }
        XCTAssertEqual(configs, [], "machine values must not be committed")
    }

    func test_theCTemplateHasBothPlaceholdersAndNothingElseUnrendered() throws {
        let template = try String(contentsOf: EndToEndEnvironment.fixtures.appendingPathComponent("clang.cfg.template"), encoding: .utf8)

        XCTAssertTrue(template.contains("${CLANG_VERSION}"))
        XCTAssertTrue(template.contains("${MACOS_SDK_PATH}"))
        let placeholders = template.components(separatedBy: "${").dropFirst().map { $0.prefix { $0 != "}" } }
        XCTAssertEqual(Set(placeholders.map(String.init)), ["CLANG_VERSION", "MACOS_SDK_PATH"])
    }
}
```

- [ ] **Step 6: Run them**

Run: `swift test --filter RosterTests`
Expected: `Executed 4 tests, with 0 failures`. If `test_noFixtureCommitsAConfig` fails, Task 2 left something behind; remove it there.

- [ ] **Step 7: Lint and commit**

Run: `swiftlint --strict --quiet` — expected: no output.

```bash
git add Package.swift .swiftlint.yml EndToEnd/Tests
git commit -m "Add the SemelEndToEndTests target with the project roster and the environment it reads"
```

---

### Task 5: Materialise and configure

**Files:**
- Create: `EndToEnd/Tests/EndToEndFailure.swift`
- Create: `EndToEnd/Tests/ClangConfigTemplate.swift`
- Create: `EndToEnd/Tests/EndToEndRun.swift` (first half)
- Create: `EndToEnd/Tests/MaterialiseTests.swift`

**Interfaces:**
- Produces:
  - `struct EndToEndFailure: Error, CustomStringConvertible { step: String; message: String; commandLine: String?; status: Int32?; outputTail: String?; serverLogTail: String? }`
  - `enum ClangConfigTemplate { static func render(template: URL, to destination: URL) throws; static func clangVersion() throws -> String; static func macOSSDKPath() throws -> String }`
  - `final class EndToEndRun` with `init(project: Project)`, `let root: URL`, `let base: URL` (set by `materialise`), `func materialise() throws`, `func configure() throws`, `func cleanUp()`, plus `static func run(_ tool: String, arguments: [String], environment: [String: String], currentDirectory: URL?, timeout: TimeInterval, step: String) throws -> ManagedProcess` (runs one of the three executables to completion, throws `EndToEndFailure` on a non-zero status or timeout).
- Consumes: `ManagedProcess`, `ProductsDirectory`, `SocketWait` (Task 1); `Project`, `EndToEndEnvironment` (Task 4).

- [ ] **Step 1: Write EndToEndFailure.swift**

```swift
//
//  EndToEndFailure.swift
//  SemelEndToEndTests
//
//  What a failed step throws: enough that a CI failure reads without a rerun — the
//  step, the command line, the status, and the tails of the process's output and of
//  the server's log.
//

import Foundation

struct EndToEndFailure: Error, CustomStringConvertible {
    var step: String
    var message: String
    var commandLine: String?
    var status: Int32?
    var outputTail: String?
    var serverLogTail: String?

    var description: String {
        var lines = ["\(step): \(message)"]
        if let commandLine { lines.append("  command: \(commandLine)") }
        if let status { lines.append("  status: \(status)") }
        if let outputTail, !outputTail.isEmpty { lines.append("  output (tail):\n" + indented(outputTail)) }
        if let serverLogTail, !serverLogTail.isEmpty { lines.append("  server log (tail):\n" + indented(serverLogTail)) }
        return lines.joined(separator: "\n")
    }

    private func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }
}
```

- [ ] **Step 2: Write ClangConfigTemplate.swift**

```swift
//
//  ClangConfigTemplate.swift
//  SemelEndToEndTests
//
//  The C fixtures' base config carries two facts about the machine: the clang version
//  string the toolchain checks against, and the macOS SDK path. Rendered at run time,
//  the way `prepare` derives the same facts for a Swift tree.
//

import Foundation
import SemelTestSupport

enum ClangConfigTemplate {

    static func render(template: URL, to destination: URL) throws {
        var text = try String(contentsOf: template, encoding: .utf8)
        text = text.replacingOccurrences(of: "${CLANG_VERSION}", with: try clangVersion())
        text = text.replacingOccurrences(of: "${MACOS_SDK_PATH}", with: try macOSSDKPath())
        guard !text.contains("${") else {
            throw EndToEndFailure(step: "configure", message: "unrendered placeholder left in \(destination.lastPathComponent)")
        }
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }

    /// The first line of `clang --version`, which is what the descriptor's version is.
    static func clangVersion() throws -> String {
        let output = try firstLine(of: "/usr/bin/xcrun", arguments: ["clang", "--version"], step: "configure: clang --version")
        return output
    }

    static func macOSSDKPath() throws -> String {
        try firstLine(of: "/usr/bin/xcrun", arguments: ["--sdk", "macosx", "--show-sdk-path"], step: "configure: show-sdk-path")
    }

    private static func firstLine(of executable: String, arguments: [String], step: String) throws -> String {
        let process = ManagedProcess(executable: URL(fileURLWithPath: executable), arguments: arguments, environment: [:])
        try process.start()
        guard let status = process.waitForExit(timeout: 60), status == 0,
              let line = process.output.split(separator: "\n").first, !line.isEmpty else {
            throw EndToEndFailure(step: step, message: "no usable output", commandLine: process.commandLine,
                                  status: process.isRunning ? nil : process.terminationStatus, outputTail: process.outputTail())
        }
        return String(line)
    }
}
```

- [ ] **Step 3: Write the first half of EndToEndRun.swift**

```swift
//
//  EndToEndRun.swift
//  SemelEndToEndTests
//
//  The harness: one project, materialised under a short root, configured the way a
//  user would, built cold twice in two fresh homes, its products checked and the two
//  export trees compared. A test calls `run()` and gets a pass, or a failure whose
//  message carries the evidence.
//

import Foundation
import SemelTestSupport

final class EndToEndRun {

    let project: Project
    let root: URL
    /// The folder `base` names in the `semel` session: the copy the build folder is
    /// relative to. Set by `materialise`.
    private(set) var base: URL

    init(project: Project) throws {
        self.project = project
        root = try EndToEndEnvironment.newRoot()
        base = root
    }

    // MARK: - The binaries

    static var testBundle: URL { Bundle(for: EndToEndRun.self).bundleURL }

    static func binary(_ name: String) -> URL {
        ProductsDirectory.executable(named: name, besideBundleAt: testBundle)
    }

    static var binariesAreBuilt: Bool {
        ["semel", "semelserv", "semel-swift"].allSatisfy { FileManager.default.isExecutableFile(atPath: binary($0).path) }
    }

    /// Runs one of the three executables to completion. A non-zero status or the
    /// deadline is a failure naming `step`, with the command and the output's tail.
    @discardableResult
    static func run(_ tool: String, arguments: [String], environment: [String: String] = [:],
                    currentDirectory: URL? = nil, timeout: TimeInterval, step: String,
                    serverLog: (() -> String)? = nil) throws -> ManagedProcess {
        let process = ManagedProcess(executable: binary(tool), arguments: arguments,
                                     environment: environment, currentDirectory: currentDirectory)
        try process.start()
        guard let status = process.waitForExit(timeout: timeout) else {
            process.kill()
            _ = process.waitForExit(timeout: 10)
            throw EndToEndFailure(step: step, message: "timed out after \(Int(timeout)) s", commandLine: process.commandLine,
                                  outputTail: process.outputTail(), serverLogTail: serverLog?())
        }
        guard status == 0 else {
            throw EndToEndFailure(step: step, message: "exit status \(status)", commandLine: process.commandLine,
                                  status: status, outputTail: process.outputTail(), serverLogTail: serverLog?())
        }
        return process
    }

    // MARK: - 1. Materialise

    /// A fixture project copies the whole `Fixtures` tree to `<root>/tree`; an external
    /// project copies the cached checkout's subfolder parent there. Either way `base` is
    /// what the build folder is relative to.
    func materialise() throws {
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        switch project.source {
        case .fixture:
            try FileManager.default.copyItem(at: EndToEndEnvironment.fixtures, to: tree)
            base = tree
        case .git(let url, let commit, let subfolder):
            let checkout = try CloneCache.checkout(name: project.name, url: url, commit: commit)
            let parent = subfolder == "." ? checkout : checkout.appendingPathComponent(subfolder).deletingLastPathComponent()
            try FileManager.default.copyItem(at: parent, to: tree)
            base = tree
        }
    }

    // MARK: - 2. Configure

    /// The C fixtures get their base config rendered; a project with a platform is
    /// prepared. Once, before both builds, so the two builds see identical inputs.
    func configure() throws {
        let template = base.appendingPathComponent("clang.cfg.template")
        if FileManager.default.fileExists(atPath: template.path) {
            try ClangConfigTemplate.render(template: template, to: base.appendingPathComponent("clang.cfg"))
        }
        if let platform = project.platform {
            try Self.run("semel-swift",
                         arguments: ["prepare", base.appendingPathComponent(project.buildFolder).path, "--platform", platform],
                         timeout: project.buildTimeout, step: "prepare")
        }
    }

    // MARK: - 7. Clean up

    func cleanUp() {
        if EndToEndEnvironment.keepsRoots {
            print("SEMEL_E2E_KEEP=1: kept \(root.path)")
        } else {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
```

`CloneCache` does not exist until Task 9. For this task, create `EndToEnd/Tests/CloneCache.swift` with the stub below so the target compiles; Task 9 replaces its body:

```swift
//
//  CloneCache.swift
//  SemelEndToEndTests
//

import Foundation

enum CloneCache {
    static func checkout(name: String, url: String, commit: String) throws -> URL {
        throw EndToEndFailure(step: "materialise", message: "external projects are not fetched yet")
    }
}
```

- [ ] **Step 4: Write MaterialiseTests.swift**

```swift
//
//  MaterialiseTests.swift
//  SemelEndToEndTests
//
//  The two steps before any build, on their own: they are fast, and a failure here is
//  about the tree or the machine, not about Semel.
//

import XCTest

final class MaterialiseTests: XCTestCase {

    private var run: EndToEndRun?

    override func tearDown() {
        run?.cleanUp()
        run = nil
        super.tearDown()
    }

    func test_aFixtureRunCopiesTheWholeTreeUnderAShortRoot() throws {
        let run = try EndToEndRun(project: Projects.cHello)
        self.run = run

        try run.materialise()

        XCTAssertTrue(run.root.path.hasPrefix("/tmp/semel-tests/"), run.root.path)
        XCTAssertLessThan(run.root.appendingPathComponent("home1/semelserv.sock").path.utf8.count, 104)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.base.appendingPathComponent("c/hello.fmla").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.base.appendingPathComponent("swift/HelloApp/semel.fmla").path))
    }

    func test_configureRendersTheCTemplateWithThisMachinesValues() throws {
        let run = try EndToEndRun(project: Projects.cHello)
        self.run = run
        try run.materialise()

        try run.configure()

        let rendered = try String(contentsOf: run.base.appendingPathComponent("clang.cfg"), encoding: .utf8)
        XCTAssertFalse(rendered.contains("${"), rendered)
        XCTAssertTrue(rendered.contains("clang.linker.toolDescriptor.version=" + (try ClangConfigTemplate.clangVersion())), rendered)
        XCTAssertTrue(rendered.contains("clang.linker.sdkPath=" + (try ClangConfigTemplate.macOSSDKPath())), rendered)
    }

    func test_configurePreparesAProjectWithAPlatform() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.swiftMyApp)
        self.run = run
        try run.materialise()

        try run.configure()

        let config = try String(contentsOf: run.base.appendingPathComponent("swift/MyApp/semel.config"), encoding: .utf8)
        XCTAssertTrue(config.contains("swift.compiler.target=arm64-apple-macosx13.0"), config)
        XCTAssertFalse(config.contains("clang.linker"), "a package tree never links through clang")
    }
}
```

- [ ] **Step 5: Run them**

Run: `swift test --filter MaterialiseTests`
Expected: `Executed 3 tests, with 0 failures`. If the third asserts on the target string, read the config it prints and correct the expectation to what `prepare` derives from `MyApp/Package.swift` (`.macOS(.v13)` gives `13.0`).

- [ ] **Step 6: Lint and commit**

Run: `swiftlint --strict --quiet` — expected: no output.

```bash
git add EndToEnd/Tests
git commit -m "End-to-end harness, part 1: materialise a fixture under a short root and configure it"
```

---

### Task 6: One cold build: the server, the client, the products

**Files:**
- Create: `EndToEnd/Tests/ServerSession.swift`
- Modify: `EndToEnd/Tests/EndToEndRun.swift` (add sections 3 and 4)
- Create: `EndToEnd/Tests/BuildTests.swift`

**Interfaces:**
- Produces:
  - `final class ServerSession { init(home: URL); let socketPath: String; func start() throws; func stop() throws; var logTail: String }`
  - `EndToEndRun.coldBuild(home: String, out: String) throws -> URL` (returns the export directory)
  - `EndToEndRun.checkProducts(in out: URL) throws`
- Consumes: Task 5's `run(_:arguments:…)`, `base`, `root`.

- [ ] **Step 1: Write ServerSession.swift**

```swift
//
//  ServerSession.swift
//  SemelEndToEndTests
//
//  One `semelserv` over one home: started with SEMEL_HOME and SEMEL_SOCKET pointing
//  into it, its socket waited for, and stopped with SIGTERM, which must exit zero and
//  leave no socket file — the same three facts SemelservExecutableTests pins.
//

import Foundation
import SemelTestSupport

final class ServerSession {

    let home: URL
    let socketPath: String
    private var process: ManagedProcess?

    init(home: URL) {
        self.home = home
        socketPath = home.appendingPathComponent("semelserv.sock").path
    }

    var environment: [String: String] { ["SEMEL_HOME": home.path, "SEMEL_SOCKET": socketPath] }

    var logTail: String { process?.outputTail() ?? "" }

    func start() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = ManagedProcess(executable: EndToEndRun.binary("semelserv"), arguments: [], environment: environment)
        try process.start()
        self.process = process
        guard SocketWait.wait(forSocketAt: socketPath, timeout: 30) else {
            process.kill()
            throw EndToEndFailure(step: "start server", message: "no socket at \(socketPath) after 30 s",
                                  commandLine: process.commandLine, outputTail: process.outputTail())
        }
    }

    /// SIGTERM; a clean exit is part of what is tested.
    func stop() throws {
        guard let process else {
            return
        }
        process.terminate()
        guard let status = process.waitForExit(timeout: 30) else {
            process.kill()
            throw EndToEndFailure(step: "stop server", message: "did not exit within 30 s of SIGTERM",
                                  commandLine: process.commandLine, serverLogTail: process.outputTail())
        }
        guard status == 0 else {
            throw EndToEndFailure(step: "stop server", message: "exit status \(status) on SIGTERM",
                                  commandLine: process.commandLine, status: status, serverLogTail: process.outputTail())
        }
        guard !FileManager.default.fileExists(atPath: socketPath) else {
            throw EndToEndFailure(step: "stop server", message: "socket file still there after exit: \(socketPath)")
        }
    }

    /// For a failure path: whatever it takes, no evidence expected.
    func killIfRunning() {
        process?.kill()
    }
}
```

- [ ] **Step 2: Add the build and the products check to EndToEndRun**

In `EndToEndRun.swift`, after the `configure()` function and before `// MARK: - 7. Clean up`, add:

```swift
    // MARK: - 3 and 5. A cold build

    /// A fresh home named `home`, a server over it, one `semel` session that pushes the
    /// extra folders, builds the build folder and exports into `<root>/<out>`; then the
    /// server stopped cleanly. Returns the export directory.
    func coldBuild(home homeName: String, out outName: String) throws -> URL {
        let server = ServerSession(home: root.appendingPathComponent(homeName, isDirectory: true))
        let out = root.appendingPathComponent(outName, isDirectory: true)
        try server.start()
        do {
            var commands = ["base \(base.path)"]
            commands += project.alsoPush.map { "push \($0)" }
            commands.append("build \(project.buildFolder) --into \(out.path)")
            try Self.run("semel", arguments: commands, environment: server.environment,
                         timeout: project.buildTimeout, step: "build (\(homeName))", serverLog: { server.logTail })
        } catch {
            server.killIfRunning()
            throw error
        }
        try server.stop()
        return out
    }

    // MARK: - 4. Products

    /// Every expected product exists under `out` and is not empty. Listed one by one, so
    /// a missing icon is a named failure.
    func checkProducts(in out: URL) throws {
        var problems: [String] = []
        for product in project.expectedProducts {
            let url = out.appendingPathComponent(product)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                problems.append("missing: \(product)")
                continue
            }
            if (attributes[.size] as? UInt64 ?? 0) == 0 {
                problems.append("empty: \(product)")
            }
        }
        guard problems.isEmpty else {
            let present = (try? FileManager.default.subpathsOfDirectory(atPath: out.path))?.sorted().joined(separator: "\n    ") ?? "(none)"
            throw EndToEndFailure(step: "products (\(out.lastPathComponent))",
                                  message: problems.joined(separator: "; ") + "\n  exported:\n    " + present)
        }
    }
```

- [ ] **Step 3: Write BuildTests.swift**

```swift
//
//  BuildTests.swift
//  SemelEndToEndTests
//
//  One cold build of the smallest fixture, on its own, so a failure in the server
//  lifecycle or the export shows up before the full run's diff does.
//

import XCTest

final class BuildTests: XCTestCase {

    private var run: EndToEndRun?

    override func tearDown() {
        run?.cleanUp()
        run = nil
        super.tearDown()
    }

    func test_cHelloBuildsColdAndExportsItsProducts() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.cHello)
        self.run = run
        try run.materialise()
        try run.configure()

        let out = try run.coldBuild(home: "home1", out: "out1")

        XCTAssertNoThrow(try run.checkProducts(in: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.root.appendingPathComponent("home1/semelserv.sock").path))
        let config = try String(contentsOf: out.appendingPathComponent("config.txt"), encoding: .utf8)
        XCTAssertFalse(config.contains("${"), "config.txt is the rendered config, pushed whole")
    }
}
```

- [ ] **Step 4: Run it**

Run: `swift test --filter BuildTests`
Expected: `Executed 1 test, with 0 failures`. On a failure, the message is an `EndToEndFailure` description: read the step, the command and the tails, fix the cause (not the test), rerun.

- [ ] **Step 5: Lint and commit**

Run: `swiftlint --strict --quiet` — expected: no output.

```bash
git add EndToEnd/Tests
git commit -m "End-to-end harness, part 2: a cold build through semelserv and semel, and the products check"
```

---

### Task 7: The second build and the determinism diff

**Files:**
- Create: `EndToEnd/Tests/TreeDiff.swift`
- Create: `EndToEnd/Tests/TreeDiffTests.swift`
- Modify: `EndToEnd/Tests/EndToEndRun.swift` (add section 6 and `run()`)

**Interfaces:**
- Produces:
  - `enum TreeDiff { struct Difference: CustomStringConvertible { enum Kind { case onlyInFirst, onlyInSecond, mode(first: Int, second: Int), size(first: Int, second: Int), content(firstDifferingOffset: Int) }; let path: String; let kind: Kind }; static func compare(_ first: URL, _ second: URL) throws -> [Difference] }`
  - `EndToEndRun.run() throws` — the whole sequence, steps 1 to 7.

- [ ] **Step 1: Write TreeDiffTests.swift first**

```swift
//
//  TreeDiffTests.swift
//  SemelEndToEndTests
//

import XCTest

final class TreeDiffTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("semel-treediff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func write(_ tree: String, _ path: String, _ bytes: [UInt8], mode: Int = 0o644) throws {
        let url = folder.appendingPathComponent(tree).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func test_identicalTreesHaveNoDifferences() throws {
        try write("a", "x/one", [1, 2, 3]); try write("b", "x/one", [1, 2, 3])

        XCTAssertEqual(try TreeDiff.compare(folder.appendingPathComponent("a"), folder.appendingPathComponent("b")).count, 0)
    }

    func test_namesEachKindOfDifferenceWithItsPath() throws {
        try write("a", "only-in-a", [1])
        try write("b", "only-in-b", [1])
        try write("a", "mode", [1], mode: 0o755); try write("b", "mode", [1], mode: 0o644)
        try write("a", "size", [1, 2]);            try write("b", "size", [1])
        try write("a", "sub/content", [9, 9, 9, 1]); try write("b", "sub/content", [9, 9, 9, 2])

        let differences = try TreeDiff.compare(folder.appendingPathComponent("a"), folder.appendingPathComponent("b"))

        XCTAssertEqual(differences.map(\.description), [
            "mode: mode 755 vs 644",
            "only-in-a: only in the first tree",
            "only-in-b: only in the second tree",
            "size: size 2 vs 1",
            "sub/content: content differs at offset 3",
        ])
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter TreeDiffTests`
Expected: compile error, `TreeDiff` not found.

- [ ] **Step 3: Write TreeDiff.swift**

```swift
//
//  TreeDiff.swift
//  SemelEndToEndTests
//
//  Two export trees compared: the same set of relative paths, the same modes, the same
//  bytes. Each difference names its path and how it differs, so a timestamp or an
//  embedded path is recognisable from the message without opening the files.
//

import Foundation

enum TreeDiff {

    struct Difference: CustomStringConvertible {
        enum Kind {
            case onlyInFirst
            case onlyInSecond
            case mode(first: Int, second: Int)
            case size(first: Int, second: Int)
            case content(firstDifferingOffset: Int)
        }
        let path: String
        let kind: Kind

        var description: String {
            switch kind {
            case .onlyInFirst:                    return "\(path): only in the first tree"
            case .onlyInSecond:                   return "\(path): only in the second tree"
            case .mode(let a, let b):             return "\(path): mode \(String(a, radix: 8)) vs \(String(b, radix: 8))"
            case .size(let a, let b):             return "\(path): size \(a) vs \(b)"
            case .content(let offset):            return "\(path): content differs at offset \(offset)"
            }
        }
    }

    /// Sorted by path. Files only; a directory is present through what is in it.
    static func compare(_ first: URL, _ second: URL) throws -> [Difference] {
        let firstFiles = try files(under: first)
        let secondFiles = try files(under: second)
        var differences: [Difference] = []
        for path in Set(firstFiles.keys).union(secondFiles.keys).sorted() {
            guard let a = firstFiles[path] else {
                differences.append(.init(path: path, kind: .onlyInSecond))
                continue
            }
            guard let b = secondFiles[path] else {
                differences.append(.init(path: path, kind: .onlyInFirst))
                continue
            }
            if a.mode != b.mode {
                differences.append(.init(path: path, kind: .mode(first: a.mode, second: b.mode)))
            } else if a.size != b.size {
                differences.append(.init(path: path, kind: .size(first: a.size, second: b.size)))
            } else if let offset = try firstDifferingOffset(a.url, b.url) {
                differences.append(.init(path: path, kind: .content(firstDifferingOffset: offset)))
            }
        }
        return differences
    }

    private struct Entry {
        let url: URL
        let mode: Int
        let size: Int
    }

    private static func files(under root: URL) throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            return result
        }
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: keys).isRegularFile == true else {
                continue
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result[relative] = Entry(url: url,
                                     mode: (attributes[.posixPermissions] as? Int ?? 0) & 0o777,
                                     size: attributes[.size] as? Int ?? 0)
        }
        return result
    }

    private static func firstDifferingOffset(_ a: URL, _ b: URL) throws -> Int? {
        let dataA = try Data(contentsOf: a)
        let dataB = try Data(contentsOf: b)
        guard dataA != dataB else {
            return nil
        }
        return zip(dataA, dataB).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(dataA.count, dataB.count)
    }
}
```

- [ ] **Step 4: Run the unit test**

Run: `swift test --filter TreeDiffTests`
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Add the determinism step and `run()` to EndToEndRun**

In `EndToEndRun.swift`, after `checkProducts` and before `// MARK: - 7. Clean up`, add:

```swift
    // MARK: - 6. Determinism

    /// The two export trees must match: the same paths, modes and bytes. This is the
    /// B-04(b) check: two processes, the same inputs, a byte-for-byte diff. A project
    /// marked not deterministic reports the differences as a note instead of failing.
    func checkDeterminism(_ out1: URL, _ out2: URL) throws {
        let differences = try TreeDiff.compare(out1, out2)
        guard !differences.isEmpty else {
            return
        }
        let listed = differences.prefix(20).map(\.description).joined(separator: "\n  ")
        let more = differences.count > 20 ? "\n  … and \(differences.count - 20) more" : ""
        guard project.expectDeterministic else {
            print("\(project.name): \(differences.count) difference(s) between the two builds (not required to match):\n  \(listed)\(more)")
            return
        }
        throw EndToEndFailure(step: "determinism", message: "\(differences.count) difference(s) between out1 and out2:\n  \(listed)\(more)")
    }

    // MARK: - The whole run

    /// Steps 1 to 7. The root is cleaned up on the way out, kept with SEMEL_E2E_KEEP=1.
    func run() throws {
        defer { cleanUp() }
        try materialise()
        try configure()
        let out1 = try coldBuild(home: "home1", out: "out1")
        try checkProducts(in: out1)
        let out2 = try coldBuild(home: "home2", out: "out2")
        try checkProducts(in: out2)
        try checkDeterminism(out1, out2)
    }
```

- [ ] **Step 6: Run c-hello through the whole sequence once, by hand**

Add nothing yet; in `BuildTests.swift` add a second test:

```swift
    func test_cHelloBuildsTwiceToTheSameBytes() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.cHello)

        XCTAssertNoThrow(try run.run(), "see the failure's steps and tails")
    }
```

Run: `swift test --filter BuildTests`

**If it passes:** go to step 7.

**If the determinism step fails:** read the differences. The likely finding is the linked executables (`hello`, `hello.dylib`) differing at a content offset while `config.txt` matches: `ld` writes the object files' absolute paths into a linked Mach-O's debug map when the objects carry debug info, and every tool run's sandbox is a fresh random directory (`LocalFileSystemTool.swift:49`). Confirm with the kept root (`SEMEL_E2E_KEEP=1 swift test --filter BuildTests`), then `strings -a <root>/out1/hello | grep /var/folders | head` against `out2`. Do **not** change the toolchains in this plan. Instead:

1. In `Projects.swift`, set `expectDeterministic: false` on the affected fixture with a comment of this shape, replacing the path family with what you saw:

```swift
        // The linked binaries differ between two cold builds: ld records each object
        // file's sandbox path, and a tool's sandbox is a fresh directory per run. B-49.
        expectDeterministic: false)
```

2. Record the finding in BACKLOG.md under B-49 in Task 11, quoting one difference line verbatim, so the entry states what the harness observed rather than what was feared.

Either way the test must be green before step 7.

- [ ] **Step 7: Lint and commit**

Run: `swiftlint --strict --quiet` — expected: no output.

```bash
git add EndToEnd/Tests
git commit -m "End-to-end harness, part 3: the second cold build and the byte-for-byte diff of the two export trees"
```

---

### Task 8: The fixture tests, one per roster entry

**Files:**
- Create: `EndToEnd/Tests/FixtureTests.swift`
- Modify: `EndToEnd/Tests/BuildTests.swift` (delete `test_cHelloBuildsTwiceToTheSameBytes`, now covered)
- Possibly modify: `EndToEnd/Tests/Projects.swift` (expected products, `expectDeterministic`)

**Interfaces:**
- Consumes: `EndToEndRun.run()`, `Projects.fixtures`.

- [ ] **Step 1: Write FixtureTests.swift**

```swift
//
//  FixtureTests.swift
//  SemelEndToEndTests
//
//  Every fixture, through the whole run, on every `swift test`. One test per project so
//  a failure names the project in the test's name, not only in its message.
//

import XCTest

final class FixtureTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
    }

    private func build(_ project: Project, file: StaticString = #filePath, line: UInt = #line) throws {
        let run = try EndToEndRun(project: project)
        do {
            try run.run()
        } catch {
            XCTFail("\(project.name)\n\(error)", file: file, line: line)
        }
    }

    func test_cHello() throws          { try build(Projects.cHello) }
    func test_cppEmu6502() throws      { try build(Projects.cppEmu6502) }
    func test_swiftMyApp() throws      { try build(Projects.swiftMyApp) }
    func test_swiftHelloApp() throws   { try build(Projects.swiftHelloApp) }

    /// The roster and the tests above must not drift apart.
    func test_everyFixtureInTheRosterHasATestHere() {
        let tested: Set<String> = ["c-hello", "cpp-emu6502", "swift-my-app", "swift-hello-app"]
        XCTAssertEqual(Set(Projects.fixtures.map(\.name)), tested)
    }
}
```

Delete `test_cHelloBuildsTwiceToTheSameBytes` from `BuildTests.swift`.

- [ ] **Step 2: Run them, one at a time first**

Run: `swift test --filter FixtureTests/test_cppEmu6502`
Run: `swift test --filter FixtureTests/test_swiftMyApp`
Run: `swift test --filter FixtureTests/test_swiftHelloApp`

For each failure, read the `EndToEndFailure`:

- `prepare` failing on `swift/HelloApp`: Task 3 was skipped or its regex missed the formula's spelling; check `semel.config` in a kept root has `apple.assetCatalogCompiler` lines.
- `build` failing on `swift/MyApp` with the log waiting for `input:/swift/MyLibrary`: `alsoPush` did not reach the command list; check the `semel` arguments in the failure's command line.
- `products` failing: the expected product name is wrong for what the converter publishes. Read the `exported:` listing in the message and correct `expectedProducts` in `Projects.swift` to the real names; the archives beside the app (`libHelloKit.a`, `libMyLibrary.a`, B-67) are not expected products and need no entry.
- `determinism` failing: apply Task 7 step 6's rule to that project.

- [ ] **Step 3: Run the whole target and time it**

Run: `time swift test --filter SemelEndToEndTests`
Expected: all pass. Note the wall time in the commit message; it lands on every PR.

- [ ] **Step 4: Run the whole root suite once**

Run: `swift test`
Expected: all pass, and the total now includes the end-to-end target.

- [ ] **Step 5: Lint and commit**

Run: `swiftlint --strict --quiet` — expected: no output.

```bash
git add EndToEnd/Tests
git commit -m "End-to-end fixture tests: the C, C++ and both Swift fixtures build twice through both binaries on every swift test"
```

---

### Task 9: External projects: the clone cache and IceCubes

**Files:**
- Modify: `EndToEnd/Tests/CloneCache.swift` (replace the stub)
- Create: `EndToEnd/Tests/ExternalProjectTests.swift`

**Interfaces:**
- Produces: `CloneCache.checkout(name: String, url: String, commit: String) throws -> URL` — the cached checkout of that one commit at `<cache>/<name>-<commit>`; fetched on the first call, reused after; never built in.
- Consumes: `EndToEndEnvironment.cacheDirectory`, `ManagedProcess`.

- [ ] **Step 1: Write CloneCache.swift**

```swift
//
//  CloneCache.swift
//  SemelEndToEndTests
//
//  A pinned commit, fetched once into the cache as a checkout of that commit alone and
//  copied out for every run. The cache holds the raw checkout only; nothing is ever
//  built in it, so a run cannot poison the next.
//

import Foundation
import SemelTestSupport

enum CloneCache {

    static func checkout(name: String, url: String, commit: String) throws -> URL {
        let directory = EndToEndEnvironment.cacheDirectory.appendingPathComponent("\(name)-\(commit)", isDirectory: true)
        let marker = directory.appendingPathComponent(".semel-e2e-complete")
        if FileManager.default.fileExists(atPath: marker.path) {
            return directory
        }
        // A half-fetched checkout from an interrupted run is removed and fetched again.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q"], in: directory)
        try git(["fetch", "-q", "--depth", "1", url, commit], in: directory)
        try git(["checkout", "-q", "FETCH_HEAD"], in: directory)
        try Data().write(to: marker)
        return directory
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        let process = ManagedProcess(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
                                     environment: [:], currentDirectory: directory)
        try process.start()
        guard let status = process.waitForExit(timeout: 15 * 60), status == 0 else {
            process.kill()
            throw EndToEndFailure(step: "fetch", message: status.map { "exit status \($0)" } ?? "timed out",
                                  commandLine: process.commandLine, status: status, outputTail: process.outputTail())
        }
    }
}
```

- [ ] **Step 2: Write ExternalProjectTests.swift**

```swift
//
//  ExternalProjectTests.swift
//  SemelEndToEndTests
//
//  Real projects pinned by commit. Skipped unless SEMEL_E2E_EXTERNAL=1, because they
//  fetch, vendor and build for minutes; nightly in CI, on demand for a developer.
//

import XCTest

final class ExternalProjectTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
    }

    func test_icecubesPackagesBuildTwiceForTheSimulator() throws {
        let run = try EndToEndRun(project: Projects.icecubes)
        do {
            try run.run()
        } catch {
            XCTFail("icecubes\n\(error)")
        }
    }

    func test_everyExternalProjectInTheRosterHasATestHere() {
        XCTAssertEqual(Set(Projects.external.map(\.name)), ["icecubes"])
    }
}
```

- [ ] **Step 3: Confirm the skip is a skip**

Run: `swift test --filter ExternalProjectTests`
Expected: the tests report as skipped, and the run takes seconds.

- [ ] **Step 4: Run it for real, once**

Run: `SEMEL_E2E_EXTERNAL=1 swift test --filter ExternalProjectTests/test_icecubesPackagesBuildTwiceForTheSimulator`
Expected: passes within the fifteen-minute timeout per build. The first run fetches into `~/Library/Caches/semel/end-to-end/icecubes-3dc60a80…`; a second run finds the marker and skips the fetch. On a `products` failure, correct the five archive names from the `exported:` listing. On a `determinism` failure, apply Task 7 step 6's rule.

- [ ] **Step 5: Lint and commit**

Run: `swiftlint --strict --quiet` — expected: no output.

```bash
git add EndToEnd/Tests
git commit -m "End-to-end external projects: a clone cache keyed by commit, and IceCubesApp's packages on opt-in"
```

---

### Task 10: CI: fixtures on every PR, external projects nightly

**Files:**
- Modify: `.github/workflows/swift.yml`
- Create: `.github/workflows/end-to-end.yml`

- [ ] **Step 1: Note the root step's new scope**

In `swift.yml`, replace the `Test the CLI` step with:

```yaml
      # The root package's tests now include SemelEndToEndTests, which builds the C, C++
      # and Swift fixtures under EndToEnd/Fixtures through semelserv, semel and
      # semel-swift, twice each. External projects are not run here; see end-to-end.yml.
      - name: Test the CLI, the server and the end-to-end fixtures
        run: swift test
```

- [ ] **Step 2: Write end-to-end.yml**

```yaml
name: End-to-end

# Real projects pinned by commit, through both binaries, twice each. Nightly on main and
# on demand; too slow and too network-bound for every pull request, which runs the
# fixtures instead (swift.yml). The clone cache is keyed on the pinned commits, so a
# project is fetched once per pin change.
on:
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:

jobs:
  external-projects:
    runs-on: macos-15

    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.3.app

      - name: Restore the clone cache
        uses: actions/cache@v4
        with:
          path: ~/Library/Caches/semel/end-to-end
          key: semel-e2e-clones-${{ hashFiles('EndToEnd/Tests/Projects.swift') }}

      - name: Build
        run: swift build

      - name: Build the external projects twice each
        env:
          SEMEL_E2E_EXTERNAL: "1"
        run: swift test --filter SemelEndToEndTests
```

- [ ] **Step 3: Validate the YAML parses**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/end-to-end.yml"); YAML.load_file(".github/workflows/swift.yml"); puts "ok"'`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows
git commit -m "CI: the fixtures run with the root tests on every PR; a nightly workflow builds the external projects with a commit-keyed clone cache"
```

---

### Task 11: Documentation and the backlog

**Files:**
- Modify: `AGENTS.md` (the build-and-test block and the composition-root paragraph)
- Modify: `README.md` (a "Testing against real projects" paragraph; two sentences in "Dependencies, and clone to build" that the `prepare` changes of PRs #11 and #12 made untrue)
- Modify: `BACKLOG.md` (B-04, B-05, and B-49 if Task 7 found something)
- Modify: `docs/superpowers/specs/2026-09-15-semel-end-to-end-testing-design.md` (status line)

- [ ] **Step 1: AGENTS.md**

In the build-and-test code block, change the last line to:

```sh
swift test                                   # the CLI, transport, server and end-to-end fixture tests (~180)
SEMEL_E2E_EXTERNAL=1 swift test --filter SemelEndToEndTests   # plus the pinned external projects (minutes; needs the network)
```

Change the sentence `swift test` at the root runs **only** … `SemelServerTests`. to name four targets: `SemelCLITests`, `SemelTransportTests`, `SemelServerTests` and `SemelEndToEndTests`.

In the composition-root paragraph (the one beginning "Nothing registers a toolchain automatically."), append:

```
`EndToEnd/Tests` is the one place the three executables are run together, as a user
runs them: `EndToEndRun` starts `semelserv` over a fresh home, drives `semel` and
`semel-swift` against it, and builds each project twice to compare the bytes.
```

- [ ] **Step 2: README.md**

After the "Dependencies, and clone to build" section and before "## Architecture", add:

```markdown
### Testing against real projects

`swift test` builds the fixtures under `EndToEnd/Fixtures` — a C program, a C++ one,
a Swift package with a path dependency and a SwiftUI app for the simulator — through
`semelserv`, `semel` and `semel-swift` together, each twice in two fresh homes, and
requires the two export trees to match byte for byte. `SEMEL_E2E_EXTERNAL=1 swift test
--filter SemelEndToEndTests` adds the real projects pinned in `EndToEnd/Tests/Projects.swift`,
fetched once into `~/Library/Caches/semel/end-to-end`; CI runs those nightly.
`SEMEL_E2E_KEEP=1` keeps a run's directory under `/tmp/semel-tests` for inspection.
```

In "Dependencies, and clone to build", replace `every namespace the toolchains declare, the tools and SDK this machine has,` with `the namespaces the formula reads, the tools and SDK this machine has,`. Replace the two sentences `The one file `prepare` does not write is the xcconfig a project's README asks a developer to create; without it the bundle identifier's `$(BUNDLE_ID_PREFIX)` is reported unresolved at build time.` with:

```
An xcconfig the project names but the repository does not ship is put in place from the
template beside it (`.template`, `.example`, `.sample` or `.dist`), or from a file named
with `--xcconfig <name>=<file>`; failing both, `prepare` says which settings are left
undefined so the file can be written by hand.
```

- [ ] **Step 3: BACKLOG.md**

B-04: replace the sentence beginning `What remains is the safety net, in order: (b) a test that builds the same project in two subprocesses …` through `doubles as the determinism probe in B-11;` with:

```
The two-process byte-for-byte diff is built: `SemelEndToEndTests` builds every fixture
and every pinned external project cold twice, in two `semelserv` processes over two
fresh homes, and `TreeDiff` requires the export trees to match. What remains is
```

so the entry continues with `(c) a source-scanning test as a backstop.` Adjust the joining words so the paragraph reads.

B-05: append the sentence `Its home is `EndToEndRun`: an extra cold build with a perturbed environment, and the same `TreeDiff` against the first.`

B-49: only if Task 7 step 6 set `expectDeterministic: false` on any project, append a paragraph beginning `Observed by the end-to-end harness (2026-09-…):` followed by one quoted difference line and the project names, and the sentence `Those projects run with `expectDeterministic: false` until part 2 lands; the flag is the list of what this item owes.`

- [ ] **Step 4: The spec's status line**

Change `**Status:** approved design, not yet implemented.` to `**Status:** implemented; see `docs/superpowers/plans/2026-09-17-semel-end-to-end-testing.md` for what differed from this text.` and under it add a short list: `SemelServTests` is `SemelServerTests`; `swift-hello-app` does not skip; `swift-my-app` pushes `swift/MyLibrary` first (`Project.alsoPush`); `prepare` writes the namespaces a kept formula selects; `Project.expectDeterministic` and what it was set to, if anything.

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md README.md BACKLOG.md docs/superpowers/specs/2026-09-15-semel-end-to-end-testing-design.md
git commit -m "Document the end-to-end target: how to run it, what it proves, and what it closed in the backlog"
```

---

### Task 12: Finish

- [ ] **Step 1: The full verification, as CI will run it**

```bash
swift build
swift test --package-path SemelNodeKit
swift test --package-path SemelSwift
swift test --package-path SemelClang
swift test --package-path SemelApple
swift test --package-path SemelCore
swift test
swiftlint --strict
```
Expected: every suite passes; lint prints nothing.

- [ ] **Step 2: Push and open the PR**

Use the `superpowers:finishing-a-development-branch` skill. The PR description lists: the target and what it builds on every PR; the wall time of `swift test --filter SemelEndToEndTests`; the IceCubes run's outcome and time; what `expectDeterministic` was set to and why, if anything; the backlog items touched.

---

## Self-review

**Spec coverage.** §2 layout: Tasks 2, 4. §2 no committed configs: Task 2 and `RosterTests.test_noFixtureCommitsAConfig`. §2 test target depending on the three executables: Task 4. §3 roster and timeouts: Task 4; `alsoPush` is the confirmation §3 asked for. §4 steps 1–7: Tasks 5 (1, 2, 7), 6 (3, 4, 5), 7 (6). §4 failure evidence and timeouts: `EndToEndFailure`, `EndToEndRun.run(_:…)`, Task 5. §4 shared code: Task 1. §5 the three variables: Task 4; opt-in skip: Task 9; PR and nightly workflows: Task 10. §6 docs: Task 11. §7 is deliberately not built.

**Placeholders.** None; every code step is complete. The one open outcome, the determinism result, is handled by an explicit rule in Task 7 step 6 rather than left to the executor.

**Type consistency.** `EndToEndRun.binary(_:)`, `binariesAreBuilt`, `run(_:arguments:environment:currentDirectory:timeout:step:serverLog:)`, `materialise()`, `configure()`, `coldBuild(home:out:)`, `checkProducts(in:)`, `checkDeterminism(_:_:)`, `run()`, `cleanUp()` are used with these names throughout. `ServerSession.environment`, `logTail`, `start()`, `stop()`, `killIfRunning()` match between Task 6's two files. `TreeDiff.compare(_:_:)` returns `[Difference]` whose `description` strings are the ones `TreeDiffTests` asserts. `Project.alsoPush` and `expectDeterministic` are `var` with defaults so the roster's memberwise inits in Task 4 compile with or without them.

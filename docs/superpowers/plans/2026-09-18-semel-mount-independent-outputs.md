# Mount-Independent Tool Outputs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make what a tool writes independent of the directory its sandbox happened to get, prove it with a third build at a differently-named mount, and then make cache keys name inputs by their project-relative path.

**Architecture:** Three parts in the spec's order. (1) The sandbox contract is written down and each compiler and linker node gains a constant flag set that keeps the sandbox root out of debug info, the linker's debug map and the serialized `.swiftmodule`. (2) The end-to-end harness builds each fixture a third time from a copy at a longer-named mount and diffs it against the first. (3) `ProjectBuilder` stamps `projectRoot` onto every cacheable node it emits; the cache key strips that root from wire names and excludes the property itself.

**Tech Stack:** Swift 5.9 packages (`SemelNodeKit`, `SemelClang`, `SemelSwift`, `SemelCore`), XCTest with the existing `RecordingToolRunner`, the `SemelEndToEndTests` harness.

**Spec:** `docs/superpowers/specs/2026-09-18-semel-mount-independent-outputs-design.md`

## Global Constraints

- Order is binding (spec §7): flags and the written invariant first, the two-mounts step and node-level flag tests second, `projectRoot` and key stripping **last**. A key that ignores a prefix an artifact still embeds is the wrong-hit bug reintroduced.
- The sandbox root stays a fresh random directory; its canonical *name* is the constant `/semel`, declared once in `SemelNodeKit` as `ToolSandbox.canonicalRootName`, never a real directory (spec §3).
- Every path a node puts on a command line is relative to the sandbox root (spec §3 rule 2). No task may add an absolute sandbox path to any argument.
- The flag set is constant and exactly (spec §4): `ClangCompiler` `-fdebug-compilation-dir=/semel`; `ClangLinker` and `SwiftLinker` `-Xlinker -oso_prefix -Xlinker .`; `SwiftCompiler` `-file-compilation-dir /semel` and `-Xfrontend -no-serialize-debugging-options`. `ClangPreprocessor` gets nothing.
- The cache-key invariant (spec §5): *a node's cache key names every input by its path relative to the project root and by nothing above it.* A wire key that does not start with the project root is used whole. The project-relative remainder stays in the key.
- `projectRoot` is a node property written by `ProjectBuilder`, carried in `graphSpec`, and excluded from the key by name through a declared `cacheKeyExcludedProperties`, not by a heuristic (spec §5).
- Verification is the existing harness plus a third build at a mount whose name has a different length (spec §6); equal cache keys are a `SemelCore` unit test.
- Repository rules: work in a `.claude` worktree and finish by PR; `swiftlint --strict` clean; Swift comments are timeless (never "now", "no longer", "today", "after the split"); a toolchain package must not depend on the engine; `SemelSwift` and `SemelClang` see only `SemelNodeKit`.

## File structure

```
SemelNodeKit/Sources/SemelNodeKit/ToolSandbox.swift          NEW: the canonical root name
SemelNodeKit/Sources/SemelNodeKit/ToolRunner.swift           MODIFY: invariant doc; sandboxPathUsed -> resolvedSandboxPath
SemelNodeKit/Sources/SemelNodeKit/LocalFileSystemTool.swift  MODIFY: field rename
SemelNodeKit/Tests/LocalFileSystemToolTests.swift            MODIFY: field rename
SemelSwift/Sources/SemelSwift/SwiftPackageReader.swift       MODIFY: field rename
SemelSwift/Tests/TestSupport.swift, SemelClang/Tests/TestSupport.swift, SemelApple/Tests/TestSupport.swift,
SemelCore/Tests/SemelCoreTests/TestGlobals.swift, semel/Tests/ToolsCommandTests.swift   MODIFY: field rename
SemelClang/Sources/SemelClang/ClangCompiler.swift            MODIFY: the flag
SemelClang/Tests/ClangCompilerTests.swift                    MODIFY: exact lists; new test
SemelClang/Sources/SemelClang/ClangLinker.swift              MODIFY: the flag
SemelClang/Tests/ClangLinkerTests.swift                      MODIFY: new test
SemelSwift/Sources/SemelSwift/SwiftCompiler.swift            MODIFY: the two flags
SemelSwift/Tests/SwiftCompilerTests.swift                    MODIFY: new test
SemelSwift/Sources/SemelSwift/SwiftLinker.swift              MODIFY: the flag, non-archive linkages only
SemelSwift/Tests/SwiftLinkerTests.swift                      MODIFY: two new tests
EndToEnd/Tests/Project.swift                                 MODIFY: twoMounts
EndToEnd/Tests/Projects.swift                                MODIFY: icecubes opts out
EndToEnd/Tests/EndToEndRun.swift                             MODIFY: coldBuild(base:…), step 6b, run()
SemelCore/Sources/SemelCore/GraphSpec.swift                  MODIFY: adding(property:where:)
SemelCore/Tests/SemelCoreTests/GraphSpecTests.swift          MODIFY (or create if absent): the transform's test
SemelCore/Sources/SemelCore/Nodes/ProjectBuilder.swift       MODIFY: stamp projectRoot
SemelCore/Tests/SemelCoreTests/ProjectBuilderTests.swift     MODIFY: the stamping test
SemelNodeKit/Sources/SemelNodeKit/Node.swift                 MODIFY: cacheKeyExcludedProperties
SemelCore/Sources/SemelCore/Cache.swift                      MODIFY: strip and exclude
SemelCore/Tests/SemelCoreTests/CacheKeyMountIndependenceTests.swift   NEW
BACKLOG.md, AGENTS.md, the spec                              MODIFY (Task 10)
```

---

### Task 1: The sandbox contract: `ToolSandbox`, the invariant, and the rename

**Files:**
- Create: `SemelNodeKit/Sources/SemelNodeKit/ToolSandbox.swift`
- Modify: `SemelNodeKit/Sources/SemelNodeKit/ToolRunner.swift:30-58` and `:154-160`, `:216-222`
- Modify: `SemelNodeKit/Sources/SemelNodeKit/LocalFileSystemTool.swift:197`
- Modify: `SemelSwift/Sources/SemelSwift/SwiftPackageReader.swift:139-141`
- Modify: `SemelNodeKit/Tests/LocalFileSystemToolTests.swift:40-123`, `SemelSwift/Tests/TestSupport.swift:86`, `SemelClang/Tests/TestSupport.swift:86`, `SemelApple/Tests/TestSupport.swift:99`, `SemelCore/Tests/SemelCoreTests/TestGlobals.swift:102`, `semel/Tests/ToolsCommandTests.swift:29`

**Interfaces:**
- Produces: `public enum ToolSandbox { public static let canonicalRootName = "/semel" }`; `ToolExecuteResult.resolvedSandboxPath` and `SimplifiedToolExecuteResult.resolvedSandboxPath` (renamed from `sandboxPathUsed`).

- [ ] **Step 1: Write ToolSandbox.swift**

```swift
//
//  ToolSandbox.swift
//  SemelNodeKit
//
//  What a tool is allowed to know about the directory it runs in.
//

import Foundation

/// The contract every `ToolRunner` keeps with the nodes that call it.
///
/// A tool runs in a fresh directory of its own, with its inputs materialised below that
/// directory at their wire keys — an input-file-system path such as `input:/c/src/hello.c`
/// — and with that directory as its working directory. Every path a node puts on a
/// command line is relative to it. The directory's real name is therefore never on a
/// command line and never in an output, so a tool run at a different mount, or on a
/// different machine, writes the same bytes.
///
/// Where a tool insists on recording a directory name anyway — a compiler's debug
/// information records the compilation directory — the nodes tell it this name instead.
public enum ToolSandbox {

    /// The name a tool is told the sandbox root is called, so that a path it records
    /// names the build rather than the directory this run happened to get. Never a real
    /// directory: nothing resolves it, nothing creates it, and the tool never opens it.
    public static let canonicalRootName = "/semel"
}
```

- [ ] **Step 2: Rename the field and state the invariant on the protocol**

In `ToolRunner.swift`, replace lines 30–38 with:

```swift
public struct ToolExecuteResult {
    public let exitCode: Int32
    /// The sandbox root as the tool saw it, symlinks resolved (`/var/…` is `/private/var/…`).
    /// For a caller that must undo a path a tool wrote into its output — `swift package
    /// dump-package` prints absolute paths — not for building a command line, which never
    /// names the sandbox (see `ToolSandbox`).
    public let resolvedSandboxPath: String

    public init(exitCode: Int32, resolvedSandboxPath: String) {
        self.exitCode = exitCode
        self.resolvedSandboxPath = resolvedSandboxPath
    }
}
```

Replace the doc comment on `protocol ToolRunner` (lines 40–44) with:

```swift
/// A tool that can be executed with a set of arguments and input files,
/// producing output files and log messages via a ToolOutput callback object.
///
/// The contract with the caller is `ToolSandbox`'s: inputs are materialised at their wire
/// keys below a fresh root that is the working directory, every argument is relative to
/// that root, and the root's real name reaches neither the command line nor the outputs.
/// `expectedOutputFolders` are sandbox-relative folders whose every file, at any
/// depth, is reported through `output.writeTreeEntry` — for a tool that decides its
/// own file set. A folder that is not there after the run is an error, like a missing
/// output file.
```

In `SimplifiedToolExecuteResult` (line 158) rename `sandboxPathUsed` to `resolvedSandboxPath`; at line 218 `resolvedSandboxPath: result.resolvedSandboxPath,`.

In `LocalFileSystemTool.swift:197`: `return .init(exitCode: exitCode, resolvedSandboxPath: canonicalSandboxPath)`.

In `SwiftPackageReader.swift:139-141`:

```swift
        // resolvedSandboxPath is symlink-resolved, captured before the sandbox was deleted,
        // so a `/private/var/…` path SPM printed matches it.
        jsonOutput = stripOutSandboxPaths(sandboxPath: result.resolvedSandboxPath, jsonOutput: jsonOutput)
```

In each of the six test files, rename `sandboxPathUsed` to `resolvedSandboxPath` in the `ToolExecuteResult(...)` initialiser calls and in `LocalFileSystemToolTests`' assertions and comment (`:40` says "which is how sandboxPathUsed is repo…"; make it "which is how resolvedSandboxPath is reported").

- [ ] **Step 3: Confirm nothing else names the old field**

Run: `grep -rn "sandboxPathUsed" --include='*.swift' --exclude-dir=.build .`
Expected: no output.

- [ ] **Step 4: Build and run the suites that compile the renamed type**

Run: `swift build` (root), then `swift test --package-path SemelNodeKit`, `swift test --package-path SemelSwift`, `swift test --package-path SemelClang`, `swift test --package-path SemelApple`, `swift test --package-path SemelCore`, `swift test --filter ToolsCommandTests`.
Expected: all pass with the counts they had (NodeKit 127, Swift 152, Clang 50, Apple 54, Core 359).

- [ ] **Step 5: Lint and commit**

Run: `swiftlint --strict --quiet` — expected: no output.

```bash
git add SemelNodeKit SemelSwift SemelClang SemelApple SemelCore semel/Tests
git commit -m "ToolSandbox: the sandbox contract written down, its canonical root name, and resolvedSandboxPath"
```

---

### Task 2: `ClangCompiler` records `/semel` as its compilation directory

**Files:**
- Modify: `SemelClang/Sources/SemelClang/ClangCompiler.swift:100-112`
- Test: `SemelClang/Tests/ClangCompilerTests.swift`

**Interfaces:**
- Consumes: `ToolSandbox.canonicalRootName` (Task 1).

- [ ] **Step 1: Write the failing test**

In `ClangCompilerTests.swift`, after `test_targetComesFromConfigurationRatherThanALiteral`, add:

```swift
    /// Debug information records the compilation directory. Told the canonical name, an
    /// object built in one sandbox is byte-identical to the same object built in another.
    func test_recordsTheCanonicalSandboxNameAsTheCompilationDirectory() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.c.p"))

        XCTAssertTrue(executor.lastArguments.contains("-fdebug-compilation-dir=\(ToolSandbox.canonicalRootName)"),
                      "\(executor.lastArguments)")
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --package-path SemelClang --filter ClangCompilerTests`
Expected: the new test fails; `test_compilesTheInputAsCToAnObjectFileForTheTargetArchitecture` still passes.

- [ ] **Step 3: Add the flag**

In `ClangCompiler.swift`, after `arguments.append("-std=\(standard)")` (line 106) and before `arguments.append(inputs.inputSourceFile.filePath)`, add:

```swift
        // The object records its compilation directory in DWARF. The sandbox's real name
        // would make two builds of one file differ; the canonical name makes them agree.
        arguments.append("-fdebug-compilation-dir=\(ToolSandbox.canonicalRootName)")
```

- [ ] **Step 4: Update the exact-list assertion**

`test_compilesTheInputAsCToAnObjectFileForTheTargetArchitecture` asserts the whole list. Insert `"-fdebug-compilation-dir=/semel",` after `"-c", "-std=c17",`. Run `grep -n "lastArguments,$" SemelClang/Tests/ClangCompilerTests.swift` and update every other exact-list assertion in the file the same way.

- [ ] **Step 5: Run the package's tests**

Run: `swift test --package-path SemelClang`
Expected: 51 tests, 0 failures.

- [ ] **Step 6: Lint and commit**

```bash
git add SemelClang
git commit -m "ClangCompiler records /semel as the compilation directory, so objects do not embed the sandbox"
```

---

### Task 3: `ClangLinker` writes a sandbox-relative debug map

**Files:**
- Modify: `SemelClang/Sources/SemelClang/ClangLinker.swift:154-160`
- Test: `SemelClang/Tests/ClangLinkerTests.swift`

- [ ] **Step 1: Write the failing test**

After `test_dynamicLibraryFlagIsPassedOnlyWhenConfigured`, add:

```swift
    /// The linker's debug map names each object by path. `-oso_prefix .` makes that the
    /// sandbox-relative path, so a binary linked in one sandbox matches one linked in another.
    func test_prefixesTheDebugMapWithTheWorkingDirectory() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        let arguments = executor.lastArguments
        let index = try XCTUnwrap(arguments.firstIndex(of: "-oso_prefix"), "\(arguments)")
        XCTAssertEqual(Array(arguments[(index - 1)...(index + 2)]), ["-Xlinker", "-oso_prefix", "-Xlinker", "."])
        XCTAssertLessThan(index, try XCTUnwrap(arguments.firstIndex(of: "a.o")), "before the objects")
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --package-path SemelClang --filter ClangLinkerTests`
Expected: the new test fails on the unwrap.

- [ ] **Step 3: Add the flag**

In `ClangLinker.swift`, after the `if inputs.configuration.dynamicLibrary { arguments.append("-dynamiclib") }` block (line 156) and before `for objectFile in inputs.objectFiles`, add:

```swift
        // The debug map (N_OSO) names each object file. Prefixed with the working
        // directory it is the object's sandbox-relative path, not the sandbox's own name.
        arguments.append(contentsOf: ["-Xlinker", "-oso_prefix", "-Xlinker", "."])
```

- [ ] **Step 4: Run the package's tests**

Run: `swift test --package-path SemelClang`
Expected: 52 tests, 0 failures. `test_linksObjectFilesIntoADylibForTheTargetArchitecture` still passes: its prefix and suffix assertions are untouched by an insertion in the middle.

- [ ] **Step 5: Lint and commit**

```bash
git add SemelClang
git commit -m "ClangLinker prefixes the debug map with the working directory, so a binary does not embed the sandbox"
```

---

### Task 4: `SwiftCompiler` records `/semel` and stops serializing debugging options

**Files:**
- Modify: `SemelSwift/Sources/SemelSwift/SwiftCompiler.swift:412-414`
- Test: `SemelSwift/Tests/SwiftCompilerTests.swift`

- [ ] **Step 1: Write the failing test**

After `test_extraSourceFilesAreCompiledBesideTheFoldersOwn`, add:

```swift
    /// A Swift object records its compilation directory, and a `.swiftmodule` serializes the
    /// search paths it was built with — the sandbox root, in both. The canonical name closes
    /// the first; not serializing the options closes the second. Every compile here gets its
    /// own explicit `-I` flags, so nothing downstream needs the serialized set.
    func test_recordsTheCanonicalSandboxNameAndSerializesNoDebuggingOptions() throws {
        var input = try makeInput(folder: try manifest("input:/ext/Sources", [file("Main.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/ext/Sources/Main.swift": .value(try "// main".intern())]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        let arguments = executor.lastArguments
        let directory = try XCTUnwrap(arguments.firstIndex(of: "-file-compilation-dir"), "\(arguments)")
        XCTAssertEqual(arguments[directory + 1], ToolSandbox.canonicalRootName)
        let frontend = try XCTUnwrap(arguments.firstIndex(of: "-no-serialize-debugging-options"), "\(arguments)")
        XCTAssertEqual(arguments[frontend - 1], "-Xfrontend", "the frontend flag has no driver spelling")
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --package-path SemelSwift --filter SwiftCompilerTests`
Expected: the new test fails on the first unwrap.

- [ ] **Step 3: Add the flags**

In `SwiftCompiler.swift`, after `arguments.append("-emit-module-interface-path"); arguments.append(interfaceOutput)` (line 414) and before the `if !inputs.moduleFiles.isEmpty` block, add:

```swift
        // The object records its compilation directory; the canonical name keeps the
        // sandbox's real one out of it. The module would serialize the search paths it was
        // built with, sandbox root included; every consumer here is handed its own `-I`
        // flags, so the serialized copy is dropped. `-no-serialize-debugging-options` is a
        // frontend flag with no driver spelling.
        arguments.append("-file-compilation-dir");           arguments.append(ToolSandbox.canonicalRootName)
        arguments.append("-Xfrontend");                      arguments.append("-no-serialize-debugging-options")
```

- [ ] **Step 4: Run the package's tests**

Run: `swift test --package-path SemelSwift`
Expected: 153 tests, 0 failures. If any existing test asserts an exact `swiftc` argument list, insert the four new tokens at that position.

- [ ] **Step 5: Lint and commit**

```bash
git add SemelSwift
git commit -m "SwiftCompiler records /semel as the compilation directory and serializes no debugging options"
```

---

### Task 5: `SwiftLinker` prefixes the debug map for the linkages that run `ld`

A static archive is produced by `libtool`, which has no debug map and does not take `-Xlinker`. The flag goes on the executable and dynamic-library linkages only.

**Files:**
- Modify: `SemelSwift/Sources/SemelSwift/SwiftLinker.swift:202-206`
- Test: `SemelSwift/Tests/SwiftLinkerTests.swift`

- [ ] **Step 1: Write the failing tests**

After `test_linksToTheConfiguredOutputName`, add:

```swift
    /// An executable or a dynamic library goes through ld, whose debug map names each
    /// object by path; prefixed with the working directory it is the sandbox-relative path.
    func test_prefixesTheDebugMapForLinkagesThatRunTheLinker() throws {
        for linkage in ["executable", "dynamicLibrary"] {
            _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: linkage))

            let arguments = executor.lastArguments
            let index = try XCTUnwrap(arguments.firstIndex(of: "-oso_prefix"), "\(linkage): \(arguments)")
            XCTAssertEqual(Array(arguments[(index - 1)...(index + 2)]), ["-Xlinker", "-oso_prefix", "-Xlinker", "."], linkage)
        }
    }

    /// A static archive is written by libtool, which has no debug map and no `-Xlinker`.
    func test_aStaticArchiveGetsNoDebugMapPrefix() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: "staticArchive"))

        XCTAssertFalse(executor.lastArguments.contains("-oso_prefix"), "\(executor.lastArguments)")
    }
```

- [ ] **Step 2: Run them to see the first fail**

Run: `swift test --package-path SemelSwift --filter SwiftLinkerTests`
Expected: the first new test fails on the unwrap; the second passes already.

- [ ] **Step 3: Add the flag**

In `SwiftLinker.swift`, replace the `switch inputs.configuration.linkage` (lines 202–206) with:

```swift
        switch inputs.configuration.linkage {
        case .executable, .dynamicLibrary:
            if case .dynamicLibrary = inputs.configuration.linkage {
                arguments.append("-emit-library")
            }
            // ld's debug map (N_OSO) names each object file. Prefixed with the working
            // directory it is the object's sandbox-relative path, not the sandbox's own name.
            arguments.append(contentsOf: ["-Xlinker", "-oso_prefix", "-Xlinker", "."])
        case .staticArchive:
            // libtool writes the archive: no debug map, and no -Xlinker to pass one to.
            arguments.append(contentsOf: ["-emit-library", "-static"])
        }
```

- [ ] **Step 4: Run the package's tests**

Run: `swift test --package-path SemelSwift`
Expected: 155 tests, 0 failures. `test_declaredArgumentsReachTheLinkLine` asserts a suffix and `test_linksToTheConfiguredOutputName` a suffix of two; both are unaffected by an insertion at the front.

- [ ] **Step 5: Lint, then run the fixture harness once**

Run: `swiftlint --strict --quiet` — expected: no output.
Run: `swift test --filter FixtureTests` (from the root; about 40 s).
Expected: all four fixtures pass. This is the same-machine verification of Tasks 2–5 (spec §6): the flags are on every command line the fixtures run, and the two cold builds still match.

- [ ] **Step 6: Commit**

```bash
git add SemelSwift
git commit -m "SwiftLinker prefixes the debug map with the working directory for the linkages that run ld"
```

---

### Task 6: The two-mounts step in the end-to-end harness

**Files:**
- Modify: `EndToEnd/Tests/Project.swift` (add `twoMounts`)
- Modify: `EndToEnd/Tests/Projects.swift` (`icecubes` opts out)
- Modify: `EndToEnd/Tests/EndToEndRun.swift` (`coldBuild(base:home:out:)`, a section `6b`, `run()`)

**Interfaces:**
- Produces: `Project.twoMounts: Bool = true`; `EndToEndRun.coldBuild(base: URL? = nil, home: String, out: String) throws -> URL`; `EndToEndRun.materialiseSecondMount() throws -> URL`.

- [ ] **Step 1: Add the roster flag**

In `Project.swift`, after `var mayDiffer: [String] = []`, add:

```swift
    /// Whether the run builds a third time from a copy at a mount whose name has a
    /// different length, and requires that export to match the first. False only for a
    /// project whose build is too long to run three times.
    var twoMounts: Bool = true
```

In `Projects.swift`, on `icecubes`, after `mayDiffer: [".a"]` (or after `buildTimeout` if that entry is gone by the time this task runs), add `, twoMounts: false` with the comment `// Two cold builds of five minutes each are enough; the fixtures prove the third.`

- [ ] **Step 2: Let a cold build take its base**

In `EndToEndRun.swift`, change the signature and first lines of `coldBuild`:

```swift
    /// A fresh home named `home`, a server over it, one `semel` session that pushes the
    /// extra folders, builds the build folder and exports into `<root>/<out>`; then the
    /// server stopped cleanly. `base` is the copy to build, the run's own unless a caller
    /// materialised another. Returns the export directory.
    func coldBuild(base buildBase: URL? = nil, home homeName: String, out outName: String) throws -> URL {
        let buildBase = buildBase ?? base
        let server = ServerSession(home: root.appendingPathComponent(homeName, isDirectory: true))
        let out = root.appendingPathComponent(outName, isDirectory: true)
        try server.start()
        do {
            var commands = ["base \(buildBase.path)"]
```

Leave the rest of the function as it is.

- [ ] **Step 3: Add the second mount**

After `checkDeterminism` and `exempt(_:by:)`, before `// MARK: - The whole run`, add:

```swift
    // MARK: - 6b. A second mount

    /// The prepared copy again, beside the first under a folder whose name has a
    /// different length, so a path a tool embedded would show up as a size difference
    /// even if the diff's content check were fooled. Prepare is not run again: the copy
    /// already carries what prepare wrote, so the third build sees the first's inputs at
    /// a different place and nothing else.
    func materialiseSecondMount() throws -> URL {
        let mount = root.appendingPathComponent("mount-b-longer-name", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let copy = mount.appendingPathComponent(base.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: base, to: copy)
        return copy
    }

    /// Build three must match build one the way build two did. The roster's exemptions
    /// apply here too: an archive's timestamp is no more a mount than it is a run.
    func checkMountIndependence(_ out1: URL, _ out3: URL) throws {
        let differences = try TreeDiff.compare(out1, out3)
        let notExempt = differences.filter { !Self.exempt($0, by: project.mayDiffer) }
        guard !notExempt.isEmpty else {
            return
        }
        let listed = notExempt.prefix(20).map(\.description).joined(separator: "\n  ")
        let more = notExempt.count > 20 ? "\n  … and \(notExempt.count - 20) more" : ""
        throw EndToEndFailure(step: "two mounts", message: "\(notExempt.count) difference(s) between out1 and out3 (the second mount):\n  \(listed)\(more)")
    }
```

Then extend `run()`:

```swift
    /// Steps 1 to 7, with the second mount between the determinism check and clean-up.
    func run() throws {
        defer { cleanUp() }
        try materialise()
        try configure()
        let out1 = try coldBuild(home: "home1", out: "out1")
        try checkProducts(in: out1)
        let out2 = try coldBuild(home: "home2", out: "out2")
        try checkProducts(in: out2)
        try checkDeterminism(out1, out2)
        if project.twoMounts {
            let second = try materialiseSecondMount()
            let out3 = try coldBuild(base: second, home: "home3", out: "out3")
            try checkProducts(in: out3)
            try checkMountIndependence(out1, out3)
        }
    }
```

- [ ] **Step 4: Check the socket path still fits**

`home3/semelserv.sock` under `/tmp/semel-tests/<8 hex>/` is 44 bytes; the second mount adds nothing to any socket path because homes stay under the root. In `MaterialiseTests.test_aFixtureRunCopiesTheWholeTreeUnderAShortRoot`, change the asserted path from `home1/semelserv.sock` to `home3/semelserv.sock` so the longest name is the one pinned.

- [ ] **Step 5: Run the fixtures**

Run: `time swift test --filter FixtureTests`
Expected: all four pass; wall time grows by roughly half (each fixture builds three times). If `two mounts` fails for a fixture, the difference lines name the file and offset: that is a leak Tasks 2–5 did not close. Report it with the lines verbatim and stop; do not exempt it.

- [ ] **Step 6: Lint and commit**

```bash
git add EndToEnd/Tests
git commit -m "End-to-end: a third cold build from a copy at a longer-named mount must match the first"
```

---

### Task 7: `GraphSpecNode.adding(property:where:)`

A transform over a spec tree, so `ProjectBuilder` can stamp a property on every cacheable node of a product without rebuilding specs by hand.

**Files:**
- Modify: `SemelCore/Sources/SemelCore/GraphSpec.swift` (after the `GraphSpecNode` init, line ~103)
- Test: `SemelCore/Tests/SemelCoreTests/GraphSpecTests.swift` (add to it if it exists; otherwise create it with the class below)

**Interfaces:**
- Produces: `func adding(property key: String, value: String, where include: (GraphSpecNode) -> Bool) -> GraphSpecNode` on `GraphSpecNode`, internal.

- [ ] **Step 1: Write the failing test**

```swift
//
//  GraphSpecTests.swift
//  SemelCoreTests
//

@testable import SemelCore
import XCTest

final class GraphSpecTests: XCTestCase {

    /// The property lands on every node the predicate admits, at every depth, and on no
    /// other; a node that already has it keeps its value. Rendering sorts properties, so
    /// the new one appears where its key sorts.
    func test_addingAPropertyReachesEveryAdmittedNodeAndNoOther() throws {
        let spec = try GraphSpecNode.parse(
            "Tool(a: '1', in: ['x': StaticFile(path: 'p').output, 'y': Tool(projectRoot: 'kept', in: ['z': Other().output]).output]).output")

        let stamped = spec.adding(property: "projectRoot", value: "input:/repo") { $0.typeName != "StaticFile" }

        XCTAssertEqual(stamped.asString(omitOutputPort: false),
                       "Tool(a: '1', projectRoot: 'input:/repo', in: [\"x\": StaticFile(path: 'p').output, "
                       + "\"y\": Tool(projectRoot: 'kept', in: [\"z\": Other(projectRoot: 'input:/repo').output]).output]).output")
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --package-path SemelCore --filter GraphSpecTests`
Expected: compile error, `adding(property:value:where:)` not found.

- [ ] **Step 3: Implement**

In `GraphSpec.swift`, after the `GraphSpecNode` initialiser (before `// MARK: - Serialisation`), add:

```swift
extension GraphSpecNode {

    /// The same tree with `key: value` added to every node `include` admits, at any depth.
    /// A node that already carries `key` keeps its own value: what a formula states wins
    /// over what a builder would stamp.
    func adding(property key: String, value: String, where include: (GraphSpecNode) -> Bool) -> GraphSpecNode {
        var properties = self.properties
        if include(self), !properties.contains(where: { $0.key == key }) {
            properties.append(GraphSpecProperty(key: key, value: value))
        }
        let inputs = self.inputs.map { port in
            GraphSpecInputPort(portName: port.portName, wires: port.wires.map { wire in
                GraphSpecWire(name: wire.name, node: wire.node.adding(property: key, value: value, where: include))
            })
        }
        return GraphSpecNode(typeName: typeName, properties: properties, inputs: inputs,
                             outputs: outputs, outputPort: outputPort)
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --package-path SemelCore --filter GraphSpecTests`
Expected: 1 test, 0 failures. If the rendered string differs only in quoting (`"x"` versus `'x'` for wire names), correct the expectation to what `asString` renders; the renderer at `GraphSpec.swift:126` uses double quotes for wire names.

- [ ] **Step 5: Lint and commit**

```bash
git add SemelCore
git commit -m "GraphSpecNode.adding(property:where:): stamp a property on every admitted node of a spec tree"
```

---

### Task 8: `ProjectBuilder` stamps `projectRoot` on every cacheable node it emits

**Files:**
- Modify: `SemelCore/Sources/SemelCore/Nodes/ProjectBuilder.swift:61` and `:157-185`
- Test: `SemelCore/Tests/SemelCoreTests/ProjectBuilderTests.swift`

**Interfaces:**
- Produces: the property name constant `ProjectBuilder.projectRootProperty = "projectRoot"`; every node in an emitted product spec whose type has a static input port carries `projectRoot: '<outputFolder>'`.
- Consumes: `GraphSpecNode.adding(property:value:where:)` (Task 7).

- [ ] **Step 1: Write the failing test**

In `ProjectBuilderTests.swift`, in the class that has the `process(formula:includes:)` helper (the one with `properties: ["outputFolder": "input:/repo"]`), add:

```swift
    /// Every node a product is built through learns the project's root, so its cache key
    /// can name its inputs relative to it. A `StaticFile` is not built through: it is
    /// the pushed file itself, shared by every project that reads it, and stamping it
    /// would split it into one node per project.
    func test_stampsTheProjectRootOnEveryCacheableNodeOfAProduct() throws {
        let output = try process(formula:
            "product 'x' = SampleTool(configuration: ['c': StaticFile(path: 'input:/repo/c').output]).output")

        let spec = try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]?["output:/repo/x"])
        XCTAssertTrue(spec.contains("SampleTool(projectRoot: 'input:/repo', configuration: ["), spec)
        XCTAssertTrue(spec.contains("StaticFile(path: 'input:/repo/c')"), spec)
        XCTAssertFalse(spec.contains("StaticFile(path: 'input:/repo/c', projectRoot"), spec)
        XCTAssertTrue(spec.contains("OutputFile(path: 'output:/repo/x', input: ["), spec)
    }
```

`SampleTool` is registered for these tests by `TestGlobals`; if the formula fails to parse because `SampleTool` is unknown in this test class, register it in `setUpWithError` the way `CacheTests` does.

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --package-path SemelCore --filter ProjectBuilderTests`
Expected: the new test fails on the first `contains`.

- [ ] **Step 3: Implement**

In `ProjectBuilder.swift`, near the other static port names, add:

```swift
    /// The property every node built for a product carries: the project's root under
    /// `input:`, which its cache key strips from its inputs' paths. Stamped on nodes with a
    /// static input port — the ones the cache handles — and not on the file-system nodes,
    /// which are shared by every project that reads them.
    static let projectRootProperty = "projectRoot"

    static func isCacheable(_ spec: GraphSpecNode) -> Bool {
        guard let type = TypeRegistry.nodeType(forTypeName: spec.typeName) as? Node.Type else {
            return false
        }
        return !type.descriptor.staticInputPorts.isEmpty
    }
```

In `process`, inside `outputFileSpec(fullPath:shapeNode:)`, `shapeNode` is used to build both the metadata wire and the wrapper. Stamp it first: at the top of that function add

```swift
            let shapeNode = shapeNode.adding(property: Self.projectRootProperty, value: outputFolder.string,
                                             where: Self.isCacheable)
```

and in the tree-product branch, replace `let treeSpec = shapeNode.asString(omitOutputPort: false)` with

```swift
                let treeSpec = shapeNode
                    .adding(property: Self.projectRootProperty, value: outputFolder.string, where: Self.isCacheable)
                    .asString(omitOutputPort: false)
```

`outputFolder` is the `Path` computed at line 61; `outputFolder.string` renders `input:/repo`.

- [ ] **Step 4: Run the package's tests**

Run: `swift test --package-path SemelCore`
Expected: all pass. Tests that assert an exact product spec string for a cacheable node now need `projectRoot: '…'` in the expectation; update each to what the renderer emits (properties sorted by key, before inputs). Tests that assert on `StaticFile`, `Folder` or `OutputFile` specs are unchanged.

- [ ] **Step 5: Run the fixtures**

Run: `swift test --filter FixtureTests`
Expected: all four pass. Every tool node is re-created with the new property on a fresh graph, which is what a cold build does anyway.

- [ ] **Step 6: Lint and commit**

```bash
git add SemelCore
git commit -m "ProjectBuilder stamps projectRoot on every cacheable node it emits"
```

---

### Task 9: Mount-independent cache keys

**Files:**
- Modify: `SemelNodeKit/Sources/SemelNodeKit/Node.swift:48` (protocol) and `:112` (defaults)
- Modify: `SemelCore/Sources/SemelCore/Cache.swift:15-43`
- Create: `SemelCore/Tests/SemelCoreTests/CacheKeyMountIndependenceTests.swift`

**Interfaces:**
- Produces: `static var cacheKeyExcludedProperties: Set<String>` on `Node`, default `["projectRoot"]`; `Node.projectRelative(wire:)` (internal, in `Cache.swift`).

- [ ] **Step 1: Write the failing tests**

```swift
//
//  CacheKeyMountIndependenceTests.swift
//  SemelCoreTests
//
//  A cache key names every input by its path relative to the project root and by nothing
//  above it (B-49). Two developers point `base` at different folders and get the same key;
//  two files at different project-relative paths never do (`Cache.swift`'s lesson).
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class CacheKeyMountIndependenceTests: XCTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try TestGlobals.freshDatabase()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private func node(projectRoot: String?) throws -> SampleTool {
        var spec = "SampleTool()"
        if let projectRoot {
            spec = "SampleTool(projectRoot: '\(projectRoot)')"
        }
        let (record, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()
        return try SampleTool(thisNode: record)
    }

    private func input(source: String) throws -> ProcessInput {
        let configuration = ["toolDescriptor.name=sample", "toolDescriptor.version=1",
                             "toolDescriptor.platform=macOS", "toolDescriptor.architecture=arm64"].joined(separator: "\n")
        return ProcessInput(inputValues: [
            SampleTool.configuration: ["configuration": .value(try configuration.intern())],
            SampleTool.input: [source: .value(try "int main(){}".intern())],
        ])
    }

    func test_theSameProjectAtTwoPlacesUnderInputHasOneKey() throws {
        let shallow = try node(projectRoot: "input:/a/proj").buildCacheKeyFromAllInputs(
            input: try input(source: "input:/a/proj/src/hello.c"))
        let deep = try node(projectRoot: "input:/deeper/b/proj").buildCacheKeyFromAllInputs(
            input: try input(source: "input:/deeper/b/proj/src/hello.c"))

        XCTAssertEqual(shallow, deep)
    }

    func test_twoProjectRelativePathsStillHaveTwoKeys() throws {
        let tool = try node(projectRoot: "input:/a/proj")

        let one = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/a/proj/src/a.c"))
        let two = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/a/proj/src/b.c"))

        XCTAssertNotEqual(one, two, "the project-relative path stays in the key")
    }

    func test_aWireOutsideTheProjectRootIsKeyedWhole() throws {
        let tool = try node(projectRoot: "input:/a/proj")

        let inside  = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/a/proj/x.c"))
        let outside = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/elsewhere/x.c"))

        XCTAssertNotEqual(inside, outside)
    }

    /// The root is not a cache input: two nodes that differ only in where their project
    /// sits agree on every key. Without this the property would put back the very string
    /// the wire names had stripped.
    func test_theProjectRootPropertyIsNotPartOfTheKey() throws {
        let one = try node(projectRoot: "input:/p").buildCacheKeyFromAllInputs(input: try input(source: "input:/p/x.c"))
        let two = try node(projectRoot: "input:/q").buildCacheKeyFromAllInputs(input: try input(source: "input:/q/x.c"))

        XCTAssertEqual(one, two)
    }

    /// A node with no root — every node created before this property existed, and every
    /// node a formula wires by hand — keys exactly as it did.
    func test_aNodeWithoutAProjectRootKeysItsWiresWhole() throws {
        let tool = try node(projectRoot: nil)

        let key = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/a/proj/src/hello.c"))
        let moved = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/b/proj/src/hello.c"))

        XCTAssertNotEqual(key, moved)
    }
}
```

If `TestGlobals.freshDatabase()` is not the helper `CacheTests` uses to get its database, copy `CacheTests.setUpWithError` exactly.

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path SemelCore --filter CacheKeyMountIndependenceTests`
Expected: `test_theSameProjectAtTwoPlacesUnderInputHasOneKey` and `test_theProjectRootPropertyIsNotPartOfTheKey` fail; the other three pass already.

- [ ] **Step 3: Declare the exclusion on `Node`**

In `Node.swift`, after `func cacheKeyMaterial(input:)` in the protocol (line 48), add:

```swift

    /// Properties that are part of a node's identity but not of its cache key: a value
    /// the key deliberately strips from elsewhere, which would otherwise return through
    /// the properties. `projectRoot` is the one every node has reason to exclude.
    static var cacheKeyExcludedProperties: Set<String> { get }
```

In the protocol extension with the defaults (after `cacheKeyMaterial`'s default at line 112–114), add:

```swift
    public static var cacheKeyExcludedProperties: Set<String> { ["projectRoot"] }
```

- [ ] **Step 4: Strip and exclude in `Cache.swift`**

Replace `buildCacheKeyPartFromOneInput` and `nodeCacheKey` (lines 15–43) with:

```swift
    /// The property `ProjectBuilder` stamps on every node it builds a product through.
    static var projectRootProperty: String { "projectRoot" }

    /// A wire key relative to the node's project root, when it has one and the key lies
    /// under it; the key whole otherwise. Two developers who point `base` at different
    /// folders put the same project at different places under `input:`; the remainder is
    /// what both builds have in common. A key of another shape — `wire0`, `product`,
    /// `modules/…` — keeps more in the key, never less.
    func projectRelative(wire: String) -> String {
        guard let root = thisNode.properties[Self.projectRootProperty], !root.isEmpty else {
            return wire
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard wire.hasPrefix(prefix) else {
            return wire
        }
        return String(wire.dropFirst(prefix.count))
    }

    func buildCacheKeyPartFromOneInput(inputPort: String, input: ProcessInput) throws -> String {
        // Keying on a partial input set would produce a key that collides with a
        // different set of inputs — the one failure mode a cache must never have.
        guard let oneInput = input.inputValues[inputPort] else {
            throw NodeError.other(
                message: "Cannot build a cache key for \(type(of: self)): input port '\(inputPort)' has no entry")
        }

        // Both halves matter.  The wire key is the file's path, and the tools embed it —
        // in the object file's debug info, in the output filename derived from it, and in
        // the compiler output published on the log ports.  Keying on the values alone
        // meant identical content at a different path scored a hit and came back with
        // another file's build. What the key names is the path relative to the project:
        // the tools embed no more than that (ToolSandbox), so no more than that is an input.
        return try oneInput
            .sorted { $0.key < $1.key }
            .map { CacheKeyEntry(wire: projectRelative(wire: $0.key), value: $0.value) }
            .toJSON()
    }

    /// The node's own contribution: its type, its properties less the excluded ones, and
    /// whatever it declares it reads from outside its inputs (`cacheKeyMaterial`). A node
    /// with no material and no excluded property adds nothing, so the key format for
    /// every node created before `projectRoot` existed is unchanged.
    private func nodeCacheKey(input: ProcessInput) throws -> String {
        let excluded = Self.cacheKeyExcludedProperties
        let properties = thisNode.properties.filter { !excluded.contains($0.key) }
        var key = "\(String(describing: type(of: self)))\n\(properties.asPlainText())"
        if let material = try cacheKeyMaterial(input: input) {
            key.append("\n\(material)")
        }
        return key
    }
```

`Self.cacheKeyExcludedProperties` is available because `Node` is the extended protocol; `properties.asPlainText()` is the same `[String: String]` extension the old line used.

- [ ] **Step 5: Run the core suite**

Run: `swift test --package-path SemelCore`
Expected: all pass, including `CacheTests`' key-format pin: a `SampleTool()` with no `projectRoot` has the same properties text and the same wire names as before.

- [ ] **Step 6: Run the fixtures and the root suite**

Run: `swift test --filter FixtureTests`, then `swift test`.
Expected: all pass. Three builds per fixture still match.

- [ ] **Step 7: Lint and commit**

```bash
git add SemelNodeKit SemelCore
git commit -m "Cache keys name inputs relative to the project root and exclude the root itself (closes B-49 parts 1-3)"
```

---

### Task 10: Backlog, AGENTS.md and the spec

**Files:**
- Modify: `BACKLOG.md` (B-49)
- Modify: `AGENTS.md` (the toolchain paragraph)
- Modify: `docs/superpowers/specs/2026-09-18-semel-mount-independent-outputs-design.md` (status line)

- [ ] **Step 1: B-49**

Replace the B-49 entry with one in the shape of B-10 (done, then residuals):

```
**B-49** `open` — **Tool outputs must not depend on where the inputs are mounted — residuals.**
Done 2026-09-18: the sandbox contract is `ToolSandbox` (inputs at their wire keys below a
fresh root that is the working directory; every argument relative to it; the root's
canonical name `/semel`); `ClangCompiler` and `SwiftCompiler` record `/semel` as the
compilation directory, `ClangLinker` and `SwiftLinker` prefix the debug map with the
working directory, and `SwiftCompiler` serializes no debugging options, which is what kept
the sandbox root out of a `.swiftmodule` built without `-g`; the end-to-end harness builds
every fixture a third time from a copy at a longer-named mount and requires it to match;
and a cache key names each input relative to `projectRoot`, the property `ProjectBuilder`
stamps on every cacheable node and the key excludes by name. The checkout prefix was never
in the graph: the client pushes base-relative paths. What remains:

1. The implicit clang module cache path in a Swift object built with `-g`
   (`/var/folders/<user>/C/clang/ModuleCache/…`): per user, stable on one machine,
   different between machines. Explicit modules would remove the cache rather than move it.
2. `OutputFile.path` and `ProjectBuilder.outputFolder` in their own nodes' keys. Both
   determine those nodes' outputs, so stripping them needs its own argument; neither sits
   upstream of a compile.
3. Whether `-Xfrontend -no-serialize-debugging-options` is safe in every graph. IceCubes
   builds with it; the fallback, if a graph ever needs the serialized search paths, is
   `-file-compilation-dir` alone and accepting the `.swiftmodule` leak.
4. `{sandbox}` substitution for a node that ever needs the real root: specified in the
   design, built by nothing, so the answer exists without an API.
```

Where the current B-49 text points at B-72 (the archive-timestamp sentence), keep that sentence if B-72 is still open on this branch's base; drop it if B-72 has been closed on `main` by the time this task runs (check `grep -n "B-72" BACKLOG.md`).

- [ ] **Step 2: AGENTS.md**

In the paragraph beginning "**A toolchain package must not depend on the engine.**", append after its last sentence:

```
A toolchain node never puts an absolute sandbox path on a command line: `ToolSandbox` in
`SemelNodeKit` is the contract, and `/semel` is the name a tool is told when it insists on
recording its directory. The end-to-end harness's third build at a second mount is what
catches a node that breaks it.
```

- [ ] **Step 3: The spec**

Change the status line to `**Status:** implemented 2026-09-18; see BACKLOG B-49 for the residuals. Plan: …` keeping the plan path. Under it, one list of what differed from the text, if anything did (a flag placed differently, a test that had to change); if nothing did, say so in one sentence.

- [ ] **Step 4: Commit**

```bash
git add BACKLOG.md AGENTS.md docs/superpowers/specs/2026-09-18-semel-mount-independent-outputs-design.md
git commit -m "B-49: record what landed and what remains; the sandbox contract in AGENTS.md"
```

---

### Task 11: Finish

- [ ] **Step 1: The full verification, as CI runs it**

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

- [ ] **Step 2: The IceCubes run, once**

Run: `SEMEL_E2E_EXTERNAL=1 swift test --filter ExternalProjectTests`
Expected: passes. This is the evidence spec §8 question 1 asks for: five roots over a real package graph with system-library module maps build with `-no-serialize-debugging-options`. If it fails in a way that names a module or a search path, record the failure verbatim in the report, revert Task 4's second flag only, and record the fallback in B-49's residual 3.

- [ ] **Step 3: Push and open the PR**

Use `superpowers:finishing-a-development-branch`. The PR description lists: the flag set per node; the third build's result per fixture and its added wall time; the IceCubes outcome; the key change and why nodes without `projectRoot` keep their keys; the residuals.

---

## Self-review

**Spec coverage.** §3 (contract, constant, rename): Task 1. §4 (flags per node, `ClangPreprocessor` untouched): Tasks 2–5. §5 (invariant, `projectRoot` via `ProjectBuilder`, exclusion set, stripping, fail-safe for other wire shapes): Tasks 7–9. §6 (harness diff, two mounts, key unit tests, per-flag node tests): Tasks 2–6 and 9. §7 order: Tasks 1–5, then 6, then 7–9. §8: question 1 is settled by Task 11 step 2 with the fallback written down; questions 2, 4 and 5 are recorded as residuals in Task 10; question 3 is accepted by Task 8.

**Placeholders.** None. Each code step is complete; the two conditional instructions (exact-list assertions to update, `TestGlobals.freshDatabase()` if named differently) tell the implementer exactly what to look for and what to do.

**Type consistency.** `ToolSandbox.canonicalRootName` (Task 1) is what Tasks 2 and 4 pass. `resolvedSandboxPath` is used consistently across Task 1's files. `Project.twoMounts`, `coldBuild(base:home:out:)`, `materialiseSecondMount()`, `checkMountIndependence(_:_:)` match between Task 6's steps. `GraphSpecNode.adding(property:value:where:)` (Task 7) is what Task 8 calls with `Self.isCacheable`. `ProjectBuilder.projectRootProperty` and `Node.projectRootProperty` are both `"projectRoot"`, and `cacheKeyExcludedProperties` defaults to that string.

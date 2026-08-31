# Configuration Selector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configuration reaches a node as a wire value selected by namespace prefix, so editing an unrelated setting does not rebuild ten thousand compilers — and no setting has a default.

**Architecture:** A new `ConfigSubset` node takes a config file on a wire, keeps the keys under one prefix, strips the prefix, and emits `key=value` text. It sits upstream of the per-target `Configuration` nodes so that one node absorbs a config edit and the cascade stops there when its slice is unchanged. Node identity carries *which file and which prefix*; the values themselves are never in a searchKey.

**Tech Stack:** Swift 6, SPM (five packages), GRDB/SQLite, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-30-semel-configuration-design.md`

## Global Constraints

- **No default values, anywhere.** A tool that is not given a setting it needs fails naming what is missing. A default baked into the binary means upgrading Semel changes what a previous build meant.
- **Node kinds are permanent.** Existing IDs cannot be renumbered without orphaning live databases. Kinds in use: 1, 3, 5, 6, 8, 9, 15, 17, 18, 19, 20, 21, 23, 24. This plan allocates **25**.
- **Configuration values must never be node properties.** Properties are rendered into `searchKey`; a value there recreates the node on every edit and orphans its cache.
- **Determinism:** anything rendered into a formula or a wire value must be sorted. `Dictionary` iteration order is seeded per process.
- **Comments describe the present.** No "used to", "the old X", or narration of what changed — that belongs in commit messages.
- **Every task ends green:** `swift build` plus all five suites (`SemelNodeKit`, `SemelSwift`, `SemelClang`, `SemelCore`, root CLI). Baseline is 464 tests.
- **Run tests with absolute paths:** `swift test --package-path /Users/jadeburton/Semel/build_system/<Package>`. A bare relative path breaks when the shell's directory has drifted.
- **After deleting or renaming a file**, clear the stale SPM plan for that package: `rm -f <Package>/.build/build.db <Package>/.build/plan.json`. Otherwise the build fails with "missing inputs" for a file that no longer exists.

---

### Task 1: The `ConfigSubset` node

**Files:**
- Create: `SemelCore/Sources/SemelCore/NodeFunctions/ConfigSubset.swift`
- Modify: `SemelCore/Sources/SemelCore/BuildEngine.swift:38-46` (register the type)
- Test: `SemelCore/Tests/SemelCoreTests/ConfigSubsetTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `ConfigSubset.kind: UInt = 25`; properties `prefix: String`; input port `"input"` (required, one wire); output port `"output"` carrying `key=value` text with the prefix stripped. Formula form: `ConfigSubset(prefix: 'swift.compiler', input: ['config': StaticFile(path: 'input:/semel.config').output]).output`

- [ ] **Step 1: Write the failing tests**

```swift
//
//  ConfigSubsetTests.swift
//  SemelCoreTests
//
//  Selecting one node's settings out of a config file that holds everyone's.
//
//  The selection is what keeps an edit local. A node wired to `swift.compiler` must produce a
//  byte-identical value when `clang.linker.target` changes, because an identical value is what
//  stops writeToOutputPort from scheduling anything downstream — and downstream here is every
//  compiler in the project.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ConfigSubsetTests: SemelCoreTestCase {

    private func subset(prefix: String, file: String) throws -> String {
        let node = try ConfigSubset(thisNode: Node(id: 1, kind: ConfigSubset.kind,
                                                   properties: ["prefix": prefix]))
        let output = try node.process(input: ProcessInput(inputValues: [
            ConfigSubset.inputPort: ["config": .value(try file.intern())]
        ]))
        return try XCTUnwrap(output.outputValues[ConfigSubset.outputPort])
            .expectValue().resolveAsString()
    }

    private let everyones = """
        swift.compiler.sdkVersion=26.5
        swift.compiler.optimisationLevel=speed
        swift.linker.sdkVersion=26.5
        clang.linker.target=arm64-apple-macos14.0
        """

    func test_keepsOnlyTheKeysUnderItsPrefix() throws {
        let result = try subset(prefix: "swift.compiler", file: everyones)

        XCTAssertEqual(result, "optimisationLevel=speed\nsdkVersion=26.5")
    }

    /// The whole point. An unrelated edit must leave this value untouched, because equality is
    /// what stops the cascade.
    func test_anUnrelatedKeyChangingLeavesTheValueIdentical() throws {
        let before = try subset(prefix: "swift.compiler", file: everyones)
        let after = try subset(prefix: "swift.compiler",
                               file: everyones.replacingOccurrences(of: "arm64-apple-macos14.0",
                                                                    with: "x86_64-apple-macos14.0"))

        XCTAssertEqual(before, after)
    }

    /// A prefix match is on whole segments. `swift.compiler` must not swallow
    /// `swift.compilerPlugin`, or two unrelated tools would share a slice.
    func test_matchesWholeSegmentsOnly() throws {
        let result = try subset(prefix: "swift.compiler", file: """
            swift.compiler.sdkVersion=26.5
            swift.compilerPlugin.sdkVersion=99.0
            """)

        XCTAssertEqual(result, "sdkVersion=26.5")
    }

    /// Keys may be dotted themselves. Stripping is not parsing: whatever follows the prefix is
    /// the key, however many dots it has.
    func test_keepsDottedKeysWhole() throws {
        let result = try subset(prefix: "swift.compiler", file: """
            swift.compiler.toolDescriptor.version=6.3.3
            """)

        XCTAssertEqual(result, "toolDescriptor.version=6.3.3")
    }

    /// Sorted, because this becomes a wire value that is compared for equality. Two runs
    /// producing the same settings in different orders would look like a change.
    func test_outputIsSorted() throws {
        let result = try subset(prefix: "p", file: "p.zebra=1\np.alpha=2\np.middle=3")

        XCTAssertEqual(result, "alpha=2\nmiddle=3\nzebra=1")
    }

    func test_aPrefixThatMatchesNothingProducesAnEmptyConfiguration() throws {
        XCTAssertEqual(try subset(prefix: "rust.compiler", file: everyones), "")
    }

    /// The prefix on its own is not a key — there is nothing left after stripping it.
    func test_ignoresAnExactMatchWithNoRemainder() throws {
        XCTAssertEqual(try subset(prefix: "swift.compiler", file: "swift.compiler=x"), "")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/jadeburton/Semel/build_system/SemelCore --filter ConfigSubset`
Expected: FAIL — "cannot find 'ConfigSubset' in scope".

- [ ] **Step 3: Write the implementation**

Create `SemelCore/Sources/SemelCore/NodeFunctions/ConfigSubset.swift`:

```swift
// ConfigSubset.swift
// SemelCore
//
// Selects one node's settings out of a config file that holds everyone's.
//
// A config file is written under a global namespace — `swift.compiler.sdkVersion`,
// `clang.linker.target` — so a single file can configure every node in a project. This takes
// the slice under one prefix and strips it, leaving exactly what that node's
// `init(properties:)` already expects to read.
//
// Selecting here rather than inside the tool is what makes an edit local. A cache key
// aggregates every input port's wire values, so text arriving at a tool has already
// rescheduled it and changed its key before the tool can decide it does not care. Upstream,
// an unrelated edit leaves this node's output byte-identical, writeToOutputPort returns false,
// and nothing below is scheduled. With one of these per prefix and ten thousand compilers
// sharing it, that is the difference between one node reparsing a file and ten thousand
// recompiling.

import SemelNodeKit

public struct ConfigSubset: NodeFunction {
    public static let kind: UInt = 25

    static let inputPort = "input"
    static let outputPort = "output"

    /// The namespace this node takes, without a trailing dot: `swift.compiler`.
    static let prefixProperty = "prefix"

    public var thisNode: Node

    public init(thisNode: Node) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeFunctionDescriptor(
        inputPorts: [.required(inputPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let prefix = thisNode.properties[Self.prefixProperty] ?? ""

        var merged: [String: String] = [:]
        for wireKey in (input.inputValues[Self.inputPort] ?? [:]).keys.sorted() {
            let text = try input.inputValues[Self.inputPort]![wireKey]!.expectValue().resolveAsString()
            merged = merged.mergedWith([String: String](plainText: text))
        }

        // A whole segment, so `swift.compiler` does not also claim `swift.compilerPlugin`.
        // Whatever follows is the key, dots and all — stripping, not parsing.
        let qualifier = prefix + "."
        var selected: [String: String] = [:]
        for (key, value) in merged where key.hasPrefix(qualifier) {
            let bare = String(key.dropFirst(qualifier.count))
            guard !bare.isEmpty else { continue }
            selected[bare] = value
        }

        return .init(outputValues: [Self.outputPort: .value(try selected.asPlainText().intern())],
                     inputWireExpectations: [:])
    }
}
```

- [ ] **Step 4: Register the type**

In `SemelCore/Sources/SemelCore/BuildEngine.swift`, add `ConfigSubset.self` to the `registerTypes()` array after `Configuration.self`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/jadeburton/Semel/build_system/SemelCore --filter ConfigSubset`
Expected: PASS, 7 tests.

- [ ] **Step 6: Run every suite**

Run each of the five. Expected: 471 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add SemelCore/Sources/SemelCore/NodeFunctions/ConfigSubset.swift \
        SemelCore/Sources/SemelCore/BuildEngine.swift \
        SemelCore/Tests/SemelCoreTests/ConfigSubsetTests.swift
git commit -m "Add ConfigSubset, which selects one node's settings from a shared config file"
```

---

### Task 2: Namespaces derived from type names

**Files:**
- Create: `SemelNodeKit/Sources/SemelNodeKit/SettingNamespace.swift`
- Test: `SemelNodeKit/Tests/SettingNamespaceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `func derivedSettingNamespace(forTypeName: String) -> String`. `"SwiftCompilerTool"` → `"swift.compiler"`, `"ClangPreprocessorTool"` → `"clang.preprocessor"`, `"SwiftPackageReaderTool"` → `"swift.packageReader"`. Task 3 uses it to give each tool type a `settingNamespace`.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  SettingNamespaceTests.swift
//  SemelNodeKitTests
//
//  Where a node's settings live in a config file, derived from what the node is called.
//
//  Deriving keeps the two from drifting, and costs one thing worth knowing: a type rename
//  becomes a breaking change to every config file written against it. That is why the derived
//  name is a default a type can override rather than a rule it cannot escape.
//

@testable import SemelNodeKit
import XCTest

final class SettingNamespaceTests: XCTestCase {

    func test_theFirstWordIsTheDomainAndTheRestIsTheNode() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftCompilerTool"), "swift.compiler")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftLinkerTool"), "swift.linker")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "ClangPreprocessorTool"), "clang.preprocessor")
    }

    /// A multi-word remainder stays one segment, lower-camelled — the namespace has exactly two
    /// levels above the key, so `swift.package.reader` would put a package domain in the file.
    func test_aMultiWordRemainderIsOneLowerCamelSegment() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftPackageReaderTool"), "swift.packageReader")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftFormulaConverter"), "swift.formulaConverter")
    }

    /// A trailing `Tool` says nothing about what the node is for.
    func test_aTrailingToolIsDropped() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "ClangLinkerTool"), "clang.linker")
    }

    /// A single-word type has no domain to give, which is the signal its name is wrong rather
    /// than something to paper over — see ClangIncludeFinder.
    func test_aSingleWordTypeGivesOnlyADomain() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "Configuration"), "configuration")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/jadeburton/Semel/build_system/SemelNodeKit --filter SettingNamespace`
Expected: FAIL — "cannot find 'derivedSettingNamespace' in scope".

- [ ] **Step 3: Write the implementation**

Create `SemelNodeKit/Sources/SemelNodeKit/SettingNamespace.swift`:

```swift
// SettingNamespace.swift
// SemelNodeKit
//
// Where a node's settings live in a config file.
//
// A config file is one flat namespace holding every node's settings, so each node needs a
// place in it that nothing else can claim. Deriving that place from the type name keeps the
// two from drifting apart as settings are added.
//
// The cost is that a type rename is a breaking change to every config file written against it.
// So a type may pin its namespace instead, which is what lets it be renamed after its
// namespace is public.

/// `SwiftCompilerTool` → `swift.compiler`. The first word is the domain, the rest is the node.
public func derivedSettingNamespace(forTypeName typeName: String) -> String {
    var name = typeName
    if name.hasSuffix("Tool") {
        name.removeLast("Tool".count)
    }

    // Split on capitals: "SwiftPackageReader" → ["Swift", "Package", "Reader"].
    var words: [String] = []
    var current = ""
    for character in name {
        if character.isUppercase && !current.isEmpty {
            words.append(current)
            current = ""
        }
        current.append(character)
    }

    if !current.isEmpty { 
        words.append(current) 
    }

    guard let domain = words.first else { 
        return "" 
    }

    let rest = words.dropFirst()

    guard !rest.isEmpty else { 
        return domain.lowercasedFirst() 
    }

    // The remainder is one segment, not one per word: the namespace is exactly
    // domain-then-node, and splitting further would invent levels the file does not have.
    let node = rest.joined().lowercasedFirst()
    return "\(domain.lowercasedFirst()).\(node)"
}

private extension String {
    func lowercasedFirst() -> String {
        guard let first else { 
            return self 
        }
        return first.lowercased() + dropFirst()
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --package-path /Users/jadeburton/Semel/build_system/SemelNodeKit --filter SettingNamespace`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add SemelNodeKit/Sources/SemelNodeKit/SettingNamespace.swift \
        SemelNodeKit/Tests/SettingNamespaceTests.swift
git commit -m "Derive a node's config namespace from its type name"
```

---

### Task 3: Point the five tool types at their namespaces

**Files:**
- Modify: `SemelSwift/Sources/SemelSwift/SwiftCompilerTool.swift:52-68`, `SemelSwift/Sources/SemelSwift/SwiftLinkerTool.swift:36-51`, `SemelClang/Sources/SemelClang/ClangCompilerTool.swift`, `SemelClang/Sources/SemelClang/ClangLinkerTool.swift`, `SemelClang/Sources/SemelClang/ClangPreprocessorTool.swift` (the `settingNamespace` / `acceptedSettings` blocks added in `8a9fd0e`)

**Interfaces:**
- Consumes: `derivedSettingNamespace(forTypeName:)` from Task 2.
- Produces: `SwiftCompilerToolConfiguration.settingNamespace == "swift.compiler"` and the same on the other four. Task 4 renders these into formula text.

- [ ] **Step 1: Replace the hand-written namespaces**

In each of the five configuration types, replace the `settingNamespace` line and delete `acceptedSettings` entirely. The prefix in the graph is now the accepted set, so a per-type key list has nothing left to do.

```swift
    /// Where this node's settings live in a config file: `swift.compiler.sdkVersion`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "SwiftCompilerTool")
```

Use the matching type name in each file. `ClangCompilerTool`, `ClangLinkerTool`, `ClangPreprocessorTool` and `SwiftLinkerTool` follow the same shape.

- [ ] **Step 2: Build and let the compiler find the callers**

Run: `swift build`
Expected: errors in `SwiftFormulaConverter.swift` where `acceptedSettings` and `ToolSchema` are referenced. Leave them — Task 4 removes that code. If you want a green intermediate, do Task 4 in the same commit.

- [ ] **Step 3: Commit with Task 4**

This task is not independently green: deleting `acceptedSettings` breaks the converter that reads it. Combine the commit with Task 4.

---

### Task 4: The converter emits selectors instead of resolving settings

**Files:**
- Modify: `SemelSwift/Sources/SemelSwift/SwiftFormulaConverter.swift` — remove the `configFiles` dynamic port, `toolSchemas`, `manifestSuppliedSettings`, the `ConfigSettings` use and the `settingsReport`; emit `ConfigSubset` nodes instead
- Delete: `SemelNodeKit/Sources/SemelNodeKit/ConfigSettings.swift`
- Modify: `SemelSwift/Tests/ConfigFileTests.swift` — replace with tests of what the converter now emits

**Interfaces:**
- Consumes: `ConfigSubset` (Task 1), `settingNamespace` (Task 3).
- Produces: formula text in which each tool's `configuration` port is wired to a `Configuration` node whose `inherit` port carries a `ConfigSubset` output.

- [ ] **Step 1: Write the failing test**

Replace `SemelSwift/Tests/ConfigFileTests.swift` with:

```swift
//
//  ConfigFileTests.swift
//  SemelSwiftTests
//
//  What the converter emits so a compiled target receives its settings.
//
//  The settings themselves are not the converter's business any more. It names a file and a
//  namespace; what the file says arrives later, on a wire, and never enters a searchKey — which
//  is what lets a setting change without recreating every node that reads it.
//

@testable import SemelSwift
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ConfigFileTests: SemelSwiftTestCase {

    private let plainManifest = """
        {
          "name": "pkg",
          "dependencies": [],
          "products": [{"name": "pkg", "targets": ["Lib"], "type": {"library": ["automatic"]}}],
          "targets": [{"name": "Lib", "type": "regular", "path": "Sources/Lib", "dependencies": []}]
        }
        """

    private func formula(packageFolder: String = "input:/pkg") throws -> String {
        let manifest = FolderManifest(baseFolderPath: packageFolder, entries: [])
        let converter = try SwiftFormulaConverter(thisNode: Node(id: 1, kind: SwiftFormulaConverter.kind))
        let output = try converter.process(input: ProcessInput(inputValues: [
            SwiftFormulaConverter.packageFolder:        ["folder": .value(try manifest.toJSON().intern())],
            SwiftFormulaConverter.packageJSON:          ["json":   .value(try plainManifest.intern())],
            SwiftFormulaConverter.externalPackageJSONs: [:],
        ]))
        return try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput])
            .expectValue().resolveAsString()
    }

    /// The compiler's settings arrive through a selector naming the compiler's namespace, not
    /// as literals the converter resolved.
    func test_theCompilerIsWiredToASelectorForItsOwnNamespace() throws {
        let result = try formula()

        XCTAssertTrue(result.contains("ConfigSubset(prefix: 'swift.compiler'"), "got:\n\(result)")
    }

    func test_theLinkerIsWiredToASelectorForItsOwnNamespace() throws {
        let result = try formula()

        XCTAssertTrue(result.contains("ConfigSubset(prefix: 'swift.linker'"), "got:\n\(result)")
    }

    /// The selector reads the config file from the package folder, named in the shape so the
    /// wire exists whether or not the file has been pushed yet.
    func test_theSelectorReadsTheConfigFileBesideThePackage() throws {
        let result = try formula(packageFolder: "input:/a/pkg")

        XCTAssertTrue(result.contains("StaticFile(path: 'input:/a/pkg/semel.config')"), "got:\n\(result)")
    }

    /// Manifest-derived values stay literals: they say what the target *is*, so they belong in
    /// identity. Settings do not appear here at all.
    func test_theManifestStillSuppliesModuleNameAsALiteral() throws {
        let result = try formula()

        XCTAssertTrue(result.contains("moduleName: 'Lib'"), "got:\n\(result)")
        XCTAssertFalse(result.contains("sdkVersion:"),
                       "a setting must not be rendered as a property, got:\n\(result)")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path /Users/jadeburton/Semel/build_system/SemelSwift --filter ConfigFile`
Expected: FAIL — the formula contains no `ConfigSubset`.

- [ ] **Step 3: Emit the selector in the converter**

In `SwiftFormulaConverter`, replace the `Configuration(...)` rendering for the compiler and linker so each wires a selector into `inherit`. The manifest-derived values stay as `Configuration` properties, which is what makes them identity and lets them override the file:

```swift
    /// The config file a package is configured by: `semel.config` beside the package.
    ///
    /// Named in the shape rather than looked up, so the wire exists before the file does — an
    /// absent file is a ghost, and pushing it later fills the wire and rebuilds what depends on
    /// it without a rescan.
    private func configSelector(namespace: String, packageFolder: String) -> String {
        let configPath = "\(packageFolder)/\(Self.configFileName)"
        return "ConfigSubset(prefix: '\(namespace)', "
             + "input: ['config': StaticFile(path: '\(configPath)').output]).output"
    }
```

and render each configuration as:

```swift
    private func configurationExpression(namespace: String,
                                         packageFolder: String,
                                         literals: [String: String]) -> String {
        let rendered = literals.sorted { $0.key < $1.key }
                               .map { "\($0.key): '\($0.value)'" }
                               .joined(separator: ", ")
        let selector = configSelector(namespace: namespace, packageFolder: packageFolder)
        let arguments = rendered.isEmpty ? "" : "\(rendered), "
        return "Configuration(\(arguments)inherit: ['settings': \(selector)]).output"
    }
```

Then delete from the converter: the `configFiles` static port and its dynamic-port entry, `toolSchemas`, `manifestSuppliedSettings`, `configFileExpectations`, the `ConfigSettings` construction, `settingsReport`, and the `settings` parameter threaded through `generateFormula` and `buildFuncDef`. `infoLog` returns to `.value("")`.

- [ ] **Step 4: Delete the resolution machinery**

```bash
rm SemelNodeKit/Sources/SemelNodeKit/ConfigSettings.swift
rm -f SemelNodeKit/.build/build.db SemelNodeKit/.build/plan.json
rm -f SemelSwift/.build/build.db SemelSwift/.build/plan.json
```

`SemelConfig.fileName` moves into `SwiftFormulaConverter` as `configFileName = "semel.config"`; `SemelConfig.expectations(forFolder:)` and `ToolSchema` go with the file.

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --package-path /Users/jadeburton/Semel/build_system/SemelSwift --filter ConfigFile`
Expected: PASS, 4 tests.

- [ ] **Step 6: Run every suite**

Expected: green. `DeclaredSDKTests` still passes — `verifySDKVersion` is unchanged, only how the value reaches it.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Wire settings in through a selector instead of resolving them in the converter"
```

---

### Task 5: Rename `IncludeFinder` to `ClangIncludeFinder`

**Files:**
- Rename: `SemelClang/Sources/SemelClang/IncludeFinder.swift` → `ClangIncludeFinder.swift`
- Modify: every reference (the compiler will list them), `SemelClang/Sources/SemelClang/SemelClang.swift` registration

**Interfaces:**
- Consumes: `derivedSettingNamespace` (Task 2).
- Produces: `ClangIncludeFinder`, deriving to `clang.includeFinder` rather than sitting at the root as `includeFinder`.

- [ ] **Step 1: Rename the type and file**

```bash
git mv SemelClang/Sources/SemelClang/IncludeFinder.swift SemelClang/Sources/SemelClang/ClangIncludeFinder.swift
```

Then replace `IncludeFinder` with `ClangIncludeFinder` throughout that file and every reference the compiler reports. **Do not change `kind`** — it stays 19; the type name in a `searchKey` changes, which recreates those nodes once, but renumbering the kind would orphan every existing database.

- [ ] **Step 2: Build and fix references**

Run: `rm -f SemelClang/.build/build.db SemelClang/.build/plan.json && swift build`
Expected: errors naming each remaining reference. Fix until clean.

- [ ] **Step 3: Run every suite**

Expected: green. Note `GraphShapeTests` may pin formula text containing the old name — update those strings.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Rename IncludeFinder to ClangIncludeFinder so its namespace has a domain"
```

---

### Task 6: Remove every default value

**Files:**
- Modify: `SemelSwift/Sources/SemelSwift/SwiftCompilerTool.swift:26-38`, `SemelSwift/Sources/SemelSwift/SwiftLinkerTool.swift:22-34`, `SemelClang/Sources/SemelClang/ClangLinkerTool.swift:23-32,143`, `SemelClang/Sources/SemelClang/ClangCompilerTool.swift`, `SemelClang/Sources/SemelClang/ClangPreprocessorTool.swift`
- Test: `SemelSwift/Tests/MissingSettingTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `init(properties:) throws` on all five configuration types, throwing `NodeError.other` naming the missing key and its full namespaced name.

- [ ] **Step 1: Write the failing test**

```swift
//
//  MissingSettingTests.swift
//  SemelSwiftTests
//
//  A setting that is not supplied is an error, not a default.
//
//  A default baked into the binary is worse than one read from the machine: xcrun at least
//  reports what is installed, while a literal in Swift source means upgrading Semel silently
//  changes what a previous build meant. So there are none, and the failure has to say what to
//  write and where.
//

@testable import SemelSwift
import SemelNodeKit
import XCTest

final class MissingSettingTests: SemelSwiftTestCase {

    private let complete = [
        "toolDescriptor.name": "swiftc",
        "toolDescriptor.version": "Apple Swift version 6.3.3",
        "toolDescriptor.platform": "macOS",
        "toolDescriptor.architecture": "arm64",
        "moduleName": "Lib",
    ]

    func test_aCompleteConfigurationIsAccepted() throws {
        XCTAssertNoThrow(try SwiftCompilerToolConfiguration(properties: complete))
    }

    func test_aMissingSettingNamesItselfAndItsNamespace() throws {
        var incomplete = complete
        incomplete["toolDescriptor.version"] = nil

        XCTAssertThrowsError(try SwiftCompilerToolConfiguration(properties: incomplete)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("swift.compiler.toolDescriptor.version"),
                          "should name the key to write in the config file, got \(message)")
        }
    }

    /// Every required setting, not just the first — a message naming one of four missing keys
    /// costs four build attempts to fix.
    func test_everyMissingSettingIsNamedAtOnce() throws {
        XCTAssertThrowsError(try SwiftCompilerToolConfiguration(properties: ["moduleName": "Lib"])) { error in
            let message = String(describing: error)
            for key in ["name", "version", "platform", "architecture"] {
                XCTAssertTrue(message.contains("toolDescriptor.\(key)"), "missing \(key) in: \(message)")
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path /Users/jadeburton/Semel/build_system/SemelSwift --filter MissingSetting`
Expected: FAIL — the initialiser does not throw.

- [ ] **Step 3: Make the initialisers throwing and demanding**

Add to `SemelNodeKit/Sources/SemelNodeKit/SettingNamespace.swift`:

```swift
/// Reads settings that have no default, reporting every one that is missing rather than the
/// first. A message naming one of four missing keys costs four build attempts to fix.
public struct RequiredSettings {
    private let properties: [String: String]
    private let namespace: String
    private var missing: [String] = []

    public init(properties: [String: String], namespace: String) {
        self.properties = properties
        self.namespace = namespace
    }

    public mutating func value(_ key: String) -> String {
        guard let value = properties[key] else {
            missing.append("\(namespace).\(key)")
            return ""
        }
        return value
    }

    public func check() throws {
        guard !missing.isEmpty else { 
            return 
        }
        throw NodeError.other(message: """
            Missing configuration. Add these to a semel.config in the input file system:

            \(missing.sorted().map { "\($0)=…" }.joined(separator: "\n"))

            There are no default values: one baked into Semel would change what this build \
            means when Semel is upgraded.
            """)
    }
}
```

Then rewrite each configuration initialiser, for example `SwiftCompilerToolConfiguration`:

```swift
    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(name:          required.value("toolDescriptor.name"),
                               version:       required.value("toolDescriptor.version"),
                               platform:      required.value("toolDescriptor.platform"),
                               architecture:  required.value("toolDescriptor.architecture"),
                               recursiveHash: properties["toolDescriptor.recursiveHash"])
        moduleName = required.value("moduleName")
        try required.check()

        arguments = []
        environment = [:]
        sdkVersion = properties["sdkVersion"]
        optimisationLevel = properties["optimisationLevel"]
        parseAsLibrary = properties["parseAsLibrary"] != "false"
        sourcePaths   = Self.pathList(properties["sourcePaths"])
        excludedPaths = Self.pathList(properties["excludedPaths"])
    }
```

`recursiveHash`, `sdkVersion` and `optimisationLevel` stay optional — absent means "not declared", which is a different thing from a default. `ClangLinkerTool`'s `target` becomes required, closing the `arm64-apple-macos14.0` TODO.

- [ ] **Step 4: Fix every caller and test fixture**

Run: `swift build && swift build --build-tests`
Expected: errors at each `.init(properties:)` call site, now throwing. Add `try`. Test fixtures that omitted settings now fail — give them complete configurations.

- [ ] **Step 5: Run every suite**

Expected: green, after fixtures are completed.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Remove every default configuration value; a missing setting is an error"
```

---

### Task 7: Semel's own `semel.config`

**Files:**
- Create: `semel.config` at the repository root

**Interfaces:**
- Consumes: Task 6.
- Produces: the file that lets Semel build itself now that nothing defaults.

- [ ] **Step 1: Write the file**

Take the values that were previously defaults, and the machine's real toolchain:

```bash
xcrun --show-sdk-version --sdk macosx
swiftc --version
```

```
# What this tree is built with. There are no defaults: every setting a node needs
# is written here, once per node that reads it.

swift.compiler.toolDescriptor.name=swiftc
swift.compiler.toolDescriptor.version=<paste swiftc --version, first line>
swift.compiler.toolDescriptor.platform=macOS
swift.compiler.toolDescriptor.architecture=arm64
swift.compiler.sdkVersion=<paste --show-sdk-version>

swift.linker.toolDescriptor.name=swiftc
swift.linker.toolDescriptor.version=<same>
swift.linker.toolDescriptor.platform=macOS
swift.linker.toolDescriptor.architecture=arm64
swift.linker.sdkVersion=<same>
```

- [ ] **Step 2: Verify the self-build**

Build this repository with Semel as before and confirm the products appear. This is the only end-to-end check that the selector, the namespaces and the removed defaults agree.

- [ ] **Step 3: Commit**

```bash
git add semel.config
git commit -m "Add the config Semel builds itself with"
```

---

### Task 8: Report keys nobody claimed

**Files:**
- Modify: `SemelCore/Sources/SemelCore/BuildEngine.swift:139` (the idle hook)
- Test: `SemelCore/Tests/SemelCoreTests/UnclaimedConfigKeyTests.swift`

**Interfaces:**
- Consumes: `ConfigSubset` (Task 1).
- Produces: `func unclaimedConfigKeys(inFileNodeID: ObjectID) throws -> [String]` on `BuildEngine`.

- [ ] **Step 1: Write the failing test**

```swift
//
//  UnclaimedConfigKeyTests.swift
//  SemelCoreTests
//
//  A key in a config file that no node selected.
//
//  A misspelt setting changes nothing and says nothing, which is the failure the old per-tool
//  check existed to prevent. A selector cannot see it — it only knows what it was asked for —
//  but the graph can: the wires from a config file lead to every node that claimed part of it.
//  That catches a bad key and a bad prefix, where the old check only ever saw the first.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class UnclaimedConfigKeyTests: SemelCoreTestCase {

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

    /// Builds a config file with two selectors reading it, and returns what nobody claimed.
    private func unclaimed(file: String, prefixes: [String]) throws -> [String] {
        let path = "input:/semel.config"
        let fileShape = try GraphShapeNode.parse("StaticFile(path: '\(path)')")
        let (fileNode, _) = try fileShape.findOrCreateMatchingNode()
        let staticFile = try XCTUnwrap(fileNode.nodeAsAny() as? StaticFile)
        _ = try staticFile.replaceContent(try file.intern())

        for prefix in prefixes {
            let shape = try GraphShapeNode.parse(
                "ConfigSubset(prefix: '\(prefix)', input: ['config': StaticFile(path: '\(path)').output]).output")
            _ = try shape.findOrCreateMatchingNode()
        }

        return try engine.unclaimedConfigKeys(inFileNodeID: fileNode.requireID())
    }

    func test_aKeyUnderAClaimedPrefixIsNotReported() throws {
        let result = try unclaimed(file: "swift.compiler.sdkVersion=26.5",
                                   prefixes: ["swift.compiler"])

        XCTAssertEqual(result, [])
    }

    /// A misspelt key under a real prefix.
    func test_aKeyNoSelectorAsksForIsReported() throws {
        let result = try unclaimed(file: "swift.compiler.sdkVerison=26.5",
                                   prefixes: ["swift.compiler"])

        XCTAssertEqual(result, ["swift.compiler.sdkVerison"])
    }

    /// A misspelt prefix, which the old per-tool accepted-set check could never have seen.
    func test_aKeyUnderAPrefixNobodySelectedIsReported() throws {
        let result = try unclaimed(file: "swift.compier.sdkVersion=26.5",
                                   prefixes: ["swift.compiler"])

        XCTAssertEqual(result, ["swift.compier.sdkVersion"])
    }
}
```

Note: `test_aKeyNoSelectorAsksForIsReported` asserts a key *under* a claimed prefix is reported. That requires knowing which keys a selector actually used, not just its prefix. Implement by having the selector's prefix claim the whole subtree, then compare against the keys each tool reads — **or**, simpler and sufficient, report only keys matching no prefix and delete that second test. Decide in Step 3 and make the tests match the choice.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path /Users/jadeburton/Semel/build_system/SemelCore --filter UnclaimedConfigKey`
Expected: FAIL — `unclaimedConfigKeys` does not exist.

- [ ] **Step 3: Implement**

Add to `BuildEngine`:

```swift
    /// Keys in a config file that no `ConfigSubset` selected.
    ///
    /// A selector knows only what it was asked for, so it cannot notice a key nobody wanted.
    /// The graph can: the wires leaving a config file lead to every node that claimed part of
    /// it, and their prefixes are properties. Answerable only once the graph has settled, which
    /// is why this is called from the idle hook rather than at parse time.
    func unclaimedConfigKeys(inFileNodeID fileNodeID: ObjectID) throws -> [String] {
        let node = try database.node.select(nodeID: fileNodeID)

        guard let staticFile = try node.nodeAsAny() as? StaticFile,
              let content = try staticFile.read(),
              case .value(let hash) = content else { 
            return []
        }

        let keys = [String: String](plainText: try hash.resolveAsString()).keys

        var prefixes: [String] = []

        for wire in try database.wire.select(comingFromNodeID: fileNodeID,
                                             fromSymbolID: StaticFile.outputPort.asSymbolID()) {
            let consumer = try database.node.select(nodeID: wire.toNodeID)

            guard consumer.kind == ConfigSubset.kind,
                  let prefix = consumer.properties[ConfigSubset.prefixProperty] else { 
                continue 
            }

            prefixes.append(prefix + ".")
        }

        return keys.filter { key in !prefixes.contains { key.hasPrefix($0) } }.sorted()
    }
```

- [ ] **Step 4: Call it from the idle hook**

At `BuildEngine.swift:139`, for each `StaticFile` named `semel.config`, print any unclaimed keys once per settle.

- [ ] **Step 5: Run to verify they pass, then every suite**

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Report config keys no node selected, on idle"
```

---

## Self-Review

**Spec coverage.** Namespace scheme → Tasks 2, 3. Selector and prefix-strip → Task 1. Identity-not-property → Task 4. Killing inheritance → Task 4 (the ancestor walk and `ConfigSettings` go). Dissolving `acceptedSettings` → Task 3. No defaults → Tasks 6, 7. Unclaimed-key reporting → Task 8. `ClangIncludeFinder` → Task 5. Variants-as-files needs no code — it falls out of wiring a different file. `semel.*` engine settings are explicitly out of scope.

**Placeholders.** Task 8 Step 1 contains a genuine open choice rather than a placeholder, and says so with both options and the consequence of each; it is the one decision this plan does not make, because it trades reporting precision against knowing which keys each tool reads.

**Type consistency.** `ConfigSubset.prefixProperty`, `inputPort`, `outputPort` and `kind = 25` are defined in Task 1 and used unchanged in Tasks 4 and 8. `derivedSettingNamespace(forTypeName:)` is defined in Task 2 and used in Tasks 3 and 5. `RequiredSettings` is defined in Task 6 and used only there.

**Sequencing note.** Task 3 is deliberately not independently green — deleting `acceptedSettings` breaks the converter that reads it — and says so, directing its commit to be combined with Task 4. Every other task ends green.

//
//  ErrorDocumentTests.swift
//  SemelNodeKit
//
//  What a failing node publishes: a typed document, interned, carried on its ports as the
//  hash of its encoding. It round-trips through the store, each helper fills what it is
//  given, and two documents made from equal inputs are one value — the hash a cache entry
//  and a report compare.
//

@testable import SemelNodeKit
import XCTest

final class ErrorDocumentTests: XCTestCase {

    private var userStore: DataObjectStore?
    private var storeRoot: URL?

    /// A store of this test's own: documents are interned, and the user's store is not the
    /// place for a test's bytes.
    override func setUpWithError() throws {
        try super.setUpWithError()
        userStore = DataObjectStore.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-error-document-tests/\(UUID().uuidString)", isDirectory: true)
        storeRoot = root
        DataObjectStore.shared = DataObjectStore(storeRoot: root)
        try TypeRegistry.register(types: [ErrorDocument.self])
    }

    override func tearDown() {
        if let userStore {
            DataObjectStore.shared = userStore
        }
        if let storeRoot {
            try? FileManager.default.removeItem(at: storeRoot)
        }
        super.tearDown()
    }

    /// The document an error value names, read back from the store.
    private func document(at value: NodeValue) throws -> ErrorDocument {
        var hash: String?
        if case .noValue(.error(let documentHash)) = value {
            hash = documentHash
        }
        return try XCTUnwrap(ErrorDocument.read(documentHash: try XCTUnwrap(hash, "expected an error, got \(value)")))
    }

    // MARK: - Round trip

    /// Interned and read back through the registry, every part of a document comes back as
    /// it was: the diagnostic, the subject and the remedy.
    func test_aDocumentRoundTripsThroughInterning() throws {
        let original = ErrorDocument.engine(
            .lockMismatch(folder: "input:/Packages/Dependencies/GRDB.swift",
                          lock: LockFacts(lockPath: "input:/Packages/Dependencies/GRDB.swift.semel-lock",
                                          version: "7.1.0", origin: "https://github.com/groue/GRDB.swift"),
                          expected: "sha256:aaa", found: "sha256:bbb",
                          leftOut: [LeftOutEntry(path: ".spi.yml", reason: .dotNamed)]),
            subject: .package(name: "GRDB.swift"))

        let read = try document(at: try original.published())

        XCTAssertEqual(read, original)
        XCTAssertEqual(read.remedy, .relock(package: "GRDB.swift"))
    }

    /// Several causes are one document whose causes come back apart, in order, each with
    /// its own subject: a converter missing two target folders reports two blocks.
    func test_severalCausesRoundTripAndComeBackApart() throws {
        let first  = ErrorDocument.engine(.targetFolderMissing(package: "Kit", packageFolder: "input:/Packages/Kit", target: "Kit"),
                                          subject: .target(name: "Kit"))
        let second = ErrorDocument.engine(.targetFolderMissing(package: "Kit", packageFolder: "input:/Packages/Kit", target: "Util"),
                                          subject: .target(name: "Util"))
        let several = try XCTUnwrap(ErrorDocument.several([first, second]))

        let read = try document(at: try several.published())

        XCTAssertEqual(read.causes, [first, second])
    }

    /// One cause is not wrapped, and none is no document.
    func test_severalOfOneIsTheOneAndOfNoneIsNothing() {
        let one = ErrorDocument.engine(.noSources, subject: .target(name: "Models"))

        XCTAssertEqual(ErrorDocument.several([one]), one)
        XCTAssertNil(ErrorDocument.several([]))
    }

    // MARK: - Helpers

    /// A tool's failure is what it printed, as it printed it, under the subject given.
    func test_aToolFailureCarriesWhatTheToolPrintedUnderItsSubject() {
        let made = ErrorDocument.tool(text: "  Account.swift:201:28: error: cannot convert\n", tool: "swiftc", status: 1,
                                      subject: .target(name: "Models"))

        XCTAssertEqual(made.diagnostic, .tool(text: "Account.swift:201:28: error: cannot convert", tool: "swiftc"))
        XCTAssertEqual(made.subject, .target(name: "Models"))
        XCTAssertNil(made.remedy)
    }

    /// A tool that failed and printed nothing is the condition that says so, with its
    /// status: the one case the status is information.
    func test_aSilentToolIsTheConditionWithItsStatus() {
        let made = ErrorDocument.tool(text: "  \n", tool: "actool", status: 70, subject: .resource(path: "input:/App/Media.xcassets"))

        XCTAssertEqual(made.diagnostic, .engine(.toolExitedSilently(tool: "actool", status: 70)))
        XCTAssertEqual(made.subject, .resource(path: "input:/App/Media.xcassets"))
    }

    /// A setting the tool complained about is the remedy, by key; one it said nothing about
    /// adds none.
    func test_aSettingTheToolComplainedAboutIsTheRemedy() {
        let settings: [SettingArgument] = [.clangTarget(key: "clang.preprocessor.target", value: "nonsense-triple")]

        let complained = ErrorDocument.tool(text: "error: unknown target triple 'nonsense-triple'", tool: "clang", status: 1,
                                            subject: .source(path: "input:/hello/src/main.c"), settings: settings)
        let unrelated  = ErrorDocument.tool(text: "main.c:1:1: error: unknown type name 'itn'", tool: "clang", status: 1,
                                            subject: .source(path: "input:/hello/src/main.c"), settings: settings)

        XCTAssertEqual(complained.remedy, .setting(keys: ["clang.preprocessor.target"]))
        XCTAssertNil(unrelated.remedy)
    }

    /// An engine condition takes the remedy it implies, and one given in its place.
    func test_anEngineConditionTakesItsImpliedRemedyUnlessGivenOne() {
        let implied = ErrorDocument.engine(.unlinkedKind(kind: 43), subject: nil)
        let given   = ErrorDocument.engine(.targetFolderMissing(package: "Kit", packageFolder: "input:/Packages/Kit", target: "Kit"),
                                           subject: .target(name: "Kit"), remedy: .missingFolder(tried: ["Sources/Kit"]))

        XCTAssertEqual(implied.remedy, .register(kind: 43))
        XCTAssertEqual(given.remedy, .missingFolder(tried: ["Sources/Kit"]))
    }

    /// A thrown error that names a condition is published as that condition; one that names
    /// none is the last resort, with its type and its own words.
    func test_aThrownErrorIsItsConditionOrTheLastResort() {
        struct Foreign: Error, CustomStringConvertible {
            var description: String { "something outside Semel" }
        }

        XCTAssertEqual(ErrorDocument.thrown(NodeError.requiredInputPortUnwired(port: "input"), subject: nil).diagnostic,
                       .engine(.requiredPortUnwired(type: nil, port: "input")))
        XCTAssertEqual(ErrorDocument.thrown(Foreign(), subject: nil).diagnostic,
                       .engine(.unclassified(type: "Foreign", description: "something outside Semel")))
    }

    /// The tool helpers on a run's result: a failure is the tool's text on a tree and on a
    /// single output alike, and a clean run that wrote nothing names what it did not write.
    func test_aRunsFailureIsTheSameDocumentOnATreeAndAnOutput() throws {
        let failed = SimplifiedToolExecuteResult(exitCode: 2, resolvedSandboxPath: "/semel", infoOutput: "error: it broke",
                                                 errorOutput: "", outputFiles: [:], outputTrees: [:])
        let tree   = try document(at: try failed.asTreeNodeValue(folder: "out", tool: "actool", subject: nil))
        let output = try document(at: try failed.asOutputNodeValue(tool: "actool", subject: nil))

        XCTAssertEqual(tree, output)
        XCTAssertEqual(tree.diagnostic, .tool(text: "error: it broke", tool: "actool"))

        let noFile = SimplifiedToolExecuteResult(exitCode: 0, resolvedSandboxPath: "/semel", infoOutput: "", errorOutput: "",
                                                 outputFiles: [:], outputTrees: [:], missingOutputFiles: ["main.o"])
        XCTAssertEqual(try document(at: try noFile.asOutputNodeValue(tool: "clang", subject: nil)).diagnostic,
                       .engine(.toolWroteNothing(tool: "clang", status: 0, paths: ["main.o"])))
    }

    /// Both streams are what the tool printed, the error stream first.
    func test_bothStreamsAreTheToolsTextErrorStreamFirst() {
        let failed = SimplifiedToolExecuteResult(exitCode: 1, resolvedSandboxPath: "/semel",
                                                 infoOutput: "Assets.xcassets: error: no runtime\n",
                                                 errorOutput: "warning: something on stderr", outputFiles: [:], outputTrees: [:])

        XCTAssertEqual(failed.failureDocument(tool: "actool", subject: nil).diagnostic,
                       .tool(text: "warning: something on stderr\nAssets.xcassets: error: no runtime", tool: "actool"))
    }

    // MARK: - Equality

    /// Equal inputs make one document and one hash, in any process: the encoding sorts its
    /// keys, so a cache entry keyed on what a failing node published is hit again.
    func test_aDocumentIsEqualForEqualInputsAndInternsToOneHash() throws {
        func made() -> ErrorDocument {
            .engine(.severalWiresOnOneWirePort(type: "ClangCompiler", port: "configuration", wires: ["a", "b"]),
                    subject: .source(path: "input:/hello/src/main.c"))
        }

        XCTAssertEqual(made(), made())
        XCTAssertEqual(try made().toJSON().intern(), try made().toJSON().intern())
        XCTAssertNotEqual(made(), .engine(.severalWiresOnOneWirePort(type: "ClangCompiler", port: "configuration", wires: ["a"]),
                                          subject: .source(path: "input:/hello/src/main.c")))
    }

    /// Two documents differing only in which subject of one kind they name are one error of
    /// a report; a different kind of subject is another.
    func test_theMergeKeyLeavesOutWhichSubjectButNotItsKind() {
        let condition = ErrorCondition.settingsMissing(project: [], machine: ["clang.compiler.toolDescriptor.name"], writer: nil)
        let first  = ErrorDocument.engine(condition, subject: .source(path: "input:/a.c"))
        let second = ErrorDocument.engine(condition, subject: .source(path: "input:/b.c"))
        let target = ErrorDocument.engine(condition, subject: .target(name: "A"))

        XCTAssertEqual(first.mergeKey, second.mergeKey)
        XCTAssertNotEqual(first.mergeKey, target.mergeKey)
    }

    /// A source nobody pushed is named as `push` takes it, without the file system's root.
    func test_anUnpushedSourceIsNamedAsPushTakesIt() {
        XCTAssertEqual(ErrorDocument.engine(.notPushed(path: "input:/hello/src", isFolder: true), subject: nil).unpushedSource,
                       "hello/src")
        XCTAssertNil(ErrorDocument.engine(.noSources, subject: nil).unpushedSource)
    }
}

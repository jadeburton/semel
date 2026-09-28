//
//  UnnamedProjectReportingTests.swift
//  SemelCoreTests
//
//  B-10 residual 2. A pushed project file a formula has to include — a `Package.swift` —
//  builds nothing when no formula does, and a settle says nothing about it. The idle
//  notice does, once per file. A real processing loop, because the candidates come from
//  `ProjectFinder` reading the pushed listings and the notice from the loop's idle hook.
//

@testable import SemelCore
import SemelNodeKit
import XCTest

final class UnnamedProjectReportingTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private let notices = NoticeLog()

    /// The notices the engine gave, captured on the loop's task and read on the test's.
    private final class NoticeLog {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.withLock { storage.append(line) }
        }

        /// Only this report's lines: a settle gives other notices too.
        var unnamed: [String] {
            lock.withLock { storage.filter { $0.contains("is not named by any formula") } }
        }
    }

    /// Claims `sample.proj` the way the Swift plugin claims `Package.swift`: a file a
    /// formula builds by including `SampleConverter(path: <folder>).formula`.
    private struct SampleProjectPlugin: IncludableProjectPlugin {
        func includeSpec(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> GraphSpecNode? {
            guard entry.isPinned, !entry.isFolder, entry.name == "sample.proj" else {
                return nil
            }
            return GraphSpecNode(typeName: "SampleConverter",
                                 properties: [GraphSpecProperty(key: "path", value: folderPath)],
                                 outputPort: "formula")
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        ProjectDiscovery.register(includable: SampleProjectPlugin())
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.noticeReporter = { [notices] line in notices.append(line) }
        engine.startProcessingLoop()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        // A loop left running would keep processing against the next test's globals.
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    /// Pushes every file in one batch, as `push` of a folder does, and waits for the settle.
    private func push(_ files: [String: String]) throws {
        engine.beginBatch()
        defer {
            engine.endBatch()
        }
        for (relativePath, contents) in files.sorted(by: { $0.key < $1.key }) {
            _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(
                    Path(relativePath).deletingLastComponent ?? .empty, pinned: true)
            let fullPath = Path(Folder.inputFileSystemName) / Path(relativePath)
            let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(fullPath.string)')").findOrCreateMatchingNode()
            _ = try XCTUnwrap(node.nodeAsAny() as? StaticFile).replaceContent(try contents.intern())
        }
    }

    private func settle() {
        engine.waitUntilIdleBlocking()
    }

    /// A formula beside the project's folder that names something else: the project file is
    /// said once, spelled from the formula's folder, and not said again on the next settle.
    func test_aProjectFileNoFormulaNamesIsSaidOnce() throws {
        try push(["Packages/semel.fmla":       "product 'notes.txt' = StaticFile(path: <notes.txt>).output",
                  "Packages/notes.txt":        "notes",
                  "Packages/Foo/sample.proj":  "a project"])
        settle()

        XCTAssertEqual(notices.unnamed, ["⚠️  input:/Packages/Foo/sample.proj is not named by any formula; "
                                         + "a formula's include SampleConverter(path: <Foo>).formula builds it"])

        try push(["Packages/more.txt": "more"])
        settle()

        XCTAssertEqual(notices.unnamed.count, 1, "a standing unnamed file is said once: \(notices.unnamed)")
    }

    /// A project file some node reads is one a formula reaches, whichever formula and
    /// however — which is how a package's dependency is reached, through its converter.
    func test_aProjectFileAFormulaReadsIsNotSaid() throws {
        try push(["Packages/semel.fmla":      "product 'copy.proj' = StaticFile(path: <Foo/sample.proj>).output",
                  "Packages/Foo/sample.proj": "a project"])
        settle()

        XCTAssertEqual(notices.unnamed, [])
    }

    /// With no formula anywhere above it, the include is spelled for a formula beside it.
    func test_aProjectFileWithNoFormulaAboveItIsSpelledFromItsOwnFolder() throws {
        try push(["Lone/sample.proj": "a project"])
        settle()

        XCTAssertEqual(notices.unnamed, ["⚠️  input:/Lone/sample.proj is not named by any formula; "
                                         + "a formula's include SampleConverter(path: <.>).formula builds it"])
    }

    /// While a settle carries errors, an unread manifest may only be one a failing converter
    /// has not reached yet; nothing is said until the build is clean.
    func test_nothingIsSaidAfterASettleWithErrors() throws {
        try push(["Packages/semel.fmla":      "product 'broken' = NoSuchNodeType(role: 'x').output",
                  "Packages/Foo/sample.proj": "a project"])
        settle()

        XCTAssertEqual(notices.unnamed, [])
    }

    /// A path in the input file system is written as a formula writes one, relative to the
    /// formula's folder; anything else stays quoted.
    func test_theIncludeIsWrittenAsAFormulaWritesIt() {
        let spec = GraphSpecNode(typeName: "SampleConverter",
                                 properties: [GraphSpecProperty(key: "root", value: "input:/Packages"),
                                              GraphSpecProperty(key: "path", value: "input:/Shared/Foo"),
                                              GraphSpecProperty(key: "role", value: "x")],
                                 outputPort: "formula")

        XCTAssertEqual(BuildEngine.formulaText(of: spec, relativeTo: "input:/Packages"),
                       "SampleConverter(path: <../Shared/Foo>, role: 'x', root: <.>).formula")
    }
}

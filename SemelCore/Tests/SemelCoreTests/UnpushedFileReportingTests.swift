//
//  UnpushedFileReportingTests.swift
//  SemelCoreTests
//
//  B-92. A file the formula names and nobody has pushed has no inputs, so nothing will
//  ever make it run: its port holds the initializing state for good, and every node that
//  needs its value publishes "an input has never been produced". Neither state is a
//  failure of the node holding it, and neither is something a reader can act on.
//
//  The file is, so the file is the line: named once, with the chain below it counted. The
//  exception is a port whose node reads an absent value as nothing to add and says so in
//  its descriptor — `ConfigMerger.override`, the one input a formula may point at a file
//  that need never exist.
//
//  B-104 brought the folders under the same rule and gave the other state a name. A folder
//  is a source too: it publishes "nobody has pushed into me" on `pinned` while its readers
//  wire from `manifest`, so what is asked is whether anything in the graph needs the node.
//  A source that was pushed and then removed holds `deleted`, and reads as the path again.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class UnpushedFileReportingTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var captured: [[ErrorReport.Entry]] = []
    private var database: DatabaseLayer { engine.database }

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

    // MARK: - Helpers

    /// A file the formula names, created the way interpreting a formula creates it: nobody
    /// has pushed it, so its output port holds the initializing state.
    private func makeUnpushedFile(path: String) throws -> ObjectID {
        let (file, _) = try GraphSpecNode.parse("StaticFile(path: '\(path)')").findOrCreateMatchingNode()
        return try file.requireID()
    }

    /// A node that insists on its input's value, the way a tool reads the files it compiles.
    private func makeDemanding(tag: String) throws -> ObjectID {
        try NodeRecord.createNode(database: database, kind: DemandingSampleTool.kind,
                                  properties: ["tag": tag], graphSpec: nil).requireID()
    }

    private func connect(_ from: ObjectID, to: ObjectID, name: String,
                         fromPort: String = "output", toPort: String = "input") throws {
        try Wire.connectWire(database: database,
                             fromNodeID: from,
                             fromSymbolID: fromPort.asSymbolID(),
                             toNodeID: to,
                             toSymbolID: toPort.asSymbolID(),
                             name: name.asSymbolID())
    }

    private func run(_ nodeID: ObjectID) throws {
        try database.node.select(nodeID: nodeID).makeNode().processWithPreCheck()
    }

    /// The file behind a node id, for a test that pushes content into it.
    private func staticFile(_ nodeID: ObjectID) throws -> StaticFile {
        try StaticFile(thisNode: try database.node.select(nodeID: nodeID))
    }

    private func reason(of nodeID: ObjectID, port: String = "output") throws -> OutputPort.ValueKind? {
        try database.outputPort.select(nodeID: nodeID, nameSymbolID: port.asSymbolID())?.valueKind
    }

    // MARK: - A file something needs

    /// The item B-92 is about: a formula naming a file nobody pushed, read by a node that
    /// needs its value. The file is the one thing a reader can act on, so it is the line the
    /// report writes, and the nodes stopped by it are counted under it.
    func test_anUnpushedFileSomethingNeedsIsNamedByThePathToPush() throws {
        let file     = try makeUnpushedFile(path: "input:/clang.cfg")
        let compiler = try makeDemanding(tag: "compiler")
        let linker   = try makeDemanding(tag: "linker")

        try connect(file, to: compiler, name: "config")
        try connect(compiler, to: linker, name: "object")
        try run(compiler)
        try run(linker)

        XCTAssertEqual(try reason(of: file), .initializing)
        XCTAssertEqual(try reason(of: compiler), .inputNotProduced)
        XCTAssertEqual(try reason(of: linker), .inputNotProduced, "the state carries down the chain")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].map(\.label), ["StaticFile #\(file) 'input:/clang.cfg'"])
        XCTAssertEqual(captured[0][0].items,
                       [ErrorReport.Item(ports: ["output"], message: "clang.cfg has not been pushed", missingSource: "clang.cfg")])
        XCTAssertEqual(captured[0][0].downstreamCarrierCount, 2,
                       "the compiler and the linker below it")
    }

    /// The line the reader sees, through the engine's own renderer.
    func test_theLineNamesTheFileAndCountsWhatItStopped() throws {
        let file     = try makeUnpushedFile(path: "input:/main.c")
        let compiler = try makeDemanding(tag: "compiler")

        try connect(file, to: compiler, name: "source")
        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(ErrorReport.lines(for: captured[0][0]),
                       ["❌ StaticFile #\(file) 'input:/main.c'",
                        "   · main.c has not been pushed",
                        "   · and 1 node downstream carries it",
                        ""])
    }

    /// The path `push` takes, which is the path relative to the input file system — the
    /// label above the line already carries the full one.
    func test_theMessageNamesThePathToPush() {
        XCTAssertEqual(ErrorReport.unpushedFileMessage(path: "input:/src/main.c"),
                       "src/main.c has not been pushed")
        XCTAssertEqual(ErrorReport.unpushedFileMessage(path: "input:/clang.cfg"),
                       "clang.cfg has not been pushed")
    }

    /// A tree ends in a separator, so a line about a folder is not read as a line about a
    /// file of the same name; a source that was removed says so in its own sentence.
    func test_theSentencesASourcesStateReadsAs() {
        XCTAssertEqual(ErrorReport.unpushedFileMessage(path: "input:/src", isTree: true),
                       "src/ has not been pushed")
        XCTAssertEqual(ErrorReport.deletedSourceMessage(path: "input:/src/main.c"),
                       "src/main.c was deleted")
        XCTAssertEqual(ErrorReport.deletedSourceMessage(path: "input:/src", isTree: true),
                       "src/ was deleted")
    }

    /// The `errors` verb asks for everything the graph holds rather than for what is newly
    /// appearing, and goes through the same two calls the handler makes. It has to name the
    /// file too, or a build that printed the line once would answer "no errors" when asked.
    func test_theErrorsReplyNamesTheSameFile() throws {
        let file     = try makeUnpushedFile(path: "input:/clang.cfg")
        let compiler = try makeDemanding(tag: "compiler")

        try connect(file, to: compiler, name: "config")
        try run(compiler)

        let entries = ErrorReport.entries(forErrorPorts: try ErrorReport.portsToReport(database: database),
                                          database: database,
                                          select: { _, messages in messages })

        XCTAssertEqual(entries.map(\.entry.label), ["StaticFile #\(file) 'input:/clang.cfg'"])
        XCTAssertEqual(entries[0].entry.items,
                       [ErrorReport.Item(ports: ["output"], message: "clang.cfg has not been pushed", missingSource: "clang.cfg")])
        XCTAssertEqual(entries[0].entry.downstreamCarrierCount, 1)
    }

    /// Asked twice, answered once: a standing absence is reported the first time the engine
    /// settles and not on every settle afterwards, the same as a standing failure.
    func test_theFileIsReportedOnceAndCountedEveryTime() throws {
        let file     = try makeUnpushedFile(path: "input:/clang.cfg")
        let compiler = try makeDemanding(tag: "compiler")

        try connect(file, to: compiler, name: "config")
        try run(compiler)

        XCTAssertEqual(engine.reportIdleTimeErrors(), 1)
        XCTAssertEqual(engine.reportIdleTimeErrors(), 1, "the file is still not pushed")
        XCTAssertEqual(captured.count, 1, "and the reader has been told once")
    }

    /// A file nobody reads is not a problem: naming one in a formula and never wiring it is
    /// how a graph looks the moment before its consumers are created.
    func test_anUnpushedFileNothingReadsIsSilent() throws {
        _ = try makeUnpushedFile(path: "input:/unused.cfg")

        engine.reportIdleTimeErrors()

        XCTAssertTrue(captured.isEmpty, "reported: \(captured)")
    }

    // MARK: - Where the knowledge lives

    /// The rule reads the port, not the node's type. The set has one member, and it is
    /// stated here so that admitting a second is a change to that node and to this line,
    /// and never to the report.
    func test_onlyAConfigMergersOverrideToleratesAnAbsentValue() {
        XCTAssertTrue(ConfigMerger.descriptor.toleratesAbsentValue(onInputPort: ConfigMerger.overridePort))

        // The settings a merge starts from and the file a filter selects out of are both
        // files the formula says must exist.
        XCTAssertFalse(ConfigMerger.descriptor.toleratesAbsentValue(onInputPort: ConfigMerger.basePort))
        XCTAssertFalse(ConfigFilter.descriptor.toleratesAbsentValue(onInputPort: ConfigFilter.inputPort))

        // Optional at creation is a different question: `inherit` may be left unwired, and a
        // wire that is there is one whose value this node demands.
        XCTAssertFalse(Configuration.descriptor.toleratesAbsentValue(onInputPort: Configuration.inputPort))
        XCTAssertFalse(OutputFile.descriptor.toleratesAbsentValue(onInputPort: OutputFile.inputPort))
        XCTAssertFalse(DemandingSampleTool.descriptor.toleratesAbsentValue(onInputPort: DemandingSampleTool.input))
    }

    // MARK: - The one port that tolerates an absence

    /// An override file nobody wrote means "nothing to add", which is what makes a formula
    /// able to name one at all — `6502emu.fmla` lays a project-local `clang.cfg` over the
    /// shared one. The base beside it is a file that must exist, so the two ports of one
    /// node answer differently and the report reads the port rather than the node's type.
    func test_anUnpushedOverrideIsSilentWhileTheBaseBesideItIsNamed() throws {
        let override = try makeUnpushedFile(path: "input:/override.cfg")
        let base     = try makeUnpushedFile(path: "input:/base.cfg")
        let merger = try NodeRecord.createNode(database: database, kind: ConfigMerger.kind,
                                               properties: [:], graphSpec: nil).requireID()

        try connect(base, to: merger, name: "base", toPort: ConfigMerger.basePort)
        try connect(override, to: merger, name: "override", toPort: ConfigMerger.overridePort)
        try run(merger)

        XCTAssertEqual(try reason(of: merger, port: ConfigMerger.outputPort), .value,
                       "a merger with nothing to merge still publishes a configuration")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["StaticFile #\(base) 'input:/base.cfg'"]])
    }

    /// With the base pushed, the override alone leaves nothing to say.
    func test_anUnpushedOverrideOverAPushedBaseIsSilent() throws {
        let override = try makeUnpushedFile(path: "input:/override.cfg")
        let base     = try makeUnpushedFile(path: "input:/base.cfg")
        let merger = try NodeRecord.createNode(database: database, kind: ConfigMerger.kind,
                                               properties: [:], graphSpec: nil).requireID()

        try connect(base, to: merger, name: "base", toPort: ConfigMerger.basePort)
        try connect(override, to: merger, name: "override", toPort: ConfigMerger.overridePort)
        _ = try staticFile(base).replaceContent(try "clang.compiler.target=x".intern())
        try run(merger)

        engine.reportIdleTimeErrors()

        XCTAssertTrue(captured.isEmpty, "reported: \(captured)")
    }

    /// The tutorial's case, and the reason B-92 exists: `clang.cfg` reaches the tools
    /// through a `ConfigFilter`, which contributes nothing rather than failing, so without
    /// this line the reader gets a wall of missing settings and nothing naming the file.
    /// The filter still runs and still publishes an empty selection; only the report
    /// changes.
    func test_anUnpushedConfigReadOnlyByAConfigFilterIsNamed() throws {
        let file = try makeUnpushedFile(path: "input:/clang.cfg")
        let filter = try NodeRecord.createNode(database: database, kind: ConfigFilter.kind,
                                               properties: [ConfigFilter.prefixProperty: "clang.compiler"],
                                               graphSpec: nil).requireID()

        try connect(file, to: filter, name: "config", toPort: ConfigFilter.inputPort)
        try run(filter)

        XCTAssertEqual(try reason(of: filter, port: ConfigFilter.outputPort), .value,
                       "the filter selects nothing rather than failing")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["StaticFile #\(file) 'input:/clang.cfg'"]])
        XCTAssertEqual(captured[0][0].items,
                       [ErrorReport.Item(ports: ["output"], message: "clang.cfg has not been pushed", missingSource: "clang.cfg")])
        XCTAssertEqual(captured[0][0].downstreamCarrierCount, 0,
                       "the filter produced a value, so nothing carries the absence")
    }

    /// One tolerant reader does not excuse an intolerant one: a file laid over a base as an
    /// override and read by a tool besides is named, because the tool needs it.
    func test_aFileOneReaderToleratesAndAnotherNeedsIsStillNamed() throws {
        let file = try makeUnpushedFile(path: "input:/override.cfg")
        let base = try makeUnpushedFile(path: "input:/base.cfg")
        let merger = try NodeRecord.createNode(database: database, kind: ConfigMerger.kind,
                                               properties: [:], graphSpec: nil).requireID()
        let tool = try makeDemanding(tag: "tool")

        try connect(base, to: merger, name: "base", toPort: ConfigMerger.basePort)
        try connect(file, to: merger, name: "override", toPort: ConfigMerger.overridePort)
        try connect(file, to: tool, name: "config")
        _ = try staticFile(base).replaceContent(try "clang.compiler.target=x".intern())
        try run(merger)
        try run(tool)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["StaticFile #\(file) 'input:/override.cfg'"]])
    }

    // MARK: - A file that was pushed and then removed

    /// A file that was pushed and later removed is in a state of its own, which the report
    /// names by the path the reader would push again. Its consumers read it as an input in
    /// error and fold under it.
    func test_aDeletedFileIsNamedByItsPath() throws {
        let file     = try makeUnpushedFile(path: "input:/gone.c")
        let compiler = try makeDemanding(tag: "compiler")

        try connect(file, to: compiler, name: "source")
        _ = try staticFile(file).replaceContent(try "int main(){}".intern())
        _ = try staticFile(file).replaceContent(nil)
        try run(compiler)

        XCTAssertEqual(try reason(of: compiler), .inputInError)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].map(\.label), ["StaticFile #\(file) 'input:/gone.c'"])
        XCTAssertEqual(ErrorReport.lines(for: captured[0][0]),
                       ["❌ StaticFile #\(file) 'input:/gone.c'",
                        "   · gone.c was deleted",
                        "   · and 1 node downstream carries it",
                        ""])
    }

    // MARK: - B-110: the source travels typed

    /// A client that pushes what a formula needs acts on the path, not the sentence.
    func test_anUnpushedFileNamesItselfAsThePathToPush() throws {
        let file     = try makeUnpushedFile(path: "input:/clang.cfg")
        let compiler = try makeDemanding(tag: "compiler")
        try connect(file, to: compiler, name: "config")
        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0][0].items.map(\.missingSource), ["clang.cfg"])
    }

    /// A folder is pushed with a trailing slash, the way the sentence spells it.
    func test_anUnpushedFolderNamesItselfWithATrailingSlash() throws {
        let folder   = try makeUnpushedFolder(path: "src")
        let compiler = try makeDemanding(tag: "compiler")
        try connect(folder, to: compiler, name: "sources", fromPort: Folder.folderManifestOutputPort)
        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0][0].items.map(\.missingSource), ["src/"])
    }

    /// A removed source went because someone took it away; a build that pushed it back
    /// would undo that unasked, so it is not offered as one to push.
    func test_aDeletedFileIsNotOfferedAsAPathToPush() throws {
        let file     = try makeUnpushedFile(path: "input:/gone.c")
        let compiler = try makeDemanding(tag: "compiler")
        try connect(file, to: compiler, name: "source")
        _ = try staticFile(file).replaceContent(try "int main(){}".intern())
        _ = try staticFile(file).replaceContent(nil)
        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0][0].items.map(\.missingSource), [nil])
    }

    // MARK: - B-104: a folder is a source too

    /// An unpinned folder in the input file system, the way a formula naming a tree finds
    /// one nobody has pushed into.
    private func makeUnpushedFolder(path: String) throws -> ObjectID {
        try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path(path), pinned: false).requireID()
    }

    /// The item B-104 is about. A folder nobody pushed reads the way a file nobody pushed
    /// does: the path to push, not a word about the port that carries the state.
    func test_anUnpushedFolderSomethingNeedsIsNamedByThePathToPush() throws {
        let folder   = try makeUnpushedFolder(path: "src")
        let compiler = try makeDemanding(tag: "compiler")

        try connect(folder, to: compiler, name: "sources", fromPort: Folder.folderManifestOutputPort)
        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["Folder #\(folder) 'input:/src'"]])
        XCTAssertEqual(ErrorReport.lines(for: captured[0][0]),
                       ["❌ Folder #\(folder) 'input:/src'",
                        "   · src/ has not been pushed",
                        ""])
    }

    /// A folder nobody reads is no more a problem than a file nobody reads.
    func test_anUnpushedFolderNothingReadsIsSilent() throws {
        _ = try makeUnpushedFolder(path: "spare")

        engine.reportIdleTimeErrors()

        XCTAssertTrue(captured.isEmpty, "reported: \(captured)")
    }

    /// A folder that was pushed into and then removed is a different state from one nobody
    /// ever pushed, and reads as a different sentence.
    func test_aRemovedFolderIsNamedAsDeleted() throws {
        let folderRecord = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("src"), pinned: true)
        let compiler     = try makeDemanding(tag: "compiler")

        try connect(try folderRecord.requireID(), to: compiler, name: "sources",
                    fromPort: Folder.folderManifestOutputPort)
        try run(compiler)
        try XCTUnwrap(folderRecord.makeNode() as? Folder).setPinned(false)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["Folder #\(try folderRecord.requireID()) 'input:/src'"]])
        XCTAssertEqual(ErrorReport.lines(for: captured[0][0]),
                       ["❌ Folder #\(try folderRecord.requireID()) 'input:/src'",
                        "   · src/ was deleted",
                        ""])
    }

    /// A file that has been pushed is no one's problem, however many nodes read it.
    func test_aPushedFileIsSilent() throws {
        let file     = try makeUnpushedFile(path: "input:/main.c")
        let compiler = try makeDemanding(tag: "compiler")

        try connect(file, to: compiler, name: "source")
        _ = try staticFile(file).replaceContent(try "int main(){}".intern())
        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertTrue(captured.isEmpty, "reported: \(captured)")
    }
}

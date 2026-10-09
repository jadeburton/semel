//
//  UnpushedFileReportingTests.swift
//  SemelCoreTests
//
//  B-92. A file the formula names and nobody has pushed has no inputs, so nothing will
//  ever make it run: its port holds the initializing state for good, and every node that
//  needs its value publishes "an input has never been produced". Neither state is a
//  failure of the node holding it, and neither is something a reader can act on.
//
//  The file is, so the file is the cause: named once, with the chain below it counted. The
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

    /// A node made the way the engine makes every node: from its tree, static wires and
    /// all, and found rather than made when the graph already holds it.
    private func make(_ specNode: GraphSpecNode) throws -> ObjectID {
        try specNode.findOrCreateMatchingNode().fromNode.requireID()
    }

    /// A file the formula names, created the way interpreting a formula creates it: nobody
    /// has pushed it, so its output port holds the initializing state.
    private func makeUnpushedFile(path: String) throws -> ObjectID {
        try make(.staticFile(at: path))
    }

    /// A node that insists on its input's value, the way a tool reads the files it compiles,
    /// wired from `inputs` by wire name.
    private func demanding(tag: String, reading inputs: [String: GraphSpecNode]) -> GraphSpecNode {
        GraphSpecNode(DemandingSampleTool.self, properties: ["tag": tag],
                      inputs: [DemandingSampleTool.input: inputs]).port(DemandingSampleTool.output)
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

    /// The document a source nobody pushed reads as.
    private func notPushed(_ path: String, isFolder: Bool = false, writers: [MachineFileCommand] = []) -> ErrorDocument {
        .engine(.notPushed(path: path, isFolder: isFolder), subject: nil,
                remedy: writers.isEmpty ? nil : .writeMachineFile(commands: writers))
    }

    /// The document a source pushed and then removed reads as.
    private func removed(_ path: String, isFolder: Bool = false) -> ErrorDocument {
        .engine(.removed(path: path, isFolder: isFolder), subject: nil)
    }

    // MARK: - A file something needs

    /// The item B-92 is about: a formula naming a file nobody pushed, read by a node that
    /// needs its value. The file is the one thing a reader can act on, so it is the line the
    /// report writes, and the nodes stopped by it are counted under it.
    func test_anUnpushedFileSomethingNeedsIsNamedByThePathToPush() throws {
        let file         = try makeUnpushedFile(path: "input:/clang.cfg")
        let compilerTree = demanding(tag: "compiler", reading: ["config": .staticFile(at: "input:/clang.cfg")])
        let compiler     = try make(compilerTree)
        let linker       = try make(demanding(tag: "linker", reading: ["object": compilerTree]))

        try run(compiler)
        try run(linker)

        XCTAssertEqual(try reason(of: file), .initializing)
        XCTAssertEqual(try reason(of: compiler), .inputNotProduced)
        XCTAssertEqual(try reason(of: linker), .inputNotProduced, "the state carries down the chain")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].map(\.label), ["StaticFile #\(file) 'input:/clang.cfg'"])
        XCTAssertEqual(captured[0][0].items,
                       [ErrorReport.Item(ports: ["output"], document: notPushed("input:/clang.cfg"))])
        XCTAssertEqual(captured[0][0].downstreamCarrierCount, 2,
                       "the compiler and the linker below it")
    }

    /// What the reader is told: the file, and the count of what it stops below it.
    func test_theCauseIsTheFileAndCountsWhatItStopped() throws {
        _            = try makeUnpushedFile(path: "input:/main.c")
        let compiler = try make(demanding(tag: "compiler", reading: ["source": .staticFile(at: "input:/main.c")]))

        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0][0].items.map(\.document), [notPushed("input:/main.c")])
        XCTAssertEqual(captured[0][0].downstreamCarrierCount, 1)
    }

    /// The path `push` takes is the path relative to the input file system, typed, so a
    /// build pushes it without reading a sentence; a removed source is not offered.
    func test_theDocumentNamesThePathToPush() {
        XCTAssertEqual(notPushed("input:/src/main.c").unpushedSource, "src/main.c")
        XCTAssertEqual(notPushed("input:/src", isFolder: true).unpushedSource, "src")
        XCTAssertNil(removed("input:/src/main.c").unpushedSource)
    }

    /// The `errors` verb asks for everything the graph holds rather than for what is newly
    /// appearing, and goes through the same two calls the handler makes. It has to name the
    /// file too, or a build that printed the line once would answer "no errors" when asked.
    func test_theErrorsReplyNamesTheSameFile() throws {
        let file     = try makeUnpushedFile(path: "input:/clang.cfg")
        let compiler = try make(demanding(tag: "compiler", reading: ["config": .staticFile(at: "input:/clang.cfg")]))

        try run(compiler)

        let entries = ErrorReport.entries(forErrorPorts: try ErrorReport.portsToReport(database: database),
                                          database: database,
                                          select: { _, documents in documents })

        XCTAssertEqual(entries.map(\.label), ["StaticFile #\(file) 'input:/clang.cfg'"])
        XCTAssertEqual(entries[0].items,
                       [ErrorReport.Item(ports: ["output"], document: notPushed("input:/clang.cfg"))])
        XCTAssertEqual(entries[0].downstreamCarrierCount, 1)
    }

    /// Asked twice, answered once: a standing absence is reported the first time the engine
    /// settles and not on every settle afterwards, the same as a standing failure.
    func test_theFileIsReportedOnceAndCountedEveryTime() throws {
        _            = try makeUnpushedFile(path: "input:/clang.cfg")
        let compiler = try make(demanding(tag: "compiler", reading: ["config": .staticFile(at: "input:/clang.cfg")]))

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

    /// The rule reads the port, not the node's type. Among the engine's nodes the set has
    /// one member, and it is stated here so that admitting a second is a change to that
    /// node and to this line, and never to the report. The clang plugin's header ports are
    /// the others (B-79), pinned in its own tests, since this target cannot see them.
    func test_onlyAConfigMergersOverrideToleratesAnAbsentValue() {
        XCTAssertTrue(ConfigMerger.descriptor.toleratesAbsentValue(onInputPort: ConfigMerger.overridePort))

        // The settings a merge starts from and the file a filter selects out of are both
        // files the formula says must exist.
        XCTAssertFalse(ConfigMerger.descriptor.toleratesAbsentValue(onInputPort: ConfigMerger.basePort))
        XCTAssertFalse(ConfigFilter.descriptor.toleratesAbsentValue(onInputPort: ConfigFilter.inputPort))

        // Optional at creation is a different question: `input` may be left unwired, and a
        // wire that is there is one whose value this node demands.
        XCTAssertFalse(TreeMerger.descriptor.toleratesAbsentValue(onInputPort: TreeMerger.inputPort))
        XCTAssertFalse(OutputFile.descriptor.toleratesAbsentValue(onInputPort: OutputFile.inputPort))
        XCTAssertFalse(DemandingSampleTool.descriptor.toleratesAbsentValue(onInputPort: DemandingSampleTool.input))
    }

    // MARK: - The engine's one port that tolerates an absence

    /// `override.cfg` laid over `base.cfg`.
    private var overrideOverBase: GraphSpecNode {
        .configMerger(base: ["base": .staticFile(at: "input:/base.cfg")],
                      override: ["override": .staticFile(at: "input:/override.cfg")])
    }

    /// An override file nobody wrote means "nothing to add", which is what makes a formula
    /// able to name one at all — `6502emu.fmla` lays a project-local `clang.cfg` over the
    /// shared one. The base beside it is a file that must exist, so the two ports of one
    /// node answer differently and the report reads the port rather than the node's type.
    func test_anUnpushedOverrideIsSilentWhileTheBaseBesideItIsNamed() throws {
        let base   = try makeUnpushedFile(path: "input:/base.cfg")
        let merger = try make(overrideOverBase)

        try run(merger)

        XCTAssertEqual(try reason(of: merger, port: ConfigMerger.outputPort), .value,
                       "a merger with nothing to merge still publishes a configuration")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["StaticFile #\(base) 'input:/base.cfg'"]])
    }

    /// With the base pushed, the override alone leaves nothing to say.
    func test_anUnpushedOverrideOverAPushedBaseIsSilent() throws {
        let base   = try makeUnpushedFile(path: "input:/base.cfg")
        let merger = try make(overrideOverBase)

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
        let file   = try makeUnpushedFile(path: "input:/clang.cfg")
        let filter = try make(.configFilter(prefix: "clang.compiler", input: ["config": .staticFile(at: "input:/clang.cfg")]))

        try run(filter)

        XCTAssertEqual(try reason(of: filter, port: ConfigFilter.outputPort), .value,
                       "the filter selects nothing rather than failing")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["StaticFile #\(file) 'input:/clang.cfg'"]])
        XCTAssertEqual(captured[0][0].items,
                       [ErrorReport.Item(ports: ["output"], document: notPushed("input:/clang.cfg"))])
        XCTAssertEqual(captured[0][0].downstreamCarrierCount, 0,
                       "the filter produced a value, so nothing carries the absence")
    }

    /// One tolerant reader does not excuse an intolerant one: a file laid over a base as an
    /// override and read by a tool besides is named, because the tool needs it.
    func test_aFileOneReaderToleratesAndAnotherNeedsIsStillNamed() throws {
        let file   = try makeUnpushedFile(path: "input:/override.cfg")
        let base   = try makeUnpushedFile(path: "input:/base.cfg")
        let merger = try make(overrideOverBase)
        let tool   = try make(demanding(tag: "tool", reading: ["config": .staticFile(at: "input:/override.cfg")]))

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
        let compiler = try make(demanding(tag: "compiler", reading: ["source": .staticFile(at: "input:/gone.c")]))

        _ = try staticFile(file).replaceContent(try "int main(){}".intern())
        _ = try staticFile(file).replaceContent(nil)
        try run(compiler)

        XCTAssertEqual(try reason(of: compiler), .inputInError)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].map(\.label), ["StaticFile #\(file) 'input:/gone.c'"])
        XCTAssertEqual(captured[0][0].items.map(\.document), [removed("input:/gone.c")])
        XCTAssertEqual(captured[0][0].downstreamCarrierCount, 1)
    }

    // MARK: - B-110: the source travels typed

    /// A client that pushes what a formula needs acts on the path, not the sentence.
    func test_anUnpushedFileNamesItselfAsThePathToPush() throws {
        _ = try makeUnpushedFile(path: "input:/clang.cfg")
        let compiler = try make(demanding(tag: "compiler", reading: ["config": .staticFile(at: "input:/clang.cfg")]))
        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0][0].items.map(\.document.unpushedSource), ["clang.cfg"])
    }

    /// A folder is the path `push` takes for it, with the case saying it is a folder.
    func test_anUnpushedFolderNamesItselfAsAFolder() throws {
        _ = try makeUnpushedFolder(path: "src")
        let compiler = try make(demanding(tag: "compiler", reading: ["sources": .folderManifest(at: "input:/src")]))
        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0][0].items.map(\.document), [notPushed("input:/src", isFolder: true)])
        XCTAssertEqual(captured[0][0].items.map(\.document.unpushedSource), ["src"])
    }

    /// A removed source went because someone took it away; a build that pushed it back
    /// would undo that unasked, so it is not offered as one to push.
    func test_aDeletedFileIsNotOfferedAsAPathToPush() throws {
        let file     = try makeUnpushedFile(path: "input:/gone.c")
        let compiler = try make(demanding(tag: "compiler", reading: ["source": .staticFile(at: "input:/gone.c")]))
        _ = try staticFile(file).replaceContent(try "int main(){}".intern())
        _ = try staticFile(file).replaceContent(nil)
        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0][0].items.map(\.document.unpushedSource), [nil])
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
        let compiler = try make(demanding(tag: "compiler", reading: ["sources": .folderManifest(at: "input:/src")]))

        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["Folder #\(folder) 'input:/src'"]])
        XCTAssertEqual(captured[0][0].items.map(\.document), [notPushed("input:/src", isFolder: true)])
    }

    /// A file under a folder that is itself unpushed and needed is the folder's detail:
    /// pushing the folder pushes it, so the folder is the one line and the one path a
    /// build pushes — a converter waiting for a package demands the package's folder and
    /// the reader of its manifest alike (B-110).
    func test_anUnpushedFileUnderAnUnpushedFolderSomethingNeedsIsTheFoldersDetail() throws {
        let folder    = try makeUnpushedFolder(path: "Helper")
        _             = try makeUnpushedFile(path: "input:/Helper/Package.swift")
        let converter = try make(demanding(tag: "converter", reading: ["package": .folderManifest(at: "input:/Helper")]))
        let reader    = try make(demanding(tag: "reader", reading: ["manifest": .staticFile(at: "input:/Helper/Package.swift")]))

        try run(converter)
        try run(reader)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["Folder #\(folder) 'input:/Helper'"]])
        XCTAssertEqual(captured[0][0].items.map(\.document.unpushedSource), ["Helper"])
    }

    /// A folder nobody reads is no more a problem than a file nobody reads.
    func test_anUnpushedFolderNothingReadsIsSilent() throws {
        _ = try makeUnpushedFolder(path: "spare")

        engine.reportIdleTimeErrors()

        XCTAssertTrue(captured.isEmpty, "reported: \(captured)")
    }

    /// A folder that was pushed into and then removed is a different state from one nobody
    /// ever pushed, and is a different condition.
    func test_aRemovedFolderIsNamedAsDeleted() throws {
        let folderRecord = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("src"), pinned: true)
        let compiler     = try make(demanding(tag: "compiler", reading: ["sources": .folderManifest(at: "input:/src")]))

        try run(compiler)
        try XCTUnwrap(folderRecord.makeNode() as? Folder).setPinned(false)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["Folder #\(try folderRecord.requireID()) 'input:/src'"]])
        XCTAssertEqual(captured[0][0].items.map(\.document), [removed("input:/src", isFolder: true)])
    }

    // MARK: - A machine file nobody has written (B-109)

    /// A prelude's settings: `machine` laid under a pushed project file by a `ConfigMerger`,
    /// and a `ConfigFilter` per namespace selecting out of the merge. Returns the file.
    private func makeSettings(machinePath: String, prefixes: [String]) throws -> ObjectID {
        let machine     = try makeUnpushedFile(path: machinePath)
        let folder      = Path(machinePath).deletingLastComponent ?? Path("input:")
        let projectPath = (folder / "semel.config").string
        let project     = try makeUnpushedFile(path: projectPath)
        _ = try staticFile(project).replaceContent(try "sample.compiler.target=x".intern())
        let mergerTree = GraphSpecNode.configMerger(base: ["machine": .staticFile(at: machinePath)],
                                                    override: ["project": .staticFile(at: projectPath)])
        for prefix in prefixes {
            _ = try make(.configFilter(prefix: prefix, input: ["settings": mergerTree]))
        }
        try run(try make(mergerTree))
        return machine
    }

    private func registerWriters() {
        ToolNamespaceRegistry.register(.init(namespace: "sample.compiler", toolName: "clang",
                                             machineFileWriter: .init(command: "semel-clang", rewriteFlags: ["--force"])))
        ToolNamespaceRegistry.register(.init(namespace: "sample.linker", toolName: "swiftc",
                                             machineFileWriter: .init(command: "semel-swift prepare")))
        ToolNamespaceRegistry.register(.init(namespace: "sample.reader", toolName: "swift",
                                             machineFileWriter: .init(command: "semel-swift prepare")))
        ToolNamespaceRegistry.register(.init(namespace: "sample.plister", toolName: "none"))
    }

    /// `build` cannot push a file that is not on disk, and the tools below say what they
    /// lack rather than what writes it: the file's remedy names the command, found from the
    /// namespaces selected out of it, in the folder it sits in, as a reader types it.
    func test_anUnpushedMachineFileNamesTheCommandThatWritesIt() throws {
        registerWriters()
        _ = try makeSettings(machinePath: "input:/semel.machine.config", prefixes: ["sample.compiler"])

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0][0].items,
                       [ErrorReport.Item(ports: ["output"],
                                         document: notPushed("input:/semel.machine.config",
                                                             writers: [MachineFileCommand(command: "semel-clang", folder: ".")]))])
    }

    /// Two toolchains' namespaces read out of one file are two writers, each once, in one
    /// remedy; a namespace whose toolchain registered no writer adds none.
    func test_aMachineFileTwoToolchainsReadNamesBothWriters() throws {
        registerWriters()
        _ = try makeSettings(machinePath: "input:/app/semel.machine.config",
                             prefixes: ["sample.compiler", "sample.linker", "sample.reader", "sample.plister"])

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0][0].items.map(\.document),
                       [notPushed("input:/app/semel.machine.config",
                                  writers: [MachineFileCommand(command: "semel-clang", folder: "app"),
                                            MachineFileCommand(command: "semel-swift prepare", folder: "app")])])
    }

    /// A writer writes `semel.machine.config` and nothing else, so a file of another name
    /// is not one it answers, whatever reads it; nor is a machine file whose namespaces no
    /// toolchain registered a writer for. Two settings chains in one graph, as a project
    /// with a subfolder of its own has.
    func test_anUnpushedFileNoWriterWritesNamesNone() throws {
        registerWriters()
        _ = try makeSettings(machinePath: "input:/clang.cfg", prefixes: ["sample.compiler"])
        _ = try makeSettings(machinePath: "input:/other/semel.machine.config", prefixes: ["sample.plister"])

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0].count, 2, "\(captured)")
        XCTAssertEqual(captured[0].flatMap(\.items).compactMap(\.document.remedy), [])
        XCTAssertEqual(captured[0].flatMap(\.items).compactMap(\.document.unpushedSource).sorted(),
                       ["clang.cfg", "other/semel.machine.config"],
                       "each is still the path build pushes once it is there")
    }

    /// A file that has been pushed is no one's problem, however many nodes read it.
    func test_aPushedFileIsSilent() throws {
        let file     = try makeUnpushedFile(path: "input:/main.c")
        let compiler = try make(demanding(tag: "compiler", reading: ["source": .staticFile(at: "input:/main.c")]))

        _ = try staticFile(file).replaceContent(try "int main(){}".intern())
        try run(compiler)

        engine.reportIdleTimeErrors()

        XCTAssertTrue(captured.isEmpty, "reported: \(captured)")
    }
}

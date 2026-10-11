//
//  TreeBuilderTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// The counterpart of `TreeFile`: N files in, one tree out, each entry named by its wire.
final class TreeBuilderTests: SemelCoreTestCase {

    private func process(_ files: [String: NodeValue]) throws -> NodeValue {
        let node = try TreeBuilder(thisNode: NodeRecord(id: 1, kind: TreeBuilder.kind))
        let output = try node.process(input: ProcessInput(inputValues: [TreeBuilder.inputPort: files]))
        return try XCTUnwrap(output.outputValues[TreeBuilder.outputPort])
    }

    func test_everyWireBecomesAnEntryNamedByItsKey() throws {
        let built = try process(["Models.o": .value(try "models".intern()),
                                 "Timeline.o": .value(try "timeline".intern())])

        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try built.expectValue().resolveAsString())
        XCTAssertEqual(manifest.entries.map(\.path), ["Models.o", "Timeline.o"])
        XCTAssertEqual(try manifest.entry(at: "Timeline.o")?.hash?.resolveAsString(), "timeline")
    }

    // MARK: - Links (B-77)

    /// A file pushed as a symbolic link is a link entry where what it names is in the
    /// tree, and the copy of its bytes where it is not: a bundle keeps its framework's links,
    /// and a link whose target was left behind still delivers what it named.
    func test_aLinkIsALinkWhereItsTargetIsInTheTreeAndACopyWhereItIsNot() throws {
        let node = try TreeBuilder(thisNode: NodeRecord(id: 1, kind: TreeBuilder.kind))
        let link = { (target: String) in try FileMetadata(mode: 0o755, symbolicLinkTarget: target).jsonString().intern() }
        let output = try node.process(input: ProcessInput(inputValues: [
            TreeBuilder.inputPort:             ["F/A/Tiny":   .value(try "binary".intern()),
                                                "F/Tiny":     .value(try "binary".intern()),
                                                "Loose/Tiny": .value(try "binary".intern())],
            TreeBuilder.fileMetadataInputPort: ["F/Tiny":     .value(try link("A/Tiny")),
                                                "Loose/Tiny": .value(try link("Elsewhere/Tiny"))],
        ]))

        let json = try XCTUnwrap(output.outputValues[TreeBuilder.outputPort]).expectValue().resolveAsString()
        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: json)
        XCTAssertEqual(manifest.entry(at: "F/Tiny"), TreeManifestEntry(path: "F/Tiny", symbolicLinkTarget: "A/Tiny"))
        XCTAssertEqual(manifest.entry(at: "Loose/Tiny"), TreeManifestEntry(path: "Loose/Tiny", hash: try "binary".intern(), mode: 0o755))
    }

    /// `links` puts the links a versioned framework has beside its files: `Versions/Current`
    /// to `A`, and each top-level name into it; one naming nothing in the tree is left out,
    /// and a property that is not a JSON dictionary of strings is an error naming it
    /// (B-77 item 4).
    func test_theLinksPropertyLaysAFrameworksLinksBesideItsFiles() throws {
        let links = #"{"Kit.framework/Versions/Current":"A","Kit.framework/Kit":"Versions/Current/Kit","Kit.framework/Modules":"Versions/Current/Modules"}"#
        let node = try TreeBuilder(thisNode: NodeRecord(id: 1, kind: TreeBuilder.kind, name: nil,
                                                        properties: [TreeBuilder.linksProperty: links], scheduled: false, identity: nil))
        let output = try node.process(input: ProcessInput(inputValues: [
            TreeBuilder.inputPort: ["Kit.framework/Versions/A/Kit": .value(try "binary".intern())],
        ]))

        let json = try XCTUnwrap(output.outputValues[TreeBuilder.outputPort]).expectValue().resolveAsString()
        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: json)
        XCTAssertEqual(manifest.entries.map(\.path), ["Kit.framework/Kit", "Kit.framework/Versions/A/Kit", "Kit.framework/Versions/Current"])
        XCTAssertEqual(manifest.entry(at: "Kit.framework/Versions/Current")?.symbolicLinkTarget, "A")
        XCTAssertEqual(manifest.entry(at: "Kit.framework/Kit")?.symbolicLinkTarget, "Versions/Current/Kit")

        let malformed = try TreeBuilder(thisNode: NodeRecord(id: 1, kind: TreeBuilder.kind, name: nil,
                                                             properties: [TreeBuilder.linksProperty: "[]"], scheduled: false, identity: nil))
        XCTAssertThrowsError(try malformed.process(input: ProcessInput(inputValues: [TreeBuilder.inputPort: [:]]))) { error in
            XCTAssertEqual(error as? ErrorCondition, .propertyNotOfForm(type: "TreeBuilder", property: "links", form: .jsonStringDictionary))
        }
    }

    /// A file that failed stops the tree, and the tree says so as its own state rather than
    /// repeating the compiler's sentence: a report folds it onto the node that failed.
    func test_aFileWithoutAValueStopsTheTreeAsACarriedState() throws {
        let node = try TreeBuilder(thisNode: NodeRecord(id: 1, kind: TreeBuilder.kind))
        let output = node.processWithCatch(input: ProcessInput(inputValues: [TreeBuilder.inputPort: [
            "Models.o": .value(try "models".intern()),
            "Timeline.o": .noValue(reason: try .failure("compile failed")),
        ]]))

        guard case .noValue(.inputInError) = try XCTUnwrap(output.outputValues[TreeBuilder.outputPort]) else {
            return XCTFail("expected the carried state")
        }
    }

    func test_noWiresIsAnEmptyTree() throws {
        let built = try process([:])

        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try built.expectValue().resolveAsString())
        XCTAssertTrue(manifest.entries.isEmpty)
    }

    // MARK: - Modes (B-108)

    /// The mode on a file's `fileMetadata` wire is the entry's; a file with no such wire —
    /// a plist builder publishes none — has the default.
    func test_eachEntryCarriesTheModeWiredBesideItsFile() throws {
        let node = try TreeBuilder(thisNode: NodeRecord(id: 1, kind: TreeBuilder.kind))
        let executable = try FileMetadata(mode: FileMetadata.executableMode).jsonString().intern()
        let output = try node.process(input: ProcessInput(inputValues: [
            TreeBuilder.inputPort:             ["Hello": .value(try "binary".intern()),
                                                "Info.plist": .value(try "plist".intern())],
            TreeBuilder.fileMetadataInputPort: ["Hello": .value(executable)],
        ]))

        let json = try XCTUnwrap(output.outputValues[TreeBuilder.outputPort]).expectValue().resolveAsString()
        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: json)
        XCTAssertEqual(manifest.entry(at: "Hello")?.mode, 0o755)
        XCTAssertEqual(manifest.entry(at: "Info.plist")?.mode, 0o644)
    }

    /// A formula names the files only; the modes are wired where the spec is built, from
    /// every source that publishes one and is read at the file it describes.
    func test_aSpecGainsAModeWireForEachFileWhoseSourcePublishesOne() throws {
        let tree = GraphSpecNode(TreeBuilder.self, inputs: [TreeBuilder.inputPort: [
            "PkgInfo":    .staticFile(at: "input:/app/PkgInfo"),
            "Info.plist": GraphSpecNode(SampleTool.self).port(SampleTool.output),
            "notes":      GraphSpecNode(TreeFile.self, properties: [TreeFile.nameProperty: "notes"],
                                        inputs: [TreeFile.treeInputPort: ["tree": .staticFile(at: "input:/tree")]])
                              .port(TreeFile.outputPort),
            "log":        GraphSpecNode(TreeFile.self, properties: [TreeFile.nameProperty: "log"],
                                        inputs: [TreeFile.treeInputPort: ["tree": .staticFile(at: "input:/tree")]])
                              .port(FileMetadata.portName),
        ]]).wiringFileMetadata()

        let modes = try XCTUnwrap(tree.inputs.first { $0.portName == TreeBuilder.fileMetadataInputPort })
        XCTAssertEqual(modes.wires.map(\.name), ["PkgInfo", "notes"],
                       "a source with no fileMetadata port, and a wire not read at the file, have none")
        XCTAssertEqual(modes.wires.map(\.node.outputPort), [FileMetadata.portName, FileMetadata.portName])
        let pkgInfo = try XCTUnwrap(tree.inputs.first { $0.portName == TreeBuilder.inputPort }?.wires.first { $0.name == "PkgInfo" })
        XCTAssertEqual(modes.wires[0].node, pkgInfo.node.port(FileMetadata.portName),
                       "the mode comes from the node the file does")
    }

    /// A spec that already wires the modes is taken as it stands.
    func test_aModeWireTheSpecStatesIsLeftAlone() throws {
        let stated = GraphSpecNode(TreeBuilder.self, inputs: [
            TreeBuilder.inputPort:             ["PkgInfo": .staticFile(at: "input:/app/PkgInfo")],
            TreeBuilder.fileMetadataInputPort: ["PkgInfo": GraphSpecNode.settingsLiteral(["mode": "493"])],
        ])

        XCTAssertEqual(stated.wiringFileMetadata(), stated)
    }
}

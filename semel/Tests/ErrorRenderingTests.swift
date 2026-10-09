//
//  ErrorRenderingTests.swift
//  SemelCLITests
//
//  The error report, drawn from the documents nodes publish (the 2026-10-09 design): one
//  test per condition and per subject pinning the exact lines, and the report's own rules —
//  one heading per set of products with the same errors, an error printed once and
//  `(above)` after, the heading's cut and its ties, a tool's text over several lines, a
//  tool that said nothing, the summary line in its four forms, `--verbose`, the `input:/`
//  substitution and colour.
//

@testable import SemelCLI
import SemelNodeKit
import SemelProtocol
import XCTest

final class ErrorRenderingTests: XCTestCase {

    private let plain = ErrorReportStyle()

    private func facts(_ type: String = "SampleTool", _ ids: [Int64] = [1], ports: [String] = ["output"],
                       carried: Int = 0) -> ErrorFacts {
        ErrorFacts(nodeType: type, nodeIDs: ids, ports: ports, carrierCount: carried)
    }

    /// One document's block: the report without its heading, and without the blank line and
    /// the summary under it.
    private func block(_ document: ErrorDocument, products: [StoppedProduct] = [],
                       style: ErrorReportStyle = ErrorReportStyle()) -> [String] {
        let lines = ErrorReportRenderer.lines(for: [ErrorRecord(document: document, products: products, facts: facts())],
                                              style: style)
        return Array(lines.dropFirst().dropLast(2))
    }

    /// One condition's block, its remedy the one it implies unless one is given.
    private func block(_ condition: ErrorCondition, subject: ErrorDocument.Subject? = nil,
                       remedy: ErrorDocument.Remedy? = nil, products: [StoppedProduct] = []) -> [String] {
        block(.engine(condition, subject: subject, remedy: remedy), products: products)
    }

    private func products(_ names: String...) -> [StoppedProduct] {
        names.map { StoppedProduct(path: "output:/\($0)") }
    }

    // MARK: - Tools

    func test_toolExitedSilently() {
        XCTAssertEqual(block(.toolExitedSilently(tool: "swiftc", status: 1)),
                       ["swiftc exited with status 1 and said nothing"])
    }

    func test_toolWroteNothing() {
        XCTAssertEqual(block(.toolWroteNothing(tool: "ibtool", status: 0, paths: ["Base.lproj/MainMenu.nib"])),
                       ["ibtool exited with status 0 and wrote nothing at Base.lproj/MainMenu.nib"])
        XCTAssertEqual(block(.toolWroteNothing(tool: "swift package dump-package", status: 0, paths: [])).first,
                       "swift package dump-package exited with status 0 and wrote nothing at its output")
    }

    func test_toolNotInstalled() {
        let condition = ErrorCondition.toolNotInstalled(
            requested: ToolIdentity(name: "clang", version: "17.0.0", platform: "macos", architecture: "arm64"),
            available: [ToolIdentity(name: "clang", version: "16.0.0", platform: "macos", architecture: "arm64")],
            namespace: "clang.compiler",
            writer: MachineFileCommand(command: "semel-clang", folder: nil, flags: ["--force"]))

        XCTAssertEqual(block(condition), [
            "no tool installed here matches clang 17.0.0 (macos/arm64)",
            "  installed: clang 16.0.0 (macos/arm64)",
            "  named by: clang.compiler.toolDescriptor",
            "  write with: semel-clang <folder> --force",
        ])
    }

    func test_toolNotFound() {
        XCTAssertEqual(block(.toolNotFound(path: "/usr/bin/nonesuch")), ["no tool exists at /usr/bin/nonesuch"])
    }

    func test_toolNotExecutable() {
        XCTAssertEqual(block(.toolNotExecutable(path: "/tmp/tool")), ["/tmp/tool is not executable"])
    }

    func test_toolInputNotWritten() {
        XCTAssertEqual(block(.toolInputNotWritten(file: "input:/a.c", reason: "disk full")),
                       ["a.c cannot be laid in the tool's sandbox", "  reason: disk full"])
    }

    func test_toolOutputNotRead() {
        XCTAssertEqual(block(.toolOutputNotRead(file: "out.o")), ["the tool's output out.o cannot be read back"])
    }

    func test_toolLaunchFailed() {
        XCTAssertEqual(block(.toolLaunchFailed(reason: "no such file")),
                       ["the tool cannot be started", "  reason: no such file"])
    }

    // MARK: - Settings

    /// The machine's keys are written by its command, which is the remedy; with the
    /// project's beside them, those are said as keys to set.
    func test_settingsMissing() {
        let writer = MachineFileCommand(command: "semel-clang", folder: nil)

        XCTAssertEqual(block(.settingsMissing(project: [], machine: ["clang.compiler.toolDescriptor.name"], writer: writer)), [
            "missing settings: clang.compiler.toolDescriptor.name",
            "  write with: semel-clang <folder>",
        ])
        XCTAssertEqual(block(.settingsMissing(project: ["clang.compiler.target"], machine: ["clang.compiler.toolDescriptor.name"],
                                              writer: writer)), [
            "missing settings: clang.compiler.target, clang.compiler.toolDescriptor.name",
            "  set: clang.compiler.target",
            "  write with: semel-clang <folder>",
        ])
        XCTAssertEqual(block(.settingsMissing(project: ["clang.compiler.target"], machine: [], writer: nil)), [
            "missing settings: clang.compiler.target",
            "  set: clang.compiler.target",
        ])
    }

    func test_settingNotAccepted() {
        XCTAssertEqual(block(.settingNotAccepted(key: "swift.linker.linkage", value: "dynamik",
                                                 accepted: ["static", "dynamic", "executable"])), [
            "swift.linker.linkage is 'dynamik', which is not one of static, dynamic, executable",
            "  set: swift.linker.linkage",
        ])
    }

    func test_settingNotAList() {
        XCTAssertEqual(block(.settingNotAList(key: "swift.compiler.unsafeFlags", value: "-Xfoo")), [
            "swift.compiler.unsafeFlags is '-Xfoo', which is not a JSON list of strings",
            "  set: swift.compiler.unsafeFlags",
        ])
    }

    func test_sdkNotFound() {
        XCTAssertEqual(block(.sdkNotFound(sdk: "iphoneos", key: "swift.compiler.sdk")), [
            "no SDK named iphoneos is installed here",
            "  named by: swift.compiler.sdk",
            "  set: swift.compiler.sdk",
        ])
    }

    /// A version with no build number is never a match, and the line says which of the
    /// three it is.
    func test_sdkVersionDiffers() {
        XCTAssertEqual(block(.sdkVersionDiffers(sdk: "macosx", declared: "26.5 (25F70)", found: nil)).first,
                       "sdkVersion is 26.5 (25F70), and no SDK named macosx is installed here")
        XCTAssertEqual(block(.sdkVersionDiffers(sdk: "macosx", declared: "26.5", found: "26.5 (25F70)")).first,
                       "sdkVersion is 26.5, without the SDK's build number; this machine's macosx SDK is 26.5 (25F70)")
        XCTAssertEqual(block(.sdkVersionDiffers(sdk: "macosx", declared: "26.4 (25E50)", found: "26.5 (25F70)")),
                       ["sdkVersion is 26.4 (25E50), and this machine's macosx SDK is 26.5 (25F70)"])
    }

    func test_settingNotSupported() {
        XCTAssertEqual(block(.settingNotSupported(key: "apple.codeSigner.identity", value: "Apple Development", supported: "-")), [
            "apple.codeSigner.identity is 'Apple Development', and '-' is the one value built with",
            "  set: apple.codeSigner.identity",
        ])
    }

    // MARK: - Sources

    func test_notPushed() {
        XCTAssertEqual(block(.notPushed(path: "input:/Packages/Kit/Sources/Kit", isFolder: true)),
                       ["Packages/Kit/Sources/Kit has not been pushed"])
    }

    /// The machine file nobody has written names the command that writes it, in the folder
    /// it goes in.
    func test_notPushedMachineFileNamesItsWriters() {
        XCTAssertEqual(block(.notPushed(path: "input:/semel.machine.config", isFolder: false),
                             remedy: .writeMachineFile(commands: [MachineFileCommand(command: "semel-clang", folder: "."),
                                                                  MachineFileCommand(command: "semel-swift prepare", folder: ".")]),
                             products: products("hello/hello")), [
            "semel.machine.config has not been pushed",
            "  write with: semel-clang . and semel-swift prepare .",
        ])
    }

    func test_removed() {
        XCTAssertEqual(block(.removed(path: "input:/src/main.c", isFolder: false)), ["src/main.c has been removed"])
        XCTAssertEqual(block(.removed(path: nil, isFolder: false)).first, "a source this node reads has been removed")
    }

    func test_inputInError() {
        XCTAssertEqual(block(.inputInError), ["an input is in error, and no node above it says why"])
    }

    func test_documentUnreadable() {
        XCTAssertEqual(block(.documentUnreadable(hash: "abc")),
                       ["an error whose document cannot be read", "  document: abc"])
        XCTAssertEqual(block(.documentUnreadable(hash: "")).dropFirst().first, "  document: none")
    }

    // MARK: - Types and the graph

    func test_unlinkedKind() {
        XCTAssertEqual(block(.unlinkedKind(kind: 43), products: products("hello/lines.txt")), [
            "a node of kind 43 is of a type this server does not link",
            "  register: kind 43",
        ])
    }

    func test_unknownTypeName() {
        XCTAssertEqual(block(.unknownTypeName(name: "MyLineCounter"), subject: .formula(path: "input:/hello/hello.fmla")), [
            "no node type is registered under the name 'MyLineCounter'",
            "  formula: hello/hello.fmla",
            "  register: MyLineCounter",
        ])
    }

    func test_requiredPortUnwired() {
        XCTAssertEqual(block(.requiredPortUnwired(type: "ClangLinker", port: "objectFiles")),
                       ["ClangLinker's required input 'objectFiles' has nothing wired to it"])
        XCTAssertEqual(block(.requiredPortUnwired(type: nil, port: "input")).first, "required input 'input' has nothing wired to it")
    }

    func test_severalWiresOnOneWirePort() {
        XCTAssertEqual(block(.severalWiresOnOneWirePort(type: "SampleTool", port: "configuration", wires: ["machine", "project"])), [
            "SampleTool's input 'configuration' takes one wire, and 2 are wired to it",
            "  wires: machine, project",
        ])
    }

    func test_portNotDeclared() {
        XCTAssertEqual(block(.portNotDeclared(type: "SampleTool", port: "nope")), ["SampleTool declares no input port 'nope'"])
        XCTAssertEqual(block(.portNotDeclared(type: nil, port: "nope")).first, "this node declares no input port 'nope'")
    }

    func test_outputPortMissing() {
        XCTAssertEqual(block(.outputPortMissing(nodeID: 12, port: "output")),
                       ["node #12 holds no row for its output port 'output', which its type declares"])
    }

    func test_nodePropertyMissing() {
        XCTAssertEqual(block(.nodePropertyMissing(kind: 3, nodeID: 7, property: "path")),
                       ["node #7 of kind 3 has no 'path', which its type is always made with"])
    }

    func test_propertyMissing() {
        XCTAssertEqual(block(.propertyMissing(type: "SwiftFormulaConverter", property: "path",
                                              alternatives: ["packageFolder", "packageJSON"])), [
            "SwiftFormulaConverter is given no 'path'",
            "  or wired: packageFolder, packageJSON",
        ])
        XCTAssertEqual(block(.propertyMissing(type: "XcodeProjectConverter", property: "path", alternatives: [])),
                       ["XcodeProjectConverter is given no 'path'"])
    }

    func test_propertiesExclusive() {
        XCTAssertEqual(block(.propertiesExclusive(type: "ModuleMapWriter", properties: ["umbrellaHeader", "umbrellaDirectory"])),
                       ["ModuleMapWriter takes exactly one of umbrellaHeader and umbrellaDirectory"])
    }

    func test_propertyNotOfForm() {
        XCTAssertEqual(block(.propertyNotOfForm(type: "InfoPlistBuilder", property: "keys", form: .jsonDictionary)),
                       ["InfoPlistBuilder's 'keys' is not a JSON dictionary"])
    }

    func test_inputNotOfForm() {
        XCTAssertEqual(block(.inputNotOfForm(port: "partials", wire: "input:/a.plist", form: .propertyListDictionary)),
                       ["'a.plist' on partials is not a property list dictionary"])
    }

    func test_inputHasNoContent() {
        XCTAssertEqual(block(.inputHasNoContent(port: "base", wire: "input:/Info.plist")),
                       ["'Info.plist' on base has no content"])
    }

    func test_sourceCannotProcess() {
        XCTAssertEqual(block(.sourceCannotProcess(type: "StaticFile")),
                       ["StaticFile declares no input ports and does not process"])
    }

    func test_processNotSupported() {
        XCTAssertEqual(block(.processNotSupported(type: nil)), ["this node does not process"])
    }

    func test_cannotHaveProperties() {
        XCTAssertEqual(block(.cannotHaveProperties), ["this node takes no properties"])
    }

    func test_cannotDeleteNodeWithOutputs() {
        XCTAssertEqual(block(.cannotDeleteNodeWithOutputs), ["a node whose outputs are wired is not deleted"])
    }

    func test_nodeNotFound() {
        XCTAssertEqual(block(.nodeNotFound), ["there is no such node"])
    }

    func test_nameCollision() {
        XCTAssertEqual(block(.nameCollision(path: "input:/src/a", existingKind: 1)),
                       ["src/a is a node of kind 1, and two children of one folder do not share a name"])
    }

    func test_graphSpecBadIntegrity() {
        XCTAssertEqual(block(.graphSpecBadIntegrity(found: "A", expected: "B", log: "line one\nline two")),
                       ["the graph holds A where its spec has B", "  line one", "  line two"])
    }

    func test_wireWithoutOutputPort() {
        XCTAssertEqual(block(.wireWithoutOutputPort(wire: "x", type: "StaticFile")),
                       ["the StaticFile feeding the wire 'x' names no output port to take a value from"])
        XCTAssertEqual(block(.wireWithoutOutputPort(wire: nil, type: "StaticFile")).first,
                       "the StaticFile feeding this node names no output port to take a value from")
    }

    func test_identityMismatch() {
        XCTAssertEqual(block(.identityMismatch(type: "SampleTool", filedUnder: "0123456789abcdef", computed: "fedcba9876543210")),
                       ["a spec table files a SampleTool under 01234567…, and its row gives fedcba98…"])
    }

    func test_emptyWireName() {
        XCTAssertEqual(block(.emptyWireName), ["a wire is asked for under an empty name"])
    }

    func test_specTableMissingRow() {
        XCTAssertEqual(block(.specTableMissingRow(identity: "0123456789abcdef")),
                       ["a spec table names the node 01234567… and holds no row for it"])
    }

    func test_specTableCycle() {
        XCTAssertEqual(block(.specTableCycle(identity: "0123456789abcdef")),
                       ["a spec table has the node 01234567… among its own sources"])
    }

    func test_specUnreadable() {
        XCTAssertEqual(block(.specUnreadable(found: nil, context: "in a port")), ["a graph spec ends early — in a port"])
        XCTAssertEqual(block(.specUnreadable(found: "", context: "")).first,
                       "a graph spec has an empty name where a type or a port belongs")
        XCTAssertEqual(block(.specUnreadable(found: "}", context: "in a port")).first,
                       "a graph spec has '}' where it does not belong — in a port")
    }

    func test_duplicateWireName() {
        XCTAssertEqual(block(.duplicateWireName(name: "a")), ["an input port holds a different wire named 'a'"])
    }

    func test_wireNotDisconnected() {
        XCTAssertEqual(block(.wireNotDisconnected), ["a wire does not disconnect"])
    }

    func test_circularWiring() {
        XCTAssertEqual(block(.circularWiring(fromNodeID: 1, toNodeID: 2)),
                       ["a wire from node #1 into node #2 would make the graph circular"])
    }

    func test_staticPortWiredAfterCreation() {
        XCTAssertEqual(block(.staticPortWiredAfterCreation(type: "SampleTool", port: "input")),
                       ["SampleTool's input 'input' is wired when the node is made, from its spec, and not after"])
    }

    func test_sourceWithoutIdentity() {
        XCTAssertEqual(block(.sourceWithoutIdentity(nodeID: 9)), ["node #9 has no identity, so nothing wired from it has one"])
    }

    func test_nodeNotPersisted() {
        XCTAssertEqual(block(.nodeNotPersisted(kind: 3, name: "a.c")),
                       ["a node of kind 3 named 'a.c' is not saved, so it has no id"])
    }

    func test_nodeHasNoName() {
        XCTAssertEqual(block(.nodeHasNoName(kind: 1, nodeID: 4)), ["node #4 of kind 1 has no name, and a path is made of names"])
        XCTAssertEqual(block(.nodeHasNoName(kind: nil, nodeID: nil)).first, "a node has no name, and a path is made of names")
    }

    func test_noSuchFolder() {
        XCTAssertEqual(block(.noSuchFolder(path: "input:/src")), ["no folder is at src"])
    }

    func test_unexpectedNodeKind() {
        XCTAssertEqual(block(.unexpectedNodeKind(kind: 5)), ["a node of kind 5 is not one a folder holds"])
    }

    func test_folderNotDeletable() {
        XCTAssertEqual(block(.folderNotDeletable(path: "input:/src")), ["src holds something that is not deletable"])
        XCTAssertEqual(block(.folderNotDeletable(path: nil)).first, "a folder holds something that is not deletable")
    }

    func test_unexpectedValueType() {
        XCTAssertEqual(block(.unexpectedValueType), ["a value is not of the type its reader takes"])
    }

    func test_kindNotSerializable() {
        XCTAssertEqual(block(.kindNotSerializable(kind: 5)), ["the type registered for kind 5 is not serializable"])
    }

    func test_kindNotANode() {
        XCTAssertEqual(block(.kindNotANode(kind: 5)), ["the type registered for kind 5 is not a node type"])
    }

    func test_duplicateKind() {
        XCTAssertEqual(block(.duplicateKind(kind: 5, existing: "A", duplicate: "B")), ["kind 5 is claimed by both A and B"])
    }

    // MARK: - Values

    func test_objectCorrupted() {
        XCTAssertEqual(block(.objectCorrupted(path: "/store/ab/cd", expected: "abcd", found: "ef01")), [
            "/store/ab/cd is filed as abcd, and its bytes hash to ef01",
            "  delete: /store/ab/cd",
        ])
    }

    func test_valueUnreadable() {
        XCTAssertEqual(block(.valueUnreadable(form: .folderManifest, port: "inputFolder", wire: "input:/src")),
                       ["the folder manifest for 'src' on inputFolder cannot be read"])
        XCTAssertEqual(block(.valueUnreadable(form: .folderManifest, port: nil, wire: "input:/src")).first,
                       "the folder manifest for 'src' cannot be read")
    }

    func test_subtreeUnreadable() {
        XCTAssertEqual(block(.subtreeUnreadable(folder: "input:/src", hash: "abc")),
                       ["the subtree manifest of src cannot be read", "  manifest: abc"])
    }

    func test_folderUnreadable() {
        XCTAssertEqual(block(.folderUnreadable(path: "/tmp/x", reason: "permission denied")),
                       ["/tmp/x cannot be read to fold its content root", "  reason: permission denied"])
    }

    func test_treeCollision() {
        XCTAssertEqual(block(.treeCollision(path: "Info.plist", first: "input:/a", second: "input:/b")),
                       ["two trees hold 'Info.plist': a and b"])
    }

    func test_treeHasNoEntry() {
        XCTAssertEqual(block(.treeHasNoEntry(name: "x", entries: ["a", "b"])), ["the tree holds no file 'x'", "  it holds: a, b"])
        XCTAssertEqual(block(.treeHasNoEntry(name: "x", entries: [])).dropFirst().first, "  it holds: nothing")
    }

    // MARK: - Formulas and products

    /// The formula's location leads, as a compiler writes one, so a terminal makes it a
    /// link; the line's text continues it.
    func test_formulaInvalid() {
        XCTAssertEqual(block(.formulaInvalid(path: "input:/Packages/semel.fmla", problem: .undefinedIdentifier(name: "x"),
                                             line: 3, column: 5, lineText: "product 'a' = x"),
                             subject: .formula(path: "input:/Packages/semel.fmla")), [
            "Packages/semel.fmla:3:5: error: 'x' is not defined",
            "  product 'a' = x",
            "  formula: Packages/semel.fmla",
        ])
        XCTAssertEqual(block(.formulaInvalid(path: "input:/Packages/semel.fmla", problem: .undefinedIdentifier(name: "x"),
                                             line: nil, column: nil, lineText: nil)).first,
                       "Packages/semel.fmla: error: 'x' is not defined")
        XCTAssertEqual(block(.formulaInvalid(path: nil, problem: .undefinedIdentifier(name: "x"),
                                             line: nil, column: nil, lineText: nil)).first,
                       "'x' is not defined")
    }

    /// Every problem a formula can have, as the sentence after `error:`.
    func test_everyFormulaProblemReadsAsItsSentence() {
        let sentences: [(FormulaProblem, String)] = [
            (.unexpectedToken(token: "')'", expected: "an expression"), "unexpected ')', where an expression belongs"),
            (.unexpectedCharacter(character: "$", context: "after 'a'"), "unexpected character '$' — after 'a'"),
            (.unterminatedString(context: "line 2"), "a string literal has no end — line 2"),
            (.unterminatedPath(context: "line 2"), "a path literal has no end — line 2"),
            (.undefinedIdentifier(name: "x"), "'x' is not defined"),
            (.typeMismatch(expected: "a node", found: "a string", context: "in 'f'"), "a string where a node belongs — in 'f'"),
            (.wrongArgumentCount(function: "f", expected: 1, found: 2), "'f' takes 1 argument, and is given 2"),
            (.wrongArgumentCount(function: "g", expected: 2, found: 1), "'g' takes 2 arguments, and is given 1"),
            (.positionalArgument(type: "StaticFile"),
             "'StaticFile' is given an argument without a name; use 'key: value' or 'port: [...]'"),
            (.pathEscapesBase(path: "../x"), "the path literal '<../x>' leads out of the formula's folder"),
            (.pathEscapesRoot(path: "../../x"), "the path literal '<../../x>' leads out of the root"),
            (.forEachWithoutItems, "a for-each '{...}' has no items"),
            (.forEachExceptLeavesNothing(variable: "f", removed: ["a.c"]),
             "for-each '{f: ...}' leaves nothing: its 'except' removes every item it matched (a.c)"),
            (.duplicateDefinition(kind: "func", name: "f"), "func 'f' is defined by the formula and by a formula it includes"),
            (.unboundParameter(function: "f", parameter: "x"), "'f' is called without its parameter 'x'"),
            (.namespaceOutsidePrelude(namespace: "clang"), "'namespace clang' belongs in a plugin's prelude, not in a formula"),
            (.productInPrelude(namespace: "clang", product: "a"),
             "the prelude 'clang' declares the product 'a', and a prelude holds funcs only"),
            (.preludeNotIncluded(namespace: "clang", callee: "clang.executable", scope: nil),
             "'clang.executable' calls into the prelude 'clang', which this formula does not include"),
            (.preludeNotIncluded(namespace: "clang", callee: "clang.executable", scope: "swift"),
             "the prelude 'swift' calls 'clang.executable' and does not include the prelude 'clang'"),
        ]
        for (problem, sentence) in sentences {
            XCTAssertEqual(block(.formulaInvalid(path: nil, problem: problem, line: nil, column: nil, lineText: nil)).first, sentence)
        }
    }

    func test_twoProductsAtOnePath() {
        XCTAssertEqual(block(.twoProductsAtOnePath(path: "output:/hello/hello")),
                       ["two products of one formula are at hello/hello"])
    }

    func test_productPathInvalid() {
        XCTAssertEqual(block(.productPathInvalid(path: "x", root: nil)), ["the product path 'x' names nothing"])
        XCTAssertEqual(block(.productPathInvalid(path: "build:/x", root: "build:")).first,
                       "the product path 'build:/x' begins with 'build:', which is neither input: nor output:")
    }

    func test_includeUnanswered() {
        XCTAssertEqual(block(.includeUnanswered(name: "rust", installed: ["SemelClang"])),
                       ["include 'rust': no plugin answers this name", "  plugins: SemelClang"])
        XCTAssertEqual(block(.includeUnanswered(name: "rust", installed: [])).dropFirst().first, "  plugins: none")
    }

    func test_includeClaimedTwice() {
        XCTAssertEqual(block(.includeClaimedTwice(name: "c", plugins: ["OtherC", "SemelClang"])),
                       ["include 'c' is claimed by both OtherC and SemelClang"])
    }

    func test_includeRefused() {
        XCTAssertEqual(block(.includeRefused(name: "clang/c++26", plugin: "SemelClang", reason: .notSupported(feature: "C++26"))),
                       ["include 'clang/c++26': SemelClang does not support C++26"])
        XCTAssertEqual(block(.includeRefused(name: "clang", plugin: "SemelClang", reason: .toolNotInstalled(tool: "clang"))).first,
                       "include 'clang': SemelClang finds no clang installed here")
    }

    // MARK: - Inputs a node asked for

    func test_inputsWithoutValue() {
        XCTAssertEqual(block(.inputsWithoutValue(kind: .includeFiles, paths: ["input:/hello/src/a.h"]), subject: .source(path: "input:/hello/src/main.c")), [
            "include files without a value: hello/src/a.h",
            "  source: hello/src/main.c",
        ])
        XCTAssertEqual(block(.inputsWithoutValue(kind: .packageFolderAndManifest, paths: ["input:/Packages/Kit"])).first,
                       "Packages/Kit and its Package.swift have no value")
        XCTAssertEqual(block(.inputsWithoutValue(kind: .packageFolderAndManifest, paths: [])).first,
                       "the package folder and its manifest have no value")
        XCTAssertEqual(block(.inputsWithoutValue(kind: .headerFolders, paths: [])).first, "header folders have no value")
        XCTAssertEqual(block(.inputsWithoutValue(kind: .targetFolders, paths: (1...7).map { "input:/t\($0)" })).first,
                       "target folders without a value: t1, t2, t3, t4, t5 and 2 more")
        let nouns: [(AwaitedInput, String)] = [(.targetFolderCandidates, "folders a target's sources may be in"),
                                               (.binaryArtifactFolders, "folders of binary targets' artifacts"),
                                               (.platformSettings, "settings that decide the platform"),
                                               (.locks, "locks of vendored packages")]
        for (kind, noun) in nouns {
            XCTAssertEqual(block(.inputsWithoutValue(kind: kind, paths: ["x"])).first, "\(noun) without a value: x")
        }
    }

    func test_noSources() {
        XCTAssertEqual(block(.noSources, subject: .target(name: "Models")), ["no Swift source to compile", "  target: Models"])
    }

    // MARK: - Swift packages

    func test_manifestUnreadable() {
        XCTAssertEqual(block(.manifestUnreadable(path: "input:/Packages/Kit/Package.swift", reason: "bad JSON")),
                       ["Packages/Kit/Package.swift cannot be read", "  reason: bad JSON"])
        XCTAssertEqual(block(.manifestUnreadable(path: nil, reason: "bad JSON")).first, "a package manifest cannot be read")
    }

    func test_packageNotPresent() {
        XCTAssertEqual(block(.packageNotPresent(path: "input:/Packages/Dependencies/GRDB.swift",
                                                origin: .repository(location: "https://github.com/groue/GRDB.swift.git")),
                             subject: .package(name: "GRDB.swift"), products: products("Packages/libModels.a")), [
            "Packages/Dependencies/GRDB.swift holds no package",
            "  from: https://github.com/groue/GRDB.swift.git",
            "  package: GRDB.swift",
            "  vendor with: semel-swift prepare",
        ])
        XCTAssertEqual(block(.packageNotPresent(path: "input:/x", origin: .registry(identity: "mona.LinkedList"))).dropFirst().first,
                       "  from: registry package mona.LinkedList")
        XCTAssertEqual(block(.packageNotPresent(path: "input:/x", origin: nil)),
                       ["x holds no package", "  from: a local path dependency"])
    }

    /// The design's example, line for line.
    func test_targetFolderMissing() {
        XCTAssertEqual(block(.targetFolderMissing(package: "Kit", packageFolder: "input:/Packages/Kit", target: "Kit"),
                             subject: .target(name: "Kit"), products: products("Packages/libKit.a")), [
            "Packages/Kit/Sources/Kit has not been pushed",
            "  target: Kit",
            "  missing: Sources/Kit (also tried Source/Kit, src/Kit, srcs/Kit)",
        ])
    }

    private let grdbLock = LockFacts(lockPath: "input:/Packages/Dependencies/GRDB.swift.semel-lock", version: "7.1.0",
                                     origin: "https://github.com/groue/GRDB.swift.git")

    /// The lock mismatch: the facts a reader compares under the line saying it differs, what
    /// the comparison left out, and the re-lock as the remedy.
    func test_lockMismatch() {
        XCTAssertEqual(block(.lockMismatch(folder: "input:/Packages/Dependencies/GRDB.swift", lock: grdbLock,
                                           expected: "sha256:aaa", found: "sha256:bbb",
                                           leftOut: [LeftOutEntry(path: ".spi.yml", reason: .dotNamed),
                                                     LeftOutEntry(path: "Sources/.swiftlint.yml", reason: .dotNamed)]),
                             subject: .package(name: "GRDB.swift"),
                             products: products("Packages/libConversations.a", "Packages/libExplore.a", "Packages/libLists.a",
                                                "Packages/libModels.a", "Packages/libTimeline.a")), [
            "Packages/Dependencies/GRDB.swift differs from its lock",
            "  lock: Packages/Dependencies/GRDB.swift.semel-lock (version 7.1.0, from https://github.com/groue/GRDB.swift.git)",
            "  expected: sha256:aaa",
            "  found: sha256:bbb",
            "  not compared: 2 dot-named (.spi.yml, Sources/.swiftlint.yml)",
            "  package: GRDB.swift",
            "  re-lock with: semel-swift prepare",
        ])
    }

    func test_lockFoldChanged() {
        XCTAssertEqual(block(.lockFoldChanged(folder: "input:/Packages/Dependencies/GRDB.swift", lock: grdbLock,
                                              lockFold: "semel-folder-content-root 1", currentFold: "semel-folder-content-root 4")), [
            "Packages/Dependencies/GRDB.swift cannot be compared with its lock",
            "  lock: Packages/Dependencies/GRDB.swift.semel-lock (version 7.1.0, from https://github.com/groue/GRDB.swift.git)",
            "  folded as: semel-folder-content-root 1",
            "  this Semel folds as: semel-folder-content-root 4",
            "  re-lock with: semel-swift prepare",
        ])
    }

    func test_lockUnreadable() {
        XCTAssertEqual(block(.lockUnreadable(folder: "input:/Packages/Dependencies/GRDB.swift",
                                             lockPath: "input:/Packages/Dependencies/GRDB.swift.semel-lock",
                                             problem: .missingKey(key: "fold"))), [
            "Packages/Dependencies/GRDB.swift.semel-lock is not a lock: there is no 'fold' line",
            "  re-lock with: semel-swift prepare",
        ])
        let problems: [(LockProblem, String)] = [
            (.unknownKey(key: "colour", line: 2, keys: ["content", "fold"]), "line 2: 'colour' is not a lock key; the keys are content, fold"),
            (.repeatedKey(key: "fold", line: 3), "line 3: 'fold' is said a second time"),
            (.emptyValue(key: "fold", line: 3), "line 3: 'fold' has no value"),
            (.unknownContentScheme(value: "md5:x", scheme: "sha256:"), "'content' is 'md5:x', and a content root is written 'sha256:<hex>'"),
            (.malformedArtifact(item: "x"), "'artifacts' holds 'x', and each item is written '<target>=<checksum>', a target once"),
        ]
        for (problem, sentence) in problems {
            XCTAssertEqual(block(.lockUnreadable(folder: "input:/f", lockPath: "input:/f.semel-lock", problem: problem)).first,
                           "f.semel-lock is not a lock: \(sentence)")
        }
    }

    /// The lock barrier's refusal of a batch: the facts a reader compares, the paths that
    /// moved the folder, and the re-lock as the remedy. Not a build's error, so no heading.
    func test_batchRejected() {
        XCTAssertEqual(ErrorReportRenderer.lines(for: .batchRejected(
            folder: "Packages/Dependencies/GRDB.swift", lock: "Packages/Dependencies/GRDB.swift.semel-lock",
            expected: .contentRoot("aaa"), found: "bbb",
            paths: ["Packages/Dependencies/GRDB.swift/a.swift", "Packages/Dependencies/GRDB.swift/b.swift"])), [
            "Packages/Dependencies/GRDB.swift is locked, and the batch changes it without a lock it matches: "
                + "nothing of the batch is committed",
            "  lock: Packages/Dependencies/GRDB.swift.semel-lock",
            "  expected: sha256:aaa",
            "  found: sha256:bbb",
            "  paths: Packages/Dependencies/GRDB.swift/a.swift, Packages/Dependencies/GRDB.swift/b.swift",
            "  re-lock with: semel-swift prepare",
        ])
        let expectations: [(LockExpectation, String)] = [
            (.otherFold(fold: "semel-folder-content-root 3", contentRoot: "aaa"),
             "  expected: sha256:aaa, folded as 'semel-folder-content-root 3'; this Semel folds as '\(FolderContentRoot.formatTag)'"),
            (.unreadable(problem: .missingKey(key: "fold")), "  expected: nothing: the lock is not a lock, there is no 'fold' line"),
        ]
        for (expected, line) in expectations {
            let lines = ErrorReportRenderer.lines(for: .batchRejected(folder: "f", lock: "f.semel-lock", expected: expected,
                                                                      found: nil, paths: []))
            XCTAssertEqual(lines.dropFirst().prefix(3), ["  lock: f.semel-lock", line, "  found: no folder"])
        }
    }

    func test_binaryTargetNotBuilt() {
        let missing = UnbuiltBinaryTarget(package: "Sparkle", packageFolder: "input:/pkg", target: "Sparkle",
                                          artifact: .remote(url: "https://example.com/Sparkle.zip"),
                                          location: .missing(folder: "input:/pkg/semel-artifacts/Sparkle"), products: ["Sparkle"])
        XCTAssertEqual(block(.binaryTargetNotBuilt(target: missing), subject: .target(name: "Sparkle")), [
            "pkg/semel-artifacts/Sparkle holds no artifact for binary target Sparkle",
            "  from: https://example.com/Sparkle.zip",
            "  products: Sparkle",
            "  target: Sparkle",
            "  vendor with: semel-swift prepare",
        ])
        let bundle = UnbuiltBinaryTarget(package: "Sparkle", packageFolder: "input:/pkg", target: "Lint",
                                         artifact: .local(path: "Lint.artifactbundle"),
                                         location: .notAnXCFramework(path: "input:/pkg/Lint.artifactbundle", contents: ["info.json"]),
                                         products: ["Lint"])
        XCTAssertEqual(block(.binaryTargetNotBuilt(target: bundle)), [
            "pkg/Lint.artifactbundle is not an .xcframework, which is the binary artifact linked here",
            "  holds: info.json",
            "  products: Lint",
        ])
        let zipped = UnbuiltBinaryTarget(package: "Sparkle", packageFolder: "input:/pkg", target: "Sparkle",
                                         artifact: .zip(path: "Sparkle.xcframework.zip"),
                                         location: .missing(folder: "input:/pkg/semel-artifacts/Sparkle"), products: ["Sparkle"])
        XCTAssertEqual(block(.binaryTargetNotBuilt(target: zipped)).dropFirst().first, "  zip: pkg/Sparkle.xcframework.zip")
    }

    func test_sourcesOnlyFromPlugins() {
        XCTAssertEqual(block(.sourcesOnlyFromPlugins(package: "Gen", target: "Schema", plugins: ["Generate (GenPlugin)", "Stamp"])), [
            "Schema has no source of its own, only what its build-tool plugins would generate, and no plugin is run",
            "  package: Gen",
            "  plugins: Generate (GenPlugin), Stamp",
        ])
    }

    // MARK: - Xcode projects

    func test_notAProject() {
        XCTAssertEqual(block(.notAProject),
                       ["the project file is not a project.pbxproj: it has no objects table and root object"])
    }

    func test_projectNotPushed() {
        XCTAssertEqual(block(.projectNotPushed(path: "input:/repo/App.xcodeproj/project.pbxproj"),
                             subject: .project(path: "input:/repo/App.xcodeproj")), [
            "repo/App.xcodeproj/project.pbxproj has not been pushed",
            "  project: App.xcodeproj",
        ])
    }

    func test_projectHasNoContent() {
        XCTAssertEqual(block(.projectHasNoContent(path: "input:/repo/App.xcodeproj/project.pbxproj")),
                       ["repo/App.xcodeproj/project.pbxproj has no content"])
    }

    func test_noSuchTarget() {
        XCTAssertEqual(block(.noSuchTarget(name: "App")), ["the project has no target named 'App'"])
    }

    func test_targetHasNoSources() {
        XCTAssertEqual(block(.targetHasNoSources(name: "App")),
                       ["App has no synchronized folder, no listed sources and no borrowed sources"])
    }

    func test_noSuchConfiguration() {
        XCTAssertEqual(block(.noSuchConfiguration(name: "Beta", available: ["Debug", "Release"])),
                       ["the project has no configuration named 'Beta'", "  configurations: Debug, Release"])
    }

    func test_unsupportedSources() {
        XCTAssertEqual(block(.unsupportedSources(target: "App", files: ["input:/repo/a.m"])),
                       ["App lists sources that are not Swift, and they are not compiled", "  sources: repo/a.m"])
    }

    func test_noApplicationTarget() {
        XCTAssertEqual(block(.noApplicationTarget), ["the project has no application target"])
    }

    func test_noApplicationForSDK() {
        XCTAssertEqual(block(.noApplicationForSDK(sdk: "iphoneos", applications: ["Mac (macosx)"])),
                       ["no application target builds for iphoneos", "  applications: Mac (macosx)"])
    }

    func test_severalApplicationsForSDK() {
        XCTAssertEqual(block(.severalApplicationsForSDK(sdk: "iphoneos", applications: ["A", "B"])),
                       ["2 application targets build for iphoneos, and nothing names one", "  applications: A, B"])
    }

    func test_noSuchApplication() {
        XCTAssertEqual(block(.noSuchApplication(name: "X", applications: [])),
                       ["the project has no application target named 'X'", "  applications: none"])
    }

    func test_localPackagesNotFound() {
        XCTAssertEqual(block(.localPackagesNotFound(application: "IceCubes", products: ["Account", "Models"], synchronizedFolders: [])), [
            "IceCubes links Account, Models from local packages, and the project has none where they are looked for",
            "  synchronized folders: none",
        ])
    }

    func test_xcconfigIncludeCycle() {
        XCTAssertEqual(block(.xcconfigIncludeCycle(chain: ["input:/a.xcconfig", "input:/b.xcconfig", "input:/a.xcconfig"])),
                       ["xcconfig files include each other in a cycle: a.xcconfig → b.xcconfig → a.xcconfig"])
    }

    func test_xcconfigMissing() {
        XCTAssertEqual(block(.xcconfigMissing(paths: ["input:/repo/App.xcconfig"], undefined: ["BUNDLE_ID_PREFIX"])),
                       ["repo/App.xcconfig has not been pushed", "  undefined: BUNDLE_ID_PREFIX"])
        XCTAssertEqual(block(.xcconfigMissing(paths: ["input:/a.xcconfig", "input:/b.xcconfig"], undefined: ["X"])).first,
                       "a.xcconfig, b.xcconfig have not been pushed")
    }

    func test_undefinedPlistVariables() {
        XCTAssertEqual(block(.undefinedPlistVariables(names: ["A", "B"])),
                       ["the Info.plist names settings nothing defines: A, B"])
    }

    // MARK: - Apple resources

    func test_notAnInterfaceBuilderDocument() {
        XCTAssertEqual(block(.notAnInterfaceBuilderDocument(path: "Base.lproj/Main.strings", compiles: [".storyboard", ".xib"])),
                       ["Base.lproj/Main.strings is not an Interface Builder document", "  compiled: .storyboard, .xib"])
    }

    func test_bundleWireKeyInvalid() {
        XCTAssertEqual(block(.bundleWireKeyInvalid(key: "Contents/Tiny.app")),
                       ["the bundle's wire is keyed 'Contents/Tiny.app', which is not one folder's name"])
    }

    func test_xcframeworkUnusable() {
        let sentences: [(XCFrameworkProblem, String)] = [
            (.infoPlistUnreadable, "its Info.plist is not an xcframework's: no AvailableLibraries with a LibraryIdentifier, "
                                 + "LibraryPath and SupportedPlatform each"),
            (.noSliceForSDK(sdk: "appletvos"), "no slice is for the SDK appletvos"),
            (.noSliceForPlatform(platform: "tvos", available: ["ios-arm64", "macos-arm64"]),
             "no slice is for tvos; its slices are ios-arm64, macos-arm64"),
            (.noSliceForArchitecture(architecture: "x86_64", slice: "ios-arm64", architectures: ["arm64"]),
             "its slice ios-arm64 has no x86_64, only arm64"),
            (.unsupportedLibrary(path: "libTiny.dylib"), "its slice's library libTiny.dylib is neither a framework nor a static archive"),
            (.noFrameworkBinary(paths: ["Tiny.framework/Tiny", "Tiny.framework/Versions/A/Tiny"]),
             "its slice's framework has no binary at Tiny.framework/Tiny or Tiny.framework/Versions/A/Tiny"),
            (.frameworkBinaryUnrecognised(path: "Tiny.framework/Tiny", reason: .unreadable),
             "its slice's framework binary Tiny.framework/Tiny cannot be read"),
            (.frameworkBinaryUnrecognised(path: "T", reason: .unknownMagic(bytes: "00 01")),
             "its slice's framework binary T is neither Mach-O nor an archive (it begins 00 01)"),
            (.frameworkBinaryUnrecognised(path: "T", reason: .machOFileType(fileType: 2)),
             "its slice's framework binary T is a Mach-O file of type 2, neither a dynamic library nor an object"),
            (.frameworkBinaryUnrecognised(path: "T", reason: .mixedSlices),
             "its slice's framework binary T is a fat file whose architectures are not all of one kind"),
        ]
        for (problem, sentence) in sentences {
            XCTAssertEqual(block(.xcframeworkUnusable(path: "input:/pkg/Tiny.xcframework", problem: problem),
                                 subject: .resource(path: "input:/pkg/Tiny.xcframework")),
                           ["pkg/Tiny.xcframework: \(sentence)", "  resource: Tiny.xcframework"])
        }
    }

    func test_assetCatalogNotCanonical() {
        let headline = "actool's Assets.car has no canonical form that reads as the file actool wrote"
        XCTAssertEqual(block(.assetCatalogNotCanonical(problem: .entryCountDiffers(actools: 4, canonical: 3)),
                             subject: .resource(path: "input:/App/Media.xcassets")), [
            headline,
            "  entries: 4 in actool's, 3 in the canonical one",
            "  resource: Media.xcassets",
        ])
        let details: [(AssetCatalogProblem, [String])] = [
            (.unreadableByAssetutil(copy: .canonical, output: "bad file"), ["  assetutil: fails on the canonical one", "  bad file"]),
            (.printedNoCatalog(copy: .actools, output: "[]"), ["  assetutil: prints no catalog for actool's", "  []"]),
            (.entriesDiffer(differences: ["entry 1: x"]), ["  entry 1: x"]),
            (.notABOMStore(problem: .notABOMStore), ["  BOM store: it does not open with 'BOMStore'"]),
            (.missingVariable(name: "CARHEADER"), ["  missing: CARHEADER"]),
            (.unknownIconFacetPart(facet: "AppIcon", part: 9), ["  icon facet: 'AppIcon' names part 9, none of the icon's own"]),
            (.generatedNameRemains(offset: 40, text: "ZZZZ"), ["  generated name: 'ZZZZ' at byte 40"]),
            (.roundTripDiffers(variable: "FACETKEYS"), ["  reads back differently: FACETKEYS"]),
        ]
        for (problem, lines) in details {
            XCTAssertEqual(block(.assetCatalogNotCanonical(problem: problem)), [headline] + lines)
        }
        let bom: [(BOMProblem, String)] = [
            (.unsupportedVersion(version: 2), "version 2, and version 1 is the one known"),
            (.truncated(what: "block table"), "its block table runs past the end of the file"),
            (.blockOutOfRange(index: 9), "it names block 9, past the end of its block table"),
            (.emptyBlockReferenced(index: 3, referrer: "CARHEADER"), "CARHEADER names block 3, which is empty"),
            (.unreachableBlocks(indices: [4, 5]), "blocks 4, 5 are reached from no variable"),
            (.treeCycle(variable: "RENDITIONS", node: 7), "the tree of RENDITIONS reaches its node 7 twice"),
            (.unknownKeyForm(variable: "RENDITIONS", form: 3), "the tree of RENDITIONS declares key form 3; 0 and 1 are the ones known"),
        ]
        for (problem, sentence) in bom {
            XCTAssertEqual(block(.assetCatalogNotCanonical(problem: .notABOMStore(problem: problem))).dropFirst().first,
                           "  BOM store: \(sentence)")
        }
    }

    // MARK: - Everything else

    func test_unclassified() {
        XCTAssertEqual(block(.unclassified(type: "Foreign", description: "a foreign failure\nwith detail")),
                       ["a foreign failure", "  error: Foreign", "  with detail"])
    }

    /// The test above each condition is the one that pins it; this one fails to compile
    /// when a case is added without being named here, which is the reminder to add its test.
    func test_everyConditionIsNamedHere() {
        func covered(_ condition: ErrorCondition) -> Bool {
            switch condition {
            case .toolExitedSilently, .toolWroteNothing, .toolNotInstalled, .toolNotFound, .toolNotExecutable,
                 .toolInputNotWritten, .toolOutputNotRead, .toolLaunchFailed,
                 .settingsMissing, .settingNotAccepted, .settingNotAList, .sdkNotFound, .sdkVersionDiffers, .settingNotSupported,
                 .notPushed, .removed, .inputInError, .documentUnreadable,
                 .unlinkedKind, .unknownTypeName, .requiredPortUnwired, .severalWiresOnOneWirePort, .portNotDeclared,
                 .outputPortMissing, .nodePropertyMissing, .propertyMissing, .propertiesExclusive, .propertyNotOfForm,
                 .inputNotOfForm, .inputHasNoContent, .sourceCannotProcess, .processNotSupported, .cannotHaveProperties,
                 .cannotDeleteNodeWithOutputs, .nodeNotFound, .nameCollision, .graphSpecBadIntegrity, .wireWithoutOutputPort,
                 .identityMismatch, .emptyWireName, .specTableMissingRow, .specTableCycle, .specUnreadable, .duplicateWireName,
                 .wireNotDisconnected, .circularWiring, .staticPortWiredAfterCreation, .sourceWithoutIdentity, .nodeNotPersisted,
                 .nodeHasNoName, .noSuchFolder, .unexpectedNodeKind, .folderNotDeletable, .unexpectedValueType,
                 .kindNotSerializable, .kindNotANode, .duplicateKind,
                 .objectCorrupted, .valueUnreadable, .subtreeUnreadable, .folderUnreadable, .treeCollision, .treeHasNoEntry,
                 .formulaInvalid, .twoProductsAtOnePath, .productPathInvalid, .includeUnanswered, .includeClaimedTwice,
                 .includeRefused,
                 .inputsWithoutValue, .noSources,
                 .manifestUnreadable, .packageNotPresent, .targetFolderMissing, .lockMismatch, .lockFoldChanged,
                 .lockUnreadable, .batchRejected, .binaryTargetNotBuilt, .sourcesOnlyFromPlugins,
                 .notAProject, .projectNotPushed, .projectHasNoContent, .noSuchTarget, .targetHasNoSources,
                 .noSuchConfiguration, .unsupportedSources, .noApplicationTarget, .noApplicationForSDK,
                 .severalApplicationsForSDK, .noSuchApplication, .localPackagesNotFound, .xcconfigIncludeCycle,
                 .xcconfigMissing, .undefinedPlistVariables,
                 .notAnInterfaceBuilderDocument, .bundleWireKeyInvalid, .xcframeworkUnusable, .assetCatalogNotCanonical,
                 .unclassified:
                return true
            }
        }
        XCTAssertTrue(covered(.nodeNotFound))
    }

    // MARK: - Subjects

    func test_eachSubjectKindIsItsLabelAndItsName() {
        let subjects: [(ErrorDocument.Subject, String)] = [
            (.target(name: "Models"), "  target: Models"),
            (.product(path: "output:/Packages/libConversations.a"), "  product: libConversations.a"),
            (.package(name: "GRDB.swift"), "  package: GRDB.swift"),
            (.resource(path: "input:/App/Media.xcassets"), "  resource: Media.xcassets"),
            (.formula(path: "input:/Packages/semel.fmla"), "  formula: Packages/semel.fmla"),
            (.project(path: "input:/CodeEdit/CodeEdit.xcodeproj"), "  project: CodeEdit.xcodeproj"),
            (.source(path: "input:/hello/src/main.c"), "  source: hello/src/main.c"),
        ]
        for (subject, line) in subjects {
            XCTAssertEqual(block(.noSources, subject: subject), ["no Swift source to compile", line])
        }
    }

    // MARK: - Line one: what the tool wrote

    /// The design's first example: the diagnostic as the tool wrote it, `input:/` written
    /// as the path below the base, then the target and the products.
    func test_aCompileErrorIsTheToolsLineThenTheTargetThenWhatNeedsIt() {
        let document = ErrorDocument.tool(
            text: "input:/Packages/Models/Sources/Models/Account.swift:201:28: error: cannot convert value of type 'String' "
                + "to specified type 'Int'",
            tool: "swiftc", status: 1, subject: .target(name: "Models"))
        let needing = products("Packages/libConversations.a", "Packages/libExplore.a", "Packages/libLists.a",
                               "Packages/libModels.a", "Packages/libTimeline.a")

        XCTAssertEqual(ErrorReportRenderer.lines(for: [ErrorRecord(document: document, products: needing, facts: facts())],
                                                 style: plain, export: .nothing), [
            "libConversations.a, libExplore.a, libLists.a and 2 more:",
            "Packages/Models/Sources/Models/Account.swift:201:28: error: cannot convert value of type 'String' to specified type 'Int'",
            "  target: Models",
            "",
            "1 error · 5 products without a value · nothing exported",
        ])
    }

    /// The prefix is substituted wherever the tool wrote it, and the base itself — here one
    /// holding a space — never appears: the input file system's root is the base, so a path
    /// below it is written relative to it.
    func test_theInputPrefixIsThePathBelowTheBaseWhateverTheBaseHolds() throws {
        let connection = RecordingConnection()
        let context    = TestCommandContext(connection: connection, baseDirectory: "/Users/you/my project")
        connection.reply(.errors(records: [ErrorRecord(
            document: .tool(text: "input:/Sources/My App/main.swift:1:1: error: x\n  note: see input:/Sources/My App/other.swift",
                            tool: "swiftc", status: 1, subject: .source(path: "input:/Sources/My App/main.swift")),
            products: [], facts: facts())]))

        try EnginePlugin().handle(verb: "errors", tokens: [], context: context)

        XCTAssertEqual(Array(context.messages.prefix(4)), [
            "no product:",
            "Sources/My App/main.swift:1:1: error: x",
            "    note: see Sources/My App/other.swift",
            "  source: Sources/My App/main.swift",
        ])
        XCTAssertFalse(context.messages.joined().contains("my project"), "\(context.messages)")
    }

    /// A tool that failed with nothing to say: its status is the one thing to say.
    func test_aSilentToolIsItsStatus() {
        XCTAssertEqual(block(.tool(text: "", tool: "actool", status: 70, subject: .resource(path: "input:/App/Media.xcassets"))), [
            "actool exited with status 70 and said nothing",
            "  resource: Media.xcassets",
        ])
    }

    // MARK: - Headings

    /// The report's first line: the heading of one condition's products.
    private func heading(_ products: [StoppedProduct]) -> String? {
        ErrorReportRenderer.lines(for: [ErrorRecord(document: .engine(.noSources, subject: nil), products: products,
                                                    facts: facts())], style: plain).first
    }

    /// Up to three named, the rest counted; three is three, with nothing counted.
    func test_aHeadingNamesThreeAndCountsTheRest() {
        XCTAssertEqual(heading(products("a/1.a", "a/2.a", "a/3.a")), "1.a, 2.a, 3.a:")
        XCTAssertEqual(heading(products("a/1.a", "a/2.a", "a/3.a", "a/4.a")), "1.a, 2.a, 3.a and 1 more:")
    }

    /// File names unless two products of the report share one: then the path under
    /// `output:` tells them apart, in every heading of the report alike.
    func test_aFileNameTwoProductsShareIsTheirPath() {
        let first  = ErrorRecord(document: .failure("a"), products: products("Packages/A/libKit.a"), facts: facts())
        let second = ErrorRecord(document: .failure("b"), products: products("Packages/B/libKit.a", "Packages/libOther.a"),
                                 facts: facts())

        XCTAssertEqual(ErrorReportRenderer.lines(for: [first, second], style: plain).filter { $0.hasSuffix(":") },
                       ["Packages/A/libKit.a:", "Packages/B/libKit.a, libOther.a:"])
    }

    /// A tree product is named once, by its folder, however many of its entries a cause
    /// reaches; a tree whose entries are not known is named the same.
    func test_aTreeProductIsNamedByItsFolderOnce() {
        let entries = [StoppedProduct(path: "output:/App/IceCubesApp.app/Info.plist", treeFolder: "output:/App/IceCubesApp.app"),
                       StoppedProduct(path: "output:/App/IceCubesApp.app/IceCubesApp", treeFolder: "output:/App/IceCubesApp.app")]

        XCTAssertEqual(heading(entries), "IceCubesApp.app:")
        XCTAssertEqual(heading([StoppedProduct(path: "output:/App/IceCubesApp.app", treeFolder: "output:/App/IceCubesApp.app")]),
                       "IceCubesApp.app:")
    }

    /// Products with the same errors share a heading; one with an error more has its own,
    /// in path order of each heading's first product. An error under an earlier heading is
    /// its first line and `(above)` under a later one, in line-one order with the rest.
    func test_productsWithTheSameErrorsShareAHeadingAndAnErrorIsPrintedOnce() {
        let models = ErrorRecord(document: .tool(text: "input:/Models/Account.swift:1:1: error: models", tool: "swiftc",
                                                 status: 1, subject: .target(name: "Models")),
                                 products: products("App/IceCubesApp.app", "Packages/libExplore.a", "Packages/libLists.a"),
                                 facts: facts())
        let app = ErrorRecord(document: .tool(text: "input:/App/App.swift:1:1: error: app", tool: "swiftc", status: 1,
                                              subject: .target(name: "IceCubesApp")),
                              products: products("App/IceCubesApp.app"), facts: facts())

        XCTAssertEqual(ErrorReportRenderer.lines(for: [models, app], style: plain), [
            "IceCubesApp.app:",
            "App/App.swift:1:1: error: app",
            "  target: IceCubesApp",
            "",
            "Models/Account.swift:1:1: error: models",
            "  target: Models",
            "",
            "libExplore.a, libLists.a:",
            "Models/Account.swift:1:1: error: models (above)",
            "",
            "2 errors · 3 products without a value",
        ])
    }

    /// An error printed above, then one printed in full: a blank line between them.
    func test_anErrorInFullAfterAnAboveLineHasABlankLineBeforeIt() {
        let shared = ErrorRecord(document: .failure("a"), products: products("x/1.a", "x/2.a"), facts: facts())
        let own    = ErrorRecord(document: .failure("b"), products: products("x/2.a"), facts: facts())

        XCTAssertEqual(ErrorReportRenderer.lines(for: [shared, own], style: plain), [
            "1.a:",
            "a",
            "",
            "2.a:",
            "a (above)",
            "",
            "b",
            "",
            "2 errors · 2 products without a value",
        ])
    }

    /// The errors no product needs come after every product's, under their own heading.
    func test_errorsNoProductNeedsComeLast() {
        let needed   = ErrorRecord(document: .failure("b"), products: products("x/1.a"), facts: facts())
        let unneeded = ErrorRecord(document: .failure("a"), products: [], facts: facts())

        XCTAssertEqual(ErrorReportRenderer.lines(for: [unneeded, needed], style: plain), [
            "1.a:",
            "b",
            "",
            "no product:",
            "a",
            "",
            "2 errors · 1 product without a value",
        ])
    }

    /// `errors <product>`: the product's heading and its errors alone, or that it has a value.
    func test_theProductViewIsItsHeadingAndItsErrors() {
        let record = ErrorRecord(document: .failure("boom"), products: products("Packages/libModels.a", "Packages/libKit.a"),
                                 facts: facts())

        XCTAssertEqual(ErrorReportRenderer.productView([record], product: "output:/Packages/libModels.a", style: plain),
                       ["libModels.a:", "boom", "", "1 error · 2 products without a value"])
        XCTAssertEqual(ErrorReportRenderer.productView([], product: "output:/Packages/libModels.a", style: plain),
                       ["libModels.a has a value."])
    }

    // MARK: - Causes, once each

    /// Two documents differing only in which source they belong to are one error: one block
    /// naming both, with every product either reaches.
    func test_oneCauseOfSeveralNodesIsOneBlockNamingThemAll() {
        let missing = ErrorCondition.settingsMissing(project: [], machine: ["clang.compiler.toolDescriptor.name"],
                                                     writer: MachineFileCommand(command: "semel-clang", folder: nil))
        let records = [
            ErrorRecord(document: .engine(missing, subject: .source(path: "input:/hello/src/main.c")),
                        products: products("hello/hello"), facts: facts("ClangCompiler", [24])),
            ErrorRecord(document: .engine(missing, subject: .source(path: "input:/hello/src/hello.c")),
                        products: products("hello/hello", "hello/hello.dylib"), facts: facts("ClangCompiler", [28])),
        ]

        XCTAssertEqual(ErrorReportRenderer.lines(for: records, style: ErrorReportStyle(verbose: true)), [
            "hello, hello.dylib:",
            "missing settings: clang.compiler.toolDescriptor.name",
            "  source: hello/src/main.c, hello/src/hello.c",
            "  write with: semel-clang <folder>",
            "  node: ClangCompiler #24, #28",
            "  ports: output",
            "  carried by: 0 nodes",
            "",
            "1 error · 2 products without a value",
        ])
    }

    /// A node with several causes is a block per cause, in the order of their first lines,
    /// whatever order the records came in.
    func test_severalCausesAreABlockEachInTheOrderOfTheirFirstLines() throws {
        let several = try XCTUnwrap(ErrorDocument.several([
            .engine(.targetFolderMissing(package: "Kit", packageFolder: "input:/Packages/Kit", target: "Util"),
                    subject: .target(name: "Util")),
            .engine(.targetFolderMissing(package: "Kit", packageFolder: "input:/Packages/Kit", target: "Kit"),
                    subject: .target(name: "Kit")),
        ]))
        let lines = ErrorReportRenderer.lines(for: [ErrorRecord(document: several, products: [], facts: facts())], style: plain)

        XCTAssertEqual(lines.filter { !$0.hasPrefix(" ") && !$0.isEmpty },
                       ["no product:", "Packages/Kit/Sources/Kit has not been pushed", "Packages/Kit/Sources/Util has not been pushed",
                        "2 errors · every product has a value"])
    }

    // MARK: - The summary line

    func test_theSummaryLineInItsFourForms() {
        XCTAssertEqual(ErrorReportRenderer.summaryLine(errors: 1, productsWithoutValue: 5, export: nil),
                       "1 error · 5 products without a value")
        XCTAssertEqual(ErrorReportRenderer.summaryLine(errors: 2, productsWithoutValue: 1, export: .nothing),
                       "2 errors · 1 product without a value · nothing exported")
        XCTAssertEqual(ErrorReportRenderer.summaryLine(errors: 1, productsWithoutValue: 0, export: .whole(destination: "semel-out/Packages")),
                       "1 error · every product has a value · exported to semel-out/Packages")
        XCTAssertEqual(ErrorReportRenderer.summaryLine(errors: 1, productsWithoutValue: 2, export: .partial(exported: 3, of: 5)),
                       "1 error · 2 products without a value · 3 of 5 products exported")
        XCTAssertEqual(ErrorReportRenderer.summaryLine(errors: 1, productsWithoutValue: 2, export: .partial(exported: 0, of: 2)),
                       "1 error · 2 products without a value · nothing exported")
    }

    // MARK: - --verbose

    /// Off by default, so the machinery stays out of the report; on, the node, the ports and
    /// the carriers under each block.
    func test_verboseAddsTheEnginesFactsUnderTheBlock() {
        let record = ErrorRecord(document: .failure("boom"), products: [],
                                 facts: facts("SwiftCompiler", [2510], ports: ["swiftmodule", "object"], carried: 22))

        XCTAssertEqual(ErrorReportRenderer.lines(for: [record], style: plain), ["no product:", "boom", "", "1 error · every product has a value"])
        XCTAssertEqual(ErrorReportRenderer.lines(for: [record], style: ErrorReportStyle(verbose: true)), [
            "no product:",
            "boom",
            "  node: SwiftCompiler #2510",
            "  ports: object, swiftmodule",
            "  carried by: 22 nodes",
            "",
            "1 error · every product has a value",
        ])
    }

    // MARK: - Colour

    /// At a terminal: the location bold, `error:` red, the labels dim. Without one, plain.
    func test_colourMarksTheLocationTheErrorAndTheLabels() {
        let document = ErrorDocument.tool(text: "input:/a.c:1:2: error: boom", tool: "clang", status: 1,
                                          subject: .source(path: "input:/a.c"))
        let bold  = "\u{1B}[1m"
        let red   = "\u{1B}[31m"
        let dim   = "\u{1B}[2m"
        let reset = "\u{1B}[0m"

        XCTAssertEqual(block(document, style: ErrorReportStyle(colour: true)), [
            "\(bold)a.c:1:2\(reset): \(red)error:\(reset) boom",
            "  \(dim)source:\(reset) a.c",
        ])
        XCTAssertEqual(block(document), ["a.c:1:2: error: boom", "  source: a.c"])
        XCTAssertEqual(block(.notPushed(path: "input:/a.c", isFolder: false)).first, "a.c has not been pushed")
    }

    /// Decided as the progress line decides: a terminal that is not `dumb`, and `NO_COLOR`
    /// unset — set to anything, the empty string included, it turns colour off.
    func test_colourIsATerminalsWithoutNoColor() {
        XCTAssertTrue(ColourPolicy.colours(environment: [:], standardOutputIsTerminal: true))
        XCTAssertFalse(ColourPolicy.colours(environment: [:], standardOutputIsTerminal: false))
        XCTAssertFalse(ColourPolicy.colours(environment: ["NO_COLOR": ""], standardOutputIsTerminal: true))
        XCTAssertFalse(ColourPolicy.colours(environment: ["NO_COLOR": "1"], standardOutputIsTerminal: true))
        XCTAssertFalse(ColourPolicy.colours(environment: ["TERM": "dumb"], standardOutputIsTerminal: true))
    }
}

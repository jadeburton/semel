//
//  SwiftLinkerTests.swift
//  semel_tests
//

@testable import SemelSwift
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class SwiftLinkerTests: SemelSwiftTestCase {

    private let descriptor = ToolDescriptor(name: "swiftc",
                                            version: "test-swiftc",
                                            platform: "macOS",
                                            architecture: "arm64",
                                            recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    private func makeTool() throws -> SwiftLinker {
        try SwiftLinker(thisNode: NodeRecord(id: 1, kind: SwiftLinker.kind))
    }

    private func makeInput(objectFiles: [String],
                           libraries: [String] = [],
                           linkage: String = "executable",
                           extraConfiguration: [String] = []) throws -> ProcessInput {
        let configuration = ([
            "toolDescriptor.name=\(descriptor.name)",
            "toolDescriptor.version=\(descriptor.version)",
            "toolDescriptor.platform=\(descriptor.platform)",
            "toolDescriptor.architecture=\(descriptor.architecture)",
            "outputName=product",
            "linkage=\(linkage)",
        ] + extraConfiguration).joined(separator: "\n")

        var objects: [String: NodeValue] = [:]
        for path in objectFiles { objects[path] = .value(try "object \(path)".intern()) }

        var libraryValues: [String: NodeValue] = [:]
        for path in libraries { libraryValues[path] = .value(try "library \(path)".intern()) }

        return ProcessInput(inputValues: [
            SwiftLinker.configuration: ["configuration": .value(try configuration.intern())],
            SwiftLinker.input: objects,
            SwiftLinker.libraries: libraryValues,
        ])
    }

    // MARK: - Which SDK and target

    /// Nothing declared links against the machine's macOS SDK with no `-target`, as every
    /// existing tree did.
    func test_linksAgainstTheMacOSSDKByDefault() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        let arguments = executor.lastArguments
        let sdkPath = try XCTUnwrap(arguments.firstIndex(of: "-sdk").map { arguments[$0 + 1] })
        XCTAssertTrue(sdkPath.contains("MacOSX"), "got \(sdkPath)")
        XCTAssertFalse(arguments.contains("-target"), "got \(arguments)")
    }

    /// An iOS package names its SDK and target, and both reach the link line.
    func test_linksAgainstTheDeclaredSDKAndTarget() throws {
        _ = try makeTool().process(input: try makeInput(
            objectFiles: ["a.o"],
            extraConfiguration: ["sdk=iphonesimulator", "target=arm64-apple-ios18.0-simulator"]))

        let arguments = executor.lastArguments
        let sdkPath = try XCTUnwrap(arguments.firstIndex(of: "-sdk").map { arguments[$0 + 1] })
        XCTAssertTrue(sdkPath.contains("iPhoneSimulator"), "got \(sdkPath)")
        let target = try XCTUnwrap(arguments.firstIndex(of: "-target").map { arguments[$0 + 1] })
        XCTAssertEqual(target, "arm64-apple-ios18.0-simulator")
    }

    /// B-90. ld's default objc_msgSend selector stubs give the linked image a second GOT entry
    /// for objc_msgSend, and which of the two the stubs reference differs between identical
    /// links. Small stubs leave one entry. An archive is not linked by ld, so it is not asked.
    func test_linksWithSmallObjcStubs() throws {
        for linkage in ["executable", "dynamicLibrary"] {
            _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: linkage))
            let arguments = executor.lastArguments
            let flag = try XCTUnwrap(arguments.firstIndex(of: "-objc_stubs_small"), "\(linkage): \(arguments)")
            XCTAssertEqual(arguments[flag - 1], "-Xlinker", linkage)
        }

        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: "staticArchive"))
        XCTAssertFalse(executor.lastArguments.contains("-objc_stubs_small"), "\(executor.lastArguments)")
    }

    // Same reproducibility requirement as the Clang linker: identical inputs must produce
    // an identical command line, so dictionary iteration order must not leak through.
    func test_objectFilesAreOrderedDeterministically() throws {
        let objectFiles = ["zebra.o", "alpha.o", "middle.o", "beta.o", "yankee.o"]

        _ = try makeTool().process(input: try makeInput(objectFiles: objectFiles))

        XCTAssertEqual(executor.lastArguments.filter { $0.hasSuffix(".o") },
                       objectFiles.sorted())
    }

    func test_librariesAreOrderedDeterministically() throws {
        let libraries = ["libz.dylib", "libapple.dylib", "libmiddle.dylib"]

        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], libraries: libraries))

        XCTAssertEqual(executor.lastArguments.filter { $0.hasSuffix(".dylib") },
                       libraries.sorted())
    }

    func test_linksToTheConfiguredOutputName() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        XCTAssertEqual(Array(executor.lastArguments.suffix(2)), ["-o", "product"])
    }

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

    /// A formula states what a product needs beyond its objects — a framework, an
    /// extension's entry point — as a comma-joined list, and every item reaches the link
    /// line after the objects.
    func test_declaredArgumentsReachTheLinkLine() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                        extraConfiguration: ["arguments=-framework,QuickLook,-e,_NSExtensionMain"]))

        XCTAssertEqual(Array(executor.lastArguments.suffix(6)),
                       ["-o", "product", "-framework", "QuickLook", "-e", "_NSExtensionMain"])
    }

    // MARK: - Object trees

    /// A package's `objects_P()` carries every object behind a product as one tree. Two
    /// products sharing a target share its object: it is linked once, since linking it
    /// twice would be a duplicate symbol. All of them come after the node's own objects.
    func test_theObjectTreesAreMergedAndLinkedOnceEach() throws {
        let timeline = try TreeManifest(entries: [.init(path: "Timeline.o", hash: try "t".intern(), mode: 0o644),
                                                  .init(path: "Models.o", hash: try "m".intern(), mode: 0o644)]).toJSON().intern()
        let explore = try TreeManifest(entries: [.init(path: "Explore.o", hash: try "e".intern(), mode: 0o644),
                                                 .init(path: "Models.o", hash: try "m".intern(), mode: 0o644)]).toJSON().intern()
        var input = try makeInput(objectFiles: ["App.o"]).inputValues
        input[SwiftLinker.objectTrees] = ["Timeline": .value(timeline), "Explore": .value(explore)]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        XCTAssertEqual(executor.lastArguments.filter { $0.hasSuffix(".o") },
                       ["App.o", "objects/Explore.o", "objects/Models.o", "objects/Timeline.o"])
        XCTAssertEqual(executor.invocations.last?.inputFileNames.sorted(),
                       ["App.o", "objects/Explore.o", "objects/Models.o", "objects/Timeline.o"])
    }

    /// The same path with different content in two trees is two different objects, and
    /// the formula that brought them together is wrong; the error names the path.
    func test_anObjectThatDiffersBetweenTreesIsAnError() throws {
        let one = try TreeManifest(entries: [.init(path: "Models.o", hash: try "m1".intern(), mode: 0o644)]).toJSON().intern()
        let two = try TreeManifest(entries: [.init(path: "Models.o", hash: try "m2".intern(), mode: 0o644)]).toJSON().intern()
        var input = try makeInput(objectFiles: ["App.o"]).inputValues
        input[SwiftLinker.objectTrees] = ["A": .value(one), "B": .value(two)]

        XCTAssertThrowsError(try makeTool().process(input: ProcessInput(inputValues: input))) { error in
            XCTAssertTrue("\(error)".contains("Models.o"), "\(error)")
        }
    }

    // MARK: - Link requirements (B-55)

    private func requirementsInput(linkage: String = "executable",
                                   configured: [String] = [],
                                   wired: [String: String]) throws -> ProcessInput {
        var input = try makeInput(objectFiles: ["App.o"], linkage: linkage, extraConfiguration: configured).inputValues
        input[SwiftLinker.linkRequirements] = try wired.mapValues { .value(try $0.intern()) }
        return ProcessInput(inputValues: input)
    }

    /// An app linking two package products gets every framework and library either
    /// product's targets name, each once, and the C++ runtime once when one of them has
    /// C++ — with what the project's own settings add. After the objects, before `-o`.
    func test_linksTheUnionOfEveryWiredProductsRequirements() throws {
        _ = try makeTool().process(input: try requirementsInput(
            configured: ["frameworks=Security"],
            wired: ["CrashReporter": "frameworks=Foundation\ncxxRuntime=true",
                    "Database":      "frameworks=Foundation\nlibraries=sqlite3,z"]))

        let arguments = executor.lastArguments
        let start = try XCTUnwrap(arguments.firstIndex(of: "App.o"))
        let end   = try XCTUnwrap(arguments.firstIndex(of: "-o"))
        XCTAssertEqual(Array(arguments[(start + 1)..<end]),
                       ["-framework", "Foundation", "-framework", "Security", "-lsqlite3", "-lz", "-lc++"])
    }

    /// No requirement is no argument: a product of Swift alone links as it always has.
    func test_noRequirementsAddNothing() throws {
        _ = try makeTool().process(input: try requirementsInput(wired: ["Kit": ""]))

        let arguments = executor.lastArguments
        XCTAssertFalse(arguments.contains("-framework") || arguments.contains("-lc++"), "\(arguments)")
    }

    /// An archive is not linked: its requirements are its consumer's to meet, as SwiftPM
    /// leaves them, and libtool would refuse a framework.
    func test_aStaticArchivePassesNoRequirement() throws {
        _ = try makeTool().process(input: try requirementsInput(linkage: "staticArchive",
                                                                wired: ["Kit": "frameworks=Foundation\ncxxRuntime=true"]))

        let arguments = executor.lastArguments
        XCTAssertFalse(arguments.contains("-framework") || arguments.contains("-lc++"), "\(arguments)")
    }

    // MARK: - Frameworks (B-77)

    private func frameworksInput(linkage: String = "executable", configured: [String] = []) throws -> ProcessInput {
        let sparkle = try TreeManifest(entries: [
            .init(path: "Sparkle.framework/Sparkle", hash: try "binary".intern(), mode: 0o755),
            .init(path: "Sparkle.framework/Versions/B/Sparkle", hash: try "binary".intern(), mode: 0o755),
            .init(path: "Sparkle.framework/Resources/Info.plist", hash: try "plist".intern(), mode: 0o644),
        ]).toJSON().intern()
        let empty = try TreeManifest(entries: []).toJSON().intern()
        var input = try makeInput(objectFiles: ["App.o"], linkage: linkage, extraConfiguration: configured).inputValues
        input[SwiftLinker.frameworkTrees] = ["Updater": .value(sparkle), "Kit": .value(empty)]
        return ProcessInput(inputValues: input)
    }

    /// A binary target's framework is linked by name from the merged trees, and found at
    /// run time where the literal says the frameworks are laid out.
    func test_linksEachFrameworkOfTheTreesByNameWithTheRunpath() throws {
        _ = try makeTool().process(input: try frameworksInput(configured: ["frameworksRunpath=@executable_path/../Frameworks"]))

        let arguments = executor.lastArguments
        let start = try XCTUnwrap(arguments.firstIndex(of: "App.o"))
        let end   = try XCTUnwrap(arguments.firstIndex(of: "-o"))
        XCTAssertEqual(Array(arguments[(start + 1)..<end]),
                       ["-F", "frameworks", "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        XCTAssertTrue(executor.invocations.last?.inputFileNames.contains("frameworks/Sparkle.framework/Versions/B/Sparkle") == true,
                      "\(executor.invocations.last?.inputFileNames ?? [])")
    }

    /// Only trees holding no framework, or none at all, add nothing — not even the runpath.
    func test_emptyFrameworkTreesAddNothing() throws {
        let empty = try TreeManifest(entries: []).toJSON().intern()
        var input = try makeInput(objectFiles: ["App.o"], extraConfiguration: ["frameworksRunpath=@loader_path"]).inputValues
        input[SwiftLinker.frameworkTrees] = ["Kit": .value(empty)]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        let arguments = executor.lastArguments
        XCTAssertFalse(arguments.contains("-F") || arguments.contains("-rpath"), "\(arguments)")
    }

    /// An archive is not linked, and libtool takes no framework.
    func test_aStaticArchiveTakesNoFramework() throws {
        _ = try makeTool().process(input: try frameworksInput(linkage: "staticArchive", configured: ["frameworksRunpath=@loader_path"]))

        XCTAssertFalse(executor.lastArguments.contains("-framework"), "\(executor.lastArguments)")
        XCTAssertFalse(executor.invocations.last?.inputFileNames.contains { $0.hasPrefix("frameworks/") } ?? true)
    }

    // MARK: - Vendored system libraries

    private func file(_ name: String) -> FolderManifestEntry { .init(name: name, isFolder: false, isPinned: true) }

    private func manifestValue(_ baseFolderPath: String, _ entries: [FolderManifestEntry]) throws -> NodeValue {
        .value(try FolderManifest(baseFolderPath: baseFolderPath, entries: entries).toJSON().intern())
    }

    /// The folder a `.systemLibrary` target points at, once a user has dropped a vendored
    /// archive and header beside the module map.
    private func vendoredFolderInput(_ entries: [FolderManifestEntry]) throws -> ProcessInput {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            outputName=product
            linkage=executable
            """
        return ProcessInput(inputValues: [
            SwiftLinker.configuration:   ["configuration": .value(try configuration.intern())],
            SwiftLinker.input:           ["a.o": .value(try "object".intern())],
            SwiftLinker.libraries:       [:],
            SwiftLinker.libraryFolders:  ["GRDBSQLite": try manifestValue("input:/pkg/Sources/GRDBSQLite", entries)],
        ])
    }

    private func librarySpecs(_ output: ProcessOutput) throws -> [String] {
        try XCTUnwrap(output.inputWireSpecs[SwiftLinker.libraries]).keys.sorted()
    }

    /// A static archive dropped in the system library's folder is what makes the linked
    /// binary self-contained — without it the modulemap's `link "sqlite3"` resolves
    /// against the SDK and the product silently depends on the system copy.
    func test_wiresStaticArchivesFoundInASystemLibraryFolder() throws {
        let output = try makeTool().process(input: try vendoredFolderInput(
            [file("libsqlite3.a"), file("module.modulemap"), file("shim.h"), file("sqlite3.h")]))

        XCTAssertEqual(try librarySpecs(output), ["input:/pkg/Sources/GRDBSQLite/libsqlite3.a"])
    }

    /// The module map, the shim and the vendored header belong to the *compile*, not the
    /// link — handing them to the linker would be an error, not merely noise.
    func test_ignoresEverythingButArchivesInASystemLibraryFolder() throws {
        let output = try makeTool().process(input: try vendoredFolderInput(
            [file("module.modulemap"), file("shim.h"), file("sqlite3.h")]))

        XCTAssertEqual(try librarySpecs(output), [])
    }

    /// A folder with no archive is the "use the system library" case, and must link
    /// exactly as it did before this port existed.
    func test_aSystemLibraryFolderWithNoArchiveAddsNoLinkerArguments() throws {
        _ = try makeTool().process(input: try vendoredFolderInput([file("module.modulemap")]))

        XCTAssertFalse(executor.lastArguments.contains { $0.hasSuffix(".a") })
    }

    func test_passesAWiredArchiveToTheLinker() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                        libraries: ["input:/pkg/Sources/GRDBSQLite/libsqlite3.a"]))

        XCTAssertTrue(executor.lastArguments.contains("input:/pkg/Sources/GRDBSQLite/libsqlite3.a"),
                      "got \(executor.lastArguments)")
    }

    // MARK: - File metadata

    private func linkedFileMode(linkage: String) throws -> UInt16? {
        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: linkage))
        let value = try XCTUnwrap(output.outputValues[SwiftLinker.fileMetadata])
        let metadata = try XCTUnwrap(FileMetadata.decode(from: try value.expectValue().resolveAsString()))
        return metadata.mode
    }

    /// Without this the linked binary is copied out at the default 0644 and will not run.
    /// ProjectBuilder wires the port automatically for any node type that declares it, so
    /// declaring it is the whole fix — same as ClangLinker.
    func test_anExecutableIsPublishedAsExecutable() throws {
        XCTAssertEqual(try linkedFileMode(linkage: "executable"), FileMetadata.executableMode)
    }

    func test_aDynamicLibraryIsPublishedWithTheDefaultMode() throws {
        XCTAssertEqual(try linkedFileMode(linkage: "dynamicLibrary"), FileMetadata.defaultMode)
    }

    /// An archive is not run either.
    func test_aStaticArchiveIsPublishedWithTheDefaultMode() throws {
        XCTAssertEqual(try linkedFileMode(linkage: "staticArchive"), FileMetadata.defaultMode)
    }

    // MARK: - Linkage (B-09)

    /// The flags that select the artifact form, in the order they are emitted.
    private func emitFlags(linkage: String) throws -> [String] {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: linkage))
        return executor.lastArguments.filter { $0 == "-emit-library" || $0 == "-static" }
    }

    func test_anExecutableIsLinkedWithNeitherLibraryFlag() throws {
        XCTAssertEqual(try emitFlags(linkage: "executable"), [])
    }

    func test_aDynamicLibraryIsLinkedWithEmitLibraryAlone() throws {
        XCTAssertEqual(try emitFlags(linkage: "dynamicLibrary"), ["-emit-library"])
    }

    /// `swiftc -emit-library -static -o lib<name>.a *.o` drives libtool and writes a plain
    /// `ar` archive — verified on the local toolchain — so the linker stays one tool.
    func test_aStaticArchiveIsLinkedWithEmitLibraryAndStatic() throws {
        XCTAssertEqual(try emitFlags(linkage: "staticArchive"), ["-emit-library", "-static"])
    }

    /// Three forms and no default: the formula has to say which one it wants.
    func test_linkageIsRequired() throws {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            outputName=product
            """
        let input = ProcessInput(inputValues: [
            SwiftLinker.configuration: ["configuration": .value(try configuration.intern())],
            SwiftLinker.input: ["a.o": .value(try "object".intern())],
            SwiftLinker.libraries: [:],
        ])

        XCTAssertThrowsError(try makeTool().process(input: input)) { error in
            XCTAssertTrue(String(describing: error).contains("swift.linker.linkage"), "got \(error)")
        }
    }

    func test_anUnknownLinkageIsRejectedNamingTheChoices() throws {
        XCTAssertThrowsError(try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: "shared"))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("shared"), "should name the bad value, got \(message)")
            XCTAssertTrue(message.contains("staticArchive"), "should list the accepted values, got \(message)")
        }
    }

    /// ProjectBuilder only wires the metadata if the port is declared on the type.
    func test_declaresTheFileMetadataPort() {
        XCTAssertTrue(SwiftLinker.descriptor.outputPorts.contains(FileMetadata.portName))
    }

    // MARK: - Deterministic archives (B-72)

    /// `ZERO_AR_DATE=1` makes Apple's `ar`/`libtool` zero a member's timestamp, uid and gid,
    /// so the same inputs produce a byte-identical archive on any run. `swiftc -emit-library
    /// -static` drives `libtool` as a child process that inherits this environment, so the
    /// variable has to be in what SwiftLinker passes to `execute`.
    func test_aStaticArchiveLinksWithADeterministicArchiveDate() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: "staticArchive"))

        XCTAssertEqual(executor.invocations.last?.environment["ZERO_AR_DATE"], "1")
    }

    /// Only the static-archive linkage writes an archive; the variable would be meaningless
    /// for an executable or a dynamic library, so it is left out.
    func test_anExecutableLinksWithNoArchiveDateVariable() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: "executable"))

        XCTAssertNil(executor.invocations.last?.environment["ZERO_AR_DATE"])
    }

    // MARK: - What a rejected argument says (B-98)

    private func failureMessage(_ output: ProcessOutput) throws -> String {
        guard case .noValue(.error(let hash)) = output.outputValues[SwiftLinker.output] else {
            XCTFail("a failed link carries an error: \(String(describing: output.outputValues))")
            return ""
        }
        return try hash.resolveAsString()
    }

    func test_aTripleSwiftcRejectsIsReportedWithTheSettingItCameFrom() throws {
        executor.exitCode = 1
        executor.errorOutput = "error: unknown target 'nonsense'"

        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                                 extraConfiguration: ["target=nonsense"]))

        let message = try failureMessage(output)
        XCTAssertTrue(message.contains("`swift.linker.target` is `nonsense`"), "got \(message)")
        XCTAssertTrue(message.contains("swiftc -print-target-info -target nonsense"), "got \(message)")
    }

    /// The link names the SDK by the key that chose it, not by the path xcrun resolved.
    func test_anSDKSwiftcCannotLoadIsReportedWithTheSettingThatNamesIt() throws {
        executor.exitCode = 1
        executor.errorOutput = """
            <unknown>:0: warning: using sysroot for 'MacOSX' but targeting 'iPhone'
            <unknown>:0: error: unable to load standard library for target 'arm64-apple-ios17.0'
            """

        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        let message = try failureMessage(output)
        XCTAssertTrue(message.contains("`swift.linker.sdk` is `macosx`"), "got \(message)")
        XCTAssertTrue(message.contains("xcrun --sdk macosx --show-sdk-path"), "got \(message)")
    }

    /// An error in what was linked is not about the command line.
    func test_anErrorInTheObjectsNamesNoSetting() throws {
        executor.exitCode = 1
        executor.errorOutput = """
            Undefined symbols for architecture arm64:
              "_missing", referenced from:
                  _main in a.o
            ld: symbol(s) not found for architecture arm64
            clang: error: linker command failed with exit code 1 (use -v to see invocation)
            """

        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                                 extraConfiguration: ["target=arm64-apple-macos14.0"]))

        XCTAssertEqual(try failureMessage(output), """
            swiftc exited with status 1:
            Undefined symbols for architecture arm64:
              "_missing", referenced from:
                  _main in a.o
            ld: symbol(s) not found for architecture arm64
            clang: error: linker command failed with exit code 1 (use -v to see invocation)
            """)
    }
}

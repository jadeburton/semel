//
//  VendoredPackageSettleTests.swift
//  SemelCLITests
//
//  B-133, B-77. NetNewsWire's vendored Sparkle declares one `.binaryTarget(url:checksum:)` and
//  nothing else; its converter was processed thousands of times and `build` never
//  returned. The converter asked for the target's folder only once the package's lock had
//  passed; the folder is not in the package, so the demand made a ghost the package's
//  content root folds, the lock failed, the failed pass withdrew the demand, the ghost was
//  collected and the lock passed again. These run the real converter and reader over a
//  live loop — the reader's tool faked to hand back the manifest's own text as its dump —
//  and ask that the build ends, with the converter's error saying what it cannot build.
//

@testable import SemelCLI
@testable import SemelCore
@testable import SemelSwift
import Foundation
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class VendoredPackageSettleTests: XCTestCase {

    private var engine: BuildEngine!
    private var interpreter: CommandInterpreter!
    private var externalRoot: URL!

    private let readerDescriptor = ToolDescriptor(name: "swift", version: "test-swift",
                                                  platform: "macOS", architecture: "arm64", recursiveHash: nil)

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()

        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        try SemelSwift.register()
        ToolRunnerRegistry.instance.registerTool(descriptor: readerDescriptor, toolExecutor: DumpEchoTool())
        engine.startProcessingLoop()

        let handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        interpreter = CommandInterpreter(connection: InProcessConnection(handler: handler), baseDirectory: externalRoot.path)
        _ = try interpreter.connect()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        BuildEngine.shared = nil
        interpreter = nil
        super.tearDown()
    }

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ text: String, to relativePath: String) throws {
        let url = externalRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `Packages/` holds a formula naming the vendored package by its folder, the way an
    /// Xcode project's formula names the packages it references, its config, and the
    /// package under `Dependencies` with the lock `prepare` writes beside it, taken from
    /// the disk as `prepare` takes it.
    private func writeTree(target: String, packageFiles: [String: String] = [:]) throws {
        try write("include SwiftFormulaConverter(path: <Dependencies/Sparkle>, root: <.>).formula", to: "Packages/semel.fmla")
        try write("// the project's choices", to: "Packages/semel.config")
        try write("""
            swift.packageReader.toolDescriptor.name=swift
            swift.packageReader.toolDescriptor.version=test-swift
            swift.packageReader.toolDescriptor.platform=macOS
            swift.packageReader.toolDescriptor.architecture=arm64
            """, to: "Packages/semel.machine.config")
        try write("""
            {
              "name": "Sparkle",
              "dependencies": [],
              "products": [{"name": "Sparkle", "targets": ["Sparkle"], "type": {"library": ["automatic"]}}],
              "targets": [\(target)]
            }
            """, to: "Packages/Dependencies/Sparkle/Package.swift")
        for (relativePath, text) in packageFiles {
            try write(text, to: "Packages/Dependencies/Sparkle/\(relativePath)")
        }
        let packageFolder = externalRoot.appendingPathComponent("Packages/Dependencies/Sparkle")
        let lock = DependencyLock(contentRoot: try FolderContentRoot.root(ofFolderAt: packageFolder),
                                  fold: FolderContentRoot.formatTag)
        try write(lock.text, to: "Packages/Dependencies/Sparkle.\(DependencyLock.fileExtension)")
    }

    /// Runs `build Packages` and waits at most `seconds` for it to return. A build that
    /// never settles is the failure; the loop is then stopped so the test process goes on.
    private func buildEnds(within seconds: Double) throws -> (ended: Bool, transcript: String) {
        let interpreter = try XCTUnwrap(self.interpreter)
        let lines = LineLog()
        interpreter.output = { lines.append($0) }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            interpreter.handleCommand("build Packages")
            finished.signal()
        }
        let ended = finished.wait(timeout: .now() + seconds) == .success
        if !ended {
            engine.stopProcessingLoop()
            _ = finished.wait(timeout: .now() + 10)
        }
        return (ended, lines.all.joined(separator: "\n"))
    }

    private let remoteTarget = """
        {"name": "Sparkle", "type": "binary", "dependencies": [], "exclude": [], "resources": [], "settings": [],
         "url": "https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-for-Swift-Package-Manager.zip",
         "checksum": "4d5de3d3b4ff9b3d1d7c5b1ad1b0a5a1bd6bc7ba7e1d1b2b8b3d0c4b6e2b2d6c"}
        """

    /// Sparkle's own shape, vendored before `prepare` put the download in the package: no
    /// `semel-artifacts`. The converter asks for nothing under the package that is not
    /// there, so the lock holds, and the build ends naming where the artifact belongs.
    func test_aRemoteBinaryTargetNotVendoredSettlesNamingWhereItBelongs() throws {
        try writeTree(target: remoteTarget)

        let (ended, transcript) = try buildEnds(within: 30)

        XCTAssertTrue(ended, "the build never settled:\n\(transcript)")
        XCTAssertTrue(transcript.contains("Packages/Dependencies/Sparkle/semel-artifacts/Sparkle holds no artifact for binary "
                                          + "target Sparkle"), transcript)
        XCTAssertTrue(transcript.contains("  vendor with: semel-swift prepare"), transcript)
        XCTAssertFalse(transcript.contains("differs from its lock"), transcript)
    }

    /// The same once `prepare` has put the download in the package, under the lock: the
    /// walk to it is ghost-free, the lock holds, and the conversion makes its formula.
    func test_aRemoteBinaryTargetInSemelArtifactsSettlesWithTheLockHolding() throws {
        try writeTree(target: remoteTarget,
                      packageFiles: ["semel-artifacts/Sparkle/Sparkle.xcframework/Info.plist": "<plist/>",
                                     "semel-artifacts/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Sparkle": "binary"])

        let (ended, transcript) = try buildEnds(within: 30)

        XCTAssertTrue(ended, "the build never settled:\n\(transcript)")
        XCTAssertFalse(transcript.contains("  package: Sparkle"), "the conversion has nothing to say\n\(transcript)")
        XCTAssertFalse(transcript.contains("differs from its lock"), transcript)
    }

    /// A binary target by `path:`: the `.xcframework` folder is in the package, and is not
    /// compiled as though it were Swift.
    func test_aPackageWhoseOnlyTargetIsALocalBinaryTargetSettles() throws {
        try writeTree(target: """
            {"name": "Sparkle", "type": "binary", "dependencies": [], "exclude": [], "resources": [], "settings": [],
             "path": "Sparkle.xcframework"}
            """,
            packageFiles: ["Sparkle.xcframework/Info.plist": "<plist/>",
                           "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Sparkle": "binary"])

        let (ended, transcript) = try buildEnds(within: 30)

        XCTAssertTrue(ended, "the build never settled:\n\(transcript)")
        XCTAssertFalse(transcript.contains("  package: Sparkle"), "the conversion has nothing to say\n\(transcript)")
        XCTAssertFalse(transcript.contains("SwiftCompiler"), transcript)
    }

    /// The loop was never about binary targets: any folder a vendored package's manifest
    /// names and the package lacks is a ghost under it. The build still ends — and not on
    /// the lock, whose comparison leaves a name nobody pushed out (B-143), but on the folder
    /// itself, named by its path as one nobody pushed.
    func test_aVendoredPackageNamingAFolderItLacksSettles() throws {
        try writeTree(target: #"{"name": "Sparkle", "type": "regular", "path": "Sources/Sparkle", "dependencies": []}"#)

        let (ended, transcript) = try buildEnds(within: 30)

        XCTAssertTrue(ended, "the build never settled:\n\(transcript)")
        XCTAssertFalse(transcript.contains("differs from its lock"), transcript)
        XCTAssertTrue(transcript.contains("Packages/Dependencies/Sparkle/Sources/Sparkle has not been pushed"), transcript)
    }

    /// A vendored checkout as `prepare` leaves one: its sources beside dot-files and
    /// dot-folders at several levels — a dot-folder of plain files, a plain folder inside a
    /// dot-folder — and a file hidden by its flag rather than its name. `build` pushes the
    /// tree through the client, follows what the settle found missing and runs the real
    /// converter, and the root its lock check reads is the one `prepare` recorded (B-143).
    func test_aVendoredPackageHoldingDotNamesBuildsWithItsLockHolding() throws {
        let sources = ["Sources/Sparkle/Sparkle.swift": "public struct Sparkle {}\n",
                       "Sources/Sparkle/.swiftlint.yml": "disabled_rules: []\n",
                       "Sources/Sparkle/Resources/.keep": "",
                       "Sources/Sparkle/Hidden.swift": "struct Hidden {}\n",
                       ".gitignore": ".build\n",
                       ".spi.yml": "version: 1\n",
                       ".swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata": "<Workspace/>\n",
                       ".github/workflows/ci.yml": "on: push\n",
                       ".config/Plain/Settings.swift": "let inDotFolder = 1\n",
                       "Tests/.only-dots/.inside": "dots\n"]
        try writeTree(target: #"{"name": "Sparkle", "type": "regular", "path": "Sources/Sparkle", "dependencies": []}"#,
                      packageFiles: sources)
        let hidden = externalRoot.appendingPathComponent("Packages/Dependencies/Sparkle/Sources/Sparkle/Hidden.swift")
        XCTAssertEqual(chflags(hidden.path, UInt32(UF_HIDDEN)), 0)
        let packageFolder = externalRoot.appendingPathComponent("Packages/Dependencies/Sparkle")
        let recorded = try FolderContentRoot.root(ofFolderAt: packageFolder)

        let (ended, transcript) = try buildEnds(within: 30)

        XCTAssertTrue(ended, "the build never settled:\n\(transcript)")
        XCTAssertFalse(transcript.contains("differs from its lock"), transcript)
        let folder = try XCTUnwrap(try engine.inputFileSystem.childNode(path: Path("Packages/Dependencies/Sparkle")))
        XCTAssertEqual(try folder.readFromOutputPort(Folder.pushedContentRootOutputPort).expectValue(), recorded, transcript)
    }
}

// MARK: - Fakes

private final class LineLog {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }

    var all: [String] {
        lock.withLock { storage }
    }
}

/// `swift package dump-package` for a manifest that is already its own dump.
private struct DumpEchoTool: ToolRunner {
    func execute(arguments: [String], environment: [String: String],
                 inputFiles: [FileNameAndContent], expectedOutputFileNames: [String],
                 expectedOutputFolders: [String], output: ToolOutput) throws -> ToolExecuteResult {
        for inputFile in inputFiles {
            output.logMessage(try inputFile.contentAsString)
        }
        return ToolExecuteResult(exitCode: 0, resolvedSandboxPath: "/tmp/dump-echo-sandbox")
    }
}

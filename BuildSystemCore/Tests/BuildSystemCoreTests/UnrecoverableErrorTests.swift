//
//  UnrecoverableErrorTests.swift
//  build_system_tests
//

@testable import BuildSystemCore
import XCTest
import SemelNodeKit

/// Some failures are properties of the machine rather than of one node — the object store
/// cannot be written, the database rejects writes. Filing those against a node hides them,
/// so they are classified as unrecoverable and stop the build.
final class UnrecoverableErrorTests: BuildSystemTestCase {

    private var reported: [any UnrecoverableError] = []
    private var storeRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        reported = []
        FatalErrors.handler = { [weak self] error in self?.reported.append(error) }
    }

    override func tearDown() {
        FatalErrors.handler = FatalErrors.defaultHandler
        super.tearDown()
    }

    /// Points the store at a location it cannot possibly write to.
    private func makeUnwritableStore() -> DataObjectStore {
        DataObjectStore(storeRoot: URL(fileURLWithPath: "/dev/null/objects"))
    }

    func test_anUnwritableObjectStoreIsUnrecoverable() throws {
        DataObjectStore.shared = makeUnwritableStore()

        XCTAssertThrowsError(try "some content".intern()) { error in
            XCTAssertTrue(error is any UnrecoverableError,
                          "a store that cannot be written is not a per-node failure")
        }
    }

    func test_theMessageNamesTheStoreAndTheReason() throws {
        DataObjectStore.shared = makeUnwritableStore()

        do {
            _ = try "some content".intern()
            XCTFail("expected the store write to fail")
        } catch let error as any UnrecoverableError {
            XCTAssertTrue(error.unrecoverableDescription.contains("/dev/null/objects"),
                          "should name the store: \(error.unrecoverableDescription)")
            XCTAssertTrue(error.unrecoverableDescription.contains("free space"),
                          "should say what to check: \(error.unrecoverableDescription)")
        }
    }

    // An ordinary build failure must not trip the fatal path, or every failed compile
    // would take the process down.
    func test_anOrdinaryNodeErrorIsNotUnrecoverable() {
        FatalErrors.check(NodeError.other(message: "compile failed"))

        XCTAssertTrue(reported.isEmpty, "a node error must stay a node error")
    }

    func test_anUnrecoverableErrorReachesTheHandler() {
        FatalErrors.check(ObjectStoreError.cannotWrite(storeRoot: "/nowhere",
                                                       underlying: NodeError.nodeNotFound))

        XCTAssertEqual(reported.count, 1)
    }

    // The engine turns a thrown error into a value on the node's output ports. That path
    // is exactly where an unrecoverable failure would otherwise be swallowed.
    func test_nodeProcessingRoutesUnrecoverableFailuresToTheHandler() throws {
        storeRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("build_system-fatal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        DataObjectStore.shared = DataObjectStore(storeRoot: storeRoot)

        let database = try DatabaseLayer()
        let engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine

        let descriptor = ToolDescriptor(name: "clang", version: "test-clang",
                                        platform: "macOS", architecture: "arm64",
                                        recursiveHash: nil)
        let executor = RecordingToolExecutor()
        // Non-empty, or the result never reaches the store: interning empty content
        // short-circuits before any write.
        executor.producedFiles = ["src/hello.c.p.o": Array("OBJECT-BYTES".utf8)]
        ToolExecutorRegistry.instance.registerTool(descriptor: descriptor,
                                                   toolExecutor: executor)

        let configuration = """
            toolDescriptor.name=clang
            toolDescriptor.version=test-clang
            toolDescriptor.platform=macOS
            toolDescriptor.architecture=arm64
            """
        let input = ProcessInput(inputValues: [
            ClangCompilerTool.configuration: ["configuration": .value(try configuration.intern())],
            ClangCompilerTool.input: ["src/hello.c.p": .value(try "int main(){}".intern())],
        ])

        // Make the store read-only rather than unreachable: the node still has to read
        // its inputs back, so only the write of its result must fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: storeRoot.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: self.storeRoot.path)
        }

        let tool = try ClangCompilerTool(thisNode: Node(id: 1, kind: ClangCompilerTool.kind))
        let output = tool.processWithCatch(input: input)

        XCTAssertFalse(reported.isEmpty,
                       "the store failure must reach the fatal handler, not just the node")
        // It is still recorded against the node as well — the handler is what decides
        // whether the process continues, not this code path.
        XCTAssertTrue(output.outputValues[ClangCompilerTool.output]?.isNoValue ?? false)
    }
}

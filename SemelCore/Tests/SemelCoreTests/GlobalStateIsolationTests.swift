//
//  GlobalStateIsolationTests.swift
//  semel_tests
//

@testable import SemelCore
import XCTest
import SemelNodeKit

/// The build system reaches its object store, symbol table and tool registry through
/// process-globals rather than threading them through every call site.  That is a
/// deliberate trade — but it only works if a test can swap out what those globals
/// point at before it runs.
final class GlobalStateIsolationTests: SemelCoreTestCase {

    func test_internedContentDoesNotReachTheUsersObjectStore() throws {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let token = try "isolation probe \(UUID().uuidString)".intern()
        let storedAt = DataObjectStore.shared.objectURL(hash: token).path

        XCTAssertFalse(storedAt.hasPrefix(appSupport.path),
                       "a test must not write into the real object store at \(appSupport.path)")
    }

    func test_isolatedStoreStillRoundTripsContent() throws {
        let content = "isolation round trip \(UUID().uuidString)"
        let token = try content.intern()

        XCTAssertEqual(try token.resolveAsString(), content)
    }

    func test_toolRegistryStartsEmptyInEachTest() throws {
        let descriptor = ToolDescriptor(name: "fake", version: "1", platform: "test",
                                        architecture: "test", recursiveHash: nil)
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor,
                                                   toolExecutor: RecordingToolRunner())

        try TestGlobals.isolate()

        XCTAssertThrowsError(try ToolRunnerRegistry.instance.tool(descriptor: descriptor, namespace: "fake.tool"),
                             "isolate() must hand back a registry with no leftover registrations")
    }
}

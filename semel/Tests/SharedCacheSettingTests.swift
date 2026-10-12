//
//  SharedCacheSettingTests.swift
//  SemelCLITests
//
//  B-153, phase 3. `cache server` and `cache identity` at the prompt, through the engine's
//  server in this process: each writes the home's `semel.engine.config` and puts the change
//  in force at once, as `cache limit` does, and `cache` shows what is set beside how the
//  connection stands. Nothing listens at the address, so the connection stays down — which
//  is also what a home whose server is not running looks like.
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class SharedCacheSettingTests: XCTestCase {

    private var engine: BuildEngine!
    private var connection: InProcessConnection!
    private var interpreter: CommandInterpreter!
    private var home: URL!
    private var printed: [String] = []

    private var settings: URL {
        home.appendingPathComponent(EngineConfiguration.fileName)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-shared-cache-setting-tests/\(UUID().uuidString)", isDirectory: true)
        DataObjectStore.shared = DataObjectStore(storeRoot: home.appendingPathComponent("objects"))
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        let handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite",
                                     engineConfigurationFile: settings)
        connection  = InProcessConnection(handler: handler)
        interpreter = CommandInterpreter(connection: connection, baseDirectory: home.path)
        interpreter.output = { [unowned self] line in printed.append(line) }
    }

    override func tearDown() {
        engine.useSharedCache(nil)
        BuildEngine.shared = nil
        connection = nil
        interpreter = nil
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func written() throws -> EngineConfiguration {
        try EngineConfiguration.read(from: settings)
    }

    func test_cacheServerAndIdentityAreWrittenToTheHomeAndPutInForce() throws {
        interpreter.handleCommand("cache server 127.0.0.1:1")

        XCTAssertEqual(try written().cacheServer, CacheAddress(host: "127.0.0.1", port: 1))
        XCTAssertEqual(engine.sharedCache?.remote.address, "127.0.0.1:1", "in force at once, without a restart")
        XCTAssertTrue(printed.contains { $0.hasPrefix("Shared cache: 127.0.0.1:1, ") }, "\(printed)")

        interpreter.handleCommand("cache identity ci-runner")

        XCTAssertEqual(try written(), EngineConfiguration(cacheServer: CacheAddress(host: "127.0.0.1", port: 1),
                                                          cacheIdentity: "ci-runner"))
        XCTAssertEqual(engine.sharedCache?.identity, "ci-runner", "a new name is said in a new hello")
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_cacheShowsTheSettingsAndTheConnection() throws {
        interpreter.handleCommand("cache server 127.0.0.1:1")
        interpreter.handleCommand("cache identity ci-runner")
        let deadline = Date(timeIntervalSinceNow: 10)
        while engine.sharedCache?.state == .connecting, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        printed = []

        interpreter.handleCommand("cache")

        XCTAssertTrue(printed.contains { $0.hasPrefix("Shared cache: 127.0.0.1:1 as ci-runner, not connected, retrying: ") },
                      "\(printed)")
        XCTAssertTrue(printed.contains { $0.hasPrefix("  Lookups: 0 hits, 0 misses") }, "\(printed)")
        XCTAssertTrue(printed.contains("  Writes: 0 entries sent (0 B), 0 queued, 0 dropped, 0 failed."), "\(printed)")
    }

    func test_cacheServerNoneTakesTheEngineBackToItsLocalCacheAndKeepsTheName() throws {
        interpreter.handleCommand("cache server 127.0.0.1:1")
        interpreter.handleCommand("cache identity ci-runner")

        interpreter.handleCommand("cache server --none")

        XCTAssertEqual(try written(), EngineConfiguration(cacheIdentity: "ci-runner"))
        XCTAssertNil(engine.sharedCache)
        XCTAssertFalse(try String(contentsOf: settings, encoding: .utf8).components(separatedBy: "\n").contains { $0.hasPrefix("cache.server") })
        XCTAssertEqual(printed.last, "No shared cache is set; this engine is named ci-runner to one.")
    }

    /// The file's other settings stand: a limit set before is not lost to a server set after.
    func test_aServerSetAfterALimitKeepsTheLimit() throws {
        interpreter.handleCommand("cache limit 2G")
        interpreter.handleCommand("cache server 127.0.0.1:1")

        XCTAssertEqual(try written(), EngineConfiguration(cacheLimit: ByteCount.gibibytes(2),
                                                          cacheServer: CacheAddress(host: "127.0.0.1", port: 1)))
    }
}

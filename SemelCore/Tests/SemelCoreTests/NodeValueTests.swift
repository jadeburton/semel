//
//  NodeValueTests.swift
//  semel_tests
//

@testable import SemelCore
import XCTest
import SemelNodeKit

final class NodeValueTests: SemelCoreTestCase {

    // MARK: - NodeValue.noValue(.pending) Codable round-trip

    func test_noValue_pending_encodesAndDecodes() throws {
        let original = NodeValue.noValue(reason: .pending)
        let json = try original.toJSON()
        let decoded = try NodeValue.fromJSON(json)
        guard case .noValue(let reason) = decoded, case .pending = reason else {
            XCTFail("Expected .noValue(.pending), got \(decoded)")
            return
        }
    }

    // MARK: - NodeValue.noValue(.error) Codable round-trip

    func test_noValue_error_preservesTheDocument() throws {
        let original = NodeValue.noValue(reason: try .failure("main.c:1:1: error: unknown type"))
        let decoded = try NodeValue.fromJSON(try original.toJSON())

        XCTAssertEqual(decoded.errorDocument, .failure("main.c:1:1: error: unknown type"))
    }

    /// A tool that printed nothing is a document too, never an empty hash.
    func test_noValue_error_silentTool_roundTrip() throws {
        let original = NodeValue.noValue(reason: try .failure(""))
        let decoded = try NodeValue.fromJSON(try original.toJSON())

        XCTAssertEqual(decoded.errorCondition, .toolExitedSilently(tool: "test", status: 1))
    }

    // MARK: - NodeValue.value Codable round-trip

    func test_value_preservesHash() throws {
        let hash = "abc123deadbeef0011223344556677889900aabb"
        let original = NodeValue.value(hash)
        let json = try original.toJSON()
        let decoded = try NodeValue.fromJSON(json)
        guard case .value(let decodedHash) = decoded else {
            XCTFail("Expected .value, got \(decoded)")
            return
        }
        XCTAssertEqual(decodedHash, hash)
    }

    func test_value_emptyHash_roundTrip() throws {
        let original = NodeValue.value("")
        let decoded = try NodeValue.fromJSON(try original.toJSON())
        guard case .value(let h) = decoded else {
            XCTFail()
            return
        }
        XCTAssertEqual(h, "")
    }

    // MARK: - isNoValue

    func test_isNoValue_pending_isTrue() {
        XCTAssertTrue(NodeValue.noValue(reason: .pending).isNoValue)
    }

    func test_isNoValue_error_isTrue() {
        XCTAssertTrue(NodeValue.noValue(reason: .error(documentHash: "oops")).isNoValue)
    }

    func test_isNoValue_value_isFalse() {
        XCTAssertFalse(NodeValue.value("abc").isNoValue)
    }

    // MARK: - expectValue

    func test_expectValue_returnsHash() throws {
        let hash = "deadbeef"
        XCTAssertEqual(try NodeValue.value(hash).expectValue(), hash)
    }

    func test_expectValue_noValue_pending_throws() {
        XCTAssertThrowsError(try NodeValue.noValue(reason: .pending).expectValue())
    }

    func test_expectValue_noValue_error_throws() {
        XCTAssertThrowsError(try NodeValue.noValue(reason: .error(documentHash: "err")).expectValue())
    }

    // MARK: - JSON is stable (same input always produces same output)

    func test_json_stability() throws {
        let v = NodeValue.value("abc")
        XCTAssertEqual(try v.toJSON(), try v.toJSON())
    }
}

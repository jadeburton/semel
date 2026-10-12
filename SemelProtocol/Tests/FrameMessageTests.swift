//
//  FrameMessageTests.swift
//  SemelProtocolTests
//
//  The whole path a message takes: typed value → frame → bytes → frame → typed value.
//  This is what phase 2's in-process connection runs every request through, so that the
//  codec is exercised by every CLI test long before a socket exists.
//

@testable import SemelProtocol
import XCTest

final class FrameMessageTests: XCTestCase {

    func test_requestSurvivesTheWholePath() throws {
        let request = Request.daemon(.pushFile(path: "src/a.c", mode: 0o644))
        let body    = Data("int main() {}".utf8)

        let frame = try Frame.request(request, correlationID: 9, body: body)
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(frame))
        let received = try XCTUnwrap(try decoder.next())

        XCTAssertEqual(received.kind, .request)
        XCTAssertEqual(received.correlationID, 9)
        XCTAssertEqual(try received.request(), request)
        XCTAssertEqual(received.body, body)
    }

    func test_responseSurvivesTheWholePath() throws {
        let response = Response.daemon(.fetch(mode: 0o755))
        let body     = Data([0xCA, 0xFE])

        let frame = try Frame.response(response, correlationID: 9, body: body)
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(frame))
        let received = try XCTUnwrap(try decoder.next())

        XCTAssertEqual(received.kind, .response)
        XCTAssertEqual(try received.response(), response)
        XCTAssertEqual(received.body, body)
    }

    /// A batch refused for a vendored package pushed whole names every file of it, and the
    /// rejection is one reply: it names a bounded sample and counts the rest, so it fits a
    /// frame whatever the batch's size and reaches the client as the refusal it is (B-161).
    func test_aBatchRejectionOfTwentyThousandPathsFitsOneFrameWithItsCount() throws {
        let folder  = "Packages/Dependencies/swift-collections"
        let changed = (0..<20_000).map { "\(folder)/Sources/OrderedCollections/Folder\($0 / 200)/File\($0).swift" }
        let rejection = ErrorResponse.rejectedBatch(folder: folder, lock: "\(folder).semel-lock",
                                                    expected: .contentRoot(String(repeating: "0", count: 64)),
                                                    found: String(repeating: "f", count: 64), changedPaths: changed)

        let frame = try Frame.response(.error(rejection), correlationID: 9)
        XCTAssertLessThanOrEqual(frame.json.count, Int(Frame.maximumJSONLength))
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(frame))
        let received = try XCTUnwrap(try decoder.next())

        guard case .error(.batchRejected(_, _, _, _, let paths, let pathsNotListed)) = try received.response() else {
            return XCTFail("the rejection did not survive the frame")
        }
        XCTAssertEqual(paths, Array(changed.prefix(ErrorResponse.batchRejectedPathsListed)))
        XCTAssertEqual(paths.count, 50)
        XCTAssertEqual(pathsNotListed, 19_950)
    }

    /// A batch with fewer paths than the sample names them all and counts none.
    func test_aSmallBatchRejectionNamesEveryPath() {
        let rejection = ErrorResponse.rejectedBatch(folder: "Dependencies/Pkg", lock: "Dependencies/Pkg.semel-lock",
                                                    expected: .contentRoot("4d5d"), found: nil,
                                                    changedPaths: ["Dependencies/Pkg/a.swift", "Dependencies/Pkg/b.swift"])

        XCTAssertEqual(rejection, .batchRejected(folder: "Dependencies/Pkg", lock: "Dependencies/Pkg.semel-lock",
                                                 expected: .contentRoot("4d5d"), found: nil,
                                                 paths: ["Dependencies/Pkg/a.swift", "Dependencies/Pkg/b.swift"],
                                                 pathsNotListed: 0))
    }

    func test_eventUsesCorrelationIDZero() throws {
        let frame = try Frame.event(.daemon(.notice(line: "hi")))

        XCTAssertEqual(frame.kind, .event)
        XCTAssertEqual(frame.correlationID, 0)
        XCTAssertEqual(try frame.event(), .daemon(.notice(line: "hi")))
    }

    func test_bodyDefaultsToEmpty() throws {
        XCTAssertEqual(try Frame.request(.daemon(.reset(clearCache: false)), correlationID: 1).body, Data())
    }

    func test_readingTheWrongKindIsAnError() throws {
        let frame = try Frame.request(.daemon(.reset(clearCache: false)), correlationID: 1)

        XCTAssertThrowsError(try frame.response()) { error in
            XCTAssertEqual(error as? MessageError, .wrongKind(expected: .response, actual: .request))
        }
    }

    func test_undecodableJSONIsAnError() {
        let frame = Frame(kind: .request, correlationID: 1, json: Data("not json".utf8))

        XCTAssertThrowsError(try frame.request())
    }
}

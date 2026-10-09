//
//  ProcessInputTests.swift
//  SemelNodeKitTests
//
//  A port declared to hold one wire holds one (B-141). `onlyWire` is where every node reads
//  such a port, so it is where two wires are refused rather than one of them picked in the
//  order a dictionary happens to yield them; a port declared `.many` is read whole and is
//  none of its business.
//

@testable import SemelNodeKit
import XCTest

final class ProcessInputTests: XCTestCase {

    // XCTestCase rather than the engine's SemelCoreTestCase: no value here is interned, so
    // nothing touches an object store.
    private let pending = NodeValue.noValue(reason: .pending)

    // MARK: - A required one-wire port

    func test_oneWireOnARequiredPortIsThatWire() throws {
        let input = ProcessInput(inputValues: ["configuration": ["swift.config": pending]])

        XCTAssertEqual(try input.onlyWire(onRequiredPort: "configuration").key, "swift.config")
    }

    func test_twoWiresOnARequiredPortAreAnErrorNamingThePortAndTheWires() {
        let input = ProcessInput(inputValues: ["configuration": ["project": pending, "machine": pending]])

        XCTAssertThrowsError(try input.onlyWire(onRequiredPort: "configuration")) { error in
            guard case NodeError.severalWiresOnOneWirePort(let port, let wires) = error else {
                return XCTFail("expected severalWiresOnOneWirePort, got \(error)")
            }
            XCTAssertEqual(port, "configuration")
            XCTAssertEqual(wires, ["machine", "project"], "sorted, so the message is the same in every process")
        }
    }

    func test_noWireOnARequiredPortIsAnErrorNamingThePort() {
        let input = ProcessInput(inputValues: ["configuration": [:]])

        XCTAssertThrowsError(try input.onlyWire(onRequiredPort: "configuration")) { error in
            guard case NodeError.requiredInputPortUnwired(let port) = error else {
                return XCTFail("expected requiredInputPortUnwired, got \(error)")
            }
            XCTAssertEqual(port, "configuration")
        }
    }

    // MARK: - An optional one-wire port

    func test_oneWireOnAnOptionalPortIsThatWireAndNoneIsNil() throws {
        let wired   = ProcessInput(inputValues: ["bridgingHeader": ["App-Bridging-Header.h": pending]])
        let unwired = ProcessInput(inputValues: ["bridgingHeader": [:]])

        XCTAssertEqual(try wired.onlyWire(onOptionalPort: "bridgingHeader")?.key, "App-Bridging-Header.h")
        XCTAssertNil(try unwired.onlyWire(onOptionalPort: "bridgingHeader"))
    }

    func test_twoWiresOnAnOptionalPortAreAnErrorNamingThePortAndTheWires() {
        let input = ProcessInput(inputValues: ["bridgingHeader": ["b.h": pending, "a.h": pending]])

        XCTAssertThrowsError(try input.onlyWire(onOptionalPort: "bridgingHeader")) { error in
            guard case NodeError.severalWiresOnOneWirePort(let port, let wires) = error else {
                return XCTFail("expected severalWiresOnOneWirePort, got \(error)")
            }
            XCTAssertEqual(port, "bridgingHeader")
            XCTAssertEqual(wires, ["a.h", "b.h"])
        }
    }

    // MARK: - A port holding many wires

    /// A port that holds many is read whole, through `wires(on:)`; its arity says so, and
    /// it is not among the ports the applier holds to one wire.
    func test_aManyWirePortIsReadWholeAndIsNotHeldToOneWire() throws {
        let descriptor = NodeDescriptor(inputPorts: [.required("configuration"),
                                                     .required("objectFiles", .many),
                                                     .optional("libraries", .many),
                                                     .optional("entitlements"),
                                                     .dynamic("frameworks")],
                                        outputPorts: [])
        let input = ProcessInput(inputValues: ["objectFiles": ["a.o": pending, "b.o": pending]])

        XCTAssertEqual(try input.wires(on: "objectFiles").keys.sorted(), ["a.o", "b.o"])
        XCTAssertEqual(descriptor.oneWireInputPorts, ["configuration", "entitlements"])
    }

    /// A port is one wire unless it says otherwise, so a node that forgets to declare a
    /// port `.many` is refused at its first formula rather than silently picking.
    func test_aStaticPortHoldsOneWireUnlessDeclaredMany() {
        XCTAssertTrue(NodeDescriptor.InputPort.required("input").holdsOneWire)
        XCTAssertTrue(NodeDescriptor.InputPort.optional("input").holdsOneWire)
        XCTAssertFalse(NodeDescriptor.InputPort.required("input", .many).holdsOneWire)
        XCTAssertFalse(NodeDescriptor.InputPort.dynamic("input").holdsOneWire)
    }
}

//
//  TypeRegistryConcurrencyTests.swift
//  SemelNodeKitTests
//
//  B-128. A host registers types while an engine's loop is already looking them up: the
//  root suite's `PackageDependencyFollowTests` registered the Swift toolchain after its
//  engine's loop had started, and the loop's first lookup followed dictionary storage the
//  registration had just replaced — `-[NSIndirectTaggedPointerString objectForKey:]`, and
//  the test process died of SIGABRT.
//

@testable import SemelNodeKit
import XCTest

/// Thousands of distinct types, each with a kind and a name of its own, so that
/// registering them grows the registry — a growing dictionary is one whose storage is
/// reallocated under a reader, which is the case that crashed. A probe is a binary numeral:
/// `RegistryProbe<RegistryProbe<RegistryProbeBase, One>, Zero>` is the base's kind with
/// `10` appended in binary, so no two probes share a kind and none reaches a real one.
private struct RegistryProbeBase: WithKind {
    static let kind: UInt = 988_000_000
}

private protocol RegistryProbeDigit {
    static var digit: UInt { get }
}

private enum Zero: RegistryProbeDigit {
    static let digit: UInt = 0
}

private enum One: RegistryProbeDigit {
    static let digit: UInt = 1
}

private struct RegistryProbe<Prefix: WithKind, Digit: RegistryProbeDigit>: WithKind {
    static var kind: UInt { Prefix.kind * 2 + Digit.digit }
}

/// Every probe with up to `digits` binary digits after `prefix`'s.
private func registryProbes<Prefix: WithKind>(extending prefix: Prefix.Type, digits: Int) -> [WithKind.Type] {
    guard digits > 0 else {
        return []
    }
    let zero = RegistryProbe<Prefix, Zero>.self
    let one  = RegistryProbe<Prefix, One>.self
    return [zero, one]
        + registryProbes(extending: zero, digits: digits - 1)
        + registryProbes(extending: one, digits: digits - 1)
}

/// How many binary digits the longest probe has: 2 + 4 + … + 2^11 probes in all.
private let registryProbeDigits = 11

final class TypeRegistryConcurrencyTests: XCTestCase {

    func test_lookupsWhileTypesAreRegisteredDoNotCorruptTheRegistry() throws {
        try TypeRegistry.register(types: [RegistryProbeBase.self])
        let baseName = String(describing: RegistryProbeBase.self)

        let readerStarted = DispatchSemaphore(value: 0)
        let writerDone    = DispatchSemaphore(value: 0)
        let writerFailure = LockedFailure()
        Thread.detachNewThread {
            let probeTypes = registryProbes(extending: RegistryProbeBase.self, digits: registryProbeDigits)
            readerStarted.wait()
            for probeType in probeTypes {
                do {
                    try TypeRegistry.register(types: [probeType])
                } catch {
                    writerFailure.record(error)
                }
            }
            writerDone.signal()
        }

        readerStarted.signal()
        repeat {
            XCTAssertEqual(try TypeRegistry.kind(forTypeName: baseName), RegistryProbeBase.kind)
            XCTAssertNotNil(try? TypeRegistry.type(kind: RegistryProbeBase.kind))
        } while writerDone.wait(timeout: .now()) == .timedOut

        XCTAssertNil(writerFailure.error)
        let lastProbe = try XCTUnwrap(registryProbes(extending: RegistryProbeBase.self, digits: registryProbeDigits).last)
        XCTAssertEqual(try TypeRegistry.kind(forTypeName: String(describing: lastProbe)), lastProbe.kind)
    }
}

/// The writer thread's first failure, for the test's thread to read.
private final class LockedFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var firstError: Error?

    func record(_ error: Error) {
        lock.withLock {
            if firstError == nil {
                firstError = error
            }
        }
    }

    var error: Error? {
        lock.withLock { firstError }
    }
}

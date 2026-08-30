//
//  MissingSettingTests.swift
//  SemelSwiftTests
//
//  A setting that is not supplied is an error, not a default.
//
//  A default baked into the binary is worse than one read from the machine: xcrun at least
//  reports what is installed, while a literal in Swift source means upgrading Semel silently
//  changes what a previous build meant. So there are none, and the failure has to say what to
//  write and where.
//

@testable import SemelSwift
import SemelNodeKit
import XCTest

final class MissingSettingTests: SemelSwiftTestCase {

    private let complete = [
        "toolDescriptor.name": "swiftc",
        "toolDescriptor.version": "Apple Swift version 6.3.3",
        "toolDescriptor.platform": "macOS",
        "toolDescriptor.architecture": "arm64",
        "moduleName": "Lib",
    ]

    func test_aCompleteConfigurationIsAccepted() throws {
        XCTAssertNoThrow(try SwiftCompilerToolConfiguration(properties: complete))
    }

    func test_aMissingSettingNamesItselfAndItsNamespace() throws {
        var incomplete = complete
        incomplete["toolDescriptor.version"] = nil

        XCTAssertThrowsError(try SwiftCompilerToolConfiguration(properties: incomplete)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("swift.compiler.toolDescriptor.version"),
                          "should name the key to write in the config file, got \(message)")
        }
    }

    /// Every required setting, not just the first — a message naming one of four missing keys
    /// costs four build attempts to fix.
    func test_everyMissingSettingIsNamedAtOnce() throws {
        XCTAssertThrowsError(try SwiftCompilerToolConfiguration(properties: ["moduleName": "Lib"])) { error in
            let message = String(describing: error)
            for key in ["name", "version", "platform", "architecture"] {
                XCTAssertTrue(message.contains("toolDescriptor.\(key)"), "missing \(key) in: \(message)")
            }
        }
    }

    /// `SwiftPackageReaderTool` reads the manifest for every package, so a hardcoded
    /// toolDescriptor here would make "no defaults" false for the very first node a
    /// build runs.
    func test_packageReaderNamesItselfAndItsOwnNamespaceWhenMissing() throws {
        XCTAssertThrowsError(try SwiftPackageReaderToolConfiguration(properties: [:])) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("swift.packageReader.toolDescriptor.version"),
                          "should name the key to write in the config file, got \(message)")
        }
    }
}

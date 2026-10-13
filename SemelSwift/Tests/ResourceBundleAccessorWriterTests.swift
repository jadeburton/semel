//
//  ResourceBundleAccessorWriterTests.swift
//  SemelSwiftTests
//
//  The bundle accessor SwiftPM generates for an Objective-C target with resources
//  (B-55 item 8): what `SWIFTPM_MODULE_BUNDLE` is defined by.
//

@testable import SemelSwift
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class ResourceBundleAccessorWriterTests: SemelSwiftTestCase {

    private func published(_ properties: [String: String]) throws -> (header: String, source: String) {
        let writer = try ResourceBundleAccessorWriter(thisNode: NodeRecord(id: 1, kind: ResourceBundleAccessorWriter.kind, name: nil,
                                                                           properties: properties, scheduled: false, identity: nil))
        guard let output = try writer.didCreate() else {
            throw NodeError.processNotSupported
        }
        return (try XCTUnwrap(output.outputValues[ResourceBundleAccessorWriter.headerPort]).expectValue().resolveAsString(),
                try XCTUnwrap(output.outputValues[ResourceBundleAccessorWriter.sourcePort]).expectValue().resolveAsString())
    }

    private let kit = ["moduleName": "ObjCKit", "bundleName": "CPackage_ObjCKit"]

    /// SwiftPM's header, as `swift build` writes it to `DerivedSources` (Swift 6.3), ended
    /// by a newline.
    func test_theHeaderIsSwiftPMsDeclaringTheFunctionAndTheMacro() throws {
        XCTAssertEqual(try published(kit).header,
                       """
                       #if __OBJC__
                       #import <Foundation/Foundation.h>

                       #if __cplusplus
                       extern "C" {
                       #endif

                       NSBundle* ObjCKit_SWIFTPM_MODULE_BUNDLE(void);

                       #define SWIFTPM_MODULE_BUNDLE ObjCKit_SWIFTPM_MODULE_BUNDLE()

                       #if __cplusplus
                       }
                       #endif
                       #endif

                       """)
    }

    /// The source defines the function the header declares, finds the bundle by the name
    /// the converter builds it under where this build lays it out, and raises naming it
    /// when it is in none of those places.
    func test_theSourceDefinesTheFunctionAndLooksForTheNamedBundle() throws {
        let source = try published(kit).source

        XCTAssertTrue(source.hasPrefix("#import <Foundation/Foundation.h>\n"), source)
        XCTAssertTrue(source.contains("NSBundle* ObjCKit_SWIFTPM_MODULE_BUNDLE(void) {"), source)
        XCTAssertTrue(source.contains("[candidate URLByAppendingPathComponent:@\"CPackage_ObjCKit.bundle\"]"), source)
        XCTAssertTrue(source.contains("[NSBundle mainBundle] bundleURL]"), source)
        XCTAssertTrue(source.contains("[mainBundleURL URLByAppendingPathComponent:@\"Contents/Resources\"]"), source)
        XCTAssertTrue(source.contains("[NSBundle bundleForClass:[ObjCKit_SemelResourceBundleFinder class]]"), source)
        XCTAssertTrue(source.contains("format:@\"unable to find bundle named %@\", @\"CPackage_ObjCKit.bundle\"]"), source)
    }

    /// Nothing of the machine or the sandbox is in either file, and equal properties give
    /// equal bytes, which is what lets four builds compare the object.
    func test_theFilesNameNoPathAndAreTheSameForTheSameProperties() throws {
        let first  = try published(kit)
        let second = try published(kit)
        XCTAssertEqual(first.header, second.header)
        XCTAssertEqual(first.source, second.source)
        XCTAssertFalse(first.source.contains("/private/"), first.source)
        XCTAssertFalse(first.source.contains(".build"), first.source)
    }

    func test_aQuoteInTheBundleNameIsEscapedAsAnObjectiveCStringLiteralWantsIt() throws {
        let source = try published(["moduleName": "Kit", "bundleName": "odd\"name"]).source
        XCTAssertTrue(source.contains("@\"odd\\\"name.bundle\""), source)
    }

    func test_aMissingPropertyIsAnErrorNamingIt() throws {
        XCTAssertThrowsError(try published(["moduleName": "Kit"])) { error in
            XCTAssertEqual(error as? ErrorCondition,
                           .propertyMissing(type: "ResourceBundleAccessorWriter", property: "bundleName", alternatives: []))
        }
        XCTAssertThrowsError(try published(["bundleName": "Pkg_Kit"])) { error in
            XCTAssertEqual(error as? ErrorCondition,
                           .propertyMissing(type: "ResourceBundleAccessorWriter", property: "moduleName", alternatives: []))
        }
    }

    /// A source with nothing to wait for, as `ModuleMapWriter` is.
    func test_itDeclaresNoInputPorts() {
        XCTAssertTrue(ResourceBundleAccessorWriter.descriptor.inputPorts.isEmpty)
    }
}

//
//  InfoPlistBuilderTests.swift
//  SemelAppleTests
//

@testable import SemelApple
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class InfoPlistBuilderTests: SemelAppleTestCase {

    private func plistValue(_ dictionary: [String: Any]) throws -> NodeValue {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        return .value(try [UInt8](data).intern())
    }

    private func process(properties: [String: String] = [:],
                         base: NodeValue? = nil,
                         partials: [String: NodeValue] = [:]) throws -> [String: Any] {
        let node = try InfoPlistBuilder(thisNode: NodeRecord(id: 1, kind: InfoPlistBuilder.kind, name: nil,
                                                             properties: properties, scheduled: false, graphSpec: nil))
        var inputs: [String: [String: NodeValue]] = [InfoPlistBuilder.partials: partials]
        if let base {
            inputs[InfoPlistBuilder.base] = ["input:/app/Info.plist": base]
        }
        let output = try node.process(input: ProcessInput(inputValues: inputs))
        let hash = try XCTUnwrap(output.outputValues[InfoPlistBuilder.output]).expectValue()
        let bytes = try XCTUnwrap(try DataObjectStore.shared.read(hash: hash))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any])
    }

    /// Base, then partials, then the node's own keys: the project's file is the starting
    /// point, actool's icon keys land over it, and a build setting has the last word.
    func test_mergesBaseThenPartialsThenProperties() throws {
        let plist = try process(
            properties: ["CFBundleIdentifier": "com.example.hello", "CFBundleName": "Hello"],
            base: try plistValue(["CFBundleName": "Base", "CFBundleVersion": "1", "LSRequiresIPhoneOS": true]),
            partials: ["actool": try plistValue(["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon"]],
                                                 "CFBundleVersion": "2"])])

        XCTAssertEqual(plist["CFBundleName"] as? String, "Hello")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.example.hello")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "2")
        XCTAssertEqual(plist["LSRequiresIPhoneOS"] as? Bool, true)
        XCTAssertNotNil((plist["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"])
    }

    /// A property is both an entry and a variable, as a build setting is in Xcode, so
    /// `$(PRODUCT_NAME)` in the base resolves from the same place `CFBundleName` came from.
    func test_substitutesVariableReferencesFromTheProperties() throws {
        let plist = try process(
            properties: ["PRODUCT_NAME": "Hello", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.hello"],
            base: try plistValue(["CFBundleExecutable": "$(PRODUCT_NAME)",
                                  "CFBundleIdentifier": "${PRODUCT_BUNDLE_IDENTIFIER}",
                                  "CFBundleDisplayName": "$(PRODUCT_NAME) App",
                                  "CFBundleURLTypes": [["CFBundleURLSchemes": ["$(PRODUCT_NAME)"]]]]))

        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Hello")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.example.hello")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Hello App")
        let schemes = ((plist["CFBundleURLTypes"] as? [[String: Any]])?.first?["CFBundleURLSchemes"]) as? [String]
        XCTAssertEqual(schemes, ["Hello"])
    }

    /// `$(PRODUCT_BUNDLE_IDENTIFIER)` left in a bundle identifier is a bundle that will not
    /// install; an undefined reference is an error naming it, not a string passed through.
    func test_anUndefinedReferenceIsAnError() throws {
        let node = try InfoPlistBuilder(thisNode: NodeRecord(id: 1, kind: InfoPlistBuilder.kind))
        let output = try node.process(input: ProcessInput(inputValues: [
            InfoPlistBuilder.base: ["input:/app/Info.plist": try plistValue(["CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)"])],
        ]))

        guard case .noValue(.error(let messageHash)) = try XCTUnwrap(output.outputValues[InfoPlistBuilder.output]) else {
            return XCTFail("expected an error")
        }
        XCTAssertTrue(try messageHash.resolveAsString().contains("PRODUCT_BUNDLE_IDENTIFIER"))
    }

    func test_aPlistCanBeBuiltFromKeysAlone() throws {
        let plist = try process(properties: ["CFBundleIdentifier": "com.example.hello", "CFBundlePackageType": "APPL"])

        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist.count, 2)
    }

    /// A converter writes the generated keys as one JSON dictionary: a plist key such as
    /// `UISupportedInterfaceOrientations~ipad` is no formula identifier, and JSON carries
    /// the arrays, dictionaries and booleans a plist has. Its values resolve `$(VAR)`
    /// from the ordinary properties like any other.
    func test_keysArriveAsAJSONDictionaryTyped() throws {
        let plist = try process(properties: [
            "keys": """
                {"UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait"], "UILaunchScreen": {},
                 "LSRequiresIPhoneOS": true, "CFBundleVersion": "1", "CFBundleExecutable": "$(PRODUCT_NAME)"}
                """,
            "PRODUCT_NAME": "Hello",
        ])

        XCTAssertEqual(plist["UISupportedInterfaceOrientations~ipad"] as? [String], ["UIInterfaceOrientationPortrait"])
        XCTAssertEqual((plist["UILaunchScreen"] as? [String: Any])?.count, 0)
        XCTAssertEqual(plist["LSRequiresIPhoneOS"] as? Bool, true)
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "1")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Hello")
        XCTAssertNil(plist["keys"], "the dictionary is its entries, not an entry")
    }
}

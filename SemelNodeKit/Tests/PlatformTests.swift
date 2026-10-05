//
//  PlatformTests.swift
//  SemelNodeKit
//
//  A platform read back from what a config or a formula already says: the triple
//  `target(deploymentVersion:)` wrote, and the SDK name.
//

import SemelNodeKit
import XCTest

final class PlatformTests: XCTestCase {

    func test_aTripleWrittenForAPlatformReadsBackAsThatPlatform() {
        for platform in Platform.allCases {
            let target = platform.target(deploymentVersion: "17.0")
            XCTAssertEqual(Platform(target: target), platform, target)
            XCTAssertEqual(platform.deploymentVersion(inTarget: target), "17.0", target)
        }
    }

    func test_aTripleNoPlatformWritesIsNone() {
        for target in ["arm64-apple-ios17.0", "x86_64-apple-macosx14.0", "arm64-apple-macosx",
                       "arm64-apple-ios17.0-simulator-extra", ""] {
            XCTAssertNil(Platform(target: target), target)
        }
        XCTAssertNil(Platform.macos.deploymentVersion(inTarget: "arm64-apple-ios17.0-simulator"))
    }

    func test_anSDKNameReadsBackAsItsPlatform() {
        for platform in Platform.allCases {
            XCTAssertEqual(Platform(sdkName: platform.sdkName), platform)
        }
        XCTAssertNil(Platform(sdkName: "iphoneos"))
    }
}

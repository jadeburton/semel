//
//  SettingArgumentTests.swift
//  SemelNodeKit
//
//  What a tool says when it rejects an argument a node built from a setting, and which
//  setting the message then names.
//
//  Every stderr line quoted here was captured from a real run of the toolchain installed
//  on a development machine — `clang -target nonsense-triple -c t.c`, `swiftc -sdk
//  /no/such/sdk -c t.swift` and their neighbours — rather than written to match the
//  matcher. A phrase list that only recognises invented phrasing recognises nothing.
//

@testable import SemelNodeKit
import XCTest

final class SettingArgumentTests: XCTestCase {

    // MARK: - clang, -target

    func test_clangRejectsATripleByQuotingIt() {
        let target = SettingArgument.clangTarget(key: "clang.preprocessor.target", value: "nonsense-triple")

        XCTAssertTrue(target.isMentioned(in: "error: unknown target triple 'nonsense-triple'"))
        XCTAssertEqual(target.sentence,
                       "`clang.preprocessor.target` is `nonsense-triple`; `clang -print-targets` "
                     + "lists the architectures this toolchain builds for, which is a triple's first word.")
    }

    func test_clangRejectsAKnownTripleItCannotBuildFor() {
        let target = SettingArgument.clangTarget(key: "clang.compiler.target", value: "sparc-apple-macos14.0")

        XCTAssertTrue(target.isMentioned(in: """
            error: unable to create target: 'No available targets are compatible with triple "sparc-apple-macos14.0"'
            1 error generated.
            """))
    }

    // MARK: - clang, -isysroot and -L

    func test_clangNamesASysrootItCannotFind() {
        let sdk = SettingArgument.clangSysroot(key: "clang.preprocessor.sdkPath", value: "/no/such/sdk")

        XCTAssertTrue(sdk.isMentioned(in: "clang: warning: no such sysroot directory: '/no/such/sdk' [-Wmissing-sysroot]"))
        XCTAssertEqual(sdk.sentence,
                       "`clang.preprocessor.sdkPath` is `/no/such/sdk`; `xcrun --show-sdk-path` "
                     + "prints the path of an SDK installed here.")
    }

    /// The case the sysroot's phrase list exists to exclude: an ordinary type error quotes
    /// the SDK's path, because the note that explains it sits in an SDK header. A setting
    /// matched on its value alone would blame the SDK for a wrong argument type.
    func test_anSDKPathQuotedByANoteIsNotAComplaintAboutTheSDK() {
        let sdk = SettingArgument.clangSysroot(
            key: "clang.preprocessor.sdkPath",
            value: "/Applications/Xcode_26_6.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")

        XCTAssertFalse(sdk.isMentioned(in: """
            hdr.c:2:22: error: incompatible integer to pointer conversion passing 'int' to parameter of type 'const char *' [-Wint-conversion]
            /Applications/Xcode_26_6.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/_stdio.h:267:23: note: passing argument to parameter here
            """))
    }

    func test_theLinkerNamesASearchPathItCannotFind() {
        let sdk = SettingArgument.clangLibrarySearchPath(key: "clang.linker.sdkPath",
                                                         value: "/no/such/sdk",
                                                         searchPath: "/no/such/sdk/usr/lib")

        XCTAssertTrue(sdk.isMentioned(in: "ld: warning: search path '/no/such/sdk/usr/lib' not found"))
        XCTAssertTrue(sdk.isMentioned(in: "ld: library 'System' not found"))
    }

    // MARK: - swiftc

    func test_swiftcRejectsATripleByQuotingIt() {
        let target = SettingArgument.swiftTarget(key: "swift.compiler.target", value: "nonsense")

        XCTAssertTrue(target.isMentioned(in: "error: unknown target 'nonsense'"))
        XCTAssertEqual(target.sentence,
                       "`swift.compiler.target` is `nonsense`; `swiftc -print-target-info` "
                     + "prints the triple this toolchain builds for by default.")
    }

    func test_swiftcRejectsAnArchitectureItHasNoFrontendFor() {
        let target = SettingArgument.swiftTarget(key: "swift.linker.target", value: "sparc-apple-macos14.0")

        XCTAssertTrue(target.isMentioned(in: """
            remark: In-process target-info query failed (Dependency module details contains a corrupted string reference). Using fallback mechanism.
            error: frontend job retrieving target info failed with code 1: <unknown>:0: error: unsupported target architecture: 'sparc'
            """))
    }

    /// The SDK reaches `-sdk` as the path `xcrun` resolved the name to, so the run
    /// complains about a path the setting never spells. The sentence names the setting.
    func test_swiftcNamesTheSDKPathAndTheSettingNamesTheSDK() {
        let sdk = SettingArgument.swiftSDK(key: "swift.compiler.sdk", value: "macosx")

        XCTAssertTrue(sdk.isMentioned(in: """
            warning: no such SDK: /no/such/sdk
            <unknown>:0: warning: no such sysroot directory: '/no/such/sdk'
            <unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx26.0'
            """))
        XCTAssertEqual(sdk.sentence,
                       "`swift.compiler.sdk` is `macosx`; `xcodebuild -showsdks` lists the SDKs "
                     + "installed here, as `-sdk <name>` names them.")
    }

    // MARK: - Nothing matched

    func test_anOrdinaryCompileErrorNamesNoSetting() {
        let settings: [SettingArgument] = [
            .clangTarget(key: "clang.compiler.target", value: "arm64-apple-macos14.0"),
            .clangSysroot(key: "clang.preprocessor.sdkPath", value: "/no/such/sdk"),
            .swiftTarget(key: "swift.compiler.target", value: "arm64-apple-macos14.0"),
            .swiftSDK(key: "swift.compiler.sdk", value: "macosx"),
        ]

        XCTAssertEqual(SettingArgument.sentences(for: settings, matching: """
            bad.c:1:1: error: unknown type name 'itn'
                1 | itn main(void){return 0;}
                  | ^
            1 error generated.
            """), [])
    }
}

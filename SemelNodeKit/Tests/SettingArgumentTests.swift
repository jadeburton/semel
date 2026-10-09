//
//  SettingArgumentTests.swift
//  SemelNodeKit
//
//  What a tool says when it rejects an argument a node built from a setting, and which
//  setting the failure's remedy then names.
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

    func test_clangRejectsATripleItCannotParse() {
        let target = SettingArgument.clangTarget(key: "clang.preprocessor.target", value: "nonsense-triple")

        XCTAssertTrue(target.isMentioned(in: "error: unknown target triple 'nonsense-triple'"))
        XCTAssertEqual(SettingArgument.keys(for: [target], matching: "error: unknown target triple 'nonsense-triple'"),
                       ["clang.preprocessor.target"])
    }

    func test_clangRejectsAKnownTripleItCannotBuildFor() {
        let target = SettingArgument.clangTarget(key: "clang.compiler.target", value: "sparc-apple-macos14.0")

        XCTAssertTrue(target.isMentioned(in: """
            error: unable to create target: 'No available targets are compatible with triple "sparc-apple-macos14.0"'
            1 error generated.
            """))
    }

    /// The phrases are the evidence, not the value: clang rewrites a triple it could not
    /// read before quoting it, so the setting's own text is absent from the complaint
    /// about it. `-target riscv64-apple-macos14.0` produces this.
    func test_clangRejectsATripleWithoutQuotingWhatWasPassed() {
        let target = SettingArgument.clangTarget(key: "clang.compiler.target", value: "riscv64-apple-macos14.0")

        XCTAssertTrue(target.isMentioned(in: "error: unknown target triple 'unknown-apple-macosx14.0.0'"))
    }

    // MARK: - clang, -isysroot and -L

    func test_clangNamesASysrootItCannotFind() {
        let sdk = SettingArgument.clangSysroot(key: "clang.preprocessor.sdkPath", value: "/no/such/sdk")

        XCTAssertTrue(sdk.isMentioned(in: "clang: warning: no such sysroot directory: '/no/such/sdk' [-Wmissing-sysroot]"))
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

    /// The one flag whose value is evidence. A linker cites libraries rather than headers,
    /// so the search path appears only in the warning that is about it.
    func test_theLinkerNamesASearchPathItCannotFind() {
        let sdk = SettingArgument.clangLibrarySearchPath(key: "clang.linker.sdkPath",
                                                         value: "/no/such/sdk",
                                                         searchPath: "/no/such/sdk/usr/lib")

        XCTAssertTrue(sdk.isMentioned(in: "ld: warning: search path '/no/such/sdk/usr/lib' not found"))
        // The second phrase stands in for a machine whose default SDK is unusable, where
        // the explicit search path is the only one `ld` has: a bad search path beside a
        // working default SDK only warns. It also shows why the matcher drops quoted
        // source rather than every line without a severity word — a linker's own failure
        // carries none.
        XCTAssertTrue(sdk.isMentioned(in: """
            ld: library 'System' not found
            clang: error: linker command failed with exit code 1 (use -v to see invocation)
            """))
    }

    // MARK: - swiftc

    func test_swiftcRejectsATripleItCannotParse() {
        let target = SettingArgument.swiftTarget(key: "swift.compiler.target", value: "nonsense")

        XCTAssertTrue(target.isMentioned(in: "error: unknown target 'nonsense'"))
    }

    func test_swiftcRejectsAnArchitectureItHasNoFrontendFor() {
        let target = SettingArgument.swiftTarget(key: "swift.linker.target", value: "sparc-apple-macos14.0")

        XCTAssertTrue(target.isMentioned(in: """
            remark: In-process target-info query failed (Dependency module details contains a corrupted string reference). Using fallback mechanism.
            error: frontend job retrieving target info failed with code 1: <unknown>:0: error: unsupported target architecture: 'sparc'
            """))
    }

    /// The SDK reaches `-sdk` as the path `xcrun` resolved the name to, so the run
    /// complains about a path the setting never spells. The remedy names the setting.
    func test_swiftcNamesTheSDKPathAndTheSettingNamesTheSDK() {
        let sdk = SettingArgument.swiftSDK(key: "swift.compiler.sdk", value: "macosx")

        XCTAssertTrue(sdk.isMentioned(in: """
            warning: no such SDK: /no/such/sdk
            <unknown>:0: warning: no such sysroot directory: '/no/such/sdk'
            <unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx26.0'
            """))
    }

    /// The failure that made the target's value no evidence: with a target declared, as
    /// `prepare` writes one, swiftc quotes it verbatim in a run that is entirely about the
    /// SDK. Captured from `swiftc -sdk /no/such/sdk -target arm64-apple-macos14.0`.
    func test_anSDKThatCannotBeLoadedNamesTheSDKAndNotTheTarget() {
        let settings: [SettingArgument] = [
            .swiftSDK(key: "swift.compiler.sdk", value: "macosx"),
            .swiftTarget(key: "swift.compiler.target", value: "arm64-apple-macos14.0"),
        ]

        XCTAssertEqual(SettingArgument.keys(for: settings, matching: """
            warning: no such SDK: /no/such/sdk
            <unknown>:0: warning: no such sysroot directory: '/no/such/sdk'
            <unknown>:0: error: unable to load standard library for target 'arm64-apple-macos14.0'
            """),
                       ["swift.compiler.sdk"])
    }

    // MARK: - Source the tool quoted back

    // Both compilers print the source around an error, so the phrases would otherwise be
    // matched against the user's own text. These two are what `clang -c snippet2.c` and
    // `swiftc -c snippet.swift` print for files whose offending line contains a phrase.

    func test_aPhraseInSourceClangQuotedIsNotClangComplaining() {
        let target = SettingArgument.clangTarget(key: "clang.compiler.target", value: "arm64-apple-macos14.0")

        XCTAssertFalse(target.isMentioned(in: """
            snippet2.c:1:47: error: expected ';' after top level declarator
                1 | const char *s = "error: unknown target triple"
                  |                                               ^
                  |                                               ;
            1 error generated.
            """))
    }

    func test_aPhraseInSourceSwiftcQuotedIsNotSwiftcComplaining() {
        let target = SettingArgument.swiftTarget(key: "swift.compiler.target", value: "arm64-apple-macos14.0")

        XCTAssertFalse(target.isMentioned(in: """
            snippet.swift:2:1: error: cannot find 'foo' in scope
            1 | let s = "error: unknown target triple"
            2 | foo(s)
              | `- error: cannot find 'foo' in scope
            3 |
            """))
    }

    // MARK: - Nothing matched

    func test_anOrdinaryCompileErrorNamesNoSetting() {
        let settings: [SettingArgument] = [
            .clangTarget(key: "clang.compiler.target", value: "arm64-apple-macos14.0"),
            .clangSysroot(key: "clang.preprocessor.sdkPath", value: "/no/such/sdk"),
            .swiftTarget(key: "swift.compiler.target", value: "arm64-apple-macos14.0"),
            .swiftSDK(key: "swift.compiler.sdk", value: "macosx"),
        ]

        XCTAssertEqual(SettingArgument.keys(for: settings, matching: """
            bad.c:1:1: error: unknown type name 'itn'
                1 | itn main(void){return 0;}
                  | ^
            1 error generated.
            """), [])
    }
}

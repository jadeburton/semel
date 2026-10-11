//
//  ClangAuditedRegionsTests.swift
//  SemelClangTests
//
//  `clang -E` drops `#pragma clang arc_cf_code_audited`, so a source that hands an
//  Objective-C object to a Core Foundation function with a plain cast compiles in one step
//  and not in two (B-77 item 4). The preprocessor writes the regions back where the
//  headers had them; text no region touches is left as it was.
//

@testable import SemelClang
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ClangAuditedRegionsTests: SemelClangTestCase {

    // MARK: - Reading a header

    /// The SDK's spelling and the pragma written out both open and close a region, and the
    /// lines that include another file are noted only for a file with a region.
    func test_aHeadersRegionsAreReadInBothSpellings() {
        let header = Array("""
            #include "Base.h"
            CF_IMPLICIT_BRIDGING_ENABLED
            void CFOne(void);
            CF_IMPLICIT_BRIDGING_DISABLED
            #pragma clang arc_cf_code_audited begin
            void CFTwo(void);
            #pragma clang arc_cf_code_audited end
            """.utf8)

        let facts = ClangAuditedRegions.FileFacts(text: header)

        XCTAssertEqual(facts.regions.map(\.begin), [2, 5])
        XCTAssertEqual(facts.regions.map(\.end), [4, 7])
        XCTAssertEqual(facts.includeLines, [1])
        XCTAssertTrue(ClangAuditedRegions.FileFacts(text: Array("#include <a.h>\nint x;\n".utf8)).regions.isEmpty)
    }

    /// The macros' own definitions are no region.
    func test_theMacrosDefinitionsAreNoRegion() {
        let base = Array("""
            #define CF_IMPLICIT_BRIDGING_ENABLED _Pragma("clang arc_cf_code_audited begin")
            #define CF_IMPLICIT_BRIDGING_DISABLED _Pragma("clang arc_cf_code_audited end")
            """.utf8)

        XCTAssertTrue(ClangAuditedRegions.FileFacts(text: base).regions.isEmpty)
    }

    // MARK: - Writing the regions back

    private let header = Array("""
        #include "Base.h"
        CF_IMPLICIT_BRIDGING_ENABLED
        void CFAppend(void *array);
        CF_IMPLICIT_BRIDGING_DISABLED
        void CFOther(void);
        """.utf8)

    private func facts(_ path: String) -> ClangAuditedRegions.FileFacts {
        path == "/SDK/CFArray.h" ? ClangAuditedRegions.FileFacts(text: header) : .none
    }

    /// The pragma pair goes around the declarations the region covers, with a line marker
    /// after the opening putting the header's numbering and its system flag back.
    func test_theRegionIsWrittenAroundTheTextItCovers() {
        let preprocessed = Array("""
            # 1 "t.m"
            # 1 "/SDK/CFArray.h" 1 3
            # 1 "/SDK/Base.h" 1 3
            typedef int CFIndex;
            # 2 "/SDK/CFArray.h" 2 3

            void CFAppend(void *array);

            void CFOther(void);
            # 2 "t.m" 2
            int main(void) { return 0; }
            """.utf8)

        let kept = String(decoding: ClangAuditedRegions.keepingRegions(in: preprocessed, facts: facts), as: UTF8.self)

        XCTAssertEqual(kept, """
            # 1 "t.m"
            # 1 "/SDK/CFArray.h" 1 3
            # 1 "/SDK/Base.h" 1 3
            typedef int CFIndex;
            # 2 "/SDK/CFArray.h" 2 3

            #pragma clang arc_cf_code_audited begin
            # 3 "/SDK/CFArray.h" 3
            void CFAppend(void *array);

            #pragma clang arc_cf_code_audited end
            # 5 "/SDK/CFArray.h" 3
            void CFOther(void);
            # 2 "t.m" 2
            int main(void) { return 0; }
            """)
    }

    /// A region whose file is left before it closes is closed where it is left, and a text
    /// no region touches comes back as the same bytes.
    func test_aRegionClosesWhereItsFileIsLeftAndOtherTextIsUntouched() {
        let unclosed = Array("""
            # 1 "/SDK/CFArray.h" 1 3
            # 3 "/SDK/CFArray.h" 3
            void CFAppend(void *array);
            # 2 "t.m" 2
            int x;
            """.utf8)
        let kept = String(decoding: ClangAuditedRegions.keepingRegions(in: unclosed) { path in
            path == "/SDK/CFArray.h"
                ? ClangAuditedRegions.FileFacts(text: Array("CF_IMPLICIT_BRIDGING_ENABLED\n\nvoid CFAppend(void *array);\n\n\nCF_IMPLICIT_BRIDGING_DISABLED\n".utf8))
                : .none
        }, as: UTF8.self)
        XCTAssertTrue(kept.contains("void CFAppend(void *array);\n#pragma clang arc_cf_code_audited end\n# 2 \"t.m\" 2"), kept)

        let plain = Array("# 1 \"t.m\"\n# 1 \"/SDK/Other.h\" 1 3\nint y;\n# 2 \"t.m\" 2\nint x;\n".utf8)
        XCTAssertEqual(ClangAuditedRegions.keepingRegions(in: plain, facts: facts), plain)
    }

    // MARK: - The real clang

    /// SPMySQL's cast, `(CFMutableArrayRef)rows` handed to `CFArrayAppendValue` under ARC:
    /// preprocessed by the node and compiled by the node, as the build splits it, the object
    /// is written, where the text `-E` writes is refused for want of a bridged cast. A C
    /// source, which no region concerns, preprocesses to what clang wrote.
    func test_aPlainCastToAnAuditedFunctionCompilesAcrossTheTwoStages() throws {
        let clang = try XCTUnwrap(ClangToolDiscovery.locate("clang"))
        let sdkPath = try XCTUnwrap(SemelClang.sdkPath(forPlatform: .macos))
        let descriptor = ToolDescriptor(name: "clang", version: "real-clang", platform: "macOS", architecture: "arm64", recursiveHash: nil)
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: try LocalFileSystemTool(localPath: clang))
        let settings = """
            toolDescriptor.name=clang
            toolDescriptor.version=real-clang
            toolDescriptor.platform=macOS
            toolDescriptor.architecture=arm64
            target=arm64-apple-macosx13.5
            sdkPath=\(sdkPath)
            cStandard=gnu11
            objectiveCARC=true
            """
        let source = """
            #import <Foundation/Foundation.h>
            void append(NSMutableArray *rows) { CFArrayAppendValue((CFMutableArrayRef)rows, NULL); }
            """

        func preprocess(_ path: String, _ text: String) throws -> NodeValue {
            let node = try ClangPreprocessor(thisNode: NodeRecord(id: 1, kind: ClangPreprocessor.kind))
            return try XCTUnwrap(node.process(input: ProcessInput(inputValues: [
                ClangPreprocessor.configuration:   ["configuration": .value(try settings.intern())],
                ClangPreprocessor.sourceFileInput: [path: .value(try text.intern())],
                ClangPreprocessor.includeFileLists: [path: .value(try "".intern())],
                ClangPreprocessor.headerInputFiles: [:],
            ])).outputValues[ClangPreprocessor.output])
        }

        let preprocessed = try preprocess("src/rows.m", source)
        XCTAssertTrue(try preprocessed.expectValue().resolveAsString().contains("#pragma clang arc_cf_code_audited begin"))
        let compiler = try ClangCompiler(thisNode: NodeRecord(id: 2, kind: ClangCompiler.kind))
        let object = try XCTUnwrap(compiler.process(input: ProcessInput(inputValues: [
            ClangCompiler.configuration: ["configuration": .value(try settings.intern())],
            ClangCompiler.input:         ["src/rows.m.p": preprocessed],
        ])).outputValues[ClangCompiler.output])
        XCTAssertNil(object.errorDocument, "\(String(describing: object.errorDocument))")
        XCTAssertNotNil(try? object.expectValue())

        let plainC = try preprocess("src/plain.c", "#include <CoreFoundation/CoreFoundation.h>\nint main(void) { return 0; }\n")
        XCTAssertFalse(try plainC.expectValue().resolveAsString().contains("arc_cf_code_audited"),
                       "a C source is no ARC source, and its text is clang's")
    }
}

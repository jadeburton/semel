// ClangIncludeFinder.swift
// semel
//
// Takes the .c or .h source files wired to its input port and outputs a
// newline-separated list of the quoted #include paths found in them (system
// angle-bracket includes are intentionally ignored).

import Foundation
import SemelNodeKit
import SemelDatabaseModels

public struct ClangIncludeFinder: Node {
    public static let kind: UInt = 15

    /// 2: a source nobody pushed lists no includes (B-79), where version 1 failed on it.
    /// 3: `.` and `..` in a quoted include are resolved against the source's folder.
    /// 4: a quoted `#import` is listed as a quoted `#include` is (B-77).
    /// 5: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    public static let implementationVersion = 5

    // MARK: Ports

    static let sourceFileInputPort = "sourceFile"
    static let includePathListOutputPort = "includePathList"

    /// An absent source is tolerated, and lists no includes: the preprocessor asks for a
    /// finder on every header a quoted include names, and a header that does not exist is
    /// clang's to judge, not the report's (`ClangPreprocessor`'s `absentHeaderPaths`).
    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(sourceFileInputPort, .many)],
        outputPorts: [includePathListOutputPort],
        inputPortsToleratingAbsentValue: [sourceFileInputPort]
    )

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    // MARK: Include extraction

    /// Returns a deduplicated, ordered list of quoted #include paths found in
    /// `sourceFileContent`, ignoring anything inside block or line comments.
    static func extractIncludePaths(sourceFileContent: String) -> [String] {
        var text = sourceFileContent

        // Remove block comments
        if let blockCommentRegex = try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/") {
            text = blockCommentRegex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }

        // Remove line comments //...
        if let lineCommentRegex = try? NSRegularExpression(pattern: "//.*") {
            text = lineCommentRegex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }

        // Match:  #include "file.h"  and Objective-C's  #import "file.h"  (quoted only;
        // angle-bracket includes are ignored). An `@import Foundation;` names a module, not
        // a file: nothing here can push it, and the preprocessor loads it from the SDK.
        let pattern = #"(?m)^[ \t]*#[ \t]*(?:include|import)[ \t]*"([^"]+)""#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var results: [String] = []
        var seen = Set<String>()

        for match in matches where match.numberOfRanges >= 2 {
            let path = ns.substring(with: match.range(at: 1))
            if seen.insert(path).inserted {
                results.append(path)
            }
        }

        return results
    }

    // MARK: Processing

    struct ClangIncludeFinderInputs {
        let inputSourceFiles: [FileNameAndContent]

        init(input: ProcessInput) throws {
            let sourceFiles = try input.wires(on: ClangIncludeFinder.sourceFileInputPort)

            var inputSourceFiles: [FileNameAndContent] = []

            // Sorted, not straight out of the dictionary: each file's include paths are
            // concatenated into the one value this node outputs, and a Dictionary's
            // iteration order is seeded per process, so an unsorted walk gives the same
            // set of sources a different output hash from one run to the next (B-04).
            for (headerFileName, nodeValue) in sourceFiles.sorted(by: { $0.key < $1.key }) {
                // A file nobody pushed does not exist and includes nothing. It is here
                // because a quoted include named it, possibly under a conditional that is
                // false (B-79); the preprocessor leaves it to clang whether that matters.
                if case .noValue(reason: .initializing) = nodeValue {
                    continue
                }
                inputSourceFiles.append(.init(filePath: headerFileName, hash: try nodeValue.expectValue()))
            }

            self.inputSourceFiles = inputSourceFiles
        }
    }

    struct ClangIncludeFinderOutputs {
        let includePathList: NodeValue

        func asProcessOutput() throws -> ProcessOutput {
            .init(outputValues: [ClangIncludeFinder.includePathListOutputPort: includePathList], inputWireSpecs: [:])
        }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: ClangIncludeFinderInputs(input: input)).asProcessOutput()
    }

    func process(inputs: ClangIncludeFinderInputs) throws -> ClangIncludeFinderOutputs {
        var aggregatedIncludePaths: [String] = []

        for sourceFileValue in inputs.inputSourceFiles {
            let containingFolderOfSourceFile = Path(sourceFileValue.filePath).deletingLastComponent ?? .empty
            let sourceContent = (try? sourceFileValue.contentAsString) ?? ""

            // Resolved, so `../hello.h` from `src/lib/` names the node `src/hello.h`. An
            // include that climbs above the file system names no node and is left out:
            // clang, not finding it beside the source, reports it as its own error.
            aggregatedIncludePaths += Self.extractIncludePaths(sourceFileContent: sourceContent)
                .compactMap { (containingFolderOfSourceFile / Path($0)).resolvingDotSegments?.string }
        }

        // One path per line throughout, including at the seam between two sources: the
        // reader of this value splits it on newlines, so a source's last path written
        // hard against the next source's first would name a file that does not exist.
        // The sources arrive in wire-key order, so the value is the same twice (B-04).
        return .init(includePathList: .value(try aggregatedIncludePaths.joined(separator: "\n").intern()))
    }
}

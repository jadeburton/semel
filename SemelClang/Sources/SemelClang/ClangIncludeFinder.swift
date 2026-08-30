// ClangIncludeFinder.swift
// build_system
//
// Takes a .c or .h source file as input and outputs a newline-separated list
// of quoted #include paths found in that file (system angle-bracket includes
// are intentionally ignored).

import Foundation
import SemelNodeKit
import SemelDatabaseModels

public struct ClangIncludeFinder: Node {
    public static let kind: UInt = 15

    // MARK: Ports

    static let sourceFileInputPort = "sourceFile"
    static let includePathListOutputPort = "includePathList"

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(sourceFileInputPort)],
        outputPorts: [includePathListOutputPort]
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

        // Match:  #include "file.h"  (quoted only; angle-bracket includes are ignored)
        let pattern = #"(?m)^[ \t]*#[ \t]*include[ \t]*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

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
            let sourceFiles = input.inputValues[ClangIncludeFinder.sourceFileInputPort]!

            var inputSourceFiles: [FileNameAndContent] = []

            for (headerFileName, nodeValue) in sourceFiles {
                inputSourceFiles.append(.init(filePath: headerFileName, hash: try nodeValue.expectValue()))
            }

            self.inputSourceFiles = inputSourceFiles
        }
    }

    struct ClangIncludeFinderOutputs {
        let includePathList: NodeValue

        func asProcessOutput() throws -> ProcessOutput {
            .init(outputValues: [ClangIncludeFinder.includePathListOutputPort: includePathList], inputWireExpectations: [:])
        }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: ClangIncludeFinderInputs(input: input)).asProcessOutput()
    }

    func process(inputs: ClangIncludeFinderInputs) throws -> ClangIncludeFinderOutputs {
        var aggregatedIncludePathList = ""

        for sourceFileValue in inputs.inputSourceFiles {
            let containingFolderOfSourceFile = Path(sourceFileValue.filePath).deletingLastComponent ?? .empty
            let sourceContent = (try? sourceFileValue.contentAsString) ?? ""
            let includePathList = Self.extractIncludePaths(sourceFileContent: sourceContent).map { (containingFolderOfSourceFile / $0).string }

            aggregatedIncludePathList.append(includePathList.joined(separator: "\n"))
        }

        return .init(includePathList: .value(try aggregatedIncludePathList.intern()))
    }
}

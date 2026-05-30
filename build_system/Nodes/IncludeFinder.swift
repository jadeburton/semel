// IncludeFinder.swift
// build_system
//
// Takes a .c or .h source file as input and outputs a newline-separated list
// of quoted #include paths found in that file (system angle-bracket includes
// are intentionally ignored).

import Foundation

final class IncludeFinder: NodeType {
    static let kind: UInt = 15

    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {}

    required init() {}

    required init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
    }

    // MARK: Ports

    static let sourceFileInputPort = NodeKindDescriptor.InputPort(index: 0,
                                                                  name: "sourceFile",
                                                                  kind: .value(dataType: .utf8Text),
                                                                  maximumConnections: 1,
                                                                  minimumConnections: 1,
                                                                  cascadingDelete: true)

    static let includePathListOutputPort = NodeKindDescriptor.OutputPort(index: 0,
                                                                         name: "includePathList",
                                                                         kind: .value(dataType: .utf8Text))

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind,
              inputs: [Self.sourceFileInputPort],
              outputs: [Self.includePathListOutputPort])
    }

    // MARK: Include extraction

    /// Returns a deduplicated, ordered list of quoted #include paths found in
    /// `sourceFileContent`, ignoring anything inside block or line comments.
    private func extractIncludePaths(sourceFileContent: String) -> [String] {
        var text = sourceFileContent

        // Remove block comments /* ... */
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

    func process() throws {
        var firstMetadata: (any PolySerializable)?
        var aggregatedIncludePathList = ""

        for sourceFileValue in try readAllValuesFromInputPort(Self.sourceFileInputPort) {
            switch sourceFileValue.kind {

            case .value(let payload, let metadata):
                let sourceText = try payload.expectDataObjectHash().resolveAsString()
                let includePathList = extractIncludePaths(sourceFileContent: sourceText)
                    .joined(separator: "\n")
                firstMetadata = metadata
                aggregatedIncludePathList.append(includePathList)

            case .noValue:
                throw NodeError.missingInput
            }
        }

        try writeToOutputPort(Self.includePathListOutputPort,
                              value: .value(.dataObjectHash(aggregatedIncludePathList.intern()),
                                            metadata: firstMetadata))
    }
}

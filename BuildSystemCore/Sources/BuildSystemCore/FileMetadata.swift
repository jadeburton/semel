// FileMetadata.swift
// build_system
//
// Metadata that travels alongside file content on a dedicated "fileMetadata"
// output port. FilePlugin reads it when copying a file to the external file
// system and applies it (e.g. chmod).

import Foundation

public struct FileMetadata: Codable {
    /// Unix mode bits. `nil` is treated as `defaultMode` by the consumer.
    public var mode: UInt16?

    public static let portName = "fileMetadata"
    public static let defaultMode: UInt16 = 0o644
    public static let executableMode: UInt16 = 0o755

    public init(mode: UInt16? = nil) { self.mode = mode }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func decode(from json: String) -> FileMetadata? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FileMetadata.self, from: data)
    }
}

/// Nodes that produce a file and also know its Unix metadata conform to this
/// protocol. `FilePlugin.cp` reads it after writing file content and applies
/// the mode via `chmod`.
public protocol FileMetadataProvider {
    func readFileMetadata() throws -> FileMetadata?
}

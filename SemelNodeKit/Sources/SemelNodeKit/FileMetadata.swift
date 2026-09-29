// FileMetadata.swift
// semel
//
// Metadata that travels alongside file content on a dedicated "fileMetadata"
// output port. FilePlugin reads it when copying a file to the external file
// system and applies it (e.g. chmod).

import Foundation

public struct FileMetadata: Codable, Equatable {
    /// Unix mode bits. `nil` is treated as `defaultMode` by the consumer.
    public var mode: UInt16?

    /// Where the file is a symbolic link to, relative to its folder, as the link holds it —
    /// `Versions/Current/Tiny` — or nil for a file. On the metadata rather than on a node
    /// of its own, so that what reads a file's bytes reads a link's as it always did: the
    /// bytes beside this are what the link names, and only what carries the file's shape —
    /// a tree, a product, the export — reads that it is a link (B-77).
    public var symbolicLinkTarget: String?

    /// The output port a node declares to have its file's mode carried into a tree or to
    /// `cp`. A consumer that asks for modes has it wired beside the file automatically
    /// (`NodeDescriptor.fileMetadataInputPorts`, `GraphSpecNode.wiringFileMetadata()`).
    public static let portName = "fileMetadata"
    /// The port whose file the metadata describes, on every node that publishes both: a
    /// wire read from a linker's `infoLog` is not the executable, and takes no mode from it.
    public static let describedPortName = "output"
    public static let executableMode: UInt16 = 0o755
    public static let defaultMode: UInt16 = 0o644

    public init(mode: UInt16? = nil, symbolicLinkTarget: String? = nil) {
        self.mode = mode
        self.symbolicLinkTarget = symbolicLinkTarget
    }

    /// Keys sorted, so one metadata is one document and so one hash: a file's is
    /// `{"mode":420}` and a link's `{"mode":420,"symbolicLinkTarget":"A"}`, whatever order
    /// an encoder would otherwise choose.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func decode(from json: String) -> FileMetadata? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(FileMetadata.self, from: data)
    }

    /// The metadata a `fileMetadata` wire carries, or none — a file with the default mode —
    /// where there is no wire or no value on it. A value missing here is never the node's
    /// to report: the file it describes carries the same state on its own wire, and that is
    /// the one demanded.
    public static func metadata(of metadataValue: NodeValue?) -> FileMetadata {
        guard case .value(let hash) = metadataValue,
              let json = try? hash.resolveAsString(),
              let metadata = decode(from: json) else {
            return FileMetadata()
        }
        return metadata
    }

    /// The mode a `fileMetadata` wire carries, or the default.
    public static func mode(of metadataValue: NodeValue?) -> UInt16 {
        metadata(of: metadataValue).mode ?? defaultMode
    }
}

/// Nodes that produce a file and also know its Unix metadata conform to this
/// protocol. `FilePlugin.cp` reads it after writing file content and applies
/// the mode via `chmod`.
public protocol FileMetadataProvider {
    func readFileMetadata() throws -> FileMetadata?
}

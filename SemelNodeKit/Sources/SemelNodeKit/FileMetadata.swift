// FileMetadata.swift
// semel
//
// Metadata that travels alongside file content on a dedicated "fileMetadata"
// output port. FilePlugin reads it when copying a file to the external file
// system and applies it (e.g. chmod).

import Foundation

public struct FileMetadata: Codable {
    /// Unix mode bits. `nil` is treated as `defaultMode` by the consumer.
    public var mode: UInt16?

    /// The output port a node declares to have its file's mode carried into a tree or to
    /// `cp`. A consumer that asks for modes has it wired beside the file automatically
    /// (`NodeDescriptor.fileMetadataInputPorts`, `GraphSpecNode.wiringFileMetadata()`).
    public static let portName = "fileMetadata"
    /// The port whose file the metadata describes, on every node that publishes both: a
    /// wire read from a linker's `infoLog` is not the executable, and takes no mode from it.
    public static let describedPortName = "output"
    public static let executableMode: UInt16 = 0o755
    public static let defaultMode: UInt16 = 0o644

    public init(mode: UInt16? = nil) { self.mode = mode }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func decode(from json: String) -> FileMetadata? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(FileMetadata.self, from: data)
    }

    /// The mode a `fileMetadata` wire carries, or the default where there is no wire or no
    /// value on it. A value missing here is never the node's to report: the file it
    /// describes carries the same state on its own wire, and that is the one demanded.
    public static func mode(of metadataValue: NodeValue?) -> UInt16 {
        guard case .value(let hash) = metadataValue,
              let json = try? hash.resolveAsString(),
              let mode = decode(from: json)?.mode else {
            return defaultMode
        }
        return mode
    }
}

/// Nodes that produce a file and also know its Unix metadata conform to this
/// protocol. `FilePlugin.cp` reads it after writing file content and applies
/// the mode via `chmod`.
public protocol FileMetadataProvider {
    func readFileMetadata() throws -> FileMetadata?
}

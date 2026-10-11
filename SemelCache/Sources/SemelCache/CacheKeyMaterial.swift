// CacheKeyMaterial.swift
// SemelCache
//
// What a cache key is taken of, and the one place a key is computed. The engine builds the
// material from a node and its inputs; everything after that — the text, the hash, the
// encoding stored with an entry — is here, so that an engine and a cache server that never
// shares its process compute the same key from the same material.

import Foundation
import SemelNodeKit

/// One line of a key's material: the word that says what the line is about, and the thing
/// itself as JSON. Keys sorted so the text is the same on two machines, slashes left alone
/// so a wire's path reads as the path it is, and JSON rather than plain text so a value
/// holding a newline stays on its line and cannot forge another.
private func cacheKeyLine(_ keyword: String, _ item: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return "\(keyword) \(String(decoding: try encoder.encode(item), as: UTF8.self))"
}

/// One wired input as it contributes to a cache key: which port and which wire it arrived
/// on, and what it carried. All three are part of the build's identity.
///
/// Coded by hand so that a line reads `"value":"<hash>"` rather than the two wrappers the
/// synthesized encoding of a two-case enum over a string gives — the field a reader of a
/// diff scans is the one worth keeping short. A wire carrying no value keeps its reason
/// whole under a key of its own: which case it is *and* what that case carries, because
/// two failures with different messages are two different builds and must not hash alike.
public struct CacheKeyEntry: Codable {
    public let port: String
    public let wire: String
    public let value: NodeValue

    public init(port: String, wire: String, value: NodeValue) {
        self.port  = port
        self.wire  = wire
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case port
        case wire
        case value
        case noValue
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(port, forKey: .port)
        try container.encode(wire, forKey: .wire)
        switch value {
        case .value(let hash):
            try container.encode(hash, forKey: .value)
        case .noValue(let reason):
            try container.encode(reason, forKey: .noValue)
        }
    }

    /// The hash decodes as a `String`, which is what `DataObjectHash` is: the alias lives
    /// in the database models, which this package does not link.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decode(String.self, forKey: .port)
        wire = try container.decode(String.self, forKey: .wire)
        if let hash = try container.decodeIfPresent(String.self, forKey: .value) {
            value = .value(hash)
        } else {
            value = .noValue(reason: try container.decode(NoValueReason.self, forKey: .noValue))
        }
    }
}

/// One of the node's own properties as it contributes to a cache key.
public struct CacheKeyProperty: Codable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key   = key
        self.value = value
    }
}

/// What a node reads from outside its inputs, as the node itself describes it — an SDK's
/// fingerprint and the like. A struct rather than a bare string so the text is JSON on one
/// line of the material, whatever the node put in it.
struct CacheKeyFingerprint: Codable {
    let fingerprint: String
}

/// Everything a cache key is taken of, as structure. Stored with the entry the key names,
/// so a mismatch between two builds is a diff of two of these and a key can be recomputed
/// where neither graph is.
///
/// The order of `inputs` is part of the key and is the order the engine builds them in —
/// static ports sorted, then dynamic ports sorted, wires sorted within each port. An
/// array, not a dictionary, so what is stored is the order that was hashed.
public struct CacheKeyMaterial: Codable {
    public let nodeType: String
    public let implementationVersion: Int
    public let properties: [CacheKeyProperty]
    /// What the node declared it reads outside its inputs, or nil where it reads nothing
    /// there — which is most nodes.
    public let fingerprint: String?
    public let inputs: [CacheKeyEntry]

    public init(nodeType: String,
                implementationVersion: Int,
                properties: [CacheKeyProperty],
                fingerprint: String?,
                inputs: [CacheKeyEntry]) {
        self.nodeType              = nodeType
        self.implementationVersion = implementationVersion
        self.properties            = properties
        self.fingerprint           = fingerprint
        self.inputs                = inputs
    }

    /// The text the key is the hash of: one line per thing the key covers, each named by
    /// the word it starts with and each carrying JSON, so a value holding a newline cannot
    /// forge a line and two materials differing in one input differ in one line.
    public func canonicalText() throws -> String {
        var lines = ["node \(nodeType)@\(implementationVersion)"]
        lines += try properties.map { try cacheKeyLine("property", $0) }
        if let fingerprint {
            lines.append(try cacheKeyLine("fingerprint", CacheKeyFingerprint(fingerprint: fingerprint)))
        }
        lines += try inputs.map { try cacheKeyLine("input", $0) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The cache key itself. The one place a key is computed.
    public func cacheKey() throws -> String {
        Sha256.hash(Array(try canonicalText().utf8))
    }
}

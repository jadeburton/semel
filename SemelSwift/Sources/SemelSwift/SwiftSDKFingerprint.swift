// SwiftSDKFingerprint.swift
// SemelSwift
//
// The Swift tools' half of B-47: the compiler and the linker pass `-sdk <path>` and
// compile against whatever is behind it, so they put the fingerprint of that tree into
// their cache key (`sdkCacheKeyMaterial` in SemelNodeKit, which says why the key and the
// machine file's `sdkFingerprint` line are both needed). The SDK is named in the
// configuration, `sdk`, and resolved to a path by the same query the nodes use to run.

import Foundation
import SemelNodeKit

/// The Swift tools' contribution to their cache key: the SDK the configuration names and
/// the fingerprint of what is behind it. Shared by the compiler and the linker, the two
/// nodes that pass `-sdk`.
func sdkCacheKeyMaterial(configuration properties: [String: String]) -> String? {
    let sdk = properties["sdk"] ?? defaultSDKName
    return resolveSDKPath(sdk: sdk).flatMap { sdkCacheKeyMaterial(sdkNamed: sdk, atPath: $0) }
}

/// The configuration on the wire as properties, empty when nothing is wired there. Read
/// from the raw text rather than through the tool's configuration type, which requires
/// every other setting to be present — and the key has to be computable before that is
/// known. Read once per key: resolving the value reads the blob from the object store and
/// verifies its hash, and both halves of the material want the same dictionary.
private func configurationProperties(input: ProcessInput, configurationPort: String) throws -> [String: String] {
    guard case .value(let hash)? = try input.onlyWire(onOptionalPort: configurationPort)?.value else {
        return [:]
    }
    return [String: String](plainText: try hash.resolveAsString())
}

/// Everything a Swift tool reads outside its inputs: the SDK behind `-sdk`, and the binary
/// behind the tool version its configuration names (B-17). Each line stands on its own, so
/// a tool that finds only one of the two still declares it.
func swiftToolCacheKeyMaterial(input: ProcessInput, configurationPort: String) throws -> String? {
    let properties = try configurationProperties(input: input, configurationPort: configurationPort)
    let lines = [sdkCacheKeyMaterial(configuration: properties),
                 toolBinaryCacheKeyMaterial(configuration: properties)].compactMap { $0 }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

extension SwiftCompiler {
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try swiftToolCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }
}

extension SwiftLinker {
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try swiftToolCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }
}

// ClangSDKFingerprint.swift
// SemelClang
//
// What the clang tools read outside their inputs, as cache-key material: the binary behind
// the tool version the configuration names (B-17), and the SDK tree at `sdkPath` (B-47).
// The preprocessor reads the SDK's headers through `-isysroot`, the compiler its modules
// when a source loads them, the linker its `usr/lib` stubs and its frameworks; the path is
// in the key already, on the configuration wire, but what is behind it is not unless it is
// fingerprinted here. Why the key and the machine file's `sdkFingerprint` line are both
// needed is said where the fingerprint lives, in SemelNodeKit.

import Foundation
import SemelNodeKit

/// The configuration on the wire as properties, empty when nothing is wired there. Read
/// from the raw text rather than through the tool's configuration type, which requires
/// every other setting to be present: the key has to be computable before that is known.
/// Read once per key, since both halves of the material want the same dictionary.
private func configurationProperties(input: ProcessInput, configurationPort: String) throws -> [String: String] {
    guard case .value(let hash)? = try input.onlyWire(onOptionalPort: configurationPort)?.value else {
        return [:]
    }
    return [String: String](plainText: try hash.resolveAsString())
}

/// Both lines, each standing on its own, so a tool that finds only one still declares it.
/// A build that configures no `sdkPath` reads no SDK and keys on the binary alone.
func clangToolCacheKeyMaterial(input: ProcessInput, configurationPort: String) throws -> String? {
    let properties = try configurationProperties(input: input, configurationPort: configurationPort)
    let lines = [sdkCacheKeyMaterial(sdkPathIn: properties),
                 toolBinaryCacheKeyMaterial(configuration: properties)].compactMap { $0 }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

extension ClangPreprocessor {
    /// Two builds of one clang version preprocess differently, and so do two SDKs under one
    /// path: the headers `-isysroot` finds are the SDK's.
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try clangToolCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }
}

extension ClangCompiler {
    /// The SDK reaches a compile through the modules a source loads; one that loads none
    /// still keys on it, which costs a recompile on an SDK change and nothing else.
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try clangToolCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }
}

extension ClangLinker {
    /// The stubs in the SDK's `usr/lib` and its frameworks are what a link resolves against.
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try clangToolCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }
}

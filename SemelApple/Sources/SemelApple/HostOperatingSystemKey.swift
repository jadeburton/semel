// HostOperatingSystemKey.swift
// SemelApple
//
// The key material of a tool that works through the system's frameworks: its binary's
// fingerprint and the system's build (B-153).

import Foundation
import SemelNodeKit

/// `toolBinary` — a node's `toolBinaryCacheKeyMaterial` — and the system's build, each on a
/// line of its own; nil when neither is known.
func appleToolCacheKeyMaterial(_ toolBinary: String?) -> String? {
    let lines = [toolBinary, HostOperatingSystem.cacheKeyMaterial].compactMap { $0 }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

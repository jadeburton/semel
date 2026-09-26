//
//  Platform.swift
//  SemelNodeKit
//
//  A platform a build is for, as the SDK, the target triple and the device list spell it.
//  Here rather than in the Swift tool because a machine setting is one per platform — the
//  SDK's path and identity — and every plugin that declares one needs the type (B-109).
//


/// What the generated config builds for.
public enum Platform: String, CaseIterable {
    case macos = "macos"
    case iosSimulator = "ios-simulator"

    /// The SDK name `xcrun --sdk` and the Swift tools' `sdk` setting take.
    public var sdkName: String {
        switch self {
        case .macos:        return "macosx"
        case .iosSimulator: return "iphonesimulator"
        }
    }

    /// The name a manifest's `platforms` uses for it.
    public var manifestPlatformName: String {
        switch self {
        case .macos:        return "macos"
        case .iosSimulator: return "ios"
        }
    }

    /// The devices `actool --target-device` compiles for, comma-joined as the setting is
    /// written.
    public var targetDevices: String {
        switch self {
        case .macos:        return "mac"
        case .iosSimulator: return "iphone,ipad"
        }
    }

    /// The target triple at a deployment version.
    public func target(deploymentVersion: String) -> String {
        switch self {
        case .macos:        return "arm64-apple-macosx\(deploymentVersion)"
        case .iosSimulator: return "arm64-apple-ios\(deploymentVersion)-simulator"
        }
    }
}

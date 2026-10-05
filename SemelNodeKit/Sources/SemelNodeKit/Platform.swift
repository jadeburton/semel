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

    /// The platform whose SDK `xcrun --sdk` calls `sdkName`, when it is one prepare
    /// builds for: how a formula's `sdk:` is read back as a platform.
    public init?(sdkName: String) {
        guard let platform = Self.allCases.first(where: { $0.sdkName == sdkName }) else {
            return nil
        }
        self = platform
    }

    /// The platform `target` is the triple of, at any deployment version: how a config's
    /// `target` setting is read back, so that what a config already holds is compared as
    /// a platform rather than as text. Nil for a triple no case writes — another
    /// architecture, a device rather than the simulator.
    public init?(target: String) {
        guard let platform = Self.allCases.first(where: { $0.deploymentVersion(inTarget: target) != nil }) else {
            return nil
        }
        self = platform
    }

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
        targetPrefix + deploymentVersion + targetSuffix
    }

    /// The deployment version `target` carries when it is this platform's triple, nil
    /// otherwise. The version must be dotted digits, so `arm64-apple-ios18.0-simulator`
    /// is never read as some other triple at version `18.0-simulator`.
    public func deploymentVersion(inTarget target: String) -> String? {
        guard target.hasPrefix(targetPrefix), target.hasSuffix(targetSuffix),
              target.count > targetPrefix.count + targetSuffix.count else {
            return nil
        }
        let version = target.dropFirst(targetPrefix.count).dropLast(targetSuffix.count)
        guard version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else {
            return nil
        }
        return String(version)
    }

    /// The triple on either side of the deployment version: one spelling, which
    /// `target(deploymentVersion:)` writes and `deploymentVersion(inTarget:)` reads.
    private var targetPrefix: String {
        switch self {
        case .macos:        return "arm64-apple-macosx"
        case .iosSimulator: return "arm64-apple-ios"
        }
    }

    private var targetSuffix: String {
        switch self {
        case .macos:        return ""
        case .iosSimulator: return "-simulator"
        }
    }
}

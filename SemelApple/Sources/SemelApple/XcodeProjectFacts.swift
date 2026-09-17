//
//  XcodeProjectFacts.swift
//  SemelApple
//
//  What a tool outside the engine needs to know about a project before the build:
//  `semel-swift prepare` writes a config whose target triple carries the deployment
//  version, and puts in place the xcconfig files the project names, and asks here rather
//  than reading the project itself. The reading and the evaluation are the converter's;
//  these are two questions, answered the same way.

import Foundation

public enum XcodeProjectFacts {

    /// The configuration the converter builds, and so the one whose xcconfig files count.
    static let configuration = "Debug"

    /// The `.xcconfig` files the project and its application target name for the built
    /// configuration, relative to the project's folder, in the order the converter reads
    /// them. Empty when the project has no application.
    public static func xcconfigPaths(ofProjectAt project: URL) throws -> [String] {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        guard let application = read.targets.first(where: \.isApplication) else {
            return []
        }
        return read.xcconfigPaths(for: application, configuration: configuration)
    }

    /// The names the settings of the application and the extensions it embeds still
    /// reference after evaluation for `sdk`, with the xcconfig files read from beside the
    /// project when they are there: what a missing xcconfig would have to define. Sorted,
    /// each once. Empty when the project has no application.
    public static func undefinedReferences(ofProjectAt project: URL, sdk: String) throws -> [String] {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        guard let application = read.targets.first(where: \.isApplication) else {
            return []
        }
        let folder = project.deletingLastPathComponent()
        let embedded = Set(application.embeddedExtensions)
        let targets = [application] + read.targets.filter { embedded.contains($0.productFileName) }
        var names = Set<String>()
        for target in targets {
            let settings = try XcodeBuildSettings.resolve(
                project: read, target: target, configuration: configuration, sdk: sdk,
                xcconfig: { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) },
                extra: ["TARGET_NAME": target.name])
            names.formUnion(settings.unresolvedReferences)
        }
        return names.sorted()
    }

    /// The application target's deployment target for the SDK named `sdk`
    /// (`iphonesimulator`, `macosx`), evaluated as the converter evaluates settings, with
    /// the xcconfig files read from beside the project when they are there. Nil when the
    /// project has no application or states no target.
    public static func deploymentTarget(ofProjectAt project: URL, sdk: String) throws -> String? {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        guard let application = read.targets.first(where: \.isApplication) else {
            return nil
        }
        let folder = project.deletingLastPathComponent()
        let settings = try XcodeBuildSettings.resolve(
            project: read, target: application, configuration: configuration, sdk: sdk,
            xcconfig: { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) },
            extra: ["TARGET_NAME": application.name])
        let key = sdk.hasPrefix("macosx") ? "MACOSX_DEPLOYMENT_TARGET" : "IPHONEOS_DEPLOYMENT_TARGET"
        return settings[key]
    }
}

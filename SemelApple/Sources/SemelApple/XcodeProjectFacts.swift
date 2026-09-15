//
//  XcodeProjectFacts.swift
//  SemelApple
//
//  What a tool outside the engine needs to know about a project before the build:
//  `semel-swift prepare` writes a config whose target triple carries the deployment
//  version, and asks here rather than reading the project itself. The reading and the
//  evaluation are the converter's; this is the one question, answered the same way.

import Foundation

public enum XcodeProjectFacts {

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
            project: read, target: application, configuration: "Debug", sdk: sdk,
            xcconfig: { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) },
            extra: ["TARGET_NAME": application.name])
        let key = sdk.hasPrefix("macosx") ? "MACOSX_DEPLOYMENT_TARGET" : "IPHONEOS_DEPLOYMENT_TARGET"
        return settings[key]
    }
}

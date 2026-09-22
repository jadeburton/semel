//
//  Projects.swift
//  SemelEndToEndTests
//
//  The roster. Fixtures run on every `swift test`; external projects on opt-in.
//

import Foundation

enum Projects {

    static let fixtureTimeout: TimeInterval = 120

    /// `hello.fmla` reads the shared base config from `../clang.cfg`, a sibling of the
    /// build folder rather than a file under it, so it needs its own push.
    static let cHello = Project(
        name: "c-hello",
        source: .fixture(folder: "."),
        buildFolder: "c",
        alsoPush: ["clang.cfg"],
        platform: nil,
        expectedProducts: ["hello", "hello.dylib", "config.txt"],
        buildTimeout: fixtureTimeout)

    /// The state docs/tutorial/first-node.md ends in: the C hello sources, and a formula
    /// that also counts their lines with `LineCounter` from SemelExamples. Reads the
    /// shared base config from `../clang.cfg`, so that needs its own push, as for `cHello`.
    static let tutorial = Project(
        name: "tutorial",
        source: .fixture(folder: "."),
        buildFolder: "tutorial",
        alsoPush: ["clang.cfg"],
        platform: nil,
        expectedProducts: ["hello", "hello.dylib", "config.txt", "lines.txt"],
        buildTimeout: fixtureTimeout)

    /// `6502emu.fmla` merges the shared base config from `../clang.cfg` with its own
    /// `clang.cfg`; the shared file is a sibling of the build folder, so it needs its
    /// own push.
    static let cppEmu6502 = Project(
        name: "cpp-emu6502",
        source: .fixture(folder: "."),
        buildFolder: "cpp",
        alsoPush: ["clang.cfg"],
        platform: nil,
        expectedProducts: ["emu6502"],
        buildTimeout: fixtureTimeout)

    /// MyLibrary is a path dependency beside MyApp, so it is pushed first: `build`
    /// pushes only its own folder, and the converter waits for a folder nobody pushed.
    static let swiftMyApp = Project(
        name: "swift-my-app",
        source: .fixture(folder: "."),
        buildFolder: "swift/MyApp",
        alsoPush: ["swift/MyLibrary"],
        platform: "macos",
        expectedProducts: ["MyApp"],
        buildTimeout: fixtureTimeout)

    static let swiftHelloApp = Project(
        name: "swift-hello-app",
        source: .fixture(folder: "."),
        buildFolder: "swift/HelloApp",
        platform: "ios-simulator",
        expectedProducts: ["Hello.app/Hello", "Hello.app/Info.plist", "Hello.app/PkgInfo", "Hello.app/Assets.car"],
        buildTimeout: fixtureTimeout)

    static let icecubes = Project(
        name: "icecubes",
        source: .git(url: "https://github.com/Dimillian/IceCubesApp.git",
                     commit: "3dc60a80a66db2c3a92c517b38398246ef4ea1b9",
                     subfolder: "Packages"),
        buildFolder: "Packages",
        platform: "ios-simulator",
        expectedProducts: ["libConversations.a", "libExplore.a", "libLists.a", "libNotifications.a", "libTimeline.a"],
        buildTimeout: 15 * 60,
        // Two cold builds of five minutes each are enough; the fixtures prove the third.
        twoMounts: false)

    /// The application itself, through `XcodeProjectConverter`: the whole checkout is the
    /// project's root, so `buildFolder` names the checkout (see `Project.Source.git`'s
    /// `"."` case). `Ice Cubes.app` is `PRODUCT_NAME`, not the target name; the four
    /// extensions embedded under `PlugIns/` keep their target names for both the bundle
    /// and the executable inside it — `IceCubesAppWidgetsExtensionExtension` doubled
    /// "Extension" is the project's own naming, not a typo here.
    static let icecubesApp = Project(
        name: "icecubes-app",
        source: .git(url: "https://github.com/Dimillian/IceCubesApp.git",
                     commit: "3dc60a80a66db2c3a92c517b38398246ef4ea1b9",
                     subfolder: "."),
        buildFolder: "icecubes-app",
        platform: "ios-simulator",
        expectedProducts: [
            "Ice Cubes.app/Ice Cubes",
            "Ice Cubes.app/Info.plist",
            "Ice Cubes.app/Assets.car",
            "Ice Cubes.app/PlugIns/IceCubesNotifications.appex/IceCubesNotifications",
            "Ice Cubes.app/PlugIns/IceCubesShareExtension.appex/IceCubesShareExtension",
            "Ice Cubes.app/PlugIns/IceCubesActionExtension.appex/IceCubesActionExtension",
            "Ice Cubes.app/PlugIns/IceCubesAppWidgetsExtensionExtension.appex/IceCubesAppWidgetsExtensionExtension",
        ],
        buildTimeout: 15 * 60,
        mayDiffer: [
            // actool embeds a fresh UUID, pid and timestamp in the renditions it derives
            // from the app's `.icon` input (B-89); the two extensions' catalogs, compiled
            // from `.xcassets` alone, need no exemption.
            "Ice Cubes.app/Assets.car",
            // The linker picks between two duplicate `_objc_msgSend` GOT entries
            // non-deterministically wherever a target's objects carry the duplicate pair
            // (B-90); `IceCubesActionExtension` links a single entry and needs none.
            "Ice Cubes.app/Ice Cubes",
            "Ice Cubes.app/PlugIns/IceCubesNotifications.appex/IceCubesNotifications",
            "Ice Cubes.app/PlugIns/IceCubesShareExtension.appex/IceCubesShareExtension",
            "Ice Cubes.app/PlugIns/IceCubesAppWidgetsExtensionExtension.appex/IceCubesAppWidgetsExtensionExtension",
        ],
        // Two cold builds of about five minutes each are enough; the fixtures prove the third.
        twoMounts: false)

    static let fixtures: [Project] = [cHello, tutorial, cppEmu6502, swiftMyApp, swiftHelloApp]
    static let external: [Project] = [icecubes, icecubesApp]
    static let all: [Project] = fixtures + external
}

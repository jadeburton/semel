//
//  Projects.swift
//  SemelEndToEndTests
//
//  The roster. Fixtures run on every `swift test`; external projects on opt-in.
//

import Foundation

enum Projects {

    static let fixtureTimeout: TimeInterval = 120

    /// `hello.fmla` reads the machine's settings from `../semel.machine.config`, a sibling
    /// of the build folder rather than a file under it, so it needs its own push.
    static let cHello = Project(
        name: "c-hello",
        source: .fixture(folder: "."),
        buildFolder: "c",
        platform: nil,
        expectedProducts: ["hello", "hello.dylib", "config.txt"],
        buildTimeout: fixtureTimeout)

    /// The state docs/tutorial/first-node.md ends in: the C hello sources, and a formula
    /// that also counts their lines with `LineCounter` from SemelExamples. Reads the
    /// machine's settings from `../semel.machine.config`, so that needs its own push, as
    /// for `cHello`.
    static let tutorial = Project(
        name: "tutorial",
        source: .fixture(folder: "."),
        buildFolder: "tutorial",
        platform: nil,
        expectedProducts: ["hello", "hello.dylib", "config.txt", "lines.txt"],
        buildTimeout: fixtureTimeout)

    /// `6502emu.fmla` lays its own `semel.config` over the machine's settings in
    /// `../semel.machine.config`, by hand; the machine file is a sibling of the build
    /// folder, so it needs its own push.
    static let cppEmu6502 = Project(
        name: "cpp-emu6502",
        source: .fixture(folder: "."),
        buildFolder: "cpp",
        platform: nil,
        expectedProducts: ["emu6502"],
        buildTimeout: fixtureTimeout)

    /// MyLibrary is a path dependency beside MyApp: `build` pushes its own folder, the
    /// converter reports the folder it needs, and `build` follows it (B-110).
    static let swiftMyApp = Project(
        name: "swift-my-app",
        source: .fixture(folder: "."),
        buildFolder: "swift/MyApp",
        platform: "macos",
        expectedProducts: ["MyApp"],
        buildTimeout: fixtureTimeout)

    static let swiftHelloApp = Project(
        name: "swift-hello-app",
        source: .fixture(folder: "."),
        buildFolder: "swift/HelloApp",
        platform: "ios-simulator",
        expectedProducts: ["Hello.app/Hello", "Hello.app/Info.plist", "Hello.app/PkgInfo", "Hello.app/Assets.car"],
        buildTimeout: fixtureTimeout,
        onlyUnder: "Hello.app")

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
        twoMounts: false,
        // And the fourth: a perturbed build costs another five minutes here, while the
        // fixtures cover every toolchain this project uses in seconds.
        perturbed: false)

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
        // A cold build takes several minutes locally; `prepare` shares the same budget,
        // and the GitHub macOS runner this also has to fit is roughly half the speed.
        buildTimeout: 25 * 60,
        mayDiffer: [
            // actool's output is not byte-reproducible (B-89): the `.icon` renditions it
            // derives for the app carry a fresh UUID and pid, and an asset catalog with
            // more than one appearance can have its appearance table's entry order vary
            // regardless of a `.icon` input — the widgets extension's catalog has no
            // `.icon` and still hit it. A bare name, not a full path, so the exemption
            // reaches every target's `Assets.car`.
            "Assets.car",
        ],
        // A cold build takes several minutes; the third build the fixtures prove is not
        // worth a third here, and neither is the perturbed fourth — run time is the
        // constraint for this project, not coverage: `actool`, both linkers and both
        // compilers are perturbed by the fixtures on every push.
        twoMounts: false,
        perturbed: false,
        onlyUnder: "Ice Cubes.app")

    static let fixtures: [Project] = [cHello, tutorial, cppEmu6502, swiftMyApp, swiftHelloApp]
    static let external: [Project] = [icecubes, icecubesApp]
    static let all: [Project] = fixtures + external
}

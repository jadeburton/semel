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

    static let fixtures: [Project] = [cHello, cppEmu6502, swiftMyApp, swiftHelloApp]
    static let external: [Project] = [icecubes]
    static let all: [Project] = fixtures + external
}

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
        buildTimeout: fixtureTimeout,
        executables: ["hello"])

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

    /// A C target inside a Swift package (B-55): nested sources and headers, an excluded
    /// folder and file that would fail the build if compiled, `publicHeadersPath`, and a
    /// define the sources `#error` without. The Swift executable imports the C target and
    /// the C executable, nothing Swift in it, links it through the same linker. The Swift
    /// executable also imports what NetNewsWire's packages need (B-77): an Objective-C
    /// target that `@import`s Foundation and compiles only under ARC, and C targets with an
    /// umbrella header or an umbrella directory and no module map — one of them nested in
    /// the folder of the Swift target that excludes and imports it, as Zip's Minizip is.
    static let swiftCPackage = Project(
        name: "swift-c-package",
        source: .fixture(folder: "."),
        buildFolder: "swift/CPackage",
        platform: "macos",
        expectedProducts: ["App", "ctool"],
        buildTimeout: fixtureTimeout)

    static let swiftHelloApp = Project(
        name: "swift-hello-app",
        source: .fixture(folder: "."),
        buildFolder: "swift/HelloApp",
        platform: "ios-simulator",
        expectedProducts: ["Hello.app/Hello", "Hello.app/Info.plist", "Hello.app/PkgInfo", "Hello.app/Assets.car"],
        buildTimeout: fixtureTimeout,
        onlyUnder: "Hello.app",
        executables: ["Hello.app/Hello"])

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

    /// Semel building Semel (B-78): the root package's four executables over the real
    /// package graph — nested path dependencies, GRDB from git with its system-library
    /// SQLite. The copy is this checkout less what is not the build (`Project.Source
    /// .repository`); `prepare` vendors GRDB and writes the machine file, and keeps the
    /// formula and the project config the repository carries. External rather than a
    /// fixture only because vendoring fetches GRDB: the build itself is a fixture's size.
    static let semel = Project(
        name: "semel",
        source: .repository,
        buildFolder: "semel",
        platform: "macos",
        expectedProducts: ["semel", "semelserv", "semel-swift", "semel-clang"],
        buildTimeout: 10 * 60)

    /// Lua 5.4 (B-79): the `lua/lua` mirror at the commit its `v5.4.7` tag names, a flat
    /// folder of C with no configure step, nested under its name as a `.git` source with
    /// `subfolder: "."` is, and built by the formula and project config laid over it from
    /// `Fixtures/external/lua` (B-76): the library archived, and the interpreter linked
    /// against it. No `luac`: the mirror carries the development tree, and `luac.c` is
    /// added to the release tarballs only. External for the fetch alone; the build is a
    /// fixture's size, so it runs every hermeticity build.
    static let lua = Project(
        name: "lua",
        source: .git(url: "https://github.com/lua/lua.git",
                     commit: "1ab3208a1fceb12fca8f24ba57d6e13c5bff15e3",
                     subfolder: ".",
                     overlay: "external/lua"),
        buildFolder: "lua",
        platform: nil,
        expectedProducts: ["liblua.a", "lua"],
        buildTimeout: 5 * 60)

    /// SQLite 3.53.4 (B-79): the amalgamation, which SQLite's own repository does not hold —
    /// its build generates it — from the `rhuijben/sqlite-amalgamation` mirror at the
    /// commit its `3.53.4` tag names. The mirror's LICENSE is BSD-3-Clause and covers its
    /// CMake files; the three sources are SQLite's, in the public domain by the notice at
    /// their head. `sqlite3.c` is the whole library as one translation unit, so the build
    /// is one preprocessor and one compiler node over a 9.5 MB file and one large cache
    /// entry each — the opposite of IceCubes's many small ones. The `sqlite3` shell is
    /// linked from `shell.c` against the archive. Laid over the checkout from
    /// `Fixtures/external/sqlite` (B-76). Seconds to build, so every hermeticity build runs.
    static let sqlite = Project(
        name: "sqlite",
        source: .git(url: "https://github.com/rhuijben/sqlite-amalgamation.git",
                     commit: "fa2905e70a3d9659cd219162d7f1ebfb3715a206",
                     subfolder: ".",
                     overlay: "external/sqlite"),
        buildFolder: "sqlite",
        platform: nil,
        expectedProducts: ["libsqlite3.a", "sqlite3"],
        buildTimeout: 5 * 60)

    /// simdjson 4.6.11 (B-79): C++ beyond the emulator, from the `simdjson/simdjson`
    /// repository at the commit its `v4.6.11` tag names. Licensed Apache-2.0, or MIT at the
    /// user's choice (`LICENSE`, `LICENSE-MIT`). The repository carries the single-header
    /// amalgamation in `singleheader/`, which is the subfolder the build folder names — the
    /// checkout is copied whole and the overlay from `Fixtures/external/simdjson` is laid
    /// over that folder (B-76), with the machine file at the checkout's root, one level up,
    /// where the formula reads it. `libsimdjson.a` is archived from `simdjson.cpp`, one
    /// translation unit that inlines the 7.7 MB header, and `amalgamate_demo` is linked
    /// against it. Seconds to build, so every hermeticity build runs.
    static let simdjson = Project(
        name: "simdjson",
        source: .git(url: "https://github.com/simdjson/simdjson.git",
                     commit: "f5de14f09256982933af2849beb43778bd421ca7",
                     subfolder: "singleheader",
                     overlay: "external/simdjson"),
        buildFolder: "singleheader",
        platform: nil,
        expectedProducts: ["libsimdjson.a", "amalgamate_demo"],
        buildTimeout: 5 * 60)

    /// Apple's Food Truck sample (B-77): an Xcode project in the older form — targets that
    /// list their files through groups, a localized `.strings` per language as a variant
    /// group — with a local package that carries resources of its own, and a widget
    /// extension. The whole checkout is the project's root, nested under its name as
    /// `icecubesApp` is. The package's resources come out as
    /// `FoodTruckKit_FoodTruckKit.bundle` inside the app and inside the extension.
    static let foodTruck = Project(
        name: "food-truck",
        source: .git(url: "https://github.com/apple/sample-food-truck.git",
                     commit: "3954a769e99f3cc53297d94f2b960ceb2665b3d6",
                     subfolder: "."),
        buildFolder: "food-truck",
        platform: "ios-simulator",
        expectedProducts: [
            "Food Truck.app/Food Truck",
            "Food Truck.app/Info.plist",
            "Food Truck.app/Assets.car",
            "Food Truck.app/en.lproj/Localizable.strings",
            "Food Truck.app/FoodTruckKit_FoodTruckKit.bundle/Assets.car",
            "Food Truck.app/FoodTruckKit_FoodTruckKit.bundle/en.lproj/Localizable.strings",
            "Food Truck.app/PlugIns/Widgets.appex/Widgets",
            "Food Truck.app/PlugIns/Widgets.appex/Info.plist",
        ],
        buildTimeout: 10 * 60,
        // actool's output is not byte-reproducible (B-89), as for icecubes-app.
        mayDiffer: ["Assets.car"],
        onlyUnder: "Food Truck.app")

    /// The same sample for the Mac (B-77): a Mac bundle's `Contents/` layout, the app
    /// icon as an `.icns`, the widget under `Contents/PlugIns`. The sample guards
    /// ActivityKit with `canImport`, which the current macOS SDK satisfies although the
    /// Live Activity API stays unavailable there, so Xcode fails on it too; the overlay
    /// `Fixtures/external/food-truck-mac` lays the four files with the guard corrected
    /// over the clone, before `prepare` (its README says what changed). The build takes
    /// seconds, so it runs every hermeticity build.
    static let foodTruckMac = Project(
        name: "food-truck-mac",
        source: .git(url: "https://github.com/apple/sample-food-truck.git",
                     commit: "3954a769e99f3cc53297d94f2b960ceb2665b3d6",
                     subfolder: ".",
                     overlay: "external/food-truck-mac"),
        buildFolder: "food-truck-mac",
        platform: "macos",
        expectedProducts: [
            "Food Truck.app/Contents/MacOS/Food Truck",
            "Food Truck.app/Contents/Info.plist",
            "Food Truck.app/Contents/Resources/Assets.car",
            "Food Truck.app/Contents/Resources/AppIcon.icns",
            "Food Truck.app/Contents/Resources/en.lproj/Localizable.strings",
            "Food Truck.app/Contents/Resources/FoodTruckKit_FoodTruckKit.bundle/Assets.car",
            "Food Truck.app/Contents/PlugIns/Widgets.appex/Contents/MacOS/Widgets",
            "Food Truck.app/Contents/PlugIns/Widgets.appex/Contents/Info.plist",
        ],
        buildTimeout: 10 * 60,
        // actool's output is not byte-reproducible (B-89), as for icecubes-app.
        mayDiffer: ["Assets.car"],
        onlyUnder: "Food Truck.app")

    static let fixtures: [Project] = [cHello, tutorial, cppEmu6502, swiftMyApp, swiftCPackage, swiftHelloApp]
    static let external: [Project] = [icecubes, icecubesApp, semel, lua, sqlite, simdjson, foodTruck, foodTruckMac]
    static let all: [Project] = fixtures + external
}

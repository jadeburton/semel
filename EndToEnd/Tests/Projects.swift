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
    /// converter reports the folder it needs, and `build` follows it (B-110). Its
    /// `MyLibraryTargetB` compiles only with its `swiftSettings`: a bare-slash regex literal
    /// that needs the upcoming feature, and a `.define` its source `#error`s without (B-77).
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

    /// Its catalog holds a colour with a dark appearance and its icon is an Icon Composer
    /// `.icon`, the two things actool writes differently from one compile to the next, so
    /// the four builds compare a canonical `Assets.car` byte for byte, unexempted (B-89).
    static let swiftHelloApp = Project(
        name: "swift-hello-app",
        source: .fixture(folder: "."),
        buildFolder: "swift/HelloApp",
        platform: "ios-simulator",
        expectedProducts: ["Hello.app/Hello", "Hello.app/Info.plist", "Hello.app/PkgInfo", "Hello.app/Assets.car",
                           "Hello.app/AppIcon60x60@2x.png", "Hello.app/Base.lproj/Card.nib"],
        buildTimeout: fixtureTimeout,
        onlyUnder: "Hello.app",
        executables: ["Hello.app/Hello"])

    /// A Mac app from an Xcode project linking a local package's product that depends on a
    /// binary target by `path:` (B-77). The `.xcframework` is built by the run, not held by
    /// the repository (`BinaryTargetFixture`): a versioned `Tiny.framework`, links and all,
    /// which the push carries as links. The converter reads the xcframework, the slice
    /// selector chooses its Mac slice, the package and the app compile against it and the app
    /// links it; the bundle embeds it under `Contents/Frameworks`, links as links, the signed
    /// export verifies deep and strict, and the exported app loads the framework through its
    /// runpath and prints its greeting. The app's synchronized folder also
    /// holds a plist and, two folders down, a JSON file, which Xcode copies flat into
    /// `Contents/Resources` (B-77 item 2); the app reads both at launch and prints them.
    static let swiftBinaryTargetApp = Project(
        name: "swift-binary-target-app",
        source: .fixture(folder: "."),
        buildFolder: "swift/BinaryTargetApp",
        platform: "macos",
        expectedProducts: ["Greeter.app/Contents/MacOS/Greeter",
                           "Greeter.app/Contents/Info.plist",
                           "Greeter.app/Contents/Resources/Messages.plist",
                           "Greeter.app/Contents/Resources/Settings.json",
                           "Greeter.app/Contents/Frameworks/Tiny.framework/Versions/A/Tiny",
                           "Greeter.app/Contents/Frameworks/Tiny.framework/Versions/A/Resources/Info.plist"],
        buildTimeout: fixtureTimeout,
        onlyUnder: "Greeter.app",
        executables: ["Greeter.app/Contents/MacOS/Greeter",
                      "Greeter.app/Contents/Frameworks/Tiny.framework/Versions/A/Tiny"],
        materialised: BinaryTargetFixture.buildXCFramework(in:),
        exported: BinaryTargetFixture.checkApp(in:))

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
    /// `FoodTruckKit_FoodTruckKit.bundle` inside the app and inside the extension. The
    /// project has two applications for every platform, `Food Truck` and `Food Truck All`,
    /// both multiplatform, so the entry names the one it builds (B-77).
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
        application: "Food Truck",
        onlyUnder: "Food Truck.app")

    /// The same sample for the Mac (B-77): a Mac bundle's `Contents/` layout, the app
    /// icon as an `.icns`, the widget under `Contents/PlugIns`. The sample guards
    /// ActivityKit with `canImport`, which the current macOS SDK satisfies although the
    /// Live Activity API stays unavailable there, so Xcode fails on it too; the overlay
    /// `Fixtures/external/food-truck-mac` lays the four files with the guard corrected
    /// over the clone, before `prepare` (its README says what changed). The build takes
    /// seconds, so it runs every hermeticity build. The bundle is signed ad-hoc, the
    /// widget with its own entitlements and then the app with the app sandbox, and the
    /// export verifies deep and strict.
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
            "Food Truck.app/Contents/_CodeSignature/CodeResources",
            "Food Truck.app/Contents/PlugIns/Widgets.appex/Contents/_CodeSignature/CodeResources",
        ],
        buildTimeout: 10 * 60,
        application: "Food Truck",
        onlyUnder: "Food Truck.app",
        executables: ["Food Truck.app/Contents/MacOS/Food Truck", "Food Truck.app/Contents/PlugIns/Widgets.appex/Contents/MacOS/Widgets"],
        exported: SignedBundleCheck.verifying(bundle: "Food Truck.app", executable: "Food Truck.app/Contents/MacOS/Food Truck",
                                              entitlement: "com.apple.security.app-sandbox"))

    /// NetNewsWire's Mac app (B-77 item 2): seventeen local packages found through a
    /// synchronized folder, Sparkle's binary framework vendored and embedded,
    /// PLCrashReporter's C and Objective-C, the app's own Objective-C behind a bridging
    /// header, thirty-five xibs compiled, xcconfig-layered settings, the Share and Safari
    /// extensions. The overlay `Fixtures/external/netnewswire` provides `SecretKey.swift`,
    /// which the project's scheme generates with gyb before a build and Semel runs no
    /// scheme action; its README says how it was made. Signed ad-hoc (item 11), Sparkle's
    /// links carried as links, and the export verified deep and strict; inspected rather
    /// than run.
    static let netNewsWireMac = Project(
        name: "netnewswire-mac",
        source: .git(url: "https://github.com/Ranchero-Software/NetNewsWire.git",
                     commit: "b4361413fc1850110f9f42652f0f84e7a51e9d64",
                     subfolder: ".",
                     overlay: "external/netnewswire"),
        buildFolder: "netnewswire-mac",
        platform: "macos",
        expectedProducts: [
            "NetNewsWire.app/Contents/MacOS/NetNewsWire",
            "NetNewsWire.app/Contents/Info.plist",
            "NetNewsWire.app/Contents/PkgInfo",
            "NetNewsWire.app/Contents/Resources/Assets.car",
            "NetNewsWire.app/Contents/Resources/AppIcon.icns",
            "NetNewsWire.app/Contents/Resources/Base.lproj/MainWindow.nib",
            "NetNewsWire.app/Contents/Resources/Sepia.nnwtheme/Info.plist",
            // What Xcode copies from the synchronized folders, flat (B-77 item 2): the
            // keyboard shortcut plists the app reads at launch, the article view's files.
            "NetNewsWire.app/Contents/Resources/GlobalKeyboardShortcuts.plist",
            "NetNewsWire.app/Contents/Resources/DetailKeyboardShortcuts.plist",
            "NetNewsWire.app/Contents/Resources/SidebarKeyboardShortcuts.plist",
            "NetNewsWire.app/Contents/Resources/TimelineKeyboardShortcuts.plist",
            "NetNewsWire.app/Contents/Resources/container-migration.plist",
            "NetNewsWire.app/Contents/Resources/template.html",
            "NetNewsWire.app/Contents/Resources/core.css",
            "NetNewsWire.app/Contents/Resources/main.js",
            "NetNewsWire.app/Contents/Resources/ContentRules.json",
            "NetNewsWire.app/Contents/Resources/NetNewsWire.sdef",
            "NetNewsWire.app/Contents/Resources/PLCrashReporter_CrashReporter.bundle/PrivacyInfo.xcprivacy",
            "NetNewsWire.app/Contents/Resources/ActivityLog_ActivityLog.bundle/es.lproj/Localizable.strings",
            "NetNewsWire.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
            "NetNewsWire.app/Contents/PlugIns/NetNewsWire Share Extension.appex/Contents/MacOS/NetNewsWire Share Extension",
            "NetNewsWire.app/Contents/PlugIns/NetNewsWire Share Extension.appex/Contents/Info.plist",
            "NetNewsWire.app/Contents/PlugIns/NetNewsWire Share Extension.appex/Contents/Resources/Base.lproj/ShareViewController.nib",
            "NetNewsWire.app/Contents/PlugIns/Subscribe to Feed.appex/Contents/MacOS/Subscribe to Feed",
            "NetNewsWire.app/Contents/PlugIns/Subscribe to Feed.appex/Contents/Info.plist",
        ],
        buildTimeout: 10 * 60,
        onlyUnder: "NetNewsWire.app",
        executables: [
            "NetNewsWire.app/Contents/MacOS/NetNewsWire",
            "NetNewsWire.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
            "NetNewsWire.app/Contents/PlugIns/NetNewsWire Share Extension.appex/Contents/MacOS/NetNewsWire Share Extension",
            "NetNewsWire.app/Contents/PlugIns/Subscribe to Feed.appex/Contents/MacOS/Subscribe to Feed",
        ],
        exported: { out in
            try AppInspection.checkLoadsEmbeddedFramework(
                executable:  out.appendingPathComponent("NetNewsWire.app/Contents/MacOS/NetNewsWire"),
                installName: "@rpath/Sparkle.framework/Versions/B/Sparkle")
            // Signed as bundles, Sparkle with them (B-77), and verified as the whole it is:
            // Sparkle's links travel as links from the push to the export.
            try SignedBundleCheck.verified(out.appendingPathComponent("NetNewsWire.app"))
            for executable in ["NetNewsWire.app/Contents/MacOS/NetNewsWire",
                               "NetNewsWire.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
                               "NetNewsWire.app/Contents/PlugIns/NetNewsWire Share Extension.appex/Contents/MacOS/NetNewsWire Share Extension",
                               "NetNewsWire.app/Contents/PlugIns/Subscribe to Feed.appex/Contents/MacOS/Subscribe to Feed"] {
                try SignedBundleCheck.signedAsPartOfTheBundle(out.appendingPathComponent(executable))
            }
        })

    /// NetNewsWire's iOS app (B-77) from the same clone and overlay as `netnewswire-mac`:
    /// the simulator builds the application whose `SDKROOT` is `iphoneos`, with the Share
    /// extension, which owns no folder and borrows its sources, xibs and catalog from
    /// `iOS`, and the WidgetKit extension, each under `PlugIns/` in the flat iOS layout;
    /// storyboards compiled to `.storyboardc`, the app's Objective-C and bridging header,
    /// the fifteen local packages linked in. Unsigned, as IceCubes' simulator bundle is.
    /// The build takes about a minute, so it runs every hermeticity build.
    static let netNewsWireIOS = Project(
        name: "netnewswire-ios",
        source: .git(url: "https://github.com/Ranchero-Software/NetNewsWire.git",
                     commit: "b4361413fc1850110f9f42652f0f84e7a51e9d64",
                     subfolder: ".",
                     overlay: "external/netnewswire"),
        buildFolder: "netnewswire-ios",
        platform: "ios-simulator",
        expectedProducts: [
            "NetNewsWire.app/NetNewsWire",
            "NetNewsWire.app/Info.plist",
            "NetNewsWire.app/Assets.car",
            "NetNewsWire.app/Base.lproj/Main.storyboardc/Info.plist",
            "NetNewsWire.app/Base.lproj/LaunchScreenPhone.storyboardc/Info.plist",
            "NetNewsWire.app/Base.lproj/LaunchScreenPad.storyboardc/Info.plist",
            "NetNewsWire.app/Settings.storyboardc/Info.plist",
            "NetNewsWire.app/SettingsTableViewCell.nib",
            "NetNewsWire.app/Sepia.nnwtheme/Info.plist",
            "NetNewsWire.app/GlobalKeyboardShortcuts.plist",
            "NetNewsWire.app/main_ios.js",
            "NetNewsWire.app/page.html",
            "NetNewsWire.app/DefaultFeeds.opml",
            "NetNewsWire.app/ActivityLog_ActivityLog.bundle/es.lproj/Localizable.strings",
            "NetNewsWire.app/PlugIns/NetNewsWire iOS Share Extension.appex/NetNewsWire iOS Share Extension",
            "NetNewsWire.app/PlugIns/NetNewsWire iOS Share Extension.appex/Info.plist",
            "NetNewsWire.app/PlugIns/NetNewsWire iOS Share Extension.appex/Assets.car",
            "NetNewsWire.app/PlugIns/NetNewsWire iOS Share Extension.appex/ShareFolderPickerAccountCell.nib",
            "NetNewsWire.app/PlugIns/NetNewsWire iOS Widget Extension.appex/NetNewsWire iOS Widget Extension",
            "NetNewsWire.app/PlugIns/NetNewsWire iOS Widget Extension.appex/Info.plist",
            "NetNewsWire.app/PlugIns/NetNewsWire iOS Widget Extension.appex/Assets.car",
            "NetNewsWire.app/PlugIns/NetNewsWire iOS Widget Extension.appex/widget-sample.json",
        ],
        buildTimeout: 10 * 60,
        onlyUnder: "NetNewsWire.app",
        executables: [
            "NetNewsWire.app/NetNewsWire",
            "NetNewsWire.app/PlugIns/NetNewsWire iOS Share Extension.appex/NetNewsWire iOS Share Extension",
            "NetNewsWire.app/PlugIns/NetNewsWire iOS Widget Extension.appex/NetNewsWire iOS Widget Extension",
        ],
        exported: { out in
            for executable in ["NetNewsWire.app/NetNewsWire",
                               "NetNewsWire.app/PlugIns/NetNewsWire iOS Share Extension.appex/NetNewsWire iOS Share Extension",
                               "NetNewsWire.app/PlugIns/NetNewsWire iOS Widget Extension.appex/NetNewsWire iOS Widget Extension"] {
                try AppInspection.checkRecordsTheSDKVersion(executable: out.appendingPathComponent(executable), sdk: "iphonesimulator")
            }
        })

    static let fixtures: [Project] = [cHello, tutorial, cppEmu6502, swiftMyApp, swiftCPackage, swiftHelloApp, swiftBinaryTargetApp]
    static let external: [Project] = [icecubes, icecubesApp, semel, lua, sqlite, simdjson, foodTruck, foodTruckMac, netNewsWireMac, netNewsWireIOS]
    static let all: [Project] = fixtures + external
}

//
//  CMakeEvaluationTests.swift
//  SemelCMakeTests
//
//  The evaluator reads the declarative subset into the model and refuses the rest by
//  name and line. These pin what a target comes out as, what a directory's defaults do,
//  how a subdirectory and an include are reached through the reader, which conditions
//  the facts decide, and that a refusal leaves the rest of the project read.
//

@testable import SemelCMake
import XCTest

final class CMakeEvaluationTests: XCTestCase {

    private let root = "/project"

    private func evaluate(_ text: String, files: [String: String] = [:],
                          variables: [String: String]? = nil) throws -> CMakeProject {
        let file  = try CMakeFile.parse(text, path: "CMakeLists.txt")
        var facts = CMakeFacts.macOS(sourceDirectory: root)
        if let variables {
            facts.variables = variables
        }
        return try CMakeEvaluation.evaluate(root: file, facts: facts, fileReader: { files[$0] })
    }

    private func location(_ line: Int, file: String = "CMakeLists.txt") -> CMakeLocation {
        CMakeLocation(file: file, line: line)
    }

    // MARK: - Targets

    func test_anExecutableAndItsLibraryWithTheirRequirements() throws {
        let project = try evaluate("""
            cmake_minimum_required(VERSION 3.16)
            project(hello VERSION 1.2 LANGUAGES C)

            add_library(greet STATIC src/greet.c src/greet.h)
            target_include_directories(greet PUBLIC include PRIVATE src)
            target_compile_definitions(greet PRIVATE -DGREET_INTERNAL PUBLIC GREET_VERSION="1.2")
            target_compile_options(greet PRIVATE -Wall)

            add_executable(hello src/main.c)
            target_link_libraries(hello PRIVATE greet m -framework Foundation)
            """)
        XCTAssertEqual(project.name, "hello")
        XCTAssertEqual(project.languages, [.c])
        XCTAssertEqual(project.untranslated, [])
        XCTAssertEqual(project.targets.map(\.name), ["greet", "hello"])

        let greet = try XCTUnwrap(project.target(named: "greet"))
        XCTAssertEqual(greet.kind, .staticLibrary)
        XCTAssertEqual(greet.folder, "")
        XCTAssertEqual(greet.declaredAt, location(4))
        XCTAssertEqual(greet.sources, ["src/greet.c", "src/greet.h"])
        XCTAssertEqual(greet.includeDirectories, [CMakeScoped("include", .public), CMakeScoped("src", .private)])
        XCTAssertEqual(greet.compileDefinitions, [CMakeScoped("GREET_INTERNAL", .private),
                                                  CMakeScoped("GREET_VERSION=\"1.2\"", .public)])
        XCTAssertEqual(greet.compileOptions, [CMakeScoped("-Wall", .private)])

        let hello = try XCTUnwrap(project.target(named: "hello"))
        XCTAssertEqual(hello.kind, .executable)
        XCTAssertEqual(hello.linkItems, [CMakeScoped(.target("greet"), .private),
                                         CMakeScoped(.library("m"), .private),
                                         CMakeScoped(.framework("Foundation"), .private)])
    }

    func test_aLibraryIsStaticUnlessSaidOrBuildSharedLibsIsOn() throws {
        let plain  = try evaluate("add_library(a a.c)")
        XCTAssertEqual(plain.targets[0].kind, .staticLibrary)
        let shared = try evaluate("add_library(a SHARED a.c)\nadd_library(b INTERFACE)")
        XCTAssertEqual(shared.targets.map(\.kind), [.sharedLibrary, .interfaceLibrary])
        let option = try evaluate("set(BUILD_SHARED_LIBS ON)\nadd_library(a a.c)")
        XCTAssertEqual(option.targets[0].kind, .sharedLibrary)
    }

    func test_aLinkItemNamesATargetDeclaredLaterAndThroughAnAlias() throws {
        let project = try evaluate("""
            add_executable(app main.c)
            target_link_libraries(app core::core)
            add_library(core core.c)
            add_library(core::core ALIAS core)
            """)
        XCTAssertEqual(project.target(named: "app")?.linkItems, [CMakeScoped(.target("core"), .public)])
        XCTAssertEqual(project.untranslated, [])
    }

    func test_anImportedTargetNobodyDeclaredIsRefusedAndTheRestIsLinked() throws {
        let project = try evaluate("""
            add_executable(app main.c)
            target_link_libraries(app PRIVATE Threads::Threads z)
            """)
        XCTAssertEqual(project.target(named: "app")?.linkItems, [CMakeScoped(.library("z"), .private)])
        XCTAssertEqual(project.untranslated, [CMakeUntranslated(location: location(2), command: "target_link_libraries",
                                                                reason: .unknownTarget("Threads::Threads"), affectedTarget: "app")])
    }

    func test_targetPropertiesAndFeaturesSetTheNameAndTheStandards() throws {
        let project = try evaluate("""
            set(CMAKE_C_STANDARD 99)
            set(CMAKE_CXX_EXTENSIONS OFF)
            add_executable(app main.cpp)
            set_target_properties(app PROPERTIES OUTPUT_NAME application CXX_STANDARD 17 C_EXTENSIONS OFF)
            target_compile_features(app PRIVATE c_std_11)
            """)
        XCTAssertEqual(project.cStandard, "99")
        XCTAssertEqual(project.cxxExtensions, false)
        let app = try XCTUnwrap(project.target(named: "app"))
        XCTAssertEqual(app.outputName, "application")
        XCTAssertEqual(app.cxxStandard, "17")
        XCTAssertEqual(app.cStandard, "11")
        XCTAssertEqual(app.cExtensions, false)
    }

    func test_directoryDefaultsReachTheTargetsDeclaredAfterThem() throws {
        let project = try evaluate("""
            add_executable(before before.c)
            include_directories(include)
            add_definitions(-DFOO -Wextra)
            add_compile_options(-O2)
            link_libraries(m)
            add_executable(after after.c)
            """)
        let before = try XCTUnwrap(project.target(named: "before"))
        XCTAssertEqual(before.includeDirectories, [])
        let after = try XCTUnwrap(project.target(named: "after"))
        XCTAssertEqual(after.includeDirectories, [CMakeScoped("include", .private)])
        XCTAssertEqual(after.compileDefinitions, [CMakeScoped("FOO", .private)])
        XCTAssertEqual(after.compileOptions, [CMakeScoped("-Wextra", .private), CMakeScoped("-O2", .private)])
        XCTAssertEqual(after.linkItems, [CMakeScoped(.library("m"), .private)])
    }

    // MARK: - Variables and paths

    func test_variablesExpandAndAnUnquotedListSplits() throws {
        let project = try evaluate("""
            set(SOURCES a.c b.c)
            list(APPEND SOURCES c.c)
            set(NAME app)
            add_executable(${NAME} ${SOURCES} "d.c;e.c")
            """)
        XCTAssertEqual(project.targets[0].name, "app")
        XCTAssertEqual(project.targets[0].sources, ["a.c", "b.c", "c.c", "d.c;e.c"])
    }

    func test_pathsAreRelativeToTheRootHoweverTheFileSpellsThem() throws {
        let project = try evaluate("""
            add_executable(app ${CMAKE_SOURCE_DIR}/src/main.c ${CMAKE_CURRENT_SOURCE_DIR}/src/../lib/x.c ./y.c /usr/share/z.c)
            """)
        XCTAssertEqual(project.targets[0].sources, ["src/main.c", "lib/x.c", "y.c", "/usr/share/z.c"])
    }

    func test_aGlobIsKeptAsThePatternItNamesAndRecursesWithTwoStars() throws {
        let project = try evaluate("""
            file(GLOB SOURCES CONFIGURE_DEPENDS src/*.c)
            file(GLOB_RECURSE DEEP lib/*.cpp)
            add_executable(app ${SOURCES} ${DEEP})
            """)
        XCTAssertEqual(project.targets[0].sources, ["src/*.c", "lib/**/*.cpp"])
    }

    func test_aCacheSetIsADefaultAndAnOptionLikewise() throws {
        let project = try evaluate("""
            set(FLAVOUR vanilla)
            set(FLAVOUR chocolate CACHE STRING "which")
            set(SIZE large CACHE STRING "how big")
            option(WITH_TESTS "build the tests" OFF)
            option(WITH_DOCS "build the docs")
            add_executable(app ${FLAVOUR}-${SIZE}-${WITH_TESTS}-${WITH_DOCS}.c)
            """)
        XCTAssertEqual(project.targets[0].sources, ["vanilla-large-OFF-OFF.c"])
    }

    // MARK: - Files

    func test_aSubdirectoryIsReadThroughTheReaderWithACopyOfTheVariables() throws {
        let project = try evaluate("""
            project(tree)
            set(SHARED_FLAG -Wall)
            include_directories(include)
            add_subdirectory(lib)
            add_executable(app main.c)
            target_link_libraries(app core)
            """, files: [
                "lib/CMakeLists.txt": """
                    set(LOCAL only-here)
                    add_library(core core.c)
                    target_compile_options(core PRIVATE ${SHARED_FLAG})
                    target_include_directories(core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
                    """,
            ])
        let core = try XCTUnwrap(project.target(named: "core"))
        XCTAssertEqual(core.folder, "lib")
        XCTAssertEqual(core.declaredAt, location(2, file: "lib/CMakeLists.txt"))
        XCTAssertEqual(core.sources, ["lib/core.c"])
        XCTAssertEqual(core.compileOptions, [CMakeScoped("-Wall", .private)])
        XCTAssertEqual(core.includeDirectories, [CMakeScoped("include", .private), CMakeScoped("lib/include", .public)])
        XCTAssertEqual(project.target(named: "app")?.linkItems, [CMakeScoped(.target("core"), .public)])
        XCTAssertEqual(project.untranslated, [])
    }

    func test_aMissingSubdirectoryIsRefusedByPath() throws {
        let project = try evaluate("add_subdirectory(missing)\nadd_executable(app main.c)")
        XCTAssertEqual(project.untranslated, [CMakeUntranslated(location: location(1), command: "add_subdirectory",
                                                                reason: .fileNotFound("missing/CMakeLists.txt"))])
        XCTAssertEqual(project.targets.map(\.name), ["app"])
    }

    func test_anIncludedFileIsReadIntoTheSameScopeAndAModuleIsRefused() throws {
        let project = try evaluate("""
            include(cmake/sources.cmake)
            include(GNUInstallDirs)
            include(cmake/absent.cmake OPTIONAL)
            add_executable(app ${APP_SOURCES})
            """, files: ["cmake/sources.cmake": "set(APP_SOURCES main.c)\n"])
        XCTAssertEqual(project.targets[0].sources, ["main.c"])
        XCTAssertEqual(project.untranslated, [CMakeUntranslated(location: location(2), command: "include",
                                                                reason: .cmakeModule("GNUInstallDirs"))])
    }

    // MARK: - Conditions

    func test_aConditionTheFactsDecideReadsTheBranchThatHolds() throws {
        let project = try evaluate("""
            if(WIN32)
              add_executable(windows w.c)
            elseif(APPLE AND NOT MSVC)
              add_executable(mac m.c)
            else()
              add_executable(other o.c)
            endif()
            if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
              add_library(darwin d.c)
            endif()
            set(FEATURES a;b)
            if(b IN_LIST FEATURES AND DEFINED FEATURES AND 2 GREATER 1)
              add_library(listed l.c)
            endif()
            if("APPLE")
              add_library(quoted q.c)
            endif()
            """)
        XCTAssertEqual(project.targets.map(\.name), ["mac", "darwin", "listed"])
        XCTAssertEqual(project.untranslated, [])
    }

    /// miniz calls `project()` in both branches of a `CMAKE_VERSION` test; a project
    /// comparing a compiler's version compares what only a `cmake` run knows.
    func test_aVersionComparisonIsDecidedUnlessItReadsTheMachine() throws {
        let project = try evaluate("""
            if(CMAKE_VERSION VERSION_LESS "3.12")
              project(old C)
            else()
              project(new C)
            endif()
            set(NEED 3.12.4)
            if(NEED VERSION_GREATER_EQUAL 3.12 AND NEED VERSION_LESS 3.12.10rc1 AND 1.0 VERSION_EQUAL 1)
              add_library(versioned v.c)
            endif()
            if(CMAKE_C_COMPILER_VERSION VERSION_LESS 10)
              add_library(old_compiler o.c)
            endif()
            """)
        XCTAssertEqual(project.name, "new")
        XCTAssertEqual(project.targets.map(\.name), ["versioned"])
        XCTAssertEqual(project.untranslated.map(\.reason),
                       [.undecidableCondition("CMAKE_C_COMPILER_VERSION VERSION_LESS 10 (CMAKE_C_COMPILER_VERSION)")])
        XCTAssertEqual(CMakeCondition.versionComponents(of: "3.12rc1.7"), [3, 12, 7, 0])
    }

    func test_aConditionTheFactsDoNotDecideSkipsTheWholeBlockAndSaysSo() throws {
        let project = try evaluate("""
            if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/extra.c)
              add_executable(extra extra.c)
            else()
              add_executable(plain plain.c)
            endif()
            add_executable(after after.c)
            """)
        XCTAssertEqual(project.targets.map(\.name), ["after"])
        XCTAssertEqual(project.untranslated.map(\.reason),
                       [.undecidableCondition("EXISTS /project/extra.c (EXISTS)")])
        XCTAssertEqual(project.untranslated[0].location, location(1))
    }

    func test_nestedBlocksCloseWhereTheyOpened() throws {
        let project = try evaluate("""
            if(APPLE)
              if(WIN32)
                add_executable(no n.c)
              else()
                add_executable(yes y.c)
              endif()
              add_executable(also a.c)
            endif()
            """)
        XCTAssertEqual(project.targets.map(\.name), ["yes", "also"])
    }

    // MARK: - Refusals

    func test_proceduralCommandsAreRefusedByNameAndLineAndTheRestIsRead() throws {
        let project = try evaluate("""
            find_package(Threads REQUIRED)
            foreach(source a.c b.c)
              add_executable(${source} ${source})
            endforeach()
            function(helper)
              add_executable(inside in.c)
            endfunction()
            helper()
            add_executable(app main.c $ENV{HOME}/x.c)
            add_executable(generated g.c $<TARGET_OBJECTS:other>)
            add_executable(built ${CMAKE_BINARY_DIR}/b.c)
            add_library(imported STATIC IMPORTED)
            add_executable(real real.c)
            """)
        XCTAssertEqual(project.targets.map(\.name), ["real"])
        XCTAssertEqual(project.untranslated, [
            CMakeUntranslated(location: location(1),  command: "find_package",   reason: .unsupportedCommand),
            CMakeUntranslated(location: location(2),  command: "foreach",        reason: .controlFlow),
            CMakeUntranslated(location: location(5),  command: "function",       reason: .controlFlow),
            CMakeUntranslated(location: location(8),  command: "helper",         reason: .unsupportedCommand),
            CMakeUntranslated(location: location(9),  command: "add_executable", reason: .environmentVariable("HOME")),
            CMakeUntranslated(location: location(10), command: "add_executable", reason: .generatorExpression("$<TARGET_OBJECTS:other>")),
            CMakeUntranslated(location: location(11), command: "add_executable", reason: .unsupportedVariable("CMAKE_BINARY_DIR")),
            CMakeUntranslated(location: location(12), command: "add_library",    reason: .unsupportedArgument("IMPORTED"),
                              affectedTarget: "imported"),
        ])
    }

    func test_aTargetCommandOnAnUnknownTargetNamesIt() throws {
        let project = try evaluate("target_compile_options(ghost PRIVATE -O2)")
        XCTAssertEqual(project.untranslated, [CMakeUntranslated(location: location(1), command: "target_compile_options",
                                                                reason: .unknownTarget("ghost"), affectedTarget: "ghost")])
    }

    func test_aRefusalDescribesItselfInOneLine() {
        let refusal = CMakeUntranslated(location: location(7, file: "src/CMakeLists.txt"), command: "find_package",
                                        reason: .unsupportedCommand, affectedTarget: nil)
        XCTAssertEqual(refusal.description, "src/CMakeLists.txt:7: find_package is not in the declarative subset")
        let linked = CMakeUntranslated(location: location(3), command: "target_link_libraries",
                                       reason: .unknownTarget("Threads::Threads"), affectedTarget: "app")
        XCTAssertEqual(linked.description,
                       "CMakeLists.txt:3: target_link_libraries links Threads::Threads, which no CMakeLists.txt here declares (target app)")
    }

    func test_ignoredCommandsLeaveNoTrace() throws {
        let project = try evaluate("""
            cmake_minimum_required(VERSION 3.5)
            message(STATUS "hello ${CMAKE_BINARY_DIR}")
            install(TARGETS app DESTINATION bin)
            enable_testing()
            add_test(NAME t COMMAND app)
            add_executable(app main.c)
            """)
        XCTAssertEqual(project.untranslated, [])
        XCTAssertEqual(project.targets.map(\.name), ["app"])
    }
}

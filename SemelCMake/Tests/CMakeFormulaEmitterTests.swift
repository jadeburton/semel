//
//  CMakeFormulaEmitterTests.swift
//  SemelCMakeTests
//
//  The emitter is text out of the model, so the assertions are on the text: a small
//  project whole, since the person who runs the tool reads exactly this, and then the
//  rules one at a time — propagation, the prelude's chain for a target that adds nothing,
//  the stages flags go to, the config's standards.
//

@testable import SemelCMake
import XCTest

final class CMakeFormulaEmitterTests: XCTestCase {

    private let build = CMakeFormulaEmitter.Build(target: "arm64-apple-macosx14.0", machineConfigPath: "semel.machine.config")

    private func project(_ text: String, files: [String: String] = [:]) throws -> CMakeProject {
        let file = try CMakeFile.parse(text, path: "CMakeLists.txt")
        return try CMakeEvaluation.evaluate(root: file, facts: .macOS(sourceDirectory: "/project"), fileReader: { files[$0] })
    }

    private func formula(_ text: String, files: [String: String] = [:]) throws -> String {
        CMakeFormulaEmitter(project: try project(text, files: files), build: build).formula()
    }

    private func config(_ text: String) throws -> String {
        CMakeFormulaEmitter(project: try project(text), build: build).config()
    }

    // MARK: - Whole files

    func test_aLibraryAndAnExecutableOverIt() throws {
        let text = try formula("""
            cmake_minimum_required(VERSION 3.16)
            project(hello LANGUAGES C)
            find_package(Threads)

            add_library(greet STATIC src/greet.c src/greet.h)
            target_include_directories(greet PUBLIC include PRIVATE src)
            target_compile_definitions(greet PRIVATE GREET_INTERNAL PUBLIC GREET_VERSION=2)
            target_compile_options(greet PRIVATE -Wall)

            add_executable(hello src/main.c)
            target_link_libraries(hello PRIVATE greet m "-framework Foundation")
            """)
        XCTAssertEqual(text, """
            // Written by semel-cmake from CMakeLists.txt: the project `hello`, as its files declare it, in
            // the funcs a hand-written C formula uses. semel-cmake never overwrites this file: edit
            // it, and run semel-cmake again only to start over.
            //
            // Not translated, the rest is:
            //   CMakeLists.txt:3: find_package is not in the declarative subset

            include 'clang'

            func settings() = clang.settings(project: <semel.config>, machine: <semel.machine.config>)

            // greet: a static library, CMakeLists.txt:5
            func preprocessed_greet(file) = ClangPreprocessor(
              configuration: [ConfigMerger(base: [clang.selected(settings: settings(), prefix: 'clang.preprocessor')], override: [SettingsLiteral(defines: 'GREET_INTERNAL,GREET_VERSION=2')])],
              input: [file: StaticFile(path: file)],
              headerFolders: ['00 include': Folder(path: <include>).manifest, '01 src': Folder(path: <src>).manifest]
            )

            func compiled_greet(file) = ClangCompiler(
              configuration: [ConfigMerger(base: [clang.selected(settings: settings(), prefix: 'clang.compiler')], override: [SettingsLiteral(arguments: '-Wall')])],
              input: ["%%file%%.p": preprocessed_greet(file: file)]
            )

            func greet() = ClangArchiver(
              configuration: [clang.selected(settings: settings(), prefix: 'clang.archiver')],
              objectFiles: [{file: <src/greet.c>} "%%file%%.o": compiled_greet(file: file)]
            )

            product 'libgreet.a' = greet()

            // hello: an executable, CMakeLists.txt:10
            func preprocessed_hello(file) = ClangPreprocessor(
              configuration: [ConfigMerger(base: [clang.selected(settings: settings(), prefix: 'clang.preprocessor')], override: [SettingsLiteral(defines: 'GREET_VERSION=2')])],
              input: [file: StaticFile(path: file)],
              headerFolders: ['00 include': Folder(path: <include>).manifest]
            )

            func compiled_hello(file) = ClangCompiler(
              configuration: [clang.selected(settings: settings(), prefix: 'clang.compiler')],
              input: ["%%file%%.p": preprocessed_hello(file: file)]
            )

            func hello() = ClangLinker(
              configuration: [ConfigMerger(base: [clang.selected(settings: settings(), prefix: 'clang.linker')], override: [SettingsLiteral(dynamicLibrary: 'false', frameworks: 'Foundation', libraries: 'm')])],
              objectFiles: [{file: <src/main.c>} "%%file%%.o": compiled_hello(file: file)],
              libraries: ['libgreet.a': greet()]
            )

            product 'hello' = hello()

            """)
    }

    func test_aTargetThatAddsNothingTakesThePreludesChain() throws {
        let text = try formula("""
            project(plain C)
            add_executable(plain main.c util.c notes.txt)
            add_library(shared SHARED lib.c)
            """)
        XCTAssertEqual(text, """
            // Written by semel-cmake from CMakeLists.txt: the project `plain`, as its files declare it, in
            // the funcs a hand-written C formula uses. semel-cmake never overwrites this file: edit
            // it, and run semel-cmake again only to start over.

            include 'clang'

            func settings() = clang.settings(project: <semel.config>, machine: <semel.machine.config>)

            // plain: an executable, CMakeLists.txt:2
            func plain() = ClangLinker(
              configuration: [ConfigMerger(base: [clang.selected(settings: settings(), prefix: 'clang.linker')], override: [SettingsLiteral(dynamicLibrary: 'false')])],
              objectFiles: [{file: <main.c>, <util.c>} "%%file%%.o": clang.compiled(file: file, settings: settings())]
            )

            product 'plain' = plain()

            // shared: a shared library, CMakeLists.txt:3
            func shared() = ClangLinker(
              configuration: [ConfigMerger(base: [clang.selected(settings: settings(), prefix: 'clang.linker')], override: [SettingsLiteral(dynamicLibrary: 'true')])],
              objectFiles: [{file: <lib.c>} "%%file%%.o": clang.compiled(file: file, settings: settings())]
            )

            product 'libshared.dylib' = shared()

            """)
    }

    func test_theConfigStatesTheTargetAndTheStandardsTheSourcesNeed() throws {
        XCTAssertEqual(try config("project(p C)\nadd_executable(a a.c)"), """
            // Written by semel-cmake from CMakeLists.txt: this project's choices, laid over the
            // machine's semel.machine.config by the formula — the target, and the standards the
            // project states or clang's own where it states none. Spelled out per tool because a
            // tool's settings are complete where they are written. semel-cmake never overwrites
            // this file.
            //
            // Values are literal: everything after the first `=` is the value, quotes included.

            clang.preprocessor.target=arm64-apple-macosx14.0
            clang.preprocessor.cStandard=gnu17

            clang.compiler.target=arm64-apple-macosx14.0
            clang.compiler.cStandard=gnu17

            clang.linker.target=arm64-apple-macosx14.0

            """)
        let mixed = try config("""
            set(CMAKE_C_STANDARD 99)
            set(CMAKE_C_EXTENSIONS OFF)
            set(CMAKE_CXX_STANDARD 20)
            add_executable(a a.c b.cpp)
            """)
        XCTAssertTrue(mixed.contains("clang.preprocessor.cStandard=c99\nclang.preprocessor.cxxStandard=gnu++20\n"), mixed)
        XCTAssertTrue(mixed.contains("clang.compiler.cStandard=c99\nclang.compiler.cxxStandard=gnu++20\n"), mixed)
        XCTAssertTrue(mixed.hasSuffix("clang.linker.target=arm64-apple-macosx14.0\nclang.linker.cxxStandard=gnu++20\n"), mixed)
    }

    // MARK: - Rules

    func test_whatAStaticLibraryLinksItsConsumersLinkAndWhatItCompilesWithTheyDoNot() throws {
        let text = try formula("""
            add_library(base base.c)
            target_compile_definitions(base PRIVATE BASE_PRIVATE INTERFACE BASE_INTERFACE)
            target_link_libraries(base PRIVATE z)
            add_library(middle middle.c)
            target_link_libraries(middle PUBLIC base)
            add_executable(app app.c)
            target_link_libraries(app PRIVATE middle)
            """)
        XCTAssertTrue(text.contains("SettingsLiteral(defines: 'BASE_INTERFACE')])],\n  input: [file: StaticFile(path: file)]\n)\n\nfunc compiled_middle"), text)
        XCTAssertTrue(text.contains("SettingsLiteral(defines: 'BASE_INTERFACE')])],\n  input: [file: StaticFile(path: file)]\n)\n\nfunc compiled_app"), text)
        XCTAssertTrue(text.contains("SettingsLiteral(defines: 'BASE_PRIVATE')])],\n  input: [file: StaticFile(path: file)]\n)\n\nfunc compiled_base"), text)
        XCTAssertEqual(text.components(separatedBy: "BASE_PRIVATE").count, 2, "the private define reaches base alone")
        XCTAssertTrue(text.contains("override: [SettingsLiteral(dynamicLibrary: 'false', libraries: 'z')])],\n  objectFiles: [{file: <app.c>} \"%%file%%.o\": compiled_app(file: file)],\n  libraries: ['libmiddle.a': middle(), 'libbase.a': base()]"), text)
    }

    func test_optionsGoToTheStageThatReadsThem() throws {
        let text = try formula("""
            add_executable(app app.c)
            target_compile_options(app PRIVATE -O2 -DFROM_OPTION -Iextra -include pre.h -Wno-unused -std=gnu11)
            target_link_options(app PRIVATE -dead_strip)
            """)
        XCTAssertTrue(text.contains("SettingsLiteral(arguments: '-include,pre.h', cStandard: 'gnu11', defines: 'FROM_OPTION')"), text)
        XCTAssertTrue(text.contains("headerFolders: ['00 extra': Folder(path: <extra>).manifest]"), text)
        XCTAssertTrue(text.contains("SettingsLiteral(arguments: '-O2,-Wno-unused', cStandard: 'gnu11')"), text)
        XCTAssertTrue(text.contains("SettingsLiteral(arguments: '-dead_strip', dynamicLibrary: 'false')"), text)
    }

    func test_aTargetsStandardLaysOverTheProjects() throws {
        let text = try formula("""
            set(CMAKE_CXX_STANDARD 14)
            add_executable(app app.cpp)
            set_target_properties(app PROPERTIES CXX_STANDARD 20 CXX_EXTENSIONS OFF)
            """)
        XCTAssertTrue(text.contains("SettingsLiteral(cxxStandard: 'c++20')"), text)
    }

    func test_aGlobIsAnItemOfTheForEach() throws {
        let text = try formula("""
            file(GLOB_RECURSE SOURCES src/*.c)
            add_executable(app ${SOURCES} main.c)
            """)
        XCTAssertTrue(text.contains("objectFiles: [{file: <src/**/*.c>, <main.c>} \"%%file%%.o\""), text)
    }

    func test_whatIsOutsideTheProjectIsSaidAndNotPlaced() throws {
        let text = try formula("""
            add_executable(app app.c /opt/vendor/extra.c)
            target_include_directories(app PRIVATE /opt/vendor/include)
            """)
        XCTAssertTrue(text.contains("// Not placed, outside the project: /opt/vendor/extra.c\n// Not placed, outside the project: /opt/vendor/include\n"), text)
        XCTAssertTrue(text.contains("objectFiles: [{file: <app.c>} \"%%file%%.o\": clang.compiled(file: file, settings: settings())]"), text)
    }

    func test_aHeaderOnlyLibraryBuildsNothingAndATargetWithNoSourceSaysSo() throws {
        let text = try formula("""
            add_library(headers INTERFACE)
            target_include_directories(headers INTERFACE include)
            add_executable(docs README.md)
            add_executable(app app.c)
            target_link_libraries(app headers)
            """)
        XCTAssertTrue(text.contains("// headers: a header-only library, CMakeLists.txt:1\n// A header-only library"), text)
        XCTAssertTrue(text.contains("// docs: an executable, CMakeLists.txt:3\n// Nothing to compile: no source a compiler takes.\n"), text)
        XCTAssertFalse(text.contains("product 'docs'"), text)
        XCTAssertTrue(text.contains("headerFolders: ['00 include': Folder(path: <include>).manifest]"), text)
        XCTAssertFalse(text.contains("libraries: ["), text)
    }

    func test_aFuncNameIsMadeFromTheTargetName() throws {
        XCTAssertEqual(CMakeFormulaEmitter.identifiers(for: ["my-lib", "my_lib", "2fast", "settings"]),
                       ["my-lib": "my_lib", "my_lib": "my_lib_2", "2fast": "_2fast", "settings": "settings_2"])
    }

    func test_theOutputNameNamesTheProduct() throws {
        let text = try formula("""
            add_library(core STATIC core.c)
            set_target_properties(core PROPERTIES OUTPUT_NAME semelcore)
            add_executable(app app.c)
            target_link_libraries(app core)
            """)
        XCTAssertTrue(text.contains("product 'libsemelcore.a' = core()"), text)
        XCTAssertTrue(text.contains("libraries: ['libsemelcore.a': core()]"), text)
    }
}

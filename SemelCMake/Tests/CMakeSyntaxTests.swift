//
//  CMakeSyntaxTests.swift
//  SemelCMakeTests
//
//  The parser reads commands and their arguments and nothing else: what a command means
//  is the evaluator's. So what matters here is the three argument forms, escapes, the
//  references an argument keeps unexpanded, comments, and where a command is.
//

@testable import SemelCMake
import XCTest

final class CMakeSyntaxTests: XCTestCase {

    private func parse(_ text: String) throws -> [CMakeCommand] {
        try CMakeFile.parse(text, path: "CMakeLists.txt").commands
    }

    private func literals(_ command: CMakeCommand) -> [String?] {
        command.arguments.map(\.literalText)
    }

    func test_aCommandIsItsLowercasedNameAndItsArgumentsWithTheLineItStartsOn() throws {
        let commands = try parse("""
            cmake_minimum_required(VERSION 3.10)

            ADD_EXECUTABLE(hello
                main.c
                util.c)
            """)
        XCTAssertEqual(commands.map(\.name), ["cmake_minimum_required", "add_executable"])
        XCTAssertEqual(literals(commands[0]), ["VERSION", "3.10"])
        XCTAssertEqual(literals(commands[1]), ["hello", "main.c", "util.c"])
        XCTAssertEqual(commands.map(\.location.line), [1, 3])
        XCTAssertEqual(commands[1].location.file, "CMakeLists.txt")
    }

    func test_commentsAreSkippedBetweenAndInsideCommands() throws {
        let commands = try parse("""
            # a line comment
            set(A 1 # trailing
                2)
            #[[ a bracket
            comment ]] set(B 3)
            #[==[ with equals ]==]
            """)
        XCTAssertEqual(commands.map(\.name), ["set", "set"])
        XCTAssertEqual(literals(commands[0]), ["A", "1", "2"])
        XCTAssertEqual(literals(commands[1]), ["B", "3"])
    }

    func test_aQuotedArgumentIsOneArgumentWhateverItHolds() throws {
        let commands = try parse(#"set(FLAGS "-Wall -Wextra" "a;b")"#)
        XCTAssertEqual(commands[0].arguments.map(\.form), [.unquoted, .quoted, .quoted])
        XCTAssertEqual(literals(commands[0]), ["FLAGS", "-Wall -Wextra", "a;b"])
    }

    func test_aBracketArgumentIsVerbatim() throws {
        let commands = try parse("""
            set(TEXT [=[a "${not a reference}" \\n ]] still inside]=])
            """)
        XCTAssertEqual(commands[0].arguments[1].form, .bracket)
        XCTAssertEqual(commands[0].arguments[1].literalText, #"a "${not a reference}" \n ]] still inside"#)
    }

    func test_escapesAreResolvedInQuotedAndUnquotedArguments() throws {
        let commands = try parse(#"set(A "tab\there" "quote\"" dollar\$ "line\"# + "\n" + #"continued")"#)
        XCTAssertEqual(literals(commands[0]), ["A", "tab\there", "quote\"", "dollar$", "linecontinued"])
    }

    func test_aVariableReferenceIsKeptAsAPartAndMayNest() throws {
        let commands = try parse(#"add_executable(${NAME} src/${NAME}.c ${${PREFIX}_DIR}/x.c $ENV{HOME}/y.c)"#)
        let arguments = commands[0].arguments
        XCTAssertEqual(arguments[0].parts, [.variable([.literal("NAME")])])
        XCTAssertEqual(arguments[1].parts, [.literal("src/"), .variable([.literal("NAME")]), .literal(".c")])
        XCTAssertEqual(arguments[2].parts, [.variable([.variable([.literal("PREFIX")]), .literal("_DIR")]), .literal("/x.c")])
        XCTAssertEqual(arguments[3].parts, [.environment("HOME"), .literal("/y.c")])
        XCTAssertNil(arguments[0].literalText)
    }

    func test_aGeneratorExpressionIsOnePartWithItsText() throws {
        let commands = try parse(#"target_compile_definitions(t PRIVATE $<$<CONFIG:Debug>:DEBUG=1> PLAIN)"#)
        XCTAssertEqual(commands[0].arguments[2].parts, [.generatorExpression("$<$<CONFIG:Debug>:DEBUG=1>")])
        XCTAssertEqual(commands[0].arguments[3].literalText, "PLAIN")
    }

    func test_parenthesesInsideTheArgumentsAreArgumentsOfTheirOwn() throws {
        let commands = try parse("if((A AND B) OR C)")
        XCTAssertEqual(literals(commands[0]), ["(", "A", "AND", "B", ")", "OR", "C"])
    }

    func test_aLegacyUnquotedArgumentKeepsItsInnerQuotes() throws {
        let commands = try parse(#"add_definitions(-DNAME="hello world")"#)
        XCTAssertEqual(literals(commands[0]), [#"-DNAME="hello world""#])
    }

    func test_aCacheReferenceReadsAsTheVariable() throws {
        let commands = try parse(#"set(A $CACHE{B})"#)
        XCTAssertEqual(commands[0].arguments[1].parts, [.variable([.literal("B")])])
    }

    func test_anUnterminatedCommandIsAnErrorNamingIt() throws {
        XCTAssertThrowsError(try parse("set(A 1\nset(B 2)")) { error in
            XCTAssertEqual(error as? CMakeSyntaxError,
                           .unterminatedArguments(command: "set", at: CMakeLocation(file: "CMakeLists.txt", line: 1)))
        }
        XCTAssertThrowsError(try parse("set(A \"open)")) { error in
            XCTAssertEqual(error as? CMakeSyntaxError,
                           .unterminatedQuotedArgument(at: CMakeLocation(file: "CMakeLists.txt", line: 1)))
        }
        XCTAssertThrowsError(try parse("set A 1")) { error in
            XCTAssertEqual(error as? CMakeSyntaxError,
                           .missingOpeningParenthesis(command: "set", at: CMakeLocation(file: "CMakeLists.txt", line: 1)))
        }
        XCTAssertThrowsError(try parse("set(A ${B)")) { error in
            XCTAssertEqual(error as? CMakeSyntaxError,
                           .unterminatedVariableReference(at: CMakeLocation(file: "CMakeLists.txt", line: 1)))
        }
    }

    func test_anEmptyFileHasNoCommands() throws {
        XCTAssertEqual(try parse(""), [])
        XCTAssertEqual(try parse("  \n# only a comment\n"), [])
    }
}

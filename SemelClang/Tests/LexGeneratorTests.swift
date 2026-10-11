//
//  LexGeneratorTests.swift
//  SemelClangTests
//
//  lex turns a lexer description into a scanner beside it, `<name>.yy.c`, which the clang
//  stages compile (B-77 item 4). The command line, what is refused, and the real tool's
//  output being a function of its input.
//

@testable import SemelClang
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class LexGeneratorTests: SemelClangTestCase {

    private let descriptor = ToolDescriptor(name: "lex", version: "flex 2.6.4 Apple(flex-35)", platform: "macOS",
                                            architecture: "arm64", recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    private func configuration(arguments: String? = nil) -> String {
        var lines = ["toolDescriptor.name=\(descriptor.name)",
                     "toolDescriptor.version=\(descriptor.version)",
                     "toolDescriptor.platform=\(descriptor.platform)",
                     "toolDescriptor.architecture=\(descriptor.architecture)"]
        if let arguments {
            lines.append("arguments=\(arguments)")
        }
        return lines.joined(separator: "\n")
    }

    private func process(source: String = "input:/repo/Parsing/Tokens.l", text: String = "%%\n",
                         configuration: String? = nil) throws -> ProcessOutput {
        let node = try LexGenerator(thisNode: NodeRecord(id: 1, kind: LexGenerator.kind))
        return try node.process(input: ProcessInput(inputValues: [
            LexGenerator.configuration: ["configuration": .value(try (configuration ?? self.configuration()).intern())],
            LexGenerator.input: [source: .value(try text.intern())],
        ]))
    }

    // MARK: - Command line

    /// The description goes in at its path in the input file system and the scanner comes
    /// out beside it, as Xcode's lex rule names it, with `LEXFLAGS` first.
    func test_writesTheScannerBesideTheDescription() throws {
        executor.producedFiles["input:/repo/Parsing/Tokens.yy.c"] = Array("int yylex(void);".utf8)

        let output = try process(configuration: configuration(arguments: "-i"))

        XCTAssertEqual(executor.lastArguments, ["-i", "-o", "input:/repo/Parsing/Tokens.yy.c", "input:/repo/Parsing/Tokens.l"])
        XCTAssertEqual(executor.invocations.last?.inputFileNames, ["input:/repo/Parsing/Tokens.l"])
        XCTAssertEqual(try output.outputValues[LexGenerator.output]?.expectValue().resolveAsString(), "int yylex(void);")
    }

    /// The actions' language is the scanner's: a `.lm` is Objective-C, as Xcode compiles it.
    func test_theScannersLanguageFollowsTheDescriptions() {
        XCTAssertEqual(LexGenerator.generatedPath(of: "a/Tokens.l"), "a/Tokens.yy.c")
        XCTAssertEqual(LexGenerator.generatedPath(of: "a/Tokens.lm"), "a/Tokens.yy.m")
        XCTAssertEqual(LexGenerator.generatedPath(of: "a/Tokens.lpp"), "a/Tokens.yy.cpp")
        XCTAssertNil(LexGenerator.generatedPath(of: "a/Grammar.y"))
    }

    /// A file that is no lexer description is refused by name, with what is taken.
    func test_aFileThatIsNoLexerDescriptionIsRefused() throws {
        XCTAssertThrowsError(try process(source: "input:/repo/Parsing/Grammar.y")) { error in
            XCTAssertEqual(error as? ErrorCondition,
                           .sourceNotTaken(path: "input:/repo/Parsing/Grammar.y", tool: "lex",
                                           takes: [".l", ".lm", ".lmm", ".lpp", ".lxx"]))
        }
    }

    /// A scanner that names the folder the run had would be a different value every run.
    func test_aScannerNamingItsSandboxIsRefused() throws {
        executor.producedFiles["input:/repo/Parsing/Tokens.yy.c"] = Array("#line 1 \"/tmp/recording-tool-sandbox/x.l\"".utf8)

        let output = try process()

        XCTAssertEqual(output.outputValues[LexGenerator.output]?.errorDocument?.diagnostic,
                       .engine(.toolOutputNamesItsSandbox(tool: "lex", file: "input:/repo/Parsing/Tokens.yy.c")))
    }

    func test_aFailedRunIsTheToolsError() throws {
        executor.exitCode = 1
        executor.errorOutput = "Tokens.l:3: unrecognized rule"

        let output = try process()

        XCTAssertNotNil(output.outputValues[LexGenerator.output]?.errorDocument)
    }

    // MARK: - The real tool

    /// Two runs of the machine's lex, each in a sandbox of its own, write the same bytes,
    /// and the only path in them is the one the node gave: the scanner is published as lex
    /// writes it.
    func test_theRealLexWritesTheSameScannerTwice() throws {
        let lex = try XCTUnwrap(ClangToolDiscovery.locate("lex"))
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: try LocalFileSystemTool(localPath: lex))
        let description = """
            %option noyywrap
            %option prefix="to"
            %%
            [0-9]+    { return 1; }
            .         { return 2; }
            %%
            """

        var scanners: [String] = []
        for _ in 0..<2 {
            let output = try process(text: description)
            scanners.append(try XCTUnwrap(output.outputValues[LexGenerator.output]).expectValue())
        }

        XCTAssertEqual(scanners[0], scanners[1])
        let text = try scanners[0].resolveAsString()
        XCTAssertTrue(text.contains("#line 1 \"input:/repo/Parsing/Tokens.l\""), String(text.prefix(400)))
        XCTAssertTrue(text.contains("tolex"), "the prefix option names the scanner")
    }
}

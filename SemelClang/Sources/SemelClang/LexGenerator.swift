// LexGenerator.swift
// SemelClang
//
// Runs the toolchain's `lex` over one lexer description, a `.l` file, writing the scanner it
// describes as C: `SPSQLTokenizer.l` becomes `SPSQLTokenizer.yy.c`, beside it, which the
// clang stages then build as any other source of the target (B-77 item 4).

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct LexGeneratorConfiguration {
    let toolDescriptor: ToolDescriptor
    /// `arguments`: Xcode's `LEXFLAGS`, comma-joined like every list in a setting, before
    /// the output and the source.
    let arguments: [String]

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        try required.check()
        arguments = clangArguments(properties)
    }

    /// Pinned under `clang.`: the derivation would make the domain `lex`, and lex is
    /// the clang toolchain's, its output what the clang stages compile.
    static let settingNamespace = "clang.lexGenerator"
}

// MARK: - Node

/// lex is a function of its input: on flex 2.6.4 (Apple flex-35), both of Sequel Ace's
/// scanners came out byte for byte the same from two runs in two folders under another time
/// zone and locale. Nothing it writes names a time; the one path in the scanner is in its
/// `#line` directives, the name it was given for the source and the output — the wire's key
/// here, relative to the sandbox like every path on a command line. So the C is published as
/// lex writes it, except that a scanner naming the sandbox's real folder is refused rather
/// than published (`toolOutputNamesItsSandbox`), since that would be a different value on
/// every run.
public struct LexGenerator: Node {
    public static let kind: UInt = 45

    // MARK: Ports

    static let configuration = "configuration"
    /// The lexer description, one wire, keyed by its path in the input file system, which is
    /// the name lex is given and the one its `#line` directives carry.
    static let input = "input"
    /// The scanner, C for a `.l`: what the clang stages compile.
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(configuration), .required(input)],
        outputPorts: [output, errorLog, infoLog]
    )

    /// What each lexer description becomes, by extension, as Xcode's lex rule names it: the
    /// language of the actions is the language of the scanner, so a `.lm` is Objective-C.
    static let generatedExtensions = ["l": "yy.c", "lm": "yy.m", "lmm": "yy.mm", "lpp": "yy.cpp", "lxx": "yy.cxx"]

    /// `Parsing/SPSQLTokenizer.l` -> `Parsing/SPSQLTokenizer.yy.c`; nil for a file that is
    /// no lexer description.
    static func generatedPath(of sourcePath: String) -> String? {
        let path = sourcePath as NSString
        guard let generated = generatedExtensions[path.pathExtension] else {
            return nil
        }
        return path.deletingPathExtension + "." + generated
    }

    // MARK: Processing

    /// The binary behind the tool version the configuration names: two builds of one
    /// version may write a scanner differently (B-17).
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try toolBinaryCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }

    /// A failure belongs to the lexer description.
    public func errorSubject(input: ProcessInput?) -> ErrorDocument.Subject? {
        input?.inputValues[Self.input]?.keys.min().map { .source(path: $0) }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let configurationText = try input.onlyWire(onRequiredPort: Self.configuration).value.expectValue().resolveAsString()
        let configuration = try LexGeneratorConfiguration(properties: [String: String](plainText: configurationText))

        let sourceWire = try input.onlyWire(onRequiredPort: Self.input)
        let sourcePath = sourceWire.key
        guard let generatedPath = Self.generatedPath(of: sourcePath) else {
            throw ErrorCondition.sourceNotTaken(path: sourcePath, tool: "lex",
                                                takes: Self.generatedExtensions.keys.sorted().map { ".\($0)" })
        }
        let source = FileNameAndContent(filePath: sourcePath, hash: try sourceWire.value.expectValue())

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: configuration.toolDescriptor,
                                                        namespace:  LexGeneratorConfiguration.settingNamespace)
        let result = try tool.execute(arguments: configuration.arguments + ["-o", generatedPath, sourcePath],
                                      environment: [:],
                                      inputFiles: [source],
                                      expectedOutputFileNames: [generatedPath])

        let subject = ErrorDocument.Subject.source(path: sourcePath)
        var output = try result.asOutputNodeValue(tool: "lex", subject: subject)
        if case .value(let scanner) = output {
            output = try Self.scannerNamingNoSandbox(hash: scanner, generatedPath: generatedPath,
                                                     sandboxPath: result.resolvedSandboxPath, subject: subject)
        }
        return .init(outputValues: [Self.output:   output,
                                    Self.errorLog: .value(try result.errorOutput.intern()),
                                    Self.infoLog:  .value(try result.infoOutput.intern())],
                     inputWireSpecs: [:])
    }

    /// The scanner as lex wrote it, or an error when it names the folder the run had.
    static func scannerNamingNoSandbox(hash: DataObjectHash, generatedPath: String, sandboxPath: String,
                                       subject: ErrorDocument.Subject) throws -> NodeValue {
        guard !ToolSandbox.names(sandboxPath: sandboxPath, in: try hash.resolve()) else {
            return try ErrorDocument.engine(.toolOutputNamesItsSandbox(tool: "lex", file: generatedPath), subject: subject).published()
        }
        return .value(hash)
    }
}

// ClangPreprocessorTool.swift
// build_system
//
// Clang preprocessor stage: runs `clang -E` on a .c file and its headers,
// producing a preprocessed .p file ready for the compiler stage.

import Foundation

// MARK: - Configuration

struct ClangPreprocessorToolConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    /// Path to the SDK root (e.g. `/path/to/MacOSX.sdk`).
    /// When set, `-isysroot <sdkPath>` is passed so clang can find system headers.
    /// Supply via `Configuration(sdkPath: '/path/to/MacOSX.sdk')` in the formula.
    let sdkPath: String?
    /// C++ language standard, e.g. `"c++17"` or `"c++20"`.
    /// Defaults to `"c++17"` for C++ source files when not specified.
    /// Supply via `Configuration(std: 'c++17')` in the formula.
    let std: String?

    init(properties: [String: String]) {
        toolDescriptor = .init(properties: properties)
        arguments = []
        environment = [:]
        sdkPath = properties["sdkPath"]
        std     = properties["std"]
    }
}

// MARK: - Node

public struct ClangPreprocessorTool: NodeFunction {
    public static let kind: UInt = 17

    var embeddedNode: Node

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    // MARK: Ports

    static let configuration = "configuration"
    static let sourceFileInput = "input"
    static let includeFileLists = "includeFileLists"
    static let headerInputFiles = "headerInputFiles"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    static let descriptor = NodeFunctionDescriptor(
        inputPorts: [
            .required(configuration),
            .required(sourceFileInput),
            .dynamic(includeFileLists),
            .dynamic(headerInputFiles),
        ],
        outputPorts: [output, errorLog, infoLog]
    )

    // MARK: Processing

    struct ClangPreprocessorToolInputs {
        let configuration: ClangPreprocessorToolConfiguration
        let inputSourceFile: FileNameAndContent
        let headerFiles: [FileNameAndContent]
        let includePathLists: [String: [String]]

        init(input: ProcessInput) throws {
            let configurationString = try input.inputValues[ClangCompilerTool.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = .init(properties: [String: String](plainText: configurationString))

            let sourceFileInput = input.inputValues[ClangPreprocessorTool.sourceFileInput]!.first!
            inputSourceFile = .init(filePath: sourceFileInput.key, hash: try sourceFileInput.value.expectValue())

            let headerInputFiles = input.inputValues[ClangPreprocessorTool.headerInputFiles]!

            var headerFiles: [FileNameAndContent] = []

            for (headerFileName, nodeValue) in headerInputFiles {
                headerFiles.append(.init(filePath: headerFileName, hash: try nodeValue.expectValue()))
            }

            self.headerFiles = headerFiles

            includePathLists = try Dictionary(uniqueKeysWithValues: input.inputValues[ClangPreprocessorTool.includeFileLists]!.map { includeFilesValue in
                let wireName = includeFilesValue.key
                let list = try includeFilesValue.value
                    .expectValue()
                    .resolveAsString()
                    .split(separator: "\n")
                    .map { String($0) }
                return (wireName, list)
            })
        }
    }

    struct ClangPreprocessorToolOutputs {
        let output: NodeValue
        let errorLog: NodeValue
        let infoLog: NodeValue

        let headerInputFilesWireExpectations: [String: String]
        let includeFileListWireExpections: [String: String]

        func asProcessOutput() -> ProcessOutput {
            return .init(outputValues: [ClangPreprocessorTool.output: output,
                                 ClangPreprocessorTool.errorLog: errorLog,
                                 ClangPreprocessorTool.infoLog: infoLog],
                  inputWireExpectations: [ClangPreprocessorTool.headerInputFiles: headerInputFilesWireExpectations,
                                          ClangPreprocessorTool.includeFileLists: includeFileListWireExpections])
        }
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    /// Returns the clang `-x` language flag for `filePath`, handling raw source
    /// files (`.cpp`), preprocessed files (`.cpp.p`), and object files (`.cpp.p.o`).
    static func language(for filePath: String) -> String {
        var lower = filePath.lowercased()
        if lower.hasSuffix(".o") { lower = String(lower.dropLast(2)) }
        let cppSuffixes = [".cpp", ".cc", ".cxx", ".c++",
                           ".cpp.p", ".cc.p", ".cxx.p", ".c++.p"]
        return cppSuffixes.contains(where: { lower.hasSuffix($0) }) ? "c++" : "c"
    }

    private func runPreprocessor(inputs: ClangPreprocessorToolInputs,
                                 headerInputFilesWireExpectations: [String: String],
                                 includeFileListWireExpections: [String: String]) throws -> ClangPreprocessorToolOutputs {

        let outputFilename = inputs.inputSourceFile.filePath + ".p"

        var arguments = [String]()

        // Preprocess only.
        let language = Self.language(for: inputs.inputSourceFile.filePath)
        arguments.append("-E")
        arguments.append("-x"); arguments.append(language)
        arguments.append("-I"); arguments.append(".")

        let effectiveStd = inputs.configuration.std ?? (language == "c++" ? "c++17" : nil)
        if let std = effectiveStd {
            arguments.append("-std=\(std)")
        }

        if let sdkPath = inputs.configuration.sdkPath {
            // -isysroot locates the SDK without stripping the compiler's own include
            // paths (-nostdinc would do that, breaking C++ standard-library headers
            // which live in the toolchain, not the SDK).
            arguments.append("-isysroot"); arguments.append(sdkPath)
        }

        arguments.append("-target"); arguments.append("arm64-apple-macos14.0")
        arguments.append(inputs.inputSourceFile.filePath)
        arguments.append("-o"); arguments.append(outputFilename)
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var inputFiles: [FileNameAndContent] = [.init(filePath: inputs.inputSourceFile.filePath, hash: inputs.inputSourceFile.hash)]

        inputFiles.append(contentsOf: inputs.headerFiles)

        let result = try tool.execute(arguments: arguments,
                                      environment: inputs.configuration.environment,
                                      inputFiles: inputFiles,
                                      expectedOutputFileNames: [outputFilename])

        return .init(output: try result.asOutputNodeValue(),
                     errorLog: .value(try result.errorOutput.intern()),
                     infoLog: .value(try result.infoOutput.intern()),
                     headerInputFilesWireExpectations: headerInputFilesWireExpectations,
                     includeFileListWireExpections: includeFileListWireExpections)
    }

    func process(inputs: ClangPreprocessorToolInputs) throws -> ClangPreprocessorToolOutputs {

        var headerInputFilesWireExpectations = [String: String]()

        let setOfIncludeFiles: Set<String> = Set(inputs.includePathLists.flatMap { (_, list) in list })

        let aggregatedIncludePathList: [String] = .init(setOfIncludeFiles)

        for includePath in aggregatedIncludePathList {
            headerInputFilesWireExpectations[includePath] = "StaticFile(path: '\(includePath)').output"
        }

        var includeFileListWireExpections = [String: String]()

        for sourcePath in (aggregatedIncludePathList + [inputs.inputSourceFile.filePath]) {
            includeFileListWireExpections[sourcePath] = "IncludeFinder(sourceFile: ['\(sourcePath)': StaticFile(path: '\(sourcePath)').output]).includePathList"
        }

        // There must be one IncludeFinder attached to the .c file.

        if inputs.includePathLists[inputs.inputSourceFile.filePath] == nil {
            let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try "Still resolving include files".intern()))
            return .init(output: error,
                         errorLog: error,
                         infoLog: error,
                         headerInputFilesWireExpectations: headerInputFilesWireExpectations,
                         includeFileListWireExpections: includeFileListWireExpections)
        }

        // do we have input wires for each of the Headers mentioned in the aggregated Include list?
        //    no -> set our output to Error but set our Expected Header File Wires to equal the Include List, so that new wires will be connected
        //          that will cause us to be scheduled for processing a second time. and connecting a new wire instantly causes all downstream
        //          nodes' outputs to go to Pending, including us.
        //    yes -> proceed to running the preprocessor
        guard inputs.headerFiles.count == aggregatedIncludePathList.count else {
            let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try "Still resolving include files".intern()))
            return .init(output: error,
                         errorLog: error,
                         infoLog: error,
                         headerInputFilesWireExpectations: headerInputFilesWireExpectations,
                         includeFileListWireExpections: includeFileListWireExpections)
        }

        return try runPreprocessor(inputs: inputs,
                                   headerInputFilesWireExpectations: headerInputFilesWireExpectations,
                                   includeFileListWireExpections: includeFileListWireExpections)
    }
}

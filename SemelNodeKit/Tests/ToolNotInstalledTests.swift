//
//  ToolNotInstalledTests.swift
//  SemelNodeKitTests
//
//  B-109. After a toolchain update the machine file names a clang that is gone, and every
//  tool below it fails asking for it. The failure names what was asked for and what is
//  installed, and — since the one fix is to write the file again — the setting that named
//  it and the command its toolchain registered to rewrite the file.
//

import SemelNodeKit
import XCTest

final class ToolNotInstalledTests: XCTestCase {

    private let installed = ToolDescriptor(name: "clang", version: "Apple clang 21", platform: "macOS",
                                           architecture: "arm64", recursiveHash: nil)
    private let stale     = ToolDescriptor(name: "clang", version: "Apple clang 17", platform: "macOS",
                                           architecture: "arm64", recursiveHash: nil)

    private struct NoTool: ToolRunner {
        func execute(arguments: [String],
                     environment: [String: String],
                     inputFiles: [FileNameAndContent],
                     expectedOutputFileNames: [String],
                     expectedOutputFolders: [String],
                     output: ToolOutput) throws -> ToolExecuteResult {
            ToolExecuteResult(exitCode: 0, resolvedSandboxPath: "/tmp/no-tool")
        }
    }

    private func failure(namespace: String) -> String {
        let registry = ToolRunnerRegistry()
        registry.registerTool(descriptor: installed, toolExecutor: NoTool())
        do {
            _ = try registry.tool(descriptor: stale, namespace: namespace)
            XCTFail("a tool that is not installed is not handed over")
            return ""
        } catch {
            return String(describing: error)
        }
    }

    func test_aToolNotInstalledNamesTheCommandThatRewritesTheMachineFile() {
        ToolNamespaceRegistry.register(.init(namespace: "stale.compiler", toolName: "clang",
                                             machineFileWriter: .init(command: "semel-clang", rewriteFlags: ["--force"])))

        XCTAssertEqual(failure(namespace: "stale.compiler"), """
            no tool matches clang Apple clang 17 (macOS/arm64); registered: clang Apple clang 21 (macOS/arm64)
            stale.compiler.toolDescriptor.* names it; when that is semel.machine.config, written before the \
            toolchain changed, 'semel-clang <folder> --force' rewrites it with the tools installed here.
            """)
    }

    /// A writer that rewrites its own blocks on every run is named without a flag.
    func test_aWriterThatRewritesEveryRunIsNamedAsItIsRun() {
        ToolNamespaceRegistry.register(.init(namespace: "stale.linker", toolName: "clang",
                                             machineFileWriter: .init(command: "semel-swift prepare")))

        let message = failure(namespace: "stale.linker")
        XCTAssertTrue(message.contains("'semel-swift prepare <folder>' rewrites it"), message)
    }

    /// A namespace whose toolchain registered no writer still says which settings named the
    /// tool, and invents no command.
    func test_aNamespaceWithNoWriterNamesTheSettingOnly() {
        ToolNamespaceRegistry.register(.init(namespace: "stale.archiver", toolName: "clang"))

        let message = failure(namespace: "stale.archiver")
        XCTAssertTrue(message.hasSuffix("\nstale.archiver.toolDescriptor.* names it."), message)
        XCTAssertFalse(message.contains("rewrites"), message)
    }
}

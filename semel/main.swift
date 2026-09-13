//
//  main.swift
//  semel
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import SemelCore
import SemelCLI
import SemelNodeKit
import SemelSwift
import SemelClang

var commandInterpreter: CommandInterpreter?

func main() throws {
    print("Semel \(Semel.version) (C) 2026 Jade Burton. All rights reserved.")
    print("Graph: \(SemelPaths.database.path)")

    // Composition root: the engine knows no toolchains, so this is where the ones this
    // binary ships are installed. Before start(), so discovery sees them on its first pass.
    try SemelSwift.register()
    try SemelClang.register()

    try BuildEngine.start()

    // Composition root: the process-wide engine and database are resolved once, here, and
    // handed to everything else.
    commandInterpreter = CommandInterpreter(database: DatabaseLayer.shared,
                                            buildEngine: BuildEngine.shared)

    // Non-interactive: each argument is one command line, run in order, then exit —
    // non-zero if any command reported an error. `semel 'build Packages'` is a build step;
    // `semel 'base /repo' 'push src' wait errors` is the same thing spelled out.
    let scripted = Array(CommandLine.arguments.dropFirst())
    if !scripted.isEmpty {
        for command in scripted {
            guard receiveUserInput(line: command) else {
                break
            }
        }
        exit(commandInterpreter!.errorsReported == 0 ? 0 : 1)
    }

    while let line = readLine(), receiveUserInput(line: line) {
    }
}

func receiveUserInput(line: String) -> Bool {
    do {
        try commandInterpreter?.handleCommand(line)
        return true
    } catch {
        return false
    }
}

#if !UNIT_TESTING
try main()
#endif

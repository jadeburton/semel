//
//  main.swift
//  build_system
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import BuildSystemCore
import BuildSystemCLI

var commandInterpreter: CommandInterpreter?

func main() throws {
    print("Semel 1.0 (C) 2026 Jade Burton. All rights reserved.")

    try BuildEngine.start()

    // Composition root: the process-wide engine and database are resolved once, here, and
    // handed to everything else.
    commandInterpreter = CommandInterpreter(database: DatabaseLayer.shared,
                                            buildEngine: BuildEngine.shared)
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

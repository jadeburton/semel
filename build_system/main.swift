//
//  main.swift
//  build_system
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import GRDB
import DatabaseModels

func main() throws {
    print("Build System 1.0 (C) 2026 Jade Burton. All rights reserved.")

    FileManager.default.changeCurrentDirectoryPath("/Users/jadeburton/Desktop/C1/C1")
    let buildEngine = BuildEngine.shared

    while let line = readLine() {
        buildEngine.receiveUserInput(line: line)
    }
}

try main()

//
//  main.swift
//  build_system
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import MyLibraryTargetA
import MyLibraryTargetB

protocol OtherProtocol {
    var myString: String { get }
}

class MyClass: MyBaseClass {
    let myOtherString: String = "This is a different string."
}

func main() throws {
    print("Build System 2.0 (C) 2026 Jade Burton. All rights reserved.")
    print(StringUtility.blah(a: "x"))
    print(WordPattern.firstWord(in: "42 semel") ?? "")
}

try main()

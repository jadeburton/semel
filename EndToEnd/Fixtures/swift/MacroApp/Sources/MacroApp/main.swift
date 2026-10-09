import Observation
import Stringify
import SwiftData

/// Expanded by the toolchain's Observation plugin.
@Observable
final class Counter {
    var count = 0
}

/// Expanded by the macOS platform's SwiftData plugin.
@Model
final class Bird {
    var name: String

    init(name: String) {
        self.name = name
    }
}

let counter = Counter()
counter.count += 2
let (value, text) = #stringify(1 + counter.count)
print("\(text) = \(value)")
print("Bird is a persistent model: \(Bird.self is any PersistentModel.Type)")

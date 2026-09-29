import Foundation
import Greeting

/// Prints what the binary framework behind the `Greeting` package says, so running the
/// built app shows that the framework was linked, embedded and found at run time; then
/// what two files of the synchronized folder say, read from the bundle's resources as the
/// app finds them at launch — a plist and a JSON file two folders down, each copied by
/// its name alone, as Xcode copies them.
@main
struct GreeterApp {
    static func main() {
        print(Greeting.text())
        print(farewell() ?? "no Messages.plist in the bundle")
        print(note() ?? "no Settings.json in the bundle")
    }

    static func farewell() -> String? {
        guard let url = Bundle.main.url(forResource: "Messages", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let messages = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            return nil
        }
        return messages["Farewell"]
    }

    static func note() -> String? {
        guard let url = Bundle.main.url(forResource: "Settings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return settings["note"]
    }
}

import Greeting

/// Prints what the binary framework behind the `Greeting` package says, so running the
/// built app shows that the framework was linked, embedded and found at run time.
@main
struct GreeterApp {
    static func main() {
        print(Greeting.text())
    }
}

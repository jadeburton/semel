import Tiny

public enum Greeting {
    /// The text the framework's C function returns.
    public static func text() -> String {
        String(cString: tiny_greeting())
    }
}

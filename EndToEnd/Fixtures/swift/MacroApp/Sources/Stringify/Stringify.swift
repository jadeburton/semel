/// The value of an expression, and the text it was written as.
@freestanding(expression)
public macro stringify<T>(_ value: T) -> (T, String) = #externalMacro(module: "StringifyMacros", type: "StringifyMacro")

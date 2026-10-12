// ErrorMark.swift
// semel
//
// The mark an error the client prints starts with (B-161).

/// The one place the client marks an error, so that it stands out from the lines around it:
/// a refusal printed under a push's count reads as part of the count when nothing sets it
/// apart. `CommandInterpreter.outputError` marks every error a command reports, and `main`
/// marks the few it prints before there is an interpreter; nothing else adds the glyph.
///
/// An emoji rather than a colour code: it is red at any terminal, whatever `NO_COLOR` or
/// the colour policy says, and it is still there in a pipe, a log or a script's output,
/// where an error has to be found just as much.
public enum ErrorMark {

    /// A red cross.
    public static let glyph = "❌"

    /// `message` with the glyph before its first line. The lines after it are the error's
    /// details, indented under it, and are left as they are.
    public static func marked(_ message: String) -> String {
        "\(glyph) \(message)"
    }
}

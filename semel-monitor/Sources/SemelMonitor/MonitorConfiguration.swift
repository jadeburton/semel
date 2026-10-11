// MonitorConfiguration.swift
// SemelMonitor
//
// The command line: `semel-monitor [--print] [--only <folder>]...`.

public struct MonitorConfiguration: Equatable {

    /// Cards as lines on standard output, with no panels and no status item.
    public var prints = false

    /// Folders of `output:` whose products make cards; empty for every product.
    public var only: [String] = []

    public init(prints: Bool = false, only: [String] = []) {
        self.prints = prints
        self.only   = only
    }

    public static let usage = """
        usage: semel-monitor [--print] [--only <folder>]...
          Shows what each settle of the engine did, as a card at the top right of the screen.
          --print          write each card as lines on standard output instead
          --only <folder>  only products under this folder of output: (repeatable)
        """

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingFolder
        case unknownArgument(String)

        public var description: String {
            switch self {
            case .missingFolder:               return "--only needs a folder of output:"
            case .unknownArgument(let given):  return "unknown argument: \(given)"
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> MonitorConfiguration {
        var configuration = MonitorConfiguration()
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--print":
                configuration.prints = true
            case "--only":
                guard let folder = remaining.popFirst(), !folder.hasPrefix("--") else {
                    throw ParseError.missingFolder
                }
                configuration.only.append(folder)
            default:
                throw ParseError.unknownArgument(argument)
            }
        }
        return configuration
    }
}

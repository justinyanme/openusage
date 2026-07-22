import Foundation

enum CLICommand: Equatable, Sendable {
    case limits
    case spend
}

struct CLIArguments: Equatable, Sendable {
    var command: CLICommand = .limits
    var providerID: String?
    var force = false
    var showHelp = false
    var showVersion = false

    static func parse(_ arguments: [String]) throws -> CLIArguments {
        var parsed = CLIArguments()
        var positionals: [String] = []
        for argument in arguments {
            switch argument {
            case "--force": parsed.force = true
            case "-h", "--help": parsed.showHelp = true
            case "-v", "--version": parsed.showVersion = true
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.usage("Unknown option: \(argument)")
                }
                positionals.append(argument.lowercased())
            }
        }
        if positionals.first == "spend" {
            parsed.command = .spend
            positionals.removeFirst()
        }
        guard positionals.count <= 1 else {
            throw CLIError.usage("Only one provider can be requested at a time.")
        }
        parsed.providerID = positionals.first
        return parsed
    }
}

enum CLIError: Error, Equatable {
    case usage(String)
    case appDefaultsUnavailable
}

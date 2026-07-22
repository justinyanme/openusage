import Darwin
import Foundation
import OpenUsage

struct CLIOutput: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32

    static func make(data: Data, warnings: [String]) -> CLIOutput {
        var stdout = data
        stdout.append(contentsOf: "\n".utf8)
        let stderr = Data(
            warnings
                .map { "openusage: warning: \($0)\n" }
                .joined()
                .utf8
        )
        return CLIOutput(
            stdout: stdout,
            stderr: stderr,
            exitCode: warnings.isEmpty ? 0 : 4
        )
    }
}

@main
struct OpenUsageCLI {
    static func main() async {
        do {
            let arguments = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
            if arguments.showHelp {
                print(help)
                return
            }

            let app = AppBundleLocator.locate()
            if arguments.showVersion {
                print(app.version.map { "openusage \($0)" } ?? "openusage (development build)")
                return
            }

            guard let defaults = UserDefaults(suiteName: app.bundleIdentifier) else {
                throw CLIError.appDefaultsUnavailable
            }
            let result = try await UsageReader(
                userDefaults: defaults,
                iCloudContainerIdentifier: app.iCloudContainerIdentifier
            ).read(
                providerID: arguments.providerID,
                force: arguments.force,
                output: arguments.command == .spend ? .spend : .limits
            )
            let output = CLIOutput.make(data: result.data, warnings: result.warnings)
            FileHandle.standardOutput.write(output.stdout)
            FileHandle.standardError.write(output.stderr)
            if output.exitCode != 0 { exit(output.exitCode) }
        } catch CLIError.usage(let message) {
            fail("\(message)\nRun 'openusage --help' for usage.", code: 2)
        } catch CLIError.appDefaultsUnavailable {
            fail("Could not open the OpenUsage settings domain.", code: 4)
        } catch UsageReaderError.unknownProvider(let providerID) {
            fail("Unknown provider: \(providerID)", code: 2)
        } catch {
            fail(error.localizedDescription, code: 4)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("openusage: \(message)\n".utf8))
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        writeError(message)
        exit(code)
    }

    private static let help = """
    Usage: openusage [provider] [--force]
           openusage spend [provider] [--force]

    Read limits, or explicit spend history, through OpenUsage's shared five-minute cache and exit.
    Output is always JSON; the default command remains the limits helper.

    Options:
      --force      Refresh even when the shared cache is still fresh
      -v, --version
      -h, --help
    """
}

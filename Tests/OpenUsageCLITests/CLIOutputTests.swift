import Foundation
import XCTest
@testable import OpenUsageCLI

final class CLIOutputTests: XCTestCase {
    func testWarningExecutionKeepsValidJSONAndReturnsExitFour() throws {
        let json = Data(#"{"errors":[],"providers":{},"schema":"openusage.spend.v1"}"#.utf8)
        let execution = CLIOutput.make(data: json, warnings: ["claude: retained last good"])

        XCTAssertEqual(execution.exitCode, 4)
        XCTAssertEqual(execution.stdout, json + Data("\n".utf8))
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: execution.stdout) as? [String: Any])?["schema"] as? String,
            "openusage.spend.v1"
        )
        XCTAssertEqual(
            String(decoding: execution.stderr, as: UTF8.self),
            "openusage: warning: claude: retained last good\n"
        )
    }

    func testBuiltCLIExecutesAsARealSubprocess() throws {
        let executable = try builtCLIURL()

        let help = try run(executable, arguments: ["--help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(String(decoding: help.stdout, as: UTF8.self).contains("openusage spend"))

        let invalid = try run(executable, arguments: ["--not-an-option"])
        XCTAssertEqual(invalid.status, 2)
        XCTAssertTrue(String(decoding: invalid.stderr, as: UTF8.self).contains("Unknown option"))
    }

    private func builtCLIURL() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildDirectory = repository.appendingPathComponent(".build")
        let candidates = try FileManager.default.subpathsOfDirectory(atPath: buildDirectory.path)
            .filter { $0 == "debug/openusage-cli" || $0.hasSuffix("/debug/openusage-cli") }
            .map(buildDirectory.appendingPathComponent)
        if let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return executable
        }
        throw XCTSkip("built openusage-cli executable was not found under .build")
    }

    private func run(_ executable: URL, arguments: [String]) throws
        -> (status: Int32, stdout: Data, stderr: Data)
    {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }
}

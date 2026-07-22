import XCTest
@testable import OpenUsageCLI

final class CLIArgumentsTests: XCTestCase {
    func testParsesProviderAndForce() throws {
        let parsed = try CLIArguments.parse(["Codex", "--force"])
        XCTAssertEqual(parsed.command, .limits)
        XCTAssertEqual(parsed.providerID, "codex")
        XCTAssertTrue(parsed.force)
    }

    func testParsesSpendSubcommandWithOptionsOnEitherSide() throws {
        let leadingOption = try CLIArguments.parse(["--force", "spend", "Claude"])
        let trailingOption = try CLIArguments.parse(["spend", "Codex", "--force"])

        XCTAssertEqual(leadingOption.command, .spend)
        XCTAssertEqual(leadingOption.providerID, "claude")
        XCTAssertTrue(leadingOption.force)
        XCTAssertEqual(trailingOption.command, .spend)
        XCTAssertEqual(trailingOption.providerID, "codex")
        XCTAssertTrue(trailingOption.force)
    }

    func testSpendWithoutProviderSelectsEnabledProviders() throws {
        let parsed = try CLIArguments.parse(["spend"])

        XCTAssertEqual(parsed.command, .spend)
        XCTAssertNil(parsed.providerID)
    }

    func testRejectsUnknownOptionsAndMultipleProviders() {
        XCTAssertThrowsError(try CLIArguments.parse(["--json"]))
        XCTAssertThrowsError(try CLIArguments.parse(["claude", "codex"]))
        XCTAssertThrowsError(try CLIArguments.parse(["claude", "spend"]))
    }
}

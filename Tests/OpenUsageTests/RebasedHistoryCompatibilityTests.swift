import XCTest
@testable import OpenUsage

final class RebasedHistoryCompatibilityTests: XCTestCase {
    func testAccountScopedCodexScanUsesThirtyCalendarDays() async throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12)))
        let today = calendar.startOfDay(for: now)
        let firstDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -29, to: today))
        let excludedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: today))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/included.jsonl": CodexLogFixture.tokenCount(
                timestamp: OpenUsageISO8601.string(from: firstDay),
                last: CodexLogFixture.usage(input: 100, output: 50), model: "gpt-5.2"
            ),
            "sessions/excluded.jsonl": CodexLogFixture.tokenCount(
                timestamp: OpenUsageISO8601.string(from: excludedDay),
                last: CodexLogFixture.usage(input: 900, output: 50), model: "gpt-5.2"
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scan = await CodexLogFixture.scanner(home: home).scan(
            homes: CodexLogHomes(read: [home], cache: [home]), now: now, pricing: TestPricing.bundled
        )

        XCTAssertEqual(scan?.series.daily.map(\.date), [DailyUsageAccumulator.dayKey(from: firstDay)])
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 150)
    }

    func testCodexPeerProvenanceMatchesAccountScopedHistory() throws {
        let descriptor = UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        let descriptors = ["codex": descriptor, "codex@1234abcd": descriptor]
        let identities = ["codex": "account-a|a@test", "codex@1234abcd": "account-b|b@test"]
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [DailyUsageEntry(date: "2026-10-21", totalTokens: 150, costUSD: 1)]),
            modelUsage: nil, unknownModelsByDay: [:]
        )
        let peer = UsageHistoryDocument(
            schema: UsageHistoryDocument.accountSchema,
            deviceID: "peer", deviceName: "Peer Mac",
            updatedAt: Date(),
            providers: ["codex@abcdef12": history],
            identities: ["codex@abcdef12": "ACCOUNT-B|B@TEST"]
        )
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12)))
        let merged = UsageHistoryAggregator.merged(
            localSnapshots: [:], peerDocuments: [peer], descriptors: descriptors,
            providerIdentityKeys: identities, now: now
        )

        XCTAssertEqual(Set(merged.keys), ["codex@1234abcd"])
        XCTAssertEqual(UsageHistoryAggregator.providerIDsWithPeerHistory(
            peerDocuments: [peer], descriptors: descriptors, providerIdentityKeys: identities
        ), Set(merged.keys))
    }
}

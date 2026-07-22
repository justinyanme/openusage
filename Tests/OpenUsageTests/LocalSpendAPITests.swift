import XCTest
@testable import OpenUsage

final class LocalSpendAPITests: XCTestCase {
    private let generatedAt = OpenUsageISO8601.date(from: "2026-07-22T04:00:00.000Z")!

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return value
    }

    private func descriptor(
        scope: UsageHistoryDescriptor.Scope = .machineLocal,
        estimated: Bool = true
    ) -> UsageHistoryDescriptor {
        UsageHistoryDescriptor(scope: scope, estimatedCost: estimated, sourceNote: "Test history")
    }

    private func snapshot(
        id: String,
        history: ProviderUsageHistory? = ProviderUsageHistory(series: DailyUsageSeries(daily: [])),
        refreshedAt: Date? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [],
            refreshedAt: refreshedAt ?? generatedAt.addingTimeInterval(-30),
            usageHistory: history
        )
    }

    func testSpendRoutePublishesDenseCanonicalHistoryWithoutInventingZeroes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let generatedAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 22,
            hour: 12
        )))
        let today = "2026-07-22"
        let yesterday = "2026-07-21"
        let tokenOnlyDay = "2026-07-20"
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [],
            refreshedAt: generatedAt.addingTimeInterval(-30),
            usageHistory: ProviderUsageHistory(
                series: DailyUsageSeries(daily: [
                    DailyUsageEntry(date: today, totalTokens: 100, costUSD: 1.25),
                    DailyUsageEntry(date: yesterday, totalTokens: 0, costUSD: 0),
                    DailyUsageEntry(date: tokenOnlyDay, totalTokens: 50, costUSD: nil),
                    DailyUsageEntry(date: "2026-06-22", totalTokens: 9_999, costUSD: 99)
                ]),
                modelUsage: ModelUsageSeries(daily: [
                    DailyModelUsageEntry(date: today, models: [
                        ModelUsageEntry(
                            model: "sonnet",
                            totalTokens: 100,
                            costUSD: 1.25,
                            variants: [
                                ModelUsageVariant(model: "sonnet-fast", totalTokens: 40, costUSD: 0.75),
                                ModelUsageVariant(model: "sonnet", totalTokens: 60, costUSD: 0.5)
                            ]
                        )
                    ])
                ]),
                unknownModelsByDay: [today: ["future-model"]]
            )
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["claude"],
            knownIDs: ["claude"],
            snapshots: ["claude": snapshot],
            localSnapshots: ["claude": snapshot],
            historyDescriptors: [
                "claude": UsageHistoryDescriptor(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From test logs"
                )
            ],
            generatedAt: generatedAt
        )

        let response = LocalUsageAPI.respond(
            method: "GET",
            path: "/v1/spend",
            state: state,
            calendar: calendar
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response.body)) as? [String: Any])
        let window = try XCTUnwrap(root["window"] as? [String: Any])
        let provider = try XCTUnwrap((root["providers"] as? [String: Any])?["claude"] as? [String: Any])
        let periods = try XCTUnwrap(provider["periods"] as? [String: Any])
        let days = try XCTUnwrap(provider["days"] as? [[String: Any]])

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(root["schema"] as? String, "openusage.spend.v1")
        XCTAssertEqual(root["calendarTimeZone"] as? String, "Asia/Singapore")
        XCTAssertEqual(window["startDate"] as? String, "2026-06-23")
        XCTAssertEqual(window["endDate"] as? String, today)
        XCTAssertEqual(window["dayCount"] as? Int, 30)
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(days.first?["date"] as? String, "2026-06-23")
        XCTAssertTrue(days.first?["total"] is NSNull)
        XCTAssertEqual(days.last?["date"] as? String, today)

        let yesterdayJSON = try XCTUnwrap(days.first { $0["date"] as? String == yesterday })
        let yesterdayTotal = try XCTUnwrap(yesterdayJSON["total"] as? [String: Any])
        XCTAssertEqual(yesterdayTotal["tokens"] as? Int, 0)
        XCTAssertEqual(yesterdayTotal["costUSD"] as? Double, 0)

        let tokenOnlyJSON = try XCTUnwrap(days.first { $0["date"] as? String == tokenOnlyDay })
        let tokenOnlyTotal = try XCTUnwrap(tokenOnlyJSON["total"] as? [String: Any])
        XCTAssertEqual(tokenOnlyTotal["tokens"] as? Int, 50)
        XCTAssertTrue(tokenOnlyTotal["costUSD"] is NSNull)

        let todayJSON = try XCTUnwrap(days.last)
        XCTAssertEqual(todayJSON["excludedModels"] as? [String], ["future-model"])
        XCTAssertEqual(todayJSON["totalsComplete"] as? Bool, false)
        let models = try XCTUnwrap(todayJSON["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["model"] as? String, "sonnet")
        XCTAssertEqual((models.first?["variants"] as? [[String: Any]])?.map { $0["model"] as? String }, ["sonnet", "sonnet-fast"])

        let last30 = try XCTUnwrap(periods["last30Days"] as? [String: Any])
        let last30Total = try XCTUnwrap(last30["total"] as? [String: Any])
        XCTAssertEqual(last30Total["tokens"] as? Int, 150)
        XCTAssertTrue(last30Total["costUSD"] is NSNull)
        XCTAssertEqual(last30["observedDays"] as? Int, 3)
        XCTAssertEqual(last30["expectedDays"] as? Int, 30)
        XCTAssertEqual(last30["totalsComplete"] as? Bool, false)
        XCTAssertEqual(last30["excludedModels"] as? [String], ["future-model"])

        XCTAssertEqual(provider["historyScope"] as? String, "machineLocal")
        XCTAssertEqual(provider["sourceNote"] as? String, "From test logs")
        XCTAssertEqual((provider["cost"] as? [String: Any])?["provenance"] as? String, "estimated")
        XCTAssertEqual(provider["stale"] as? Bool, false)
        XCTAssertEqual(root["errors"] as? [[String: String]], [])
    }

    func testAuthoritativeEmptyHistoryIsIncludedButMissingHistoryIsOmitted() throws {
        let empty = snapshot(id: "claude")
        let missing = snapshot(id: "codex", history: nil)
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["claude", "codex", "grok"],
            knownIDs: ["claude", "codex", "grok"],
            snapshots: ["claude": empty, "codex": missing],
            localSnapshots: ["claude": empty, "codex": missing],
            historyDescriptors: [
                "claude": descriptor(),
                "codex": descriptor(),
                "grok": descriptor()
            ],
            errors: ["grok": "No local history"],
            generatedAt: generatedAt
        )

        let response = LocalUsageAPI.respond(
            method: "GET", path: "/v1/spend", state: state, calendar: calendar
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response.body)) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let claude = try XCTUnwrap(providers["claude"] as? [String: Any])
        let days = try XCTUnwrap(claude["days"] as? [[String: Any]])
        let errors = try XCTUnwrap(root["errors"] as? [[String: Any]])

        XCTAssertEqual(Set(providers.keys), ["claude"])
        XCTAssertEqual(days.count, 30)
        XCTAssertTrue(days.allSatisfy { $0["total"] is NSNull })
        XCTAssertEqual(errors.first?["providerId"] as? String, "grok")
    }

    func testExplicitFamilyIncludesDisabledCardsAndRetainedErrorMarksDataStale() throws {
        let primary = snapshot(id: "claude")
        let extra = snapshot(id: "claude@abc123")
        var state = LocalUsageAPI.State(
            enabledOrderedIDs: [],
            knownIDs: ["claude", "claude@abc123"],
            snapshots: ["claude": primary, "claude@abc123": extra],
            localSnapshots: ["claude": primary, "claude@abc123": extra],
            historyDescriptors: ["claude": descriptor(), "claude@abc123": descriptor()],
            errors: ["claude": "Refresh failed"],
            generatedAt: generatedAt
        )
        state = state.resolvingDisplayNames(["claude": "Claude Work"])

        let rootResponse = LocalUsageAPI.respond(
            method: "GET", path: "/v1/spend", state: state, calendar: calendar
        )
        let rootJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(rootResponse.body)) as? [String: Any])
        XCTAssertTrue((rootJSON["providers"] as? [String: Any])?.isEmpty == true)

        let familyResponse = LocalUsageAPI.respond(
            method: "GET", path: "/v1/spend/claude", state: state, calendar: calendar
        )
        let familyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(familyResponse.body)) as? [String: Any])
        let providers = try XCTUnwrap(familyJSON["providers"] as? [String: Any])
        let claude = try XCTUnwrap(providers["claude"] as? [String: Any])

        XCTAssertEqual(Set(providers.keys), ["claude", "claude@abc123"])
        XCTAssertEqual(claude["displayName"] as? String, "Claude Work")
        XCTAssertEqual(claude["stale"] as? Bool, true)
        XCTAssertEqual(LocalUsageAPI.respond(
            method: "GET", path: "/v1/spend/nope", state: state, calendar: calendar
        ).status, 404)
        XCTAssertEqual(LocalUsageAPI.respond(
            method: "POST", path: "/v1/spend", state: state, calendar: calendar
        ).status, 405)
    }

    func testReportedAccountWideHistoryKeepsMissingModelBreakdownExplicit() throws {
        let value = snapshot(id: "cursor")
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["cursor"],
            knownIDs: ["cursor"],
            snapshots: ["cursor": value],
            localSnapshots: ["cursor": value],
            historyDescriptors: ["cursor": descriptor(scope: .accountWide, estimated: false)],
            generatedAt: generatedAt
        )

        let response = LocalUsageAPI.respond(
            method: "GET", path: "/v1/spend", state: state, calendar: calendar
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response.body)) as? [String: Any])
        let provider = try XCTUnwrap((root["providers"] as? [String: Any])?["cursor"] as? [String: Any])
        let day = try XCTUnwrap((provider["days"] as? [[String: Any]])?.last)

        XCTAssertEqual(provider["historyScope"] as? String, "accountWide")
        XCTAssertEqual((provider["cost"] as? [String: Any])?["provenance"] as? String, "reported")
        XCTAssertTrue(day["models"] is NSNull)
        XCTAssertTrue(day["totalsComplete"] is NSNull)
    }

    func testSpendRoutePublishesTheRenderedICloudCombinedHistory() throws {
        let day = "2026-07-22"
        let local = snapshot(
            id: "codex",
            history: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: day, totalTokens: 100, costUSD: 1)
            ]))
        )
        let combined = snapshot(
            id: "codex",
            history: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: day, totalTokens: 250, costUSD: 2.5)
            ]))
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["codex"],
            knownIDs: ["codex"],
            snapshots: ["codex": combined],
            localSnapshots: ["codex": local],
            historyDescriptors: ["codex": descriptor()],
            syncedHistoryProviderIDs: ["codex"],
            generatedAt: generatedAt
        )

        let response = LocalUsageAPI.respond(
            method: "GET", path: "/v1/spend", state: state, calendar: calendar
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response.body)) as? [String: Any])
        let provider = try XCTUnwrap((root["providers"] as? [String: Any])?["codex"] as? [String: Any])
        let today = try XCTUnwrap((provider["periods"] as? [String: Any])?["today"] as? [String: Any])
        let total = try XCTUnwrap(today["total"] as? [String: Any])

        XCTAssertEqual(total["tokens"] as? Int, 250)
        XCTAssertEqual(total["costUSD"] as? Double, 2.5)
        XCTAssertEqual(provider["includesSyncedPeers"] as? Bool, true)
        XCTAssertEqual(provider["sourceNote"] as? String, "Across your Macs · Test history")
    }
}

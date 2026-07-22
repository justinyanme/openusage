import XCTest
@testable import OpenUsage

@MainActor
final class UsageReaderTests: XCTestCase {
    private final class StubProvider: ProviderRuntime {
        let provider: Provider
        var widgetDescriptors: [WidgetDescriptor] {
            [WidgetDescriptor.percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent")
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "Test history")]
        }
        var refreshCount = 0
        var refreshError: String?
        var refreshedAt = Date()

        init(id: String = "stub") {
            self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        }

        func hasLocalCredentials() async -> Bool { true }

        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            if let refreshError {
                return .error(provider: provider, message: refreshError)
            }
            return ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Weekly", used: 20, limit: 100, format: .percent)],
                refreshedAt: refreshedAt,
                usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                    DailyUsageEntry(
                        date: DailyUsageAccumulator.dayKey(from: refreshedAt),
                        totalTokens: 123,
                        costUSD: 0.45
                    )
                ]))
            )
        }
    }

    private func defaults() -> UserDefaults {
        let suite = "UsageReaderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testReadsSharedSnapshotCacheWithoutRefreshing() async throws {
        let defaults = defaults()
        let provider = StubProvider()
        ProviderSnapshotCache(userDefaults: defaults).store(await provider.refresh())
        provider.refreshCount = 0

        let result = try await UsageReader(userDefaults: defaults, providers: [provider]).read(providerID: "stub")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])

        XCTAssertNotNil((object["providers"] as? [String: Any])?["stub"])
        XCTAssertEqual(provider.refreshCount, 0)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testForceUsesSharedProviderAndStoresResult() async throws {
        let defaults = defaults()
        let provider = StubProvider()
        let reader = UsageReader(userDefaults: defaults, providers: [provider])

        let result = try await reader.read(providerID: "stub", force: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let cached = ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: ["stub"])

        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertNotNil((object["providers"] as? [String: Any])?["stub"])
        XCTAssertEqual(cached["stub"]?.line(label: "Weekly"), .progress(
            label: "Weekly", used: 20, limit: 100, format: .percent
        ))
    }

    func testStalePersistedSnapshotRefreshesBeforeReading() async throws {
        let defaults = defaults()
        let provider = StubProvider()
        provider.refreshedAt = Date().addingTimeInterval(-RefreshSetting.interval - 1)
        ProviderSnapshotCache(userDefaults: defaults).store(await provider.refresh())
        provider.refreshCount = 0
        provider.refreshedAt = Date()

        let result = try await UsageReader(userDefaults: defaults, providers: [provider]).read(providerID: "stub")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])

        XCTAssertNotNil((object["providers"] as? [String: Any])?["stub"])
        XCTAssertEqual(provider.refreshCount, 1)
    }

    func testForcedProviderReadRefreshesOnlyRequestedProvider() async throws {
        let defaults = defaults()
        let requested = StubProvider(id: "requested")
        let other = StubProvider(id: "other")

        _ = try await UsageReader(userDefaults: defaults, providers: [requested, other])
            .read(providerID: "requested", force: true)

        XCTAssertEqual(requested.refreshCount, 1)
        XCTAssertEqual(other.refreshCount, 0)
    }

    func testUnknownProviderFailsBeforeRefresh() async {
        let defaults = defaults()
        let provider = StubProvider()

        do {
            _ = try await UsageReader(userDefaults: defaults, providers: [provider]).read(providerID: "missing", force: true)
            XCTFail("Expected unknown provider error")
        } catch UsageReaderError.unknownProvider(let providerID) {
            XCTAssertEqual(providerID, "missing")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(provider.refreshCount, 0)
    }

    func testFailedForceWithoutCacheReturnsMachineReadableError() async throws {
        let defaults = defaults()
        let provider = StubProvider()
        provider.refreshError = "Not logged in"

        let result = try await UsageReader(userDefaults: defaults, providers: [provider])
            .read(providerID: "stub", force: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let errors = try XCTUnwrap(root["errors"] as? [[String: Any]])

        XCTAssertEqual(result.warnings, ["stub: Not logged in"])
        XCTAssertEqual(errors.first?["providerId"] as? String, "stub")
        XCTAssertEqual(errors.first?["message"] as? String, "Not logged in")
    }

    func testSpendOutputUsesTheSameDiscoveryRefreshAndCachePath() async throws {
        let defaults = defaults()
        let provider = StubProvider()
        provider.refreshedAt = Date()

        let result = try await UsageReader(userDefaults: defaults, providers: [provider])
            .read(providerID: "stub", force: true, output: .spend)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let providerJSON = try XCTUnwrap((root["providers"] as? [String: Any])?["stub"] as? [String: Any])
        let days = try XCTUnwrap(providerJSON["days"] as? [[String: Any]])

        XCTAssertEqual(root["schema"] as? String, "openusage.spend.v1")
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertEqual(((days.last?["total"] as? [String: Any])?["tokens"] as? Int), 123)
    }

    func testDefaultOutputRemainsLimits() async throws {
        let defaults = defaults()
        let provider = StubProvider()

        let result = try await UsageReader(userDefaults: defaults, providers: [provider])
            .read(providerID: "stub", force: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])

        XCTAssertEqual(root["schema"] as? String, "openusage.limits.v1")
    }

    func testSpendCLIBytesEqualHTTPRouterBytesForTheSameCapturedState() async throws {
        let defaults = defaults()
        let provider = StubProvider()
        provider.refreshedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let cli = try await UsageReader(userDefaults: defaults, providers: [provider])
            .read(force: true, output: .spend)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: cli.data) as? [String: Any])
        let generatedAtText = try XCTUnwrap(root["generatedAt"] as? String)
        let generatedAt = try XCTUnwrap(OpenUsageISO8601.date(from: generatedAtText))
        let snapshots = ProviderSnapshotCache(userDefaults: defaults)
            .loadSnapshots(providerIDs: ["stub"])
        let registry = WidgetRegistry.from([provider])
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["stub"],
            knownIDs: ["stub"],
            snapshots: snapshots,
            localSnapshots: snapshots,
            limitDescriptors: registry.limitDescriptorsByProvider,
            historyDescriptors: registry.historyDescriptorsByProvider,
            generatedAt: generatedAt
        )

        let http = LocalUsageAPI.respond(method: "GET", path: "/v1/spend", state: state)

        XCTAssertEqual(cli.data, try XCTUnwrap(http.body))
    }

    func testSpendReadMergesICloudPeerHistoryWithFreshCachedLocalHistory() async throws {
        let defaults = defaults()
        defaults.set(true, forKey: ICloudUsageSyncStore.enabledKey)
        defaults.set(UUID().uuidString.lowercased(), forKey: ICloudUsageSyncStore.deviceIDKey)
        let provider = StubProvider()
        provider.refreshedAt = Date()
        ProviderSnapshotCache(userDefaults: defaults).store(await provider.refresh())
        provider.refreshCount = 0

        let day = DailyUsageAccumulator.dayKey(from: provider.refreshedAt)
        let peer = UsageHistoryDocument(
            deviceID: UUID().uuidString.lowercased(),
            deviceName: "Peer Mac",
            updatedAt: provider.refreshedAt,
            providers: [
                "stub": ProviderUsageHistory(series: DailyUsageSeries(daily: [
                    DailyUsageEntry(date: day, totalTokens: 456, costUSD: 0.55)
                ]))
            ]
        )
        let fileStore = StubHistoryFileStore(documents: [peer])

        let result = try await UsageReader(
            userDefaults: defaults,
            providers: [provider],
            historyFileStore: fileStore
        ).read(providerID: "stub", output: .spend)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let providerJSON = try XCTUnwrap((root["providers"] as? [String: Any])?["stub"] as? [String: Any])
        let periods = try XCTUnwrap(providerJSON["periods"] as? [String: Any])
        let today = try XCTUnwrap(periods["today"] as? [String: Any])
        let total = try XCTUnwrap(today["total"] as? [String: Any])

        XCTAssertEqual(provider.refreshCount, 0, "a fresh local cache must remain fresh while peers load")
        XCTAssertEqual(total["tokens"] as? Int, 579)
        XCTAssertEqual(total["costUSD"] as? Double, 1)
        XCTAssertEqual(providerJSON["includesSyncedPeers"] as? Bool, true)
        XCTAssertTrue(result.warnings.isEmpty)
    }
}

private actor StubHistoryFileStore: UsageHistoryFileStoring {
    let documents: [UsageHistoryDocument]

    init(documents: [UsageHistoryDocument]) {
        self.documents = documents
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        UsageHistoryLoadResult(documents: documents, invalidFileMessages: [])
    }

    func write(_: UsageHistoryDocument) async throws {}
    func delete(deviceID _: String) async throws {}
}

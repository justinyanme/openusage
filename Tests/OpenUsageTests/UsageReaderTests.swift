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
            label: "Weekly",
            used: 20,
            limit: 100,
            format: .percent,
            resetsAt: nil,
            periodDurationMs: nil,
            colorHex: nil
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
}

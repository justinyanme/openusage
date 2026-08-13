import XCTest
@testable import OpenUsage

final class ICloudUsageHistoryFileStoreTests: XCTestCase {
    func testLoadSuppressesAccountV2WhenNewerV1ReplacesSameDevice() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        try write(
            makeDocument(
                deviceID: "retired-id",
                deviceName: "Test Mac",
                updatedAt: Date(timeIntervalSince1970: 100),
                providers: ["claude"]
            ),
            schema: "openusage.history.v2",
            fileName: "retired.json",
            to: container
        )
        try write(
            makeDocument(
                deviceID: "current-id",
                deviceName: "Test Mac",
                updatedAt: Date(timeIntervalSince1970: 200),
                providers: ["claude"]
            ),
            fileName: "current.json",
            to: container
        )
        let store = ICloudUsageHistoryFileStore(containerURLOverride: container)

        let result = try await store.loadDocuments()

        XCTAssertEqual(result.documents.map(\.deviceID), ["current-id"])
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
    }

    func testLoadKeepsAccountV2WithoutAnExactNewerV1Replacement() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        try write(
            makeDocument(
                deviceID: "retired-id",
                deviceName: "Test Mac",
                updatedAt: Date(timeIntervalSince1970: 200),
                providers: ["claude", "codex"]
            ),
            schema: "openusage.history.v2",
            fileName: "retired.json",
            to: container
        )
        try write(
            makeDocument(
                deviceID: "current-id",
                deviceName: "Test Mac",
                updatedAt: Date(timeIntervalSince1970: 100),
                providers: ["claude"]
            ),
            fileName: "current.json",
            to: container
        )
        let store = ICloudUsageHistoryFileStore(containerURLOverride: container)

        let result = try await store.loadDocuments()

        XCTAssertEqual(Set(result.documents.map(\.deviceID)), ["retired-id", "current-id"])
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
    }

    func testLoadNeverSuppressesAnUnknownFutureSchema() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        try write(
            makeDocument(
                deviceID: "future-id",
                deviceName: "Test Mac",
                updatedAt: Date(timeIntervalSince1970: 100),
                providers: ["claude"]
            ),
            schema: "openusage.history.v3",
            fileName: "future.json",
            to: container
        )
        try write(
            makeDocument(
                deviceID: "current-id",
                deviceName: "Test Mac",
                updatedAt: Date(timeIntervalSince1970: 200),
                providers: ["claude"]
            ),
            fileName: "current.json",
            to: container
        )
        let store = ICloudUsageHistoryFileStore(containerURLOverride: container)

        let result = try await store.loadDocuments()

        XCTAssertEqual(result.invalidFileMessages.count, 1)
        XCTAssertTrue(result.invalidFileMessages[0].hasPrefix("future.json:"))
    }

    private func makeContainer() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageHistoryFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: historyDirectory(in: container),
            withIntermediateDirectories: true
        )
        return container
    }

    private func makeDocument(
        deviceID: String,
        deviceName: String,
        updatedAt: Date,
        providers: Set<String>
    ) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: deviceID,
            deviceName: deviceName,
            updatedAt: updatedAt,
            providers: Dictionary(uniqueKeysWithValues: providers.map { providerID in
                (
                    providerID,
                    ProviderUsageHistory(
                        series: DailyUsageSeries(daily: [
                            DailyUsageEntry(date: "2026-08-13", totalTokens: 100, costUSD: 1)
                        ])
                    )
                )
            })
        )
    }

    private func write(
        _ document: UsageHistoryDocument,
        schema: String = UsageHistoryDocument.currentSchema,
        fileName: String,
        to container: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any]
        )
        object["schema"] = schema
        if schema == "openusage.history.v2" {
            object["identities"] = ["claude": "account-a"]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: historyDirectory(in: container).appendingPathComponent(fileName))
    }

    private func historyDirectory(in container: URL) -> URL {
        container
            .appendingPathComponent("OpenUsage", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }
}

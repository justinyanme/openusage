import Foundation
import Testing
@testable import OpenUsage

@MainActor
struct KimiProviderTests {
    @Test func loginValidatesThePastedKeyBeforeReturningACredential() async throws {
        let http = RoutingHTTPClient { _ in .json(Self.monthlyPlan) }
        let input = AsyncStream<String> { continuation in
            continuation.yield("  test-kimi-key\n")
            continuation.finish()
        }

        let result = try await APIKeyLogin(kind: .kimi, http: http).login(prompt: { _ in }, pastedCode: input)

        #expect(result.label == "Kimi Code")
        #expect(result.credential == .apiKey("test-kimi-key"))
        #expect(http.requests.count == 1)
        #expect(http.requests.first?.headers["Authorization"] == "Bearer test-kimi-key")
    }

    @Test func loginRejectsAnInvalidKeyWithoutReturningACredential() async {
        let http = RoutingHTTPClient { _ in .json("{}", status: 401) }
        let input = AsyncStream<String> { continuation in
            continuation.yield("rejected-key")
            continuation.finish()
        }
        await #expect(throws: ProviderError.unavailable("Kimi Code rejected the API key.")) {
            try await APIKeyLogin(kind: .kimi, http: http).login(prompt: { _ in }, pastedCode: input)
        }
    }

    @Test func refreshAndExportKeepTheAccountScopeAndOmitMissingQuota() async throws {
        let account = Account(kind: .kimi, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("saved-key"), for: account.id)
        let http = RoutingHTTPClient { _ in .json(Self.monthlyPlan) }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

        let snapshot = try await runtime.refresh().get()

        #expect(snapshot.providerID == account.cardID)
        #expect(snapshot.plan == nil)
        #expect(snapshot.lines.map(\.label) == ["Session", "Monthly"])
        #expect(runtime.widgetDescriptors.map(\.key) == ["session", "weekly", "monthly"])
        #expect(http.requests.first?.headers["Authorization"] == "Bearer saved-key")

        let data = LimitsEnvelope.encode(.init(registry: .from([runtime]), snapshots: [account.cardID: snapshot]))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(root["providers"] as? [String: [String: Any]])
        let exported = try #require(providers[account.cardID])
        let resources = try #require(exported["resources"] as? [String: [String: Any]])
        #expect(exported["displayName"] as? String == "Kimi Code · Work")
        #expect(Set(resources.keys) == ["session", "monthly"])
        #expect(resources["session"]?["used"] as? Double == 25)
        #expect(resources["session"]?["windowSeconds"] as? Double == 18_000)
        #expect(resources["monthly"]?["remaining"] as? Double == 60)
        #expect(resources["monthly"]?["resetsAt"] as? String == "2026-12-01T00:00:00.000Z")
        #expect(resources["monthly"]?["windowSeconds"] == nil)
    }

    @Test(arguments: [403, 429])
    func refreshHandlesForbiddenKeysAndRetryAfter(status: Int) async {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: status, headers: status == 429 ? ["retry-after": "120"] : [:], body: Data())
        }
        let runtime = AccountProviderRuntime(account: Account(kind: .kimi, label: "Work"), vault: InMemoryCredentialVault(), http: http)
        let expected: ProviderError = status == 403
            ? .keyRejected("Kimi Code rejected the API key.")
            : .rateLimited(retryAfter: 120)

        await #expect(throws: expected) { try await runtime.readSnapshot(using: .apiKey("test-key")) }
        #expect(http.requests.count == 1)
    }

    @Test func refreshRejectsAQuotaFreeSuccessResponse() async {
        let http = RoutingHTTPClient { _ in .json(#"{"usages":{}}"#) }
        let runtime = AccountProviderRuntime(account: Account(kind: .kimi, label: "Work"), vault: InMemoryCredentialVault(), http: http)
        await #expect(throws: ProviderError.unavailable("Kimi Code reported no subscription quota for this account.")) {
            try await runtime.readSnapshot(using: .apiKey("test-key"))
        }
    }

    private nonisolated static let monthlyPlan = #"""
    {"usages":{
        "limit_5h":{"used_ratio":0.25,"reset_time":"2026-11-06T12:00:00Z"},
        "limit_month_total":{"used_ratio":0.4,"reset_time":"2026-12-01T00:00:00Z"}
    }}
    """#
}

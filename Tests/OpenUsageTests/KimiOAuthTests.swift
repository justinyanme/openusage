import Foundation
import Testing
@testable import OpenUsage

@MainActor
struct KimiOAuthTests {
    @Test func deviceSignInChecksTheProfileAndQuotaAndKeepsRenewalTokens() async throws {
        let shown = TestSwitch<LoginPrompt?>(nil)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/device_authorization": .json(Self.device)
            case "/api/oauth/token": .json(Self.token)
            case "/coding/v1/me": .json(#"{"user_id":"user-123","email":"kimi@example.com","nickname":"Kimi User"}"#)
            case "/coding/v1/usages": .json(Self.usage)
            default: .json("{}", status: 404)
            }
        }
        let result = try await KimiLogin(http: http).login(prompt: { shown.value = $0 }, pastedCode: AsyncStream { $0.finish() })

        guard case .deviceCode(let code, let url)? = shown.value, case .oauth(let tokens) = result.credential else {
            Issue.record("Expected a device-code prompt and an OAuth credential")
            return
        }
        #expect(code == "KIMI-CODE")
        #expect(url.absoluteString == "https://auth.kimi.com/device?user_code=KIMI-CODE")
        #expect(result.label == "kimi@example.com")
        #expect(tokens.accessToken == "access-new")
        #expect(tokens.refreshToken == "refresh-new")
        #expect(abs(try #require(tokens.expiresAt).timeIntervalSinceNow - 3600) < 5)
        #expect(tokens.extras[OAuthTokens.identityKey] == "kimi:user-123")
        #expect(Self.form(http.requests[0]) == ["client_id": KimiLogin.clientID])
        #expect(Self.form(http.requests[1]) == [
            "client_id": KimiLogin.clientID, "device_code": "device-secret",
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])
        #expect(http.requests.allSatisfy { $0.headers["User-Agent"] == "OpenUsage" })
        #expect(http.requests.suffix(2).allSatisfy { $0.headers["Authorization"] == "Bearer access-new" })
    }

    @Test func deniedAuthorizationDoesNotReadTheProfileOrQuota() async {
        let http = RoutingHTTPClient { request in
            request.url.path.hasSuffix("device_authorization")
                ? .json(Self.device) : .json(#"{"error":"access_denied"}"#, status: 400)
        }
        await #expect(throws: LoginError.self) {
            try await KimiLogin(http: http).login(prompt: { _ in }, pastedCode: AsyncStream { $0.finish() })
        }
        #expect(http.requests.count == 2)
    }

    @Test func aRefusedAccessTokenIsRenewedOnceAndTheRotatedTokensAreSaved() async throws {
        let now = Date()
        let account = Account(kind: .kimi, label: "Work", credentialKind: .oauth)
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(
            accessToken: "access-old", refreshToken: "refresh-old", expiresAt: now.addingTimeInterval(3600),
            extras: [OAuthTokens.identityKey: "kimi:user-123"]
        )), for: account.id)
        let http = RoutingHTTPClient { request in
            if request.url == KimiLogin.tokenURL { return .json(Self.token) }
            return request.headers["Authorization"] == "Bearer access-old" ? .json("{}", status: 401) : .json(Self.usage)
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { now })
        _ = try await runtime.refresh().get()

        #expect(http.requests.map(\.url) == [KimiUsageClient.usageURL, KimiLogin.tokenURL, KimiUsageClient.usageURL])
        #expect(Self.form(http.requests[1])["refresh_token"] == "refresh-old")
        #expect(try vault.load(account.id) == .oauth(OAuthTokens(
            accessToken: "access-new", refreshToken: "refresh-new", expiresAt: now.addingTimeInterval(3600),
            extras: [OAuthTokens.identityKey: "kimi:user-123"]
        )))
    }

    @Test(arguments: [
        #"{"access_token":"","refresh_token":"r","expires_in":3600}"#,
        #"{"access_token":"a","expires_in":3600}"#,
        #"{"access_token":"a","refresh_token":"","expires_in":3600}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":0}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":-1}"#
    ])
    func malformedRenewalIsNotSaved(body: String) async {
        let http = RoutingHTTPClient { _ in .json(body) }
        await #expect(throws: ProviderError.invalidResponse) { try await KimiLogin.refresh("old", http: http, now: Date()) }
    }

    @Test func oldKeyAccountsAndNewOAuthAccountsKeepTheirOwnSignInMethods() throws {
        let legacy = #"{"id":"8AD3B217-0000-4000-8000-000000000000","kind":"kimi","label":"Old Key","addedAt":0}"#
        let old = try JSONDecoder().decode(Account.self, from: Data(legacy.utf8))
        guard case .apiKey = old.authMethod else { Issue.record("An existing Kimi key became OAuth"); return }

        let suite = "KimiOAuthTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = InMemoryCredentialVault()
        let store = AccountStore(defaults: defaults, vault: vault)
        let oauth = store.add(kind: .kimi, label: "OAuth", credential: .oauth(OAuthTokens(accessToken: "a")))
        let keyed = store.add(kind: .kimi, label: "API Key", credential: .apiKey("key"))
        let loaded = AccountStore(defaults: defaults, vault: vault)
        #expect(loaded.accounts.first { $0.id == oauth.id }?.authMethod == .oauth)
        #expect(loaded.accounts.first { $0.id == keyed.id }?.authMethod == old.authMethod)
        #expect(AddAccountFlow(store: loaded, signingInAgainTo: oauth).method == .oauth)
        #expect(AddAccountFlow(store: loaded, signingInAgainTo: keyed).method == old.authMethod)
        #expect(ProviderLoginCatalog.login(for: .kimi, method: .oauth, organization: "", domain: .github) is KimiLogin)
        #expect(ProviderLoginCatalog.login(for: .kimi, method: old.authMethod, organization: "", domain: .github) is APIKeyLogin)
    }

    private nonisolated static func form(_ request: HTTPRequest) -> [String: String] {
        let query = String(decoding: request.body ?? Data(), as: UTF8.self)
        let items = URLComponents(string: "https://example.test/?\(query)")?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })
    }

    private nonisolated static let device = #"{"device_code":"device-secret","user_code":"KIMI-CODE","verification_uri_complete":"https://auth.kimi.com/device?user_code=KIMI-CODE","expires_in":600,"interval":1}"#
    private nonisolated static let token = #"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":3600}"#
    private nonisolated static let usage = #"{"usages":{"limit_5h":{"used_ratio":0.25}}}"#
}

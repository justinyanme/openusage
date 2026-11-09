import Foundation

/// Kimi Code's public device-code client. No client secret or requested scope is used by the
/// official flow; OpenUsage identifies itself with its own User-Agent.
struct KimiLogin: ProviderLogin {
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    static let profileURL = URL(string: "https://api.kimi.com/coding/v1/me")!
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let token = try await deviceAuthorization(
            provider: "Kimi Code",
            startURL: URL(string: "https://auth.kimi.com/api/oauth/device_authorization")!,
            tokenURL: Self.tokenURL,
            clientID: Self.clientID,
            scopes: nil,
            headers: ["User-Agent": "OpenUsage"],
            deniedMessage: "Kimi Code sign-in was denied.",
            http: http,
            prompt: prompt
        )
        let grant = try Self.validatedGrant(token, now: Date())
        let profileResponse = try await LoginHTTP.get(Self.profileURL, bearerToken: grant.accessToken, using: http,
                                                       headers: ["Accept": "application/json", "User-Agent": "OpenUsage"])
        let profile = try LoginHTTP.decode(KimiProfile.self, from: profileResponse)
        guard let id = profile.userID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            throw LoginError.invalidResponse
        }
        let usage = try await KimiUsageClient(http: http).fetchUsage(token: grant.accessToken)
        try ProviderError.requireSuccess(usage, kind: .kimi)
        _ = try KimiUsageMapper.map(usage.body)
        let label = [profile.email, profile.nickname].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }.first
        return (label ?? ProviderKind.kimi.displayName, .oauth(OAuthTokens(
            accessToken: grant.accessToken, refreshToken: grant.refreshToken, expiresAt: grant.expiresAt,
            extras: [OAuthTokens.identityKey: "kimi:\(id)"]
        )))
    }

    static func refresh(_ refreshToken: String, http: any HTTPClient, now: Date) async throws -> OAuthGrant {
        let response = try await LoginHTTP.postForm(tokenURL, fields: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ], using: http, headers: ["User-Agent": "OpenUsage"])
        if ProviderError.isAuthFailure(response) { throw ProviderError.signInExpired(.kimi) }
        return try validatedGrant(OAuthTokenResponse(renewal: response, kind: .kimi), now: now)
    }

    private static func validatedGrant(_ token: OAuthTokenResponse, now: Date) throws -> OAuthGrant {
        guard !token.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let refresh = token.refreshToken, !refresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let lifetime = token.expiresIn, lifetime.isFinite, lifetime > 0 else {
            throw ProviderError.invalidResponse
        }
        return token.grant(now: now)
    }
}

private struct KimiProfile: Decodable {
    let userID: String
    let email: String?
    let nickname: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case email, nickname
    }
}

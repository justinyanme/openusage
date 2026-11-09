import Foundation

extension AccountProviderRuntime {
    func refreshKimi(_ credential: AccountCredential) async throws -> ProviderUsage {
        let client = KimiUsageClient(http: http)
        let response: HTTPResponse
        switch credential {
        case .apiKey(let key):
            response = try await client.fetchUsage(token: key)
        case .oauth:
            (_, response) = try await authorizedRead(credential, grant: KimiLogin.refresh) { tokens in
                try await client.fetchUsage(token: tokens.accessToken)
            }
        }
        try ProviderError.requireSuccess(response, kind: .kimi)
        return try KimiUsageMapper.map(response.body)
    }
}

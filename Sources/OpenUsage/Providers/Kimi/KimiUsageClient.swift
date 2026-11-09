import Foundation

struct KimiUsageClient: Sendable {
    static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    var http: any HTTPClient

    func fetchUsage(token: String) async throws -> HTTPResponse {
        try await LoginHTTP.get(Self.usageURL, bearerToken: token, using: http, headers: [
            "Accept": "application/json",
            "User-Agent": "OpenUsage"
        ])
    }
}

import Foundation
import Testing
@testable import OpenUsage

struct KimiUsageMapperTests {
    @Test func modernPlanShowsOnlyItsReportedWindows() throws {
        let usage = try map(#"""
        {"goods_version":2,"usages":{
            "limit_5h":{"used_ratio":"0.25","reset_time":"2026-11-06T12:00:00Z"},
            "limit_month_total":{"used_ratio":0.4,"reset_time":"2026-12-01T00:00:00Z"},
            "limit_month_code":{"used_ratio":0.3,"reset_time":"2026-12-01T00:00:00Z"}
        },"usage":{"limit":"100","used":"90","resetTime":"2026-11-08T00:00:00Z"}}
        """#)

        #expect(usage.plan == nil)
        #expect(Set(usage.lines.map(\.label)) == ["Session", "Monthly"])
        #expect(usage.lines.contains(.percent("Session", 25, resetsAt: date("2026-11-06T12:00:00Z"), periodMs: MetricPeriod.sessionMs)))
        #expect(usage.lines.contains(.percent("Monthly", 40, resetsAt: date("2026-12-01T00:00:00Z"))))
    }

    @Test func legacySessionIsIdentifiedByDurationRatherThanPosition() throws {
        let usage = try map(#"""
        {"usage":{"limit":"200","used":"50","resetTime":"2026-11-08T00:00:00Z"},
         "limits":[
            {"window":{"duration":1,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"10","remaining":"5"}},
            {"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"60","resetTime":"2026-11-06T12:00:00.123456Z"}}
         ]}
        """#)

        #expect(usage.lines.contains(.percent("Session", 40, resetsAt: date("2026-11-06T12:00:00.123456Z"), periodMs: MetricPeriod.sessionMs)))
        #expect(usage.lines.contains(.percent("Weekly", 25, resetsAt: date("2026-11-08T00:00:00Z"), periodMs: MetricPeriod.weekMs)))
    }

    @Test func matchingLegacyCountersCorrectStaleZeroRatios() throws {
        let usage = try map(#"""
        {"usages":{
            "limit_5h":{"used_ratio":0,"reset_time":"2026-11-06T12:00:00Z"},
            "limit_7d":{"used_ratio":0,"reset_time":"2026-11-08T02:09:06Z"}
        },"usage":{"limit":"100","used":"100","resetTime":"2026-11-08T02:09:07.465054Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"100","remaining":"20","resetTime":"2026-11-06T12:00:00Z"}}]}
        """#)

        #expect(usage.lines.contains(.percent("Session", 80, resetsAt: date("2026-11-06T12:00:00Z"), periodMs: MetricPeriod.sessionMs)))
        #expect(usage.lines.contains(.percent("Weekly", 100, resetsAt: date("2026-11-08T02:09:07.465054Z"), periodMs: MetricPeriod.weekMs)))
    }

    @Test func legacyCountersFromAnotherCycleDoNotOverrideModernUsage() throws {
        let usage = try map(#"""
        {"usages":{"limit_7d":{"used_ratio":0.1,"reset_time":"2026-11-08T00:00:00Z"}},
         "usage":{"limit":"100","used":"100","resetTime":"2026-11-01T00:00:00Z"}}
        """#)
        #expect(usage.lines == [.percent("Weekly", 10, resetsAt: date("2026-11-08T00:00:00Z"), periodMs: MetricPeriod.weekMs)])
    }

    @Test(arguments: [#""used":"0""#, #""remaining":"100""#])
    func protobufZeroUsageIsAcceptedWithEitherCounter(counter: String) throws {
        let usage = try map("{\"usage\":{\"limit\":\"100\",\(counter)}}")
        #expect(usage.lines == [.percent("Weekly", 0, periodMs: MetricPeriod.weekMs)])
    }

    @Test func missingResetDoesNotInventAResetOrAPlan() throws {
        let usage = try map(#"{"usages":{"limit_5h":{"used_ratio":0}}}"#)
        #expect(usage.lines == [.percent("Session", 0, periodMs: MetricPeriod.sessionMs)])
        #expect(usage.plan == nil)
    }

    @Test func overLimitRatiosSaturateWithoutOverflow() throws {
        let usage = try map(#"{"usages":{"limit_5h":{"used_ratio":"1e308"}}}"#)
        #expect(usage.lines == [.percent("Session", 100, periodMs: MetricPeriod.sessionMs)])
    }

    @Test(arguments: [
        #"{"usages":{}}"#,
        #"{"usages":{"limit_7d":null}}"#,
        #"{"usage":null,"limits":[]}"#
    ])
    func absentQuotaIsExplained(body: String) {
        #expect(throws: ProviderError.unavailable("Kimi Code reported no subscription quota for this account.")) {
            try map(body)
        }
    }

    @Test(arguments: [
        #"{}"#,
        #"{"error":"rejected"}"#,
        #"{"usages":[]}"#,
        #"{"usages":{"limit_5h":{}}}"#,
        #"{"usages":{"limit_5h":{"used_ratio":true}}}"#,
        #"{"usages":{"limit_5h":{"used_ratio":"nan"}}}"#,
        #"{"usages":{"limit_5h":{"used_ratio":-0.1}}}"#,
        #"{"usages":{"limit_5h":{"used_ratio":0,"reset_time":"bad-date"}}}"#,
        #"{"usage":{"limit":"100"}}"#,
        #"{"usage":{"limit":"0","used":"0"}}"#,
        #"{"usage":{"limit":"100","used":false}}"#,
        #"{"usage":{"limit":"100","remaining":"101"}}"#,
        #"{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{}}]}"#
    ])
    func malformedQuotaIsNotReportedAsUnused(body: String) {
        #expect(throws: ProviderError.invalidResponse) { try map(body) }
    }

    private func map(_ json: String) throws -> ProviderUsage {
        try KimiUsageMapper.map(Data(json.utf8))
    }

    private func date(_ string: String) -> Date? {
        OpenUsageISO8601.date(from: string)
    }
}

struct KimiUsageClientTests {
    @Test func requestsOnlyTheQuotaEndpointWithTheSuppliedKey() async throws {
        let http = RoutingHTTPClient { _ in .json(#"{"usages":{}}"#) }
        _ = try await KimiUsageClient(http: http).fetchUsage(token: "test-key")
        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://api.kimi.com/coding/v1/usages")
        #expect(request.headers["Authorization"] == "Bearer test-key")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["User-Agent"] == "OpenUsage")
        #expect(request.body == nil)
    }
}

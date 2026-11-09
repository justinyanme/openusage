import Foundation

enum KimiUsageMapper {
    static func map(_ body: Data) throws -> ProviderUsage {
        guard let root = ProviderParse.jsonObject(body) else { throw ProviderError.invalidResponse }
        let lines: [MetricLine]
        if let raw = root["usages"] {
            guard let usages = raw as? [String: Any] else { throw ProviderError.invalidResponse }
            lines = try modernWindows(usages, root: root)
        } else if root["usage"] != nil || root["limits"] != nil {
            lines = try legacyWindows(root)
        } else {
            throw ProviderError.invalidResponse
        }
        guard !lines.isEmpty else {
            throw ProviderError.unavailable("Kimi Code reported no subscription quota for this account.")
        }
        return ProviderUsage(plan: nil, lines: lines)
    }

    private enum Window {
        case session, weekly, monthly

        var label: String {
            switch self {
            case .session: "Session"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            }
        }

        var key: String {
            switch self {
            case .session: "limit_5h"
            case .weekly: "limit_7d"
            case .monthly: "limit_month_total"
            }
        }

        var periodMs: Int? {
            switch self {
            case .session: MetricPeriod.sessionMs
            case .weekly: MetricPeriod.weekMs
            // The API supplies a billing reset but no start. Do not invent a 30-day pace window.
            case .monthly: nil
            }
        }
    }

    private static func modernWindows(_ usages: [String: Any], root: [String: Any]) throws -> [MetricLine] {
        try [Window.session, .weekly, .monthly].compactMap { window in
            guard let entry = try object(usages[window.key]) else { return nil }
            guard let ratio = ProviderParse.number(entry["used_ratio"]), ratio >= 0 else {
                throw ProviderError.invalidResponse
            }
            let reset = try resetDate(entry["reset_time"])

            // Some older plans send zero ratios beside valid legacy counters. Use those counters
            // only for a window the modern schema actually reports, with a matching reset. The
            // reported legacy/new timestamps can differ by up to two seconds (kimi-code#3951).
            // In particular, a residual `usage` must never create Weekly on a new monthly plan.
            let legacy = switch window {
            case .session: try legacySession(root)
            case .weekly: try object(root["usage"])
            case .monthly: nil as [String: Any]?
            }
            if let legacy, let reset,
               let oldReset = legacy["resetTime"] as? String,
               let oldDate = OpenUsageISO8601.date(from: oldReset),
               abs(oldDate.timeIntervalSince(reset)) <= 2 {
                return try counter(legacy, window: window)
            }
            return .percent(window.label, min(ratio, 1) * 100, resetsAt: reset, periodMs: window.periodMs)
        }
    }

    private static func legacyWindows(_ root: [String: Any]) throws -> [MetricLine] {
        var lines: [MetricLine] = []
        if let session = try legacySession(root) { lines.append(try counter(session, window: .session)) }
        if let weekly = try object(root["usage"]) { lines.append(try counter(weekly, window: .weekly)) }
        return lines
    }

    private static func legacySession(_ root: [String: Any]) throws -> [String: Any]? {
        guard let raw = root["limits"], !(raw is NSNull) else { return nil }
        guard let limits = raw as? [[String: Any]] else { throw ProviderError.invalidResponse }
        var session: [String: Any]?
        for limit in limits {
            guard let window = limit["window"] as? [String: Any],
                  let duration = ProviderParse.number(window["duration"]),
                  let unit = window["timeUnit"] as? String else { throw ProviderError.invalidResponse }
            let isSession = switch unit {
            case "TIME_UNIT_MINUTE": duration == 300
            case "TIME_UNIT_HOUR": duration == 5
            case "TIME_UNIT_SECOND": duration == 18_000
            default: false
            }
            guard isSession else { continue }
            guard session == nil, let detail = try object(limit["detail"]) else { throw ProviderError.invalidResponse }
            session = detail
        }
        return session
    }

    private static func counter(_ detail: [String: Any], window: Window) throws -> MetricLine {
        guard let limit = ProviderParse.number(detail["limit"]), limit > 0 else {
            throw ProviderError.invalidResponse
        }
        let used: Double
        if let raw = detail["used"] {
            guard let value = ProviderParse.number(raw), value >= 0 else { throw ProviderError.invalidResponse }
            used = value
        } else if let remaining = ProviderParse.number(detail["remaining"]), (0...limit).contains(remaining) {
            used = limit - remaining
        } else {
            // Protobuf may omit a zero counter, but it must supply either used or remaining.
            throw ProviderError.invalidResponse
        }
        return .percent(window.label, min(used / limit, 1) * 100,
                        resetsAt: try resetDate(detail["resetTime"]), periodMs: window.periodMs)
    }

    private static func object(_ value: Any?) throws -> [String: Any]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else { throw ProviderError.invalidResponse }
        return object
    }

    private static func resetDate(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw ProviderError.invalidResponse }
        guard !text.isEmpty else { return nil }
        guard let date = OpenUsageISO8601.date(from: text) else { throw ProviderError.invalidResponse }
        return date
    }
}

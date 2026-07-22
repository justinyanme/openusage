import Foundation

/// Provider-neutral spend-history serializer shared byte-for-byte by the one-shot CLI and local HTTP API.
/// It reads normalized history from the rendered snapshot set, so iCloud-enabled callers export the
/// same cross-Mac history shown by the dashboard while callers without sync keep machine-local data.
enum LocalSpendAPI {
    static let schema = "openusage.spend.v1"

    private static func isValid(cost: Double?) -> Bool {
        guard let cost else { return true }
        return cost.isFinite && cost >= 0
    }

    static func encode(
        providerIDs: [String],
        state: LocalUsageAPI.State,
        calendar: Calendar = .current
    ) -> Data {
        let dayDates = windowDates(through: state.generatedAt, calendar: calendar)
        let dayKeys = dayDates.map { DailyUsageAccumulator.dayKey(from: $0, calendar: calendar) }
        let includedDays = Set(dayKeys)
        var providers: [String: WireProvider] = [:]
        for providerID in providerIDs {
            guard let snapshot = state.snapshots[providerID],
                  let history = snapshot.usageHistory,
                  let descriptor = state.historyDescriptors[providerID]
            else { continue }
            providers[providerID] = WireProvider(
                snapshot: snapshot,
                history: history,
                descriptor: descriptor,
                dayKeys: dayKeys,
                includedDays: includedDays,
                generatedAt: state.generatedAt,
                includesSyncedPeers: state.syncedHistoryProviderIDs.contains(providerID),
                hasError: state.errors[providerID] != nil
            )
        }
        let errors = providerIDs.compactMap { providerID in
            state.errors[providerID].map { WireError(providerID: providerID, message: $0) }
        }
        let envelope = WireEnvelope(
            schema: schema,
            generatedAt: OpenUsageISO8601.string(from: state.generatedAt),
            calendarTimeZone: calendar.timeZone.identifier,
            window: WireWindow(
                startDate: dayKeys.first ?? "",
                endDate: dayKeys.last ?? "",
                dayCount: dayKeys.count
            ),
            providers: providers,
            errors: errors
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(envelope))
            ?? Data(#"{"errors":[],"providers":{},"schema":"openusage.spend.v1"}"#.utf8)
    }

    private static func windowDates(through now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0...UsageHistoryWindow.previousDays).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
        }
    }

    private struct WireEnvelope: Encodable {
        let schema: String
        let generatedAt: String
        let calendarTimeZone: String
        let window: WireWindow
        let providers: [String: WireProvider]
        let errors: [WireError]
    }

    private struct WireWindow: Encodable {
        let startDate: String
        let endDate: String
        let dayCount: Int
    }

    private struct WireError: Encodable {
        let providerID: String
        let message: String

        enum CodingKeys: String, CodingKey {
            case providerID = "providerId"
            case message
        }
    }

    private struct WireProvider: Encodable {
        let displayName: String
        let fetchedAt: String
        let expiresAt: String
        let stale: Bool
        let historyScope: String
        let includesSyncedPeers: Bool
        let sourceNote: String
        let cost: WireCost
        let periods: WirePeriods
        let days: [WireDay]

        init(
            snapshot: ProviderSnapshot,
            history: ProviderUsageHistory,
            descriptor: UsageHistoryDescriptor,
            dayKeys: [String],
            includedDays: Set<String>,
            generatedAt: Date,
            includesSyncedPeers: Bool,
            hasError: Bool
        ) {
            displayName = snapshot.displayName
            fetchedAt = OpenUsageISO8601.string(from: snapshot.refreshedAt)
            let expiry = snapshot.refreshedAt.addingTimeInterval(RefreshSetting.interval)
            expiresAt = OpenUsageISO8601.string(from: expiry)
            stale = hasError || generatedAt >= expiry
            historyScope = descriptor.scope.rawValue
            self.includesSyncedPeers = includesSyncedPeers
            sourceNote = includesSyncedPeers
                ? "Across your Macs · \(descriptor.sourceNote)"
                : descriptor.sourceNote
            cost = WireCost(
                currency: "USD",
                provenance: descriptor.estimatedCost ? .estimated : .reported
            )

            var totalsByDay: [String: WireTotal] = [:]
            for entry in history.series.daily
            where includedDays.contains(entry.date)
                && entry.totalTokens >= 0
                && LocalSpendAPI.isValid(cost: entry.costUSD)
            {
                let total = WireTotal(tokens: entry.totalTokens, costUSD: entry.costUSD)
                if let existing = totalsByDay[entry.date] {
                    totalsByDay[entry.date] = existing.adding(total)
                } else {
                    totalsByDay[entry.date] = total
                }
            }

            let hasModelBreakdown = history.modelUsage != nil
            var modelsByDay: [String: [WireModel]] = [:]
            for entry in history.modelUsage?.daily ?? [] where includedDays.contains(entry.date) {
                modelsByDay[entry.date, default: []].append(contentsOf: entry.models.compactMap(WireModel.init))
            }
            modelsByDay = modelsByDay.mapValues { models in
                models.sorted { $0.model < $1.model }
            }

            var excludedByDay: [String: [String]] = [:]
            for (day, names) in history.unknownModelsByDay where includedDays.contains(day) {
                excludedByDay[day] = Array(Set(names.filter { !$0.isEmpty })).sorted()
            }

            days = dayKeys.map { day in
                let total = totalsByDay[day]
                let excludedModels = excludedByDay[day] ?? []
                return WireDay(
                    date: day,
                    total: total,
                    models: hasModelBreakdown ? (modelsByDay[day] ?? []) : nil,
                    totalsComplete: Self.completeness(total: total, excludedModels: excludedModels),
                    excludedModels: excludedModels
                )
            }
            periods = WirePeriods(
                today: Self.period(Array(days.suffix(1)), expectedDays: 1),
                yesterday: Self.period(Array(days.dropLast().suffix(1)), expectedDays: 1),
                last30Days: Self.period(days, expectedDays: dayKeys.count)
            )
        }

        private static func period(_ days: [WireDay], expectedDays: Int) -> WirePeriod {
            let observed = days.compactMap(\.total)
            let total: WireTotal?
            if observed.isEmpty {
                total = nil
            } else {
                total = observed.dropFirst().reduce(observed[0]) { $0.adding($1) }
            }
            let excludedModels = Array(Set(days.flatMap(\.excludedModels))).sorted()
            return WirePeriod(
                total: total,
                observedDays: observed.count,
                expectedDays: expectedDays,
                totalsComplete: completeness(total: total, excludedModels: excludedModels),
                excludedModels: excludedModels
            )
        }

        private static func completeness(total: WireTotal?, excludedModels: [String]) -> Bool? {
            if !excludedModels.isEmpty { return false }
            return total == nil ? nil : true
        }
    }

    private struct WireCost: Encodable {
        enum Provenance: String, Encodable {
            case estimated
            case reported
        }

        let currency: String
        let provenance: Provenance
    }

    private struct WirePeriods: Encodable {
        let today: WirePeriod
        let yesterday: WirePeriod
        let last30Days: WirePeriod
    }

    private struct WirePeriod: Encodable {
        let total: WireTotal?
        let observedDays: Int
        let expectedDays: Int
        let totalsComplete: Bool?
        let excludedModels: [String]

        enum CodingKeys: String, CodingKey {
            case total
            case observedDays
            case expectedDays
            case totalsComplete
            case excludedModels
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let total {
                try container.encode(total, forKey: .total)
            } else {
                try container.encodeNil(forKey: .total)
            }
            try container.encode(observedDays, forKey: .observedDays)
            try container.encode(expectedDays, forKey: .expectedDays)
            if let totalsComplete {
                try container.encode(totalsComplete, forKey: .totalsComplete)
            } else {
                try container.encodeNil(forKey: .totalsComplete)
            }
            try container.encode(excludedModels, forKey: .excludedModels)
        }
    }

    private struct WireDay: Encodable {
        let date: String
        let total: WireTotal?
        let models: [WireModel]?
        let totalsComplete: Bool?
        let excludedModels: [String]

        enum CodingKeys: String, CodingKey {
            case date
            case total
            case models
            case totalsComplete
            case excludedModels
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(date, forKey: .date)
            if let total {
                try container.encode(total, forKey: .total)
            } else {
                try container.encodeNil(forKey: .total)
            }
            if let models {
                try container.encode(models, forKey: .models)
            } else {
                try container.encodeNil(forKey: .models)
            }
            if let totalsComplete {
                try container.encode(totalsComplete, forKey: .totalsComplete)
            } else {
                try container.encodeNil(forKey: .totalsComplete)
            }
            try container.encode(excludedModels, forKey: .excludedModels)
        }
    }

    private struct WireTotal: Encodable {
        let tokens: Int
        let costUSD: Double?

        enum CodingKeys: String, CodingKey {
            case tokens
            case costUSD
        }

        func adding(_ other: WireTotal) -> WireTotal {
            WireTotal(
                tokens: tokens + other.tokens,
                costUSD: costUSD.flatMap { lhs in other.costUSD.map { lhs + $0 } }
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tokens, forKey: .tokens)
            if let costUSD {
                try container.encode(costUSD, forKey: .costUSD)
            } else {
                try container.encodeNil(forKey: .costUSD)
            }
        }
    }

    private struct WireModel: Encodable {
        let model: String
        let totalTokens: Int
        let costUSD: Double?
        let variants: [WireVariant]?

        init?(_ value: ModelUsageEntry) {
            guard !value.model.isEmpty,
                  value.totalTokens >= 0,
                  LocalSpendAPI.isValid(cost: value.costUSD)
            else { return nil }
            model = value.model
            totalTokens = value.totalTokens
            costUSD = value.costUSD
            let normalizedVariants = value.variants?.compactMap(WireVariant.init).sorted { $0.model < $1.model }
            variants = normalizedVariants?.isEmpty == false ? normalizedVariants : nil
        }

        enum CodingKeys: String, CodingKey {
            case model
            case totalTokens
            case costUSD
            case variants
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(totalTokens, forKey: .totalTokens)
            if let costUSD {
                try container.encode(costUSD, forKey: .costUSD)
            } else {
                try container.encodeNil(forKey: .costUSD)
            }
            if let variants {
                try container.encode(variants, forKey: .variants)
            } else {
                try container.encodeNil(forKey: .variants)
            }
        }
    }

    private struct WireVariant: Encodable {
        let model: String
        let totalTokens: Int
        let costUSD: Double?

        init?(_ value: ModelUsageVariant) {
            guard !value.model.isEmpty,
                  value.totalTokens >= 0,
                  LocalSpendAPI.isValid(cost: value.costUSD)
            else { return nil }
            model = value.model
            totalTokens = value.totalTokens
            costUSD = value.costUSD
        }

        enum CodingKeys: String, CodingKey {
            case model
            case totalTokens
            case costUSD
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(totalTokens, forKey: .totalTokens)
            if let costUSD {
                try container.encode(costUSD, forKey: .costUSD)
            } else {
                try container.encodeNil(forKey: .costUSD)
            }
        }
    }
}

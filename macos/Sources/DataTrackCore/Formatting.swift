import Foundation

public enum ByteFormat {
    /// Formats a byte count for display, e.g. `4.21 GB`.
    ///
    /// Uses decimal units (1 GB = 1000 MB) because that is what mobile carriers
    /// bill in. Showing GiB here would make the app disagree with the bundle the
    /// user is trying not to exceed.
    public static func string(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: value >= 100 ? "%.0f %@" : "%.2f %@", value, units[unit])
    }

    /// Parses a human-written size such as `5GB`, `500 MB`, `1.5gb`, `2048`.
    /// A bare number is interpreted as bytes.
    public static func parse(_ input: String) -> UInt64? {
        let text = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }

        let suffixes: [(String, Double)] = [
            ("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3),
            ("t", 1e12), ("g", 1e9), ("m", 1e6), ("k", 1e3), ("b", 1),
        ]
        for (suffix, multiplier) in suffixes where text.hasSuffix(suffix) {
            let numberPart = text.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let n = Double(numberPart), n >= 0 else { return nil }
            return UInt64((n * multiplier).rounded())
        }
        guard let n = Double(text), n >= 0 else { return nil }
        return UInt64(n.rounded())
    }
}

/// How fresh the recorded data is.
///
/// A tool that exists to prevent surprises must not present a stale number as a
/// current one. If sampling has stopped, the displayed total is a floor, not a
/// total, and the user has to be told.
public enum SampleFreshness {
    /// Sampling is considered stalled beyond this age. Generous relative to the
    /// 10s default poll so a momentarily slow tick is not reported as a failure.
    public static let stalledAfter: TimeInterval = 120

    public enum State: Equatable, Sendable {
        case neverSampled
        case fresh(age: TimeInterval)
        case stalled(age: TimeInterval)
    }

    public static func state(lastSample: Date?, now: Date = Date()) -> State {
        guard let lastSample else { return .neverSampled }
        let age = max(0, now.timeIntervalSince(lastSample))
        return age > stalledAfter ? .stalled(age: age) : .fresh(age: age)
    }

    /// Compact human age, e.g. `6s`, `4m`, `3h`, `2d`.
    public static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

/// Resolves a budget cycle into the day range it currently covers.
public enum BudgetCycle {
    /// Inclusive local-day range for the cycle containing `now`.
    public static func currentRange(_ budget: Budget, now: Date = Date(), calendar: Calendar = .current) -> (from: String, to: String, key: String) {
        let today = Store.dayKey(now)
        switch budget.cycle {
        case .none:
            // No cycle: report the single day, so a limit still means something.
            return (from: today, to: today, key: "day:\(today)")

        case .rolling30:
            let start = calendar.date(byAdding: .day, value: -29, to: now) ?? now
            return (from: Store.dayKey(start), to: today, key: "rolling30:\(today)")

        case .monthly:
            let day = max(1, min(31, budget.cycleStartDay))
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            let currentDay = components.day ?? 1

            // If we have not yet reached the reset day this month, the cycle
            // opened in the previous month.
            if currentDay < day {
                let prev = calendar.date(byAdding: .month, value: -1, to: now) ?? now
                components = calendar.dateComponents([.year, .month], from: prev)
            } else {
                components = calendar.dateComponents([.year, .month], from: now)
            }
            // Clamp to the month's length so a reset day of 31 still resolves in
            // February rather than rolling into March.
            let monthStart = calendar.date(from: components) ?? now
            let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 28
            components.day = min(day, daysInMonth)

            let cycleStart = calendar.date(from: components) ?? now
            let cycleEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: cycleStart) ?? now
            let from = Store.dayKey(cycleStart)
            return (from: from, to: Store.dayKey(min(cycleEnd, now)), key: "monthly:\(from)")
        }
    }
}

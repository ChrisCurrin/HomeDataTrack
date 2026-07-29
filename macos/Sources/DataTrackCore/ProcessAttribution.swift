import Foundation

/// One process instance's cumulative counters as reported by `nettop`.
public struct ProcessSample: Sendable {
    /// `nettop`'s instance key, `name.pid` — unique per running process.
    public let key: String
    /// Process name with the pid stripped, for aggregation across restarts.
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(key: String, name: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.key = key
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// Attributes traffic to processes so "what used the data" is answerable.
///
/// This is the half of the tool that explains a surprise after the fact: the
/// interface counters say four gigabytes vanished, and this says
/// `softwareupdated` and `nsurlsessiond` were holding the bag.
///
/// `nettop` reports per-process totals since each process started, and it runs
/// unprivileged while still seeing system daemons (verified against
/// `mDNSResponder`, `IntuneMdmDaemon`, `OneDrive`). Traffic is restricted to the
/// Wi-Fi interface type so these numbers stay comparable with the interface
/// counters the sampler uses.
public enum ProcessAttribution {
    /// Takes a one-shot sample of per-process Wi-Fi byte totals.
    public static func sample() throws -> [ProcessSample] {
        let result = try Shell.run(
            "/usr/bin/nettop",
            ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out", "-t", "wifi"],
            timeout: 20
        )
        guard result.status == 0 else { return [] }
        return parse(result.stdout)
    }

    /// Parses `nettop -x -J bytes_in,bytes_out` CSV. Exposed for unit testing.
    ///
    /// Output shape (note the leading and trailing commas):
    /// ```
    /// ,bytes_in,bytes_out,
    /// mDNSResponder.663,85030881,29183216,
    /// ```
    public static func parse(_ output: String) -> [ProcessSample] {
        var samples: [ProcessSample] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count >= 3 else { continue }
            let key = fields[0]
            // Skip the header row (empty first field) and any total/blank rows.
            guard !key.isEmpty, let bytesIn = UInt64(fields[1]), let bytesOut = UInt64(fields[2]) else { continue }

            samples.append(ProcessSample(key: key, name: stripPID(key), bytesIn: bytesIn, bytesOut: bytesOut))
        }
        return samples
    }

    /// `mDNSResponder.663` -> `mDNSResponder`. Leaves names without a numeric
    /// suffix untouched so a process legitimately ending in digits survives.
    ///
    /// Public so the test runner can pin the behaviour directly.
    public static func stripPID(_ key: String) -> String {
        guard let dot = key.lastIndex(of: "."), dot != key.startIndex else { return key }
        let suffix = key[key.index(after: dot)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return key }
        return String(key[key.startIndex..<dot])
    }

    /// Converts two consecutive samples into per-process deltas.
    ///
    /// A counter that moved backwards means the pid was reused or the process
    /// restarted, so the new reading is treated as the delta rather than
    /// producing a negative or absurd value.
    public static func deltas(previous: [String: (bytesIn: UInt64, bytesOut: UInt64)], current: [ProcessSample]) -> [ProcessUsage] {
        var byName: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        for sample in current {
            let deltaIn: UInt64
            let deltaOut: UInt64
            if let prev = previous[sample.key] {
                deltaIn = sample.bytesIn >= prev.bytesIn ? sample.bytesIn - prev.bytesIn : sample.bytesIn
                deltaOut = sample.bytesOut >= prev.bytesOut ? sample.bytesOut - prev.bytesOut : sample.bytesOut
            } else {
                // First sighting. Its totals accrued before we were watching, so
                // counting them now would backdate traffic into this interval.
                deltaIn = 0
                deltaOut = 0
            }
            guard deltaIn > 0 || deltaOut > 0 else { continue }
            var entry = byName[sample.name] ?? (0, 0)
            entry.bytesIn &+= deltaIn
            entry.bytesOut &+= deltaOut
            byName[sample.name] = entry
        }
        return byName.map { ProcessUsage(process: $0.key, bytesIn: $0.value.bytesIn, bytesOut: $0.value.bytesOut) }
            .sorted { $0.total > $1.total }
    }
}

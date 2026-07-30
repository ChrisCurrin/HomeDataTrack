import Foundation

/// One network flow belonging to one process, as reported by `nettop`.
///
/// Attribution is done per *flow* rather than per process because a flow is a
/// genuine monotonic counter with a well-defined lifetime, whereas a process's
/// total is a sum over a changing set of flows — it falls whenever a connection
/// closes, which is indistinguishable from a counter reset.
public struct FlowSample: Sendable, Equatable {
    /// `nettop`'s process key, `name.pid`.
    public let processKey: String
    /// Process name with the pid stripped, for aggregation across restarts.
    public let processName: String
    /// The connection descriptor, e.g. `udp4 *:5353<->*:*`. Stable for the life
    /// of the socket.
    public let connection: String
    /// Interface carrying the flow, e.g. `en0`, `awdl0`, `utun4`.
    public let interface: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(
        processKey: String, processName: String, connection: String,
        interface: String, bytesIn: UInt64, bytesOut: UInt64
    ) {
        self.processKey = processKey
        self.processName = processName
        self.connection = connection
        self.interface = interface
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }

    /// Stable baseline key for this flow.
    public var key: String { "\(processKey)|\(interface)|\(connection)" }
}

/// Attributes traffic to processes so "what used the data" is answerable.
///
/// This is the half of the tool that explains a surprise after the fact: the
/// interface counters say four gigabytes vanished, and this says
/// `softwareupdated` and `nsurlsessiond` were holding the bag.
///
/// ## Why per-flow, and why the interface filter matters
///
/// `nettop -t wifi` does *not* scope byte totals to the interface carrying the
/// default route. Measured on macOS 26.5, mDNSResponder reported 85.8 MB both
/// unfiltered and under `-t wifi`, and its per-flow breakdown was:
///
/// ```
/// udp6 *.5353<->*.*,awdl0,40856648,14019111
/// udp4 *:5353<->*:*,en0,45675525,16008556
/// ```
///
/// `awdl0` is a virtual interface on the same Wi-Fi radio carrying AirDrop,
/// Continuity, Handoff and Sidecar, and its peer discovery *is* mDNS. It is a
/// separate interface that the `en0` byte counters never include, so counting it
/// here made a single process appear to exceed the machine's whole total.
/// Attribution is therefore filtered to the interface actually being accounted.
public enum ProcessAttribution {
    /// Takes a one-shot per-flow sample.
    ///
    /// Runs in per-connection mode rather than `-P`, because the rolled-up
    /// per-process totals carry no interface information.
    public static func sample() throws -> [FlowSample] {
        let result = try Shell.run(
            "/usr/bin/nettop",
            ["-L", "1", "-x", "-J", "interface,bytes_in,bytes_out"],
            timeout: 20
        )
        guard result.status == 0 else { return [] }
        return parse(result.stdout)
    }

    /// Parses `nettop -x -J interface,bytes_in,bytes_out`. Exposed for testing.
    ///
    /// Output interleaves process header rows with their connection rows:
    /// ```
    /// ,interface,bytes_in,bytes_out,
    /// mDNSResponder.663,,86532173,30028019,
    /// udp6 *.5353<->*.*,awdl0,40856648,14019111,
    /// udp4 *:5353<->*:*,en0,45675525,16008556,
    /// apsd.588,,13306,70840,
    /// tcp4 192.168.2.243:62834<->17.57.146.183:5223,en0,13306,70840,
    /// ```
    /// Header rows are distinguished by their first field *not* starting with a
    /// protocol token. Matching on protocol rather than on "contains a space" is
    /// deliberate: plenty of process names contain spaces ("OneDrive Sync S",
    /// "Code Helper"), so a space-based test would misclassify them.
    public static func parse(_ output: String) -> [FlowSample] {
        let protocols = ["tcp4 ", "tcp6 ", "udp4 ", "udp6 "]
        var flows: [FlowSample] = []
        var currentKey: String?
        var currentName: String?

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count >= 4 else { continue }
            let first = fields[0]
            guard !first.isEmpty else { continue }  // header row

            if protocols.contains(where: { first.hasPrefix($0) }) {
                // Connection row. Needs an owning process, an interface, and counts.
                guard let processKey = currentKey, let processName = currentName else { continue }
                let interface = fields[1]
                guard !interface.isEmpty,
                      let bytesIn = UInt64(fields[2]),
                      let bytesOut = UInt64(fields[3])
                else { continue }

                flows.append(FlowSample(
                    processKey: processKey, processName: processName, connection: first,
                    interface: interface, bytesIn: bytesIn, bytesOut: bytesOut
                ))
            } else {
                // Process header row.
                currentKey = first
                currentName = stripPID(first)
            }
        }
        return flows
    }

    /// `mDNSResponder.663` -> `mDNSResponder`. Leaves names without a numeric
    /// suffix untouched so a process legitimately ending in digits survives.
    public static func stripPID(_ key: String) -> String {
        guard let dot = key.lastIndex(of: "."), dot != key.startIndex else { return key }
        let suffix = key[key.index(after: dot)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return key }
        return String(key[key.startIndex..<dot])
    }

    /// Converts a flow sample into per-process deltas for one interface.
    ///
    /// - Parameters:
    ///   - previous: stored baselines, keyed by `FlowSample.key`.
    ///   - current: this sample's flows, unfiltered.
    ///   - interface: the interface being accounted; all other flows are dropped.
    ///   - isFirstSample: true when no baselines exist yet at all.
    ///
    /// A flow appearing for the first time normally has its full byte count
    /// counted, because a new socket's whole total accrued since the previous
    /// sample. The exception is the very first sample of all, where long-lived
    /// sockets — mDNSResponder's `*:5353` has been open since boot — would
    /// otherwise dump their entire history into one interval. On that pass
    /// everything is baselined and nothing is recorded.
    public static func deltas(
        previous: [String: MonotonicCounter.Reading],
        current: [FlowSample],
        interface: String,
        isFirstSample: Bool
    ) -> [ProcessUsage] {
        guard !isFirstSample else { return [] }

        var byName: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        for flow in current where flow.interface == interface {
            let reading = MonotonicCounter.Reading(bytesIn: flow.bytesIn, bytesOut: flow.bytesOut)
            let deltaIn: UInt64
            let deltaOut: UInt64

            switch MonotonicCounter.resolve(previous: previous[flow.key], current: reading) {
            case .baseline:
                // Newly-seen socket: everything it has transferred is new.
                deltaIn = flow.bytesIn
                deltaOut = flow.bytesOut
            case .reset:
                // Jitter or pid reuse. Never re-add the cumulative total.
                continue
            case let .delta(bytesIn, bytesOut):
                deltaIn = bytesIn
                deltaOut = bytesOut
            }

            guard deltaIn > 0 || deltaOut > 0 else { continue }
            var entry = byName[flow.processName] ?? (0, 0)
            entry.bytesIn &+= deltaIn
            entry.bytesOut &+= deltaOut
            byName[flow.processName] = entry
        }

        return byName.map { ProcessUsage(process: $0.key, bytesIn: $0.value.bytesIn, bytesOut: $0.value.bytesOut) }
            .sorted { $0.total > $1.total }
    }
}

import Foundation

public struct SamplerConfig: Sendable {
    /// How often interface counters are read. The default is frequent enough that
    /// a network switch straddles at most a few seconds of traffic.
    public var pollInterval: TimeInterval = 10
    /// How often per-process attribution runs. Kept much longer than
    /// `pollInterval` because each sample spawns `nettop`, which is comparatively
    /// expensive.
    public var processInterval: TimeInterval = 60
    /// Percentages of a budget at which the user is alerted, once per cycle each.
    public var alertThresholds: [Int] = [50, 80, 95, 100]
    public var attributeProcesses: Bool = true

    public init() {}
}

/// The outcome of one sampling tick, for logging and for the CLI's `once` mode.
public struct TickResult: Sendable {
    public enum Kind: String, Sendable {
        /// No default route; nothing to measure.
        case offline
        /// First reading on this interface — baseline stored, no delta yet.
        case baselineEstablished
        /// Counters moved backwards; interface or machine was reset.
        case counterReset
        /// Normal delta recorded.
        case recorded
    }
    public let kind: Kind
    public let network: String?
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let note: String?
}

/// Turns monotonic interface counters into per-network usage.
///
/// The core problem: macOS counts bytes per *interface*, not per *network*. `en0`
/// accumulates across every Wi-Fi network you have ever joined. Attribution is
/// therefore a differencing problem — read the counter, subtract the previous
/// reading, and credit the difference to whichever network was active for that
/// interval.
///
/// Two failure modes drive the design:
///
/// 1. **Counter resets.** A reboot or an interface teardown returns the counter
///    to zero. A naive subtraction would underflow into an enormous bogus delta,
///    so a decrease is treated as a reset and only re-baselines.
/// 2. **Straddled intervals.** If the network changed mid-interval, the bytes
///    belong mostly to the *previous* network, since the switch happened at some
///    unknown point inside it. The baseline therefore records which network it
///    was taken on, and a straddled delta is credited there rather than to the
///    network that happens to be active at read time. Without this, joining a
///    metered hotspot would immediately inherit the tail of the previous
///    network's traffic.
public final class Sampler {
    public typealias CounterDelta = MonotonicCounter.Outcome

    /// Decides what a counter reading means, given the previous one.
    ///
    /// Delegates to `MonotonicCounter` so the interface path and the per-process
    /// path cannot drift apart again — they did once, and the process side
    /// fabricated traffic for weeks' worth of samples as a result.
    public static func resolveDelta(
        baseline: (bytesIn: UInt64, bytesOut: UInt64)?,
        current: InterfaceCounter
    ) -> CounterDelta {
        MonotonicCounter.resolve(
            previous: baseline.map { MonotonicCounter.Reading(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut) },
            current: MonotonicCounter.Reading(bytesIn: current.bytesIn, bytesOut: current.bytesOut)
        )
    }

    private let store: Store
    private let config: SamplerConfig
    private var lastProcessSampleAt: Date?

    public init(store: Store, config: SamplerConfig = SamplerConfig()) {
        self.store = store
        self.config = config
    }

    /// Performs one sampling tick.
    @discardableResult
    public func tick(now: Date = Date()) throws -> TickResult {
        guard let identity = NetworkIdentityReader.current() else {
            return TickResult(kind: .offline, network: nil, bytesIn: 0, bytesOut: 0, note: "no default route")
        }

        let networkID = try store.upsertNetwork(identity, now: now)
        let counters = try InterfaceCounters.read()
        guard let counter = counters[identity.interface] else {
            return TickResult(kind: .offline, network: identity.inferredName, bytesIn: 0, bytesOut: 0,
                              note: "no counters for \(identity.interface)")
        }

        let baseline = try store.counterBaseline(interface: identity.interface)
        // Flattened deliberately: optional-chaining into an optional member of an
        // optional tuple gives Int64??, where `.some(.none)` would read as "we
        // know the previous network" when in fact we do not.
        let baselineNetworkID: Int64? = baseline.flatMap { $0.networkID }
        let deltaIn: UInt64
        let deltaOut: UInt64

        let previous = baseline.map { (bytesIn: $0.bytesIn, bytesOut: $0.bytesOut) }
        switch Self.resolveDelta(baseline: previous, current: counter) {
        case .baseline:
            try store.setCounterBaseline(interface: identity.interface, bytesIn: counter.bytesIn,
                                         bytesOut: counter.bytesOut, networkID: networkID, now: now)
            return TickResult(kind: .baselineEstablished, network: identity.inferredName,
                              bytesIn: 0, bytesOut: 0, note: "first reading on \(identity.interface)")

        case .reset:
            try store.setCounterBaseline(interface: identity.interface, bytesIn: counter.bytesIn,
                                         bytesOut: counter.bytesOut, networkID: networkID, now: now)
            return TickResult(kind: .counterReset, network: identity.inferredName, bytesIn: 0, bytesOut: 0,
                              note: "counter reset on \(identity.interface); interval discarded")

        case let .delta(bytesIn, bytesOut):
            deltaIn = bytesIn
            deltaOut = bytesOut
        }

        // Credit a straddled interval to the network the baseline was taken on.
        let attributedID = baselineNetworkID ?? networkID
        let straddled = baselineNetworkID != nil && baselineNetworkID != networkID

        try store.recordDelta(networkID: attributedID, bytesIn: deltaIn, bytesOut: deltaOut, at: now)
        try store.setCounterBaseline(interface: identity.interface, bytesIn: counter.bytesIn,
                                     bytesOut: counter.bytesOut, networkID: networkID, now: now)

        if config.attributeProcesses, shouldSampleProcesses(now: now) {
            // Process deltas cover the same interval, so they follow the same
            // attribution decision as the interface delta, and are scoped to the
            // same interface the delta was measured on.
            try attributeProcesses(to: attributedID, interface: identity.interface, now: now)
            lastProcessSampleAt = now
        }

        try checkBudget(networkID: attributedID, now: now)

        return TickResult(
            kind: .recorded,
            network: (try? store.network(id: attributedID))?.displayName ?? identity.inferredName,
            bytesIn: deltaIn, bytesOut: deltaOut,
            note: straddled ? "network changed mid-interval; credited to previous network" : nil
        )
    }

    private func shouldSampleProcesses(now: Date) -> Bool {
        guard let last = lastProcessSampleAt else { return true }
        return now.timeIntervalSince(last) >= config.processInterval
    }

    private func attributeProcesses(to networkID: Int64, interface: String, now: Date) throws {
        let flows = try ProcessAttribution.sample()
        guard !flows.isEmpty else { return }

        // An empty baseline table means this is the first sample ever taken.
        // Long-lived sockets (mDNSResponder's *:5353 has been open since boot)
        // must be baselined rather than counted, or their entire history lands in
        // a single interval.
        let isFirstSample = try store.processStateIsEmpty()

        let relevant = flows.filter { $0.interface == interface }
        var previous: [String: MonotonicCounter.Reading] = [:]
        for flow in relevant {
            if let baseline = try store.processBaseline(key: flow.key) {
                previous[flow.key] = MonotonicCounter.Reading(bytesIn: baseline.bytesIn, bytesOut: baseline.bytesOut)
            }
        }

        let deltas = ProcessAttribution.deltas(
            previous: previous, current: relevant, interface: interface, isFirstSample: isFirstSample
        )
        try store.recordProcessDeltas(networkID: networkID, deltas: deltas, at: now)

        for flow in relevant {
            try store.setProcessBaseline(key: flow.key, bytesIn: flow.bytesIn, bytesOut: flow.bytesOut, now: now)
        }
        // Only genuinely dead flows are pruned. The window is long because a
        // live long-lived socket that got pruned would be re-counted in full on
        // its next sighting — the very failure this rewrite removes.
        try store.pruneProcessState(before: now.addingTimeInterval(-86_400))
    }

    /// Alerts once per threshold per cycle when a budgeted network fills up.
    private func checkBudget(networkID: Int64, now: Date) throws {
        guard let budget = try store.budget(networkID: networkID), budget.limitBytes > 0 else { return }
        let range = BudgetCycle.currentRange(budget, now: now)
        let used = try store.usage(networkID: networkID, fromDay: range.from, toDay: range.to)
        let total = used.bytesIn &+ used.bytesOut
        let percent = Int((Double(total) / Double(budget.limitBytes) * 100).rounded(.down))

        let name = (try? store.network(id: networkID))?.displayName ?? "network"
        for threshold in config.alertThresholds.sorted() where percent >= threshold {
            guard try store.claimAlert(networkID: networkID, cycleKey: range.key, threshold: threshold, now: now) else {
                continue
            }
            let remaining = budget.limitBytes > total ? budget.limitBytes - total : 0
            Notifier.notify(
                title: threshold >= 100 ? "Data budget exhausted — \(name)" : "\(threshold)% of data budget used — \(name)",
                subtitle: "\(ByteFormat.string(total)) of \(ByteFormat.string(budget.limitBytes))",
                message: threshold >= 100
                    ? "This network is over its limit. Anything downloading now is costing you."
                    : "\(ByteFormat.string(remaining)) left this cycle."
            )
        }
    }

    /// Runs until the process is terminated, sampling on `config.pollInterval`.
    public func run(log: @escaping @Sendable (String) -> Void = { print($0) }) throws {
        log("datatrack sampler started (poll \(Int(config.pollInterval))s, process attribution every \(Int(config.processInterval))s)")

        // Sample immediately so a short-lived session still records something,
        // then settle into the interval.
        while true {
            do {
                let result = try tick()
                switch result.kind {
                case .recorded:
                    if result.bytesIn > 0 || result.bytesOut > 0 {
                        var line = "\(result.network ?? "?") +\(ByteFormat.string(result.bytesIn)) in / +\(ByteFormat.string(result.bytesOut)) out"
                        if let note = result.note { line += " (\(note))" }
                        log(line)
                    }
                case .baselineEstablished, .counterReset:
                    log("\(result.kind.rawValue): \(result.note ?? "")")
                case .offline:
                    break
                }
            } catch {
                // A transient failure (netstat killed, database locked) must not
                // take down a long-running agent.
                log("tick failed: \(error)")
            }
            Thread.sleep(forTimeInterval: config.pollInterval)
        }
    }
}

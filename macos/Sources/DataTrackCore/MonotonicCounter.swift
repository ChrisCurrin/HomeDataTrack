import Foundation

/// The single rule for turning successive readings of a monotonic byte counter
/// into a delta.
///
/// This exists because the rule was originally implemented twice — once for
/// interface counters, once for per-process counters — and the two
/// implementations disagreed. The interface path correctly discarded an interval
/// when the counter moved backwards; the process path added the *entire*
/// cumulative counter instead. A few bytes of jitter between samples therefore
/// re-injected a process's whole lifetime total, and mDNSResponder was credited
/// with 119.9 MB of outbound traffic on a day it had sent 29.9 MB since boot —
/// almost exactly 4x, one spurious injection per dip.
///
/// Every counter in this codebase now goes through here.
public enum MonotonicCounter {
    public struct Reading: Equatable, Sendable {
        public let bytesIn: UInt64
        public let bytesOut: UInt64

        public init(bytesIn: UInt64, bytesOut: UInt64) {
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// No previous reading. Store this one; record nothing.
        case baseline
        /// Counter moved backwards — reboot, interface teardown, process restart,
        /// pid reuse, or sampling jitter. Re-baseline and drop the interval.
        case reset
        case delta(bytesIn: UInt64, bytesOut: UInt64)
    }

    /// Resolves one reading against the previous one.
    ///
    /// A decrease in *either* direction is treated as a reset. Handling the two
    /// axes independently would let one of them underflow while the other looked
    /// healthy, and the magnitude of a decrease is deliberately not considered:
    /// there is no threshold at which re-adding a cumulative total becomes
    /// correct, so the interval is always discarded instead.
    public static func resolve(previous: Reading?, current: Reading) -> Outcome {
        guard let previous else { return .baseline }
        if current.bytesIn < previous.bytesIn || current.bytesOut < previous.bytesOut { return .reset }
        return .delta(
            bytesIn: current.bytesIn - previous.bytesIn,
            bytesOut: current.bytesOut - previous.bytesOut
        )
    }
}

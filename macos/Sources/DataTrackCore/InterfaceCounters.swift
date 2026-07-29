import Darwin
import Foundation

/// Cumulative byte counters for one network interface, as reported by the kernel.
///
/// Counters are monotonic for the lifetime of the interface. They reset to zero
/// on reboot and can reset when an interface is torn down and recreated, so
/// callers must treat a decrease as a reset rather than as negative traffic.
public struct InterfaceCounter: Equatable, Sendable {
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(name: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public enum CounterError: Error, CustomStringConvertible {
    case netstatFailed(status: Int32, stderr: String)
    case unparseableHeader(String)

    public var description: String {
        switch self {
        case let .netstatFailed(status, err):
            return "netstat exited \(status): \(err)"
        case let .unparseableHeader(line):
            return "could not locate Ibytes/Obytes columns in netstat header: \(line)"
        }
    }
}

/// Reads per-interface byte counters.
///
/// ## Why this shells out to `netstat` instead of reading the kernel struct
///
/// The obvious native route is `sysctl(NET_RT_IFLIST2)` walked as `if_msghdr2`,
/// whose `ifm_data` is an `if_data64` carrying 64-bit `ifi_ibytes`/`ifi_obytes`.
/// On macOS 26.5 that is actively wrong: Swift's imported `if_msghdr2` is 160
/// bytes while the kernel emits `ifm_msglen == 180`, so reading `ifm_data` at
/// the imported offset lands on a 32-bit field. The observed value equals the
/// true counter mod 2^32 (verified: 945_435_648 read against a netstat truth of
/// 69_664_912_535, which is 945_435_799 mod 2^32). A byte-wise scan of the full
/// 180-byte message did not contain the true 64-bit value at any offset.
///
/// A 32-bit counter wraps every 4 GiB. That is well inside a single macOS
/// update, which is precisely the event this tool exists to catch, and a wrap
/// missed across a sleep window is unrecoverable. `netstat -ibn` is shipped by
/// Apple, needs no elevated privileges, and demonstrably reports the true
/// 64-bit values, so it is the source of record. `lowWordSelfTest()` keeps the
/// native path around as a consistency check rather than as the truth.
public enum InterfaceCounters {
    /// Reads 64-bit counters for every interface, keyed by interface name.
    public static func read() throws -> [String: InterfaceCounter] {
        let result = try Shell.run("/usr/sbin/netstat", ["-ibn"])
        guard result.status == 0 else {
            throw CounterError.netstatFailed(status: result.status, stderr: result.stderr)
        }
        return try parse(netstatOutput: result.stdout)
    }

    /// Parses `netstat -ibn` output. Exposed for unit testing.
    ///
    /// The Address column is empty for interfaces without a link address (`lo0`),
    /// so rows have a variable field count and cannot be indexed from the left.
    /// Column positions are therefore derived from the header and applied as
    /// offsets from the end of each row.
    public static func parse(netstatOutput: String) throws -> [String: InterfaceCounter] {
        var lines = netstatOutput.split(separator: "\n", omittingEmptySubsequences: true)
        guard let headerLine = lines.first else {
            throw CounterError.unparseableHeader("<empty output>")
        }
        lines.removeFirst()

        let header = headerLine.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let inIndex = header.firstIndex(of: "Ibytes"),
              let outIndex = header.firstIndex(of: "Obytes")
        else {
            throw CounterError.unparseableHeader(headerLine.description)
        }
        // Offsets counted from the end of the row, which is stable even when the
        // optional Address column is blank.
        let inFromEnd = header.count - inIndex
        let outFromEnd = header.count - outIndex

        var counters: [String: InterfaceCounter] = [:]
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            // Only the link-layer row carries the interface-wide totals; the
            // per-protocol rows that follow repeat the same numbers per address
            // family and would double count if summed.
            guard fields.count > max(inFromEnd, outFromEnd),
                  fields.count >= 3,
                  fields[2].hasPrefix("<Link")
            else { continue }

            let name = fields[0]
            guard let bytesIn = UInt64(fields[fields.count - inFromEnd]),
                  let bytesOut = UInt64(fields[fields.count - outFromEnd])
            else { continue }

            // An interface name appearing twice would mean our row filter is
            // wrong; keep the first and never accumulate.
            if counters[name] == nil {
                counters[name] = InterfaceCounter(name: name, bytesIn: bytesIn, bytesOut: bytesOut)
            }
        }
        return counters
    }

    /// Reads the kernel's 32-bit `if_data` counters via `getifaddrs`.
    ///
    /// Used only by `selfTest(...)`. These wrap at 2^32 and must not be used for
    /// accounting.
    public static func lowWordCounters() -> [String: (bytesIn: UInt32, bytesOut: UInt32)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var out: [String: (bytesIn: UInt32, bytesOut: UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = entry.pointee.ifa_data
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            out[name] = (bytesIn: data.ifi_ibytes, bytesOut: data.ifi_obytes)
        }
        return out
    }

    /// Confirms the `netstat` source agrees with the kernel's own 32-bit
    /// counters modulo 2^32, within `tolerance` bytes of sampling drift.
    ///
    /// A failure means the netstat column mapping has drifted on this OS
    /// version and totals can no longer be trusted.
    public static func selfTest(interface: String, tolerance: UInt64 = 50_000_000) throws -> Bool {
        let truth = try read()
        let low = lowWordCounters()
        guard let t = truth[interface], let l = low[interface] else { return false }

        let modulus: UInt64 = 1 << 32
        func agrees(_ wide: UInt64, _ narrow: UInt32) -> Bool {
            let expected = wide % modulus
            let actual = UInt64(narrow)
            // Compare on a ring: the two reads are not simultaneous, and either
            // side may have advanced past a wrap boundary in between.
            let forward = (actual &+ modulus &- expected) % modulus
            let backward = (expected &+ modulus &- actual) % modulus
            return min(forward, backward) <= tolerance
        }
        return agrees(t.bytesIn, l.bytesIn) && agrees(t.bytesOut, l.bytesOut)
    }
}

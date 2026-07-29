import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// Everything we can learn about the network the Mac is currently using.
///
/// `ssid` is frequently `nil`. As of macOS 26 the Wi-Fi network *name* is gated
/// behind Location Services authorization: an unsigned CLI gets `nil` from
/// `CWInterface.ssid()`, `networksetup -getairportnetwork` reports "You are not
/// associated with an AirPort network" while plainly associated, and
/// `system_profiler` prints `<redacted>`. Signal strength, channel and PHY mode
/// are *not* gated. Identity therefore cannot depend on the SSID.
public struct NetworkIdentity: Sendable {
    /// Interface carrying the default route, e.g. `en0`.
    public let interface: String
    /// Wi-Fi network name, or `nil` when privacy-gated or not on Wi-Fi.
    public let ssid: String?
    /// Default gateway address, e.g. `172.20.10.1`.
    public let gatewayIP: String?
    /// Gateway hardware address — the permission-free identity anchor.
    public let gatewayMAC: String?
    /// Local subnet in CIDR form, e.g. `172.20.10.0/28`.
    public let subnet: String?
    /// True when the kernel marks the interface `constrained` — macOS's own
    /// signal that it considers this link metered (Low Data Mode / hotspot).
    public let isConstrained: Bool
    /// True when the gateway address matches a known phone-tethering range.
    public let matchesTetherRange: Bool

    public init(
        interface: String, ssid: String?, gatewayIP: String?, gatewayMAC: String?,
        subnet: String?, isConstrained: Bool, matchesTetherRange: Bool
    ) {
        self.interface = interface
        self.ssid = ssid
        self.gatewayIP = gatewayIP
        self.gatewayMAC = gatewayMAC
        self.subnet = subnet
        self.isConstrained = isConstrained
        self.matchesTetherRange = matchesTetherRange
    }

    /// Stable primary key for this network.
    ///
    /// Keyed on the gateway MAC in preference to the SSID so that history stays
    /// attached to one network across permission changes. If identity were keyed
    /// on the SSID, granting Location Services later would silently fork a
    /// network's history into a second record.
    public var fingerprint: String {
        if let mac = gatewayMAC, !mac.isEmpty { return "gw:\(mac)" }
        if let ssid, !ssid.isEmpty { return "ssid:\(ssid)" }
        if let subnet, !subnet.isEmpty { return "subnet:\(subnet)@\(interface)" }
        return "iface:\(interface)"
    }

    /// Best available human-readable name, before any user-assigned label.
    public var inferredName: String {
        if let ssid, !ssid.isEmpty { return ssid }
        if matchesTetherRange { return "Phone hotspot (\(gatewayIP ?? interface))" }
        if let subnet { return "Network \(subnet)" }
        return interface
    }

    /// Whether this link should be treated as metered by default.
    ///
    /// Only a seed value — once a network exists, the user's explicit choice owns
    /// this flag and is never overwritten by the heuristic.
    public var looksMetered: Bool {
        if matchesTetherRange { return true }
        if isConstrained { return true }
        if let ssid { return Self.ssidSuggestsTethering(ssid) }
        return false
    }

    /// Whether an SSID reads like a phone sharing its connection.
    ///
    /// Device names are matched as whole tokens rather than substrings. A plain
    /// `contains` check is too eager: a home network called "Pixelated" contains
    /// "pixel", and mislabelling an unmetered network as metered is the more
    /// annoying error — it is the one that produces budget warnings the user
    /// never asked for. Phrases like "hotspot" carry their own meaning wherever
    /// they appear, so those stay as substring matches.
    public static func ssidSuggestsTethering(_ ssid: String) -> Bool {
        let lowered = ssid.lowercased()
        for phrase in ["hotspot", "tether"] where lowered.contains(phrase) { return true }

        let deviceNames: Set<String> = ["iphone", "ipad", "android", "pixel", "galaxy", "oneplus", "huawei"]
        let tokens = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.contains { deviceNames.contains(String($0)) }
    }
}

public enum NetworkIdentityReader {
    /// Gateway addresses handed out by phone tethering implementations.
    /// iOS Personal Hotspot is deterministic at 172.20.10.1, which makes it
    /// detectable even when the SSID is hidden from us.
    private static let tetherGateways: Set<String> = [
        "172.20.10.1",      // iOS Personal Hotspot
        "192.168.43.1",     // Android (AOSP default)
        "192.168.42.129",   // Android (USB/legacy)
        "192.168.44.1",     // Android (alternate)
        "192.168.137.1",    // Windows Internet Connection Sharing
    ]

    /// Resolves the currently-active network, or `nil` when nothing is routable.
    public static func current() -> NetworkIdentity? {
        guard let (interface, gatewayIP) = primaryRoute() else { return nil }

        let mac = gatewayIP.flatMap { arpLookup(ip: $0, interface: interface) }
        let ssid = currentSSID(interface: interface)
        let subnet = subnetCIDR(interface: interface)
        let constrained = isConstrained(interface: interface)
        let tether = gatewayIP.map { tetherGateways.contains($0) } ?? false

        return NetworkIdentity(
            interface: interface,
            ssid: ssid,
            gatewayIP: gatewayIP,
            gatewayMAC: mac,
            subnet: subnet,
            isConstrained: constrained,
            matchesTetherRange: tether
        )
    }

    /// Primary interface and router, read from the SystemConfiguration dynamic
    /// store. This needs no entitlement and reflects the actual default route
    /// rather than guessing at interface ordering.
    static func primaryRoute() -> (interface: String, gateway: String?)? {
        guard let store = SCDynamicStoreCreate(nil, "DataTrack" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = value["PrimaryInterface"] as? String
        else { return nil }
        return (interface, value["Router"] as? String)
    }

    /// Reads the SSID via CoreWLAN. Returns `nil` when Location Services has not
    /// authorized this process, which is the default for anything not running
    /// from a signed app bundle.
    static func currentSSID(interface: String) -> String? {
        guard let wifi = CWWiFiClient.shared().interface(withName: interface) else { return nil }
        guard let ssid = wifi.ssid(), !ssid.isEmpty else { return nil }
        return ssid
    }

    /// Resolves a gateway IP to its hardware address.
    ///
    /// The ARP cache may not hold the entry yet, so on a miss we provoke one
    /// round trip to the gateway and look again. The ping is to the local router
    /// only and costs a single packet.
    static func arpLookup(ip: String, interface: String) -> String? {
        if let mac = try? arpQuery(ip: ip) { return mac }
        _ = try? Shell.run("/sbin/ping", ["-c", "1", "-t", "1", "-n", ip], timeout: 3)
        return try? arpQuery(ip: ip)
    }

    private static func arpQuery(ip: String) throws -> String? {
        let result = try Shell.run("/usr/sbin/arp", ["-n", ip], timeout: 5)
        guard result.status == 0 else { return nil }
        return parseARP(result.stdout)
    }

    /// Extracts the MAC from `arp -n` output. Exposed for unit testing.
    /// Example: `? (10.0.0.1) at da:f7:ed:85:e7:d5 on en0 ifscope [ethernet]`
    public static func parseARP(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let atIndex = fields.firstIndex(of: "at"), atIndex + 1 < fields.count else { continue }
            let candidate = fields[atIndex + 1]
            if candidate == "(incomplete)" { continue }
            // A MAC has six colon-separated hex groups. Anything else is noise.
            let groups = candidate.split(separator: ":")
            guard groups.count == 6, groups.allSatisfy({ $0.count <= 2 && UInt8($0, radix: 16) != nil }) else { continue }
            // Normalize to zero-padded lowercase so `1:0:5e:...` and
            // `01:00:5e:...` cannot become two different networks.
            return groups.map { String(format: "%02x", UInt8($0, radix: 16)!) }.joined(separator: ":")
        }
        return nil
    }

    /// Computes the interface's IPv4 subnet in CIDR form from its address and mask.
    static func subnetCIDR(interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, head != nil else { return nil }
        defer { freeifaddrs(head) }

        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == interface,
                  let addrPtr = entry.pointee.ifa_addr,
                  addrPtr.pointee.sa_family == UInt8(AF_INET),
                  let maskPtr = entry.pointee.ifa_netmask
            else { continue }

            let addr = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let network = addr & mask
            let prefix = mask.nonzeroBitCount
            let octets = [network >> 24 & 0xFF, network >> 16 & 0xFF, network >> 8 & 0xFF, network & 0xFF]
            return "\(octets.map(String.init).joined(separator: "."))/\(prefix)"
        }
        return nil
    }

    /// Detects the kernel's `constrained` interface flag, which macOS sets for
    /// links it considers metered. Surfaced by `ifconfig` on the flags line.
    static func isConstrained(interface: String) -> Bool {
        guard let result = try? Shell.run("/sbin/ifconfig", [interface], timeout: 5), result.status == 0 else {
            return false
        }
        guard let flagsLine = result.stdout.split(separator: "\n").first else { return false }
        return flagsLine.split(whereSeparator: \.isWhitespace).contains("constrained")
    }
}

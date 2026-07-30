import DataTrackCore
import Foundation

// Hand-rolled argument handling keeps the package dependency-free, so the build
// works offline and the binary has nothing to resolve at install time.

let usage = """
datatrack — per-Wi-Fi-network data usage for macOS

USAGE
  datatrack status                       Current network, today's usage, budget state
  datatrack networks                     Every network seen, with lifetime totals
  datatrack history <network> [--days N] Daily breakdown (default 14 days)
  datatrack top [<network>] [--days N]   Which processes used the data
  datatrack name <network> <label>        Name a network (needed when macOS hides the SSID)
  datatrack meter <network> on|off        Mark a network as metered
  datatrack budget set <network> <size> [--cycle monthly|rolling30|none] [--start-day N]
  datatrack budget clear <network>
  datatrack reset-processes              Discard per-process history (keeps network totals)
  datatrack once                         Take one sample and print the result
  datatrack watch [--interval S]         Run the sampler in the foreground
  datatrack doctor                       Diagnose what this Mac will and will not tell us
  datatrack selftest                     Verify the byte counters are trustworthy

<network> is a row id from `datatrack networks`, or `current`.
<size> accepts 5GB, 500MB, 1.5g, or a bare byte count.
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

var arguments = Array(CommandLine.arguments.dropFirst())

/// Extracts `--flag value` and removes it from the argument list.
func takeOption(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)") else { return nil }
    guard index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func takeFlag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: "--\(name)") else { return false }
    arguments.remove(at: index)
    return true
}

func resolveNetwork(_ token: String?, store: Store) throws -> NetworkRecord {
    let all = try store.networks()
    guard let token, token != "current" else {
        guard let identity = NetworkIdentityReader.current() else {
            throw CLIError("not connected to any network")
        }
        let id = try store.resolveNetwork(identity)
        guard let record = try store.network(id: id) else { throw CLIError("could not resolve current network") }
        return record
    }
    if let id = Int64(token), let match = all.first(where: { $0.id == id }) { return match }
    if let match = all.first(where: { $0.fingerprint == token }) { return match }
    // Fall back to a case-insensitive name match so `datatrack top "iPhone"` works.
    if let match = all.first(where: { $0.displayName.lowercased() == token.lowercased() }) { return match }
    throw CLIError("no network matching '\(token)'. Run `datatrack networks` to list them.")
}

func dayRange(days: Int, now: Date = Date()) -> (from: String, to: String) {
    let start = Calendar.current.date(byAdding: .day, value: -(max(1, days) - 1), to: now) ?? now
    return (Store.dayKey(start), Store.dayKey(now))
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func padLeft(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

/// Renders a budget as a bar plus percentage, which is the thing you actually
/// want to see at a glance.
func budgetLine(store: Store, network: NetworkRecord) throws -> String? {
    guard let budget = try store.budget(networkID: network.id) else { return nil }
    let range = BudgetCycle.currentRange(budget)
    let used = try store.usage(networkID: network.id, fromDay: range.from, toDay: range.to)
    let total = used.bytesIn &+ used.bytesOut
    let fraction = budget.limitBytes == 0 ? 0 : min(1.0, Double(total) / Double(budget.limitBytes))
    let filled = Int((fraction * 24).rounded())
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 24 - filled)
    let percent = Int((fraction * 100).rounded())
    let remaining = budget.limitBytes > total ? budget.limitBytes - total : 0
    return """
      Budget    \(bar) \(percent)%
                \(ByteFormat.string(total)) of \(ByteFormat.string(budget.limitBytes)) \
    (\(ByteFormat.string(remaining)) left) · \(budget.cycle.rawValue) cycle from \(range.from)
    """
}

func commandStatus(store: Store) throws {
    guard let identity = NetworkIdentityReader.current() else {
        print("Offline — no default route.")
        return
    }
    let id = try store.resolveNetwork(identity)
    guard let record = try store.network(id: id) else { throw CLIError("could not resolve current network") }

    let today = Store.dayKey(Date())
    let todayUsage = try store.usage(networkID: id, fromDay: today, toDay: today)

    print("Current network")
    print("  Name      \(record.displayName)\(record.isMetered ? "   ⚠︎ metered" : "")")
    print("  Interface \(identity.interface)\(identity.isConstrained ? " (macOS marks this link constrained)" : "")")
    if let gateway = identity.gatewayIP { print("  Gateway   \(gateway)\(identity.gatewayMAC.map { " · \($0)" } ?? "")") }
    if identity.ssid == nil {
        print("  SSID      hidden by macOS — identified by gateway instead. `datatrack name current \"…\"` to label it.")
    }
    print("  Id        \(record.id)   (\(record.fingerprint))")
    print("")
    print("Today")
    print("  ↓ \(ByteFormat.string(todayUsage.bytesIn))   ↑ \(ByteFormat.string(todayUsage.bytesOut))   total \(ByteFormat.string(todayUsage.bytesIn &+ todayUsage.bytesOut))")

    // A frozen total that looks current is the worst thing this tool can show.
    switch SampleFreshness.state(lastSample: try store.lastSampleAt()) {
    case .neverSampled:
        print("  ⚠︎ nothing has been sampled yet — run `datatrack watch` or install the agent")
    case let .stalled(age):
        print("  ⚠︎ NOT SAMPLING — last reading \(SampleFreshness.ago(age)) ago. This total is stale.")
        print("     Check: launchctl print gui/$(id -u)/com.chriscurrin.datatrack")
    case let .fresh(age):
        print("  last sampled \(SampleFreshness.ago(age)) ago")
    }

    if let line = try budgetLine(store: store, network: record) {
        print("")
        print(line)
    }

    let top = try store.topProcesses(networkID: id, fromDay: today, toDay: today, limit: 5)
    if !top.isEmpty {
        print("")
        print("Top talkers today                     (sampled; will not sum to the total)")
        for p in top {
            print("  \(pad(p.process, 26)) \(padLeft(ByteFormat.string(p.total), 10))")
        }
    }
}

func commandNetworks(store: Store) throws {
    let networks = try store.networks()
    guard !networks.isEmpty else {
        print("No networks recorded yet. Run `datatrack once` or start the agent.")
        return
    }
    let currentFingerprint = NetworkIdentityReader.current()?.fingerprint

    print("\(pad("ID", 4))\(pad("NETWORK", 30))\(padLeft("TOTAL", 11))  \(pad("METERED", 8))LAST SEEN")
    for network in networks {
        // Lifetime total: from the epoch to today covers every recorded day.
        let usage = try store.usage(networkID: network.id, fromDay: "0000-00-00", toDay: "9999-99-99")
        let marker = network.fingerprint == currentFingerprint ? "▸ " : "  "
        let name = marker + network.displayName
        print("\(pad(String(network.id), 4))\(pad(String(name.prefix(29)), 30))\(padLeft(ByteFormat.string(usage.bytesIn &+ usage.bytesOut), 11))  \(pad(network.isMetered ? "yes" : "no", 8))\(Store.dayKey(network.lastSeen))")
    }
}

func commandHistory(store: Store) throws {
    let days = Int(takeOption("days") ?? "14") ?? 14
    let network = try resolveNetwork(arguments.first, store: store)
    let range = dayRange(days: days)
    let rows = try store.dailyBreakdown(networkID: network.id, fromDay: range.from, toDay: range.to)
    print("\(network.displayName) — last \(days) days")
    guard !rows.isEmpty else { print("  no usage recorded"); return }

    let peak = rows.map { $0.bytesIn &+ $0.bytesOut }.max() ?? 1
    for row in rows {
        let total = row.bytesIn &+ row.bytesOut
        let width = peak == 0 ? 0 : Int((Double(total) / Double(peak) * 30).rounded())
        print("  \(row.day)  \(padLeft(ByteFormat.string(total), 10))  \(String(repeating: "▇", count: width))")
    }
    let sum = rows.reduce(UInt64(0)) { $0 &+ $1.bytesIn &+ $1.bytesOut }
    print("  total     \(padLeft(ByteFormat.string(sum), 10))")
}

func commandTop(store: Store) throws {
    let days = Int(takeOption("days") ?? "1") ?? 1
    let network = try resolveNetwork(arguments.first, store: store)
    let range = dayRange(days: days)
    let top = try store.topProcesses(networkID: network.id, fromDay: range.from, toDay: range.to, limit: 20)
    print("\(network.displayName) — processes over last \(days) day(s)")
    guard !top.isEmpty else {
        print("  No process data yet. Attribution samples once a minute while the agent runs.")
        return
    }
    for p in top {
        print("  \(pad(p.process, 28)) \(padLeft(ByteFormat.string(p.total), 10))   ↓\(ByteFormat.string(p.bytesIn)) ↑\(ByteFormat.string(p.bytesOut))")
    }
    print("")
    print("  Sampled once a minute, so these will not sum to the network total.")
    print("  Multicast is delivered to several processes and counted for each.")
}

func commandName(store: Store) throws {
    guard arguments.count >= 2 else { throw CLIError("usage: datatrack name <network> <label>") }
    let network = try resolveNetwork(arguments[0], store: store)
    let label = arguments[1...].joined(separator: " ")
    try store.setLabel(networkID: network.id, label: label)
    print("Network \(network.id) is now \"\(label)\".")
}

func commandMeter(store: Store) throws {
    guard arguments.count >= 2, ["on", "off"].contains(arguments[1]) else {
        throw CLIError("usage: datatrack meter <network> on|off")
    }
    let network = try resolveNetwork(arguments[0], store: store)
    try store.setMetered(networkID: network.id, metered: arguments[1] == "on")
    print("\(network.displayName) metered = \(arguments[1]).")
}

func commandBudget(store: Store) throws {
    guard let sub = arguments.first else { throw CLIError("usage: datatrack budget set|clear …") }
    arguments.removeFirst()

    switch sub {
    case "set":
        let cycleName = takeOption("cycle") ?? "monthly"
        let startDay = Int(takeOption("start-day") ?? "1") ?? 1
        guard arguments.count >= 2 else { throw CLIError("usage: datatrack budget set <network> <size>") }
        guard let cycle = Budget.Cycle(rawValue: cycleName) else {
            throw CLIError("cycle must be monthly, rolling30, or none")
        }
        guard let limit = ByteFormat.parse(arguments[1]) else {
            throw CLIError("could not read size '\(arguments[1])'. Try 5GB or 500MB.")
        }
        let network = try resolveNetwork(arguments[0], store: store)
        try store.setBudget(Budget(networkID: network.id, limitBytes: limit, cycle: cycle, cycleStartDay: startDay))
        // A budget is a statement that this network costs money; record that.
        try store.setMetered(networkID: network.id, metered: true)
        print("Budget for \(network.displayName): \(ByteFormat.string(limit)) per \(cycle.rawValue) cycle.")
        if let line = try budgetLine(store: store, network: network) { print(line) }

    case "clear":
        let network = try resolveNetwork(arguments.first, store: store)
        try store.clearBudget(networkID: network.id)
        print("Budget cleared for \(network.displayName).")

    default:
        throw CLIError("unknown budget subcommand '\(sub)'")
    }
}

func commandResetProcesses(store: Store) throws {
    try store.resetProcessHistory()
    print("Per-process history cleared. Network totals are untouched.")
    print("Attribution restarts from the next sample; the first one only establishes baselines.")
}

func commandOnce(store: Store) throws {
    let sampler = Sampler(store: store)
    let result = try sampler.tick()
    print("\(result.kind.rawValue): \(result.network ?? "—")  ↓\(ByteFormat.string(result.bytesIn)) ↑\(ByteFormat.string(result.bytesOut))")
    if let note = result.note { print("  \(note)") }
}

func commandWatch(store: Store) throws {
    var config = SamplerConfig()
    if let interval = takeOption("interval"), let seconds = Double(interval) { config.pollInterval = seconds }
    if let interval = takeOption("process-interval"), let seconds = Double(interval) { config.processInterval = seconds }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    try Sampler(store: store, config: config).run { line in
        print("[\(formatter.string(from: Date()))] \(line)")
        // launchd captures stdout to a file; flush so `tail -f` is live.
        fflush(stdout)
    }
}

/// Reports what this specific Mac will disclose, because the answer varies by OS
/// version and by whether the caller is a signed bundle.
func commandDoctor(store: Store) throws {
    print("datatrack doctor")
    print("")

    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    print("  macOS                \(osVersion)")

    guard let identity = NetworkIdentityReader.current() else {
        print("  Default route        NONE — offline, nothing to measure")
        return
    }
    print("  Default route        \(identity.interface)")
    print("  Gateway IP           \(identity.gatewayIP ?? "unknown")")
    print("  Gateway MAC          \(identity.gatewayMAC ?? "unknown — identity falls back to subnet")")
    print("  Subnet               \(identity.subnet ?? "unknown")")
    print("  Constrained flag     \(identity.isConstrained ? "SET — macOS treats this link as metered" : "not set")")
    print("  Tether-range gateway \(identity.matchesTetherRange ? "YES — looks like a phone hotspot" : "no")")
    print("  Fingerprint          \(identity.fingerprint)")
    print("")

    if let ssid = identity.ssid {
        print("  SSID                 \(ssid)")
    } else {
        print("  SSID                 UNAVAILABLE")
        print("                       macOS gates the Wi-Fi network name behind Location Services.")
        print("                       Tracking still works — networks are keyed on gateway MAC.")
        print("                       Use `datatrack name current \"My Hotspot\"` to label this one,")
        print("                       or run the DataTrack menu bar app and grant location access.")
    }
    print("")

    let counterOK = (try? InterfaceCounters.selfTest(interface: identity.interface)) ?? false
    print("  Byte counters        \(counterOK ? "OK — netstat agrees with kernel counters mod 2^32" : "MISMATCH — totals may be wrong, please report")")

    let processSamples = (try? ProcessAttribution.sample()) ?? []
    print("  Process attribution  \(processSamples.isEmpty ? "UNAVAILABLE — nettop returned nothing" : "OK — \(processSamples.count) processes visible")")

    print("  Database             \(Store.defaultPath.path)")

    let networks = try store.networks()
    print("  Networks recorded    \(networks.count)")

    let agentPath = ("~/Library/LaunchAgents/com.chriscurrin.datatrack.plist" as NSString).expandingTildeInPath
    let agentInstalled = FileManager.default.fileExists(atPath: agentPath)
    print("  launchd agent        \(agentInstalled ? "installed" : "not installed — run Scripts/install-agent.sh")")

    // Installed is not the same as running, and running is not the same as
    // sampling. Report all three, because only the last one actually matters.
    if agentInstalled {
        let label = "gui/\(getuid())/com.chriscurrin.datatrack"
        let printed = try? Shell.run("/bin/launchctl", ["print", label], timeout: 10)
        let running = (printed?.status == 0) && (printed?.stdout.contains("state = running") ?? false)
        print("  agent process        \(running ? "running" : "NOT RUNNING — launchctl kickstart -k \(label)")")
    }

    switch SampleFreshness.state(lastSample: try store.lastSampleAt()) {
    case .neverSampled:
        print("  sampling             never — no reading has been taken")
    case let .stalled(age):
        print("  sampling             STALLED — last reading \(SampleFreshness.ago(age)) ago")
    case let .fresh(age):
        print("  sampling             OK — last reading \(SampleFreshness.ago(age)) ago")
    }
}

func commandSelfTest() throws {
    guard let identity = NetworkIdentityReader.current() else { throw CLIError("offline") }
    let wide = try InterfaceCounters.read()
    let narrow = InterfaceCounters.lowWordCounters()
    guard let w = wide[identity.interface], let n = narrow[identity.interface] else {
        throw CLIError("no counters for \(identity.interface)")
    }
    print("interface        \(identity.interface)")
    print("netstat  (64-bit) in=\(w.bytesIn) out=\(w.bytesOut)")
    print("getifaddrs (32b)  in=\(n.bytesIn) out=\(n.bytesOut)")
    print("netstat mod 2^32  in=\(w.bytesIn % (1 << 32)) out=\(w.bytesOut % (1 << 32))")
    let ok = try InterfaceCounters.selfTest(interface: identity.interface)
    print(ok ? "PASS — counter source is consistent" : "FAIL — netstat column mapping may have drifted on this OS")
    if !ok { exit(1) }
}

// MARK: - Dispatch

do {
    guard let command = arguments.first else {
        print(usage)
        exit(0)
    }
    arguments.removeFirst()

    if ["-h", "--help", "help"].contains(command) {
        print(usage)
        exit(0)
    }

    if command == "selftest" {
        try commandSelfTest()
        exit(0)
    }

    let store = try Store()
    switch command {
    case "status": try commandStatus(store: store)
    case "networks": try commandNetworks(store: store)
    case "history": try commandHistory(store: store)
    case "top": try commandTop(store: store)
    case "name": try commandName(store: store)
    case "meter": try commandMeter(store: store)
    case "budget": try commandBudget(store: store)
    case "reset-processes": try commandResetProcesses(store: store)
    case "once": try commandOnce(store: store)
    case "watch", "daemon": try commandWatch(store: store)
    case "doctor": try commandDoctor(store: store)
    default:
        FileHandle.standardError.write("unknown command '\(command)'\n\n".data(using: .utf8)!)
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}

import DataTrackCore
import Foundation

let E = Harness.self

// Real `netstat -ibn` output. The lo0 row has no Address value, so rows have a
// variable field count — the reason the parser indexes from the right.
let netstatFixture = """
Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
lo0        16384 <Link#1>                       5621409     0 5571821451  5621409     0 5571821451     0
lo0        16384 127           localhost        5621409     - 5571821451  5621409     - 5571821451     -
lo0        16384 localhost   ::1                5621409     - 5571821451  5621409     - 5571821451     -
gif0*      1280  <Link#2>                             0     0          0        0     0          0     0
en0        1500  <Link#11>   8e:7d:70:2c:e6:f1 63515070     0 69656550566 36662694     0 22368458679     0
en0        1500  l-a0021.loc fe80:b::3d:52fc:f 63515070     - 69656550566 36662694     - 22368458679     -
en0        1500  10.139.153/24 10.139.153.126  63515070     - 69656550566 36662694     - 22368458679     -
awdl0      1500  <Link#13>   66:00:91:ad:22:5b     1697     0     628317     1826     0     534040     0
"""

func makeStore() throws -> (Store, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("datatrack-test-\(UUID().uuidString).sqlite3")
    return (try Store(path: url), url)
}

func identity(
    mac: String? = "aa:bb:cc:dd:ee:ff",
    ssid: String? = nil,
    interface: String = "en0",
    subnet: String? = "192.168.1.0/24",
    constrained: Bool = false,
    tether: Bool = false
) -> NetworkIdentity {
    NetworkIdentity(
        interface: interface, ssid: ssid, gatewayIP: "192.168.1.1", gatewayMAC: mac,
        subnet: subnet, isConstrained: constrained, matchesTetherRange: tether
    )
}

func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

// MARK: - netstat counter parsing

E.suite("netstat counter parsing") {
    E.test("reads 64-bit byte counters that exceed 2^32") {
        let counters = try InterfaceCounters.parse(netstatOutput: netstatFixture)
        guard let en0 = E.notNil(counters["en0"], "en0 present") else { return }
        // Both values are past 2^32 — exactly what the 32-bit kernel struct
        // path silently truncated.
        E.equal(en0.bytesIn, 69_656_550_566, "en0 in")
        E.equal(en0.bytesOut, 22_368_458_679, "en0 out")
        E.expect(en0.bytesIn > UInt64(UInt32.max), "must exceed 32-bit range")
    }

    E.test("handles rows whose Address column is empty") {
        let counters = try InterfaceCounters.parse(netstatOutput: netstatFixture)
        guard let lo0 = E.notNil(counters["lo0"], "lo0 present") else { return }
        E.equal(lo0.bytesIn, 5_571_821_451, "lo0 in")
        E.equal(lo0.bytesOut, 5_571_821_451, "lo0 out")
    }

    E.test("counts each interface once despite repeated per-protocol rows") {
        let counters = try InterfaceCounters.parse(netstatOutput: netstatFixture)
        // en0 appears three times in the fixture; summing would treble it.
        E.equal(counters["en0"]?.bytesIn, 69_656_550_566, "en0 not trebled")
        E.equal(counters["awdl0"]?.bytesIn, 628_317, "awdl0")
        E.equal(counters["gif0*"]?.bytesIn, 0, "idle interface")
    }

    E.test("rejects output whose header lacks the byte columns") {
        E.throwsError("bad header") {
            _ = try InterfaceCounters.parse(netstatOutput: "Name Mtu Network Address\nen0 1500 <Link#1> x")
        }
    }

    E.test("survives a column layout that gains a trailing column") {
        // `netstat -ibd` adds Drop after Coll. Deriving offsets from the header
        // means the numbers still land correctly.
        let output = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll Drop
        en0        1500  <Link#11>   8e:7d:70:2c:e6:f1 63515070     0 69656550566 36662694     0 22368458679     0    0
        """
        let counters = try InterfaceCounters.parse(netstatOutput: output)
        E.equal(counters["en0"]?.bytesIn, 69_656_550_566, "in with extra column")
        E.equal(counters["en0"]?.bytesOut, 22_368_458_679, "out with extra column")
    }
}

// MARK: - ARP gateway identity

E.suite("ARP gateway identity") {
    E.test("extracts the gateway MAC") {
        let output = "? (10.139.153.111) at da:f7:ed:85:e7:d5 on en0 ifscope [ethernet]"
        E.equal(NetworkIdentityReader.parseARP(output), "da:f7:ed:85:e7:d5")
    }

    E.test("zero-pads so one router cannot become two networks") {
        // macOS prints `1:0:5e` rather than `01:00:5e`; without normalization the
        // same gateway would fingerprint differently between readings.
        let output = "? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]"
        E.equal(NetworkIdentityReader.parseARP(output), "01:00:5e:00:00:fb")
    }

    E.test("ignores incomplete entries") {
        E.equal(NetworkIdentityReader.parseARP("? (169.254.169.254) at (incomplete) on en0 [ethernet]"), nil)
    }

    E.test("returns nil when there is no entry at all") {
        E.equal(NetworkIdentityReader.parseARP("arp: 10.0.0.1: no entry"), nil)
    }
}

// MARK: - byte formatting

E.suite("byte formatting") {
    E.test("formats in the decimal units carriers bill in") {
        E.equal(ByteFormat.string(0), "0 B")
        E.equal(ByteFormat.string(999), "999 B")
        E.equal(ByteFormat.string(1_000), "1.00 KB")
        E.equal(ByteFormat.string(5_000_000_000), "5.00 GB")
    }

    E.test("parses the sizes a person would actually type") {
        for (input, expected) in [
            ("5GB", UInt64(5_000_000_000)),
            ("500 MB", UInt64(500_000_000)),
            ("1.5gb", UInt64(1_500_000_000)),
            ("2048", UInt64(2048)),
            ("10g", UInt64(10_000_000_000)),
        ] {
            E.equal(ByteFormat.parse(input), expected, "parse \(input)")
        }
    }

    E.test("rejects nonsense") {
        E.equal(ByteFormat.parse(""), nil, "empty")
        E.equal(ByteFormat.parse("banana"), nil, "word")
        E.equal(ByteFormat.parse("-5GB"), nil, "negative")
    }
}

// MARK: - process attribution

E.suite("process attribution") {
    E.test("parses nettop CSV including the leading empty header field") {
        let output = """
        ,bytes_in,bytes_out,
        mDNSResponder.663,85030881,29183216,
        softwareupdated.4021,4210000000,120000,
        OneDrive.98080,9695,3054,
        """
        let samples = ProcessAttribution.parse(output)
        E.equal(samples.count, 3, "sample count")
        guard samples.count == 3 else { return }
        E.equal(samples[0].name, "mDNSResponder")
        E.equal(samples[0].key, "mDNSResponder.663")
        E.equal(samples[1].bytesIn, 4_210_000_000, "wide value")
    }

    E.test("strips the pid but keeps names that legitimately end in digits") {
        E.equal(ProcessAttribution.stripPID("mDNSResponder.663"), "mDNSResponder")
        E.equal(ProcessAttribution.stripPID("com.apple.WebKit.1234"), "com.apple.WebKit")
        E.equal(ProcessAttribution.stripPID("noPIDHere"), "noPIDHere")
    }

    E.test("does not backdate traffic from a process seen for the first time") {
        // A process already holding 4 GB when first seen accrued that before we
        // were watching; counting it now would blame the wrong network.
        let current = [ProcessSample(key: "softwareupdated.1", name: "softwareupdated", bytesIn: 4_000_000_000, bytesOut: 1000)]
        E.expect(ProcessAttribution.deltas(previous: [:], current: current).isEmpty, "first sighting must contribute nothing")
    }

    E.test("differences against the previous reading") {
        let previous = ["a.1": (bytesIn: UInt64(100), bytesOut: UInt64(50))]
        let current = [ProcessSample(key: "a.1", name: "a", bytesIn: 400, bytesOut: 90)]
        let deltas = ProcessAttribution.deltas(previous: previous, current: current)
        E.equal(deltas.count, 1, "one process")
        guard let first = deltas.first else { return }
        E.equal(first.bytesIn, 300)
        E.equal(first.bytesOut, 40)
    }

    E.test("treats a backwards counter as a restarted process, not negative traffic") {
        let previous = ["a.1": (bytesIn: UInt64(9_000), bytesOut: UInt64(9_000))]
        let current = [ProcessSample(key: "a.1", name: "a", bytesIn: 120, bytesOut: 30)]
        guard let first = ProcessAttribution.deltas(previous: previous, current: current).first else {
            E.record("expected a delta"); return
        }
        E.equal(first.bytesIn, 120)
        E.equal(first.bytesOut, 30)
    }

    E.test("aggregates several pids of the same program") {
        let previous = [
            "chrome.1": (bytesIn: UInt64(0), bytesOut: UInt64(0)),
            "chrome.2": (bytesIn: UInt64(0), bytesOut: UInt64(0)),
        ]
        let current = [
            ProcessSample(key: "chrome.1", name: "chrome", bytesIn: 100, bytesOut: 10),
            ProcessSample(key: "chrome.2", name: "chrome", bytesIn: 200, bytesOut: 20),
        ]
        let deltas = ProcessAttribution.deltas(previous: previous, current: current)
        E.equal(deltas.count, 1, "aggregated to one row")
        E.equal(deltas.first?.bytesIn, 300)
    }
}

// MARK: - counter delta resolution

E.suite("counter delta resolution") {
    func counter(_ bytesIn: UInt64, _ bytesOut: UInt64) -> InterfaceCounter {
        InterfaceCounter(name: "en0", bytesIn: bytesIn, bytesOut: bytesOut)
    }

    E.test("no previous reading establishes a baseline") {
        E.equal(Sampler.resolveDelta(baseline: nil, current: counter(100, 50)), .baseline)
    }

    E.test("a normal advance produces the difference") {
        E.equal(Sampler.resolveDelta(baseline: (100, 50), current: counter(400, 90)),
                .delta(bytesIn: 300, bytesOut: 40))
    }

    E.test("a counter that went backwards is a reset, not an underflow") {
        // Without this, 0 - 69_656_550_566 wraps to ~18 exabytes and instantly
        // trips every budget alarm.
        E.equal(Sampler.resolveDelta(baseline: (69_656_550_566, 22_368_458_679), current: counter(0, 0)), .reset)
    }

    E.test("one axis going backwards is enough to call it a reset") {
        E.equal(Sampler.resolveDelta(baseline: (100, 500), current: counter(200, 10)), .reset)
    }

    E.test("an idle interval produces a zero delta rather than a reset") {
        E.equal(Sampler.resolveDelta(baseline: (100, 50), current: counter(100, 50)),
                .delta(bytesIn: 0, bytesOut: 0))
    }

    E.test("deltas past 2^32 are preserved") {
        E.equal(Sampler.resolveDelta(baseline: (0, 0), current: counter(69_656_550_566, 22_368_458_679)),
                .delta(bytesIn: 69_656_550_566, bytesOut: 22_368_458_679))
    }
}

// MARK: - network identity

E.suite("network identity") {
    E.test("identity is keyed on the gateway MAC, not the SSID") {
        // If the SSID were the key, granting Location Services later would fork
        // one network's history into two records.
        E.equal(identity(ssid: nil).fingerprint, identity(ssid: "Home WiFi").fingerprint, "stable across SSID visibility")
        E.equal(identity(ssid: nil).fingerprint, "gw:aa:bb:cc:dd:ee:ff")
    }

    E.test("falls back to subnet when there is no gateway MAC") {
        E.equal(identity(mac: nil).fingerprint, "subnet:192.168.1.0/24@en0")
    }

    E.test("tether gateway ranges are treated as metered") {
        E.expect(identity(tether: true).looksMetered, "tether is metered")
        E.expect(!identity(tether: false).looksMetered, "plain network is not")
    }

    E.test("an SSID naming a phone is treated as metered") {
        E.expect(identity(ssid: "Chris's iPhone").looksMetered, "iPhone")
        E.expect(identity(ssid: "Pixel_Hotspot").looksMetered, "Pixel_Hotspot")
        E.expect(identity(ssid: "Galaxy S21").looksMetered, "Galaxy S21")
        E.expect(!identity(ssid: "Office 5G").looksMetered, "office network")
    }

    E.test("an ordinary name merely containing a device name is not metered") {
        // Found on a real network called "Pixelated": a substring match on
        // "pixel" flagged it as a phone hotspot and would have produced budget
        // warnings the user never asked for.
        E.expect(!NetworkIdentity.ssidSuggestsTethering("Pixelated"), "Pixelated")
        E.expect(!NetworkIdentity.ssidSuggestsTethering("Androidian Cafe"), "Androidian Cafe")
        E.expect(!NetworkIdentity.ssidSuggestsTethering("Galaxybrain"), "Galaxybrain")
        // But the real device names still match as whole tokens.
        E.expect(NetworkIdentity.ssidSuggestsTethering("Pixel 8"), "Pixel 8")
        E.expect(NetworkIdentity.ssidSuggestsTethering("android-ap"), "android-ap")
        // And phrases match anywhere, since they carry their own meaning.
        E.expect(NetworkIdentity.ssidSuggestsTethering("MyHotspot2"), "MyHotspot2")
    }

    E.test("the kernel's constrained flag alone marks a network metered") {
        E.expect(identity(ssid: "Some Net", constrained: true).looksMetered, "constrained implies metered")
    }
}

// MARK: - store

E.suite("store") {
    E.test("upserting the same network twice yields one row") {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try store.upsertNetwork(identity())
        let second = try store.upsertNetwork(identity())
        E.equal(first, second, "same row id")
        E.equal(try store.networks().count, 1, "one network")
    }

    E.test("an SSID discovered later fills in without creating a new network") {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try store.upsertNetwork(identity(ssid: nil))
        E.equal(try store.network(id: id)?.ssid, nil, "initially unknown")
        _ = try store.upsertNetwork(identity(ssid: "Home WiFi"))
        E.equal(try store.networks().count, 1, "still one network")
        E.equal(try store.network(id: id)?.ssid, "Home WiFi", "backfilled")
    }

    E.test("a known SSID is not erased by a later reading that lacks one") {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try store.upsertNetwork(identity(ssid: "Home WiFi"))
        _ = try store.upsertNetwork(identity(ssid: nil))
        E.equal(try store.network(id: id)?.ssid, "Home WiFi", "preserved")
    }

    E.test("deltas accumulate into the daily rollup") {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try store.upsertNetwork(identity())
        let now = Date()
        try store.recordDelta(networkID: id, bytesIn: 1_000, bytesOut: 200, at: now)
        try store.recordDelta(networkID: id, bytesIn: 500, bytesOut: 100, at: now)
        let key = Store.dayKey(now)
        let usage = try store.usage(networkID: id, fromDay: key, toDay: key)
        E.equal(usage.bytesIn, 1_500)
        E.equal(usage.bytesOut, 300)
    }

    E.test("usage stays separated per network") {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let home = try store.upsertNetwork(identity(mac: "11:11:11:11:11:11"))
        let hotspot = try store.upsertNetwork(identity(mac: "22:22:22:22:22:22"))
        let key = Store.dayKey(Date())
        try store.recordDelta(networkID: home, bytesIn: 9_000_000_000, bytesOut: 0)
        try store.recordDelta(networkID: hotspot, bytesIn: 5_000, bytesOut: 1_000)
        E.equal(try store.usage(networkID: home, fromDay: key, toDay: key).bytesIn, 9_000_000_000, "home")
        E.equal(try store.usage(networkID: hotspot, fromDay: key, toDay: key).bytesIn, 5_000, "hotspot")
    }

    E.test("an explicit metered choice survives later ticks") {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        // Seen first as a tethered network, so the heuristic marks it metered.
        let id = try store.upsertNetwork(identity(tether: true))
        E.equal(try store.network(id: id)?.isMetered, true, "heuristic seeds metered")
        // The user disagrees. The next poll must not undo that.
        try store.setMetered(networkID: id, metered: false)
        _ = try store.upsertNetwork(identity(tether: true))
        E.equal(try store.network(id: id)?.isMetered, false, "user choice wins")
    }

    E.test("a label overrides the SSID for display") {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try store.upsertNetwork(identity(ssid: "DIRECT-xY-Thing"))
        try store.setLabel(networkID: id, label: "iPhone Hotspot")
        E.equal(try store.network(id: id)?.displayName, "iPhone Hotspot")
    }

    E.test("a threshold alert can only be claimed once per cycle") {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try store.upsertNetwork(identity())
        E.expect(try store.claimAlert(networkID: id, cycleKey: "monthly:2026-07-01", threshold: 80), "first claim wins")
        E.expect(!(try store.claimAlert(networkID: id, cycleKey: "monthly:2026-07-01", threshold: 80)), "second is refused")
        E.expect(try store.claimAlert(networkID: id, cycleKey: "monthly:2026-08-01", threshold: 80), "new cycle re-arms")
    }

    E.test("counter baselines round-trip values above 2^32") {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try store.upsertNetwork(identity())
        // SQLite integers are signed; these must survive the bit-pattern cast.
        try store.setCounterBaseline(interface: "en0", bytesIn: 69_656_550_566, bytesOut: 22_368_458_679, networkID: id)
        guard let baseline = E.notNil(try store.counterBaseline(interface: "en0"), "baseline") else { return }
        E.equal(baseline.bytesIn, 69_656_550_566)
        E.equal(baseline.bytesOut, 22_368_458_679)
        E.equal(baseline.networkID, id)
    }

    E.test("process usage aggregates and ranks") {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try store.upsertNetwork(identity())
        try store.recordProcessDeltas(networkID: id, deltas: [
            ProcessUsage(process: "softwareupdated", bytesIn: 4_000_000_000, bytesOut: 1_000),
            ProcessUsage(process: "Safari", bytesIn: 20_000_000, bytesOut: 5_000_000),
        ])
        let key = Store.dayKey(Date())
        let top = try store.topProcesses(networkID: id, fromDay: key, toDay: key)
        E.equal(top.first?.process, "softwareupdated", "ranked first")
        E.equal(top.first?.bytesIn, 4_000_000_000)
    }
}

// MARK: - budget cycles

E.suite("budget cycles") {
    E.test("a monthly cycle opens on its reset day") {
        let budget = Budget(networkID: 1, limitBytes: 5_000_000_000, cycle: .monthly, cycleStartDay: 15)
        let range = BudgetCycle.currentRange(budget, now: day(2026, 7, 20))
        E.equal(range.from, "2026-07-15")
        E.equal(range.to, "2026-07-20")
    }

    E.test("before the reset day the cycle belongs to the previous month") {
        let budget = Budget(networkID: 1, limitBytes: 5_000_000_000, cycle: .monthly, cycleStartDay: 15)
        E.equal(BudgetCycle.currentRange(budget, now: day(2026, 7, 10)).from, "2026-06-15")
    }

    E.test("a reset day of 31 clamps into a short month instead of overflowing") {
        // Naive date arithmetic turns 31 February into 3 March and silently
        // reports the wrong cycle.
        let budget = Budget(networkID: 1, limitBytes: 5_000_000_000, cycle: .monthly, cycleStartDay: 31)
        E.equal(BudgetCycle.currentRange(budget, now: day(2026, 3, 1)).from, "2026-02-28")
    }

    E.test("cycle key changes between cycles so alerts re-arm") {
        let budget = Budget(networkID: 1, limitBytes: 1, cycle: .monthly, cycleStartDay: 1)
        let june = BudgetCycle.currentRange(budget, now: day(2026, 6, 5)).key
        let july = BudgetCycle.currentRange(budget, now: day(2026, 7, 5)).key
        E.expect(june != july, "keys differ: \(june) vs \(july)")
    }

    E.test("a rolling 30-day window spans 30 days inclusive") {
        let budget = Budget(networkID: 1, limitBytes: 1, cycle: .rolling30, cycleStartDay: 1)
        let range = BudgetCycle.currentRange(budget, now: day(2026, 7, 30))
        E.equal(range.from, "2026-07-01")
        E.equal(range.to, "2026-07-30")
    }
}

// MARK: - AppleScript escaping

E.suite("AppleScript escaping") {
    E.test("a network name cannot break out of the script literal") {
        // SSIDs are third-party input. An unescaped quote would end the literal
        // and let the remainder execute as AppleScript.
        let escaped = Notifier.escape("evil\" & do shell script \"whoami")
        E.equal(escaped, #""evil\" & do shell script \"whoami""#)

        // Every interior quote must carry a preceding backslash.
        let interior = Array(escaped.dropFirst().dropLast())
        for (offset, character) in interior.enumerated() where character == "\"" {
            E.expect(offset > 0 && interior[offset - 1] == "\\", "quote at \(offset) is escaped")
        }
    }

    E.test("escapes backslashes and flattens newlines") {
        E.equal(Notifier.escape("a\\b"), "\"a\\\\b\"")
        E.equal(Notifier.escape("a\nb"), "\"a b\"")
    }
}

E.finish()

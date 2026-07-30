import Foundation
import SQLite3

public struct NetworkRecord: Sendable, Identifiable {
    public let id: Int64
    public let fingerprint: String
    /// User-assigned name. Takes precedence over `ssid` for display, and is the
    /// escape hatch for networks whose SSID macOS will not disclose.
    public let label: String?
    public let ssid: String?
    public let gatewayIP: String?
    public let gatewayMAC: String?
    public let subnet: String?
    public let interface: String
    public let isMetered: Bool
    public let firstSeen: Date
    public let lastSeen: Date

    /// What to show the user, in descending order of trustworthiness.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        if let ssid, !ssid.isEmpty { return ssid }
        if let gatewayIP { return "Network at \(gatewayIP)" }
        return fingerprint
    }
}

public struct Budget: Sendable {
    public enum Cycle: String, Sendable {
        case monthly
        case rolling30
        case none
    }
    public let networkID: Int64
    public let limitBytes: UInt64
    public let cycle: Cycle
    /// Day of month the billing cycle resets on, for `.monthly`.
    public let cycleStartDay: Int

    public init(networkID: Int64, limitBytes: UInt64, cycle: Cycle, cycleStartDay: Int) {
        self.networkID = networkID
        self.limitBytes = limitBytes
        self.cycle = cycle
        self.cycleStartDay = cycleStartDay
    }
}

public struct ProcessUsage: Sendable {
    public let process: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public var total: UInt64 { bytesIn &+ bytesOut }

    public init(process: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.process = process
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case sql(String)

    public var description: String {
        switch self {
        case let .open(m): return "could not open database: \(m)"
        case let .sql(m): return "sql error: \(m)"
        }
    }
}

/// SQLite-backed record of per-network usage.
///
/// Two layers are kept deliberately: `usage_daily` is the aggregate the UI reads,
/// and `samples` is an append-only trail of raw deltas. The trail costs little and
/// makes it possible to answer "when exactly did those four gigabytes go" after
/// the fact, which a rollup alone cannot.
public final class Store {
    private var db: OpaquePointer?

    public static var defaultPath: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DataTrack", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("usage.sqlite3")
    }

    public init(path: URL = Store.defaultPath) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &db, flags, nil) == SQLITE_OK else {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        // WAL lets the menu bar app read while the sampler daemon writes.
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA busy_timeout=5000;")
        try exec("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    // MARK: - Schema

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS networks (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            fingerprint  TEXT NOT NULL UNIQUE,
            label        TEXT,
            ssid         TEXT,
            gateway_ip   TEXT,
            gateway_mac  TEXT,
            subnet       TEXT,
            interface    TEXT NOT NULL,
            is_metered   INTEGER NOT NULL DEFAULT 0,
            first_seen   TEXT NOT NULL,
            last_seen    TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS usage_daily (
            network_id  INTEGER NOT NULL REFERENCES networks(id) ON DELETE CASCADE,
            day         TEXT NOT NULL,
            bytes_in    INTEGER NOT NULL DEFAULT 0,
            bytes_out   INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (network_id, day)
        );

        CREATE TABLE IF NOT EXISTS samples (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            network_id  INTEGER NOT NULL REFERENCES networks(id) ON DELETE CASCADE,
            ts          TEXT NOT NULL,
            bytes_in    INTEGER NOT NULL,
            bytes_out   INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS samples_network_ts ON samples(network_id, ts);

        CREATE TABLE IF NOT EXISTS process_daily (
            network_id  INTEGER NOT NULL REFERENCES networks(id) ON DELETE CASCADE,
            day         TEXT NOT NULL,
            process     TEXT NOT NULL,
            bytes_in    INTEGER NOT NULL DEFAULT 0,
            bytes_out   INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (network_id, day, process)
        );

        CREATE TABLE IF NOT EXISTS budgets (
            network_id      INTEGER PRIMARY KEY REFERENCES networks(id) ON DELETE CASCADE,
            limit_bytes     INTEGER NOT NULL,
            cycle           TEXT NOT NULL,
            cycle_start_day INTEGER NOT NULL DEFAULT 1
        );

        -- Last raw counter reading per interface, tagged with the network it was
        -- taken on so a mid-interval network change can be attributed correctly.
        CREATE TABLE IF NOT EXISTS counter_state (
            interface   TEXT PRIMARY KEY,
            bytes_in    INTEGER NOT NULL,
            bytes_out   INTEGER NOT NULL,
            network_id  INTEGER REFERENCES networks(id) ON DELETE SET NULL,
            updated     TEXT NOT NULL
        );

        -- Which budget thresholds have already alerted, per cycle, so the user is
        -- warned once per crossing rather than on every poll.
        CREATE TABLE IF NOT EXISTS alerts_fired (
            network_id  INTEGER NOT NULL REFERENCES networks(id) ON DELETE CASCADE,
            cycle_key   TEXT NOT NULL,
            threshold   INTEGER NOT NULL,
            fired_at    TEXT NOT NULL,
            PRIMARY KEY (network_id, cycle_key, threshold)
        );

        CREATE TABLE IF NOT EXISTS process_state (
            key         TEXT PRIMARY KEY,
            bytes_in    INTEGER NOT NULL,
            bytes_out   INTEGER NOT NULL,
            updated     TEXT NOT NULL
        );
        """)
    }

    // MARK: - Networks

    /// Inserts or refreshes the network record for `identity`, returning its row id.
    ///
    /// Attributes discovered later (an SSID that only becomes visible once
    /// Location Services is granted) are filled in without overwriting anything
    /// already known, so the record improves monotonically.
    @discardableResult
    public func upsertNetwork(_ identity: NetworkIdentity, now: Date = Date()) throws -> Int64 {
        let ts = Self.iso(now)
        try run(
            """
            INSERT INTO networks (fingerprint, ssid, gateway_ip, gateway_mac, subnet, interface, is_metered, first_seen, last_seen)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            -- is_metered is deliberately absent from the update: it is seeded from
            -- the heuristic on first sight, then owned by the user. Re-asserting
            -- the heuristic here would silently revert an explicit "not metered"
            -- within one poll interval.
            ON CONFLICT(fingerprint) DO UPDATE SET
                ssid        = COALESCE(excluded.ssid, networks.ssid),
                gateway_ip  = COALESCE(excluded.gateway_ip, networks.gateway_ip),
                gateway_mac = COALESCE(excluded.gateway_mac, networks.gateway_mac),
                subnet      = COALESCE(excluded.subnet, networks.subnet),
                interface   = excluded.interface,
                last_seen   = excluded.last_seen
            """,
            [
                .text(identity.fingerprint), .textOrNull(identity.ssid), .textOrNull(identity.gatewayIP),
                .textOrNull(identity.gatewayMAC), .textOrNull(identity.subnet), .text(identity.interface),
                .int(identity.looksMetered ? 1 : 0), .text(ts), .text(ts),
            ]
        )
        guard let id = try scalarInt("SELECT id FROM networks WHERE fingerprint = ?", [.text(identity.fingerprint)]) else {
            throw StoreError.sql("network row vanished after upsert")
        }
        return id
    }

    /// Resolves an identity to a network row, recovering from a transient failure
    /// to read the gateway MAC.
    ///
    /// Without a MAC, `NetworkIdentity.fingerprint` degrades to `subnet:…`, which
    /// would mint a second record for a network already known under `gw:…`. That
    /// is not merely untidy: the sampler stores the resolved id on the counter
    /// baseline, so the *next* interval gets credited to the phantom and the real
    /// network's budget check is skipped for that tick.
    ///
    /// If we saw a fully-identified network on the same interface, with the same
    /// subnet and the same gateway IP, within `staleness`, this is overwhelmingly
    /// that network with a missed ARP read rather than a different one. Matching
    /// on subnet alone would be unsafe — 192.168.1.0/24 is shared by half the
    /// routers on earth — so recency and gateway IP carry the decision.
    @discardableResult
    public func resolveNetwork(
        _ identity: NetworkIdentity,
        now: Date = Date(),
        staleness: TimeInterval = 600
    ) throws -> Int64 {
        if identity.gatewayMAC == nil,
           let subnet = identity.subnet,
           let gatewayIP = identity.gatewayIP,
           let recent = try recentIdentifiedNetwork(
               interface: identity.interface, subnet: subnet, gatewayIP: gatewayIP,
               since: now.addingTimeInterval(-staleness)
           )
        {
            try run("UPDATE networks SET last_seen = ? WHERE id = ?", [.text(Self.iso(now)), .int(recent)])
            return recent
        }
        return try upsertNetwork(identity, now: now)
    }

    /// Most recently seen network with a known gateway MAC matching this
    /// interface, subnet and gateway IP.
    func recentIdentifiedNetwork(interface: String, subnet: String, gatewayIP: String, since: Date) throws -> Int64? {
        try query(
            """
            SELECT id FROM networks
            WHERE interface = ? AND subnet = ? AND gateway_ip = ?
              AND gateway_mac IS NOT NULL AND last_seen >= ?
            ORDER BY last_seen DESC LIMIT 1
            """,
            [.text(interface), .text(subnet), .text(gatewayIP), .text(Self.iso(since))]
        ) { $0.int64(0) }.first
    }

    /// Timestamp of the most recent sampling tick, or nil if none has run.
    ///
    /// Read from `counter_state`, which every tick rewrites. This is how the tool
    /// detects that it has stopped measuring — a frozen number that looks current
    /// is the most dangerous output this app can produce.
    public func lastSampleAt() throws -> Date? {
        try query("SELECT MAX(updated) FROM counter_state", []) { row in row.string(0) }
            .compactMap { $0 }
            .first
            .map { Self.date($0) }
    }

    public func networks() throws -> [NetworkRecord] {
        try query(
            """
            SELECT id, fingerprint, label, ssid, gateway_ip, gateway_mac, subnet, interface, is_metered, first_seen, last_seen
            FROM networks ORDER BY last_seen DESC
            """, []
        ) { row in
            NetworkRecord(
                id: row.int64(0), fingerprint: row.string(1) ?? "", label: row.string(2), ssid: row.string(3),
                gatewayIP: row.string(4), gatewayMAC: row.string(5), subnet: row.string(6),
                interface: row.string(7) ?? "", isMetered: row.int64(8) != 0,
                firstSeen: Self.date(row.string(9)), lastSeen: Self.date(row.string(10))
            )
        }
    }

    public func network(id: Int64) throws -> NetworkRecord? {
        try networks().first { $0.id == id }
    }

    public func setLabel(networkID: Int64, label: String) throws {
        try run("UPDATE networks SET label = ? WHERE id = ?", [.text(label), .int(networkID)])
    }

    public func setMetered(networkID: Int64, metered: Bool) throws {
        try run("UPDATE networks SET is_metered = ? WHERE id = ?", [.int(metered ? 1 : 0), .int(networkID)])
    }

    // MARK: - Counter baselines

    public func counterBaseline(interface: String) throws -> (bytesIn: UInt64, bytesOut: UInt64, networkID: Int64?)? {
        let rows = try query(
            "SELECT bytes_in, bytes_out, network_id FROM counter_state WHERE interface = ?",
            [.text(interface)]
        ) { row -> (bytesIn: UInt64, bytesOut: UInt64, networkID: Int64?) in
            (bytesIn: UInt64(bitPattern: row.int64(0)),
             bytesOut: UInt64(bitPattern: row.int64(1)),
             networkID: row.isNull(2) ? nil : row.int64(2))
        }
        return rows.first
    }

    public func setCounterBaseline(interface: String, bytesIn: UInt64, bytesOut: UInt64, networkID: Int64?, now: Date = Date()) throws {
        try run(
            """
            INSERT INTO counter_state (interface, bytes_in, bytes_out, network_id, updated)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(interface) DO UPDATE SET
                bytes_in = excluded.bytes_in, bytes_out = excluded.bytes_out,
                network_id = excluded.network_id, updated = excluded.updated
            """,
            [.text(interface), .int(Int64(bitPattern: bytesIn)), .int(Int64(bitPattern: bytesOut)),
             networkID.map { Value.int($0) } ?? .null, .text(Self.iso(now))]
        )
    }

    // MARK: - Usage

    /// Records a traffic delta against a network, updating both the daily rollup
    /// and the raw sample trail in one transaction.
    public func recordDelta(networkID: Int64, bytesIn: UInt64, bytesOut: UInt64, at date: Date = Date()) throws {
        guard bytesIn > 0 || bytesOut > 0 else { return }
        let day = Self.dayKey(date)
        try exec("BEGIN IMMEDIATE;")
        do {
            try run(
                """
                INSERT INTO usage_daily (network_id, day, bytes_in, bytes_out) VALUES (?, ?, ?, ?)
                ON CONFLICT(network_id, day) DO UPDATE SET
                    bytes_in = usage_daily.bytes_in + excluded.bytes_in,
                    bytes_out = usage_daily.bytes_out + excluded.bytes_out
                """,
                [.int(networkID), .text(day), .int(Int64(bitPattern: bytesIn)), .int(Int64(bitPattern: bytesOut))]
            )
            try run(
                "INSERT INTO samples (network_id, ts, bytes_in, bytes_out) VALUES (?, ?, ?, ?)",
                [.int(networkID), .text(Self.iso(date)), .int(Int64(bitPattern: bytesIn)), .int(Int64(bitPattern: bytesOut))]
            )
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func recordProcessDeltas(networkID: Int64, deltas: [ProcessUsage], at date: Date = Date()) throws {
        guard !deltas.isEmpty else { return }
        let day = Self.dayKey(date)
        try exec("BEGIN IMMEDIATE;")
        do {
            for d in deltas where d.total > 0 {
                try run(
                    """
                    INSERT INTO process_daily (network_id, day, process, bytes_in, bytes_out) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(network_id, day, process) DO UPDATE SET
                        bytes_in = process_daily.bytes_in + excluded.bytes_in,
                        bytes_out = process_daily.bytes_out + excluded.bytes_out
                    """,
                    [.int(networkID), .text(day), .text(d.process),
                     .int(Int64(bitPattern: d.bytesIn)), .int(Int64(bitPattern: d.bytesOut))]
                )
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Total usage on a network across an inclusive range of local days.
    public func usage(networkID: Int64, fromDay: String, toDay: String) throws -> (bytesIn: UInt64, bytesOut: UInt64) {
        let rows = try query(
            """
            SELECT COALESCE(SUM(bytes_in), 0), COALESCE(SUM(bytes_out), 0) FROM usage_daily
            WHERE network_id = ? AND day >= ? AND day <= ?
            """,
            [.int(networkID), .text(fromDay), .text(toDay)]
        ) { row -> (bytesIn: UInt64, bytesOut: UInt64) in
            (bytesIn: UInt64(bitPattern: row.int64(0)), bytesOut: UInt64(bitPattern: row.int64(1)))
        }
        return rows.first ?? (bytesIn: 0, bytesOut: 0)
    }

    public func dailyBreakdown(networkID: Int64, fromDay: String, toDay: String) throws -> [(day: String, bytesIn: UInt64, bytesOut: UInt64)] {
        try query(
            """
            SELECT day, bytes_in, bytes_out FROM usage_daily
            WHERE network_id = ? AND day >= ? AND day <= ? ORDER BY day
            """,
            [.int(networkID), .text(fromDay), .text(toDay)]
        ) { row -> (day: String, bytesIn: UInt64, bytesOut: UInt64) in
            (day: row.string(0) ?? "",
             bytesIn: UInt64(bitPattern: row.int64(1)),
             bytesOut: UInt64(bitPattern: row.int64(2)))
        }
    }

    public func topProcesses(networkID: Int64, fromDay: String, toDay: String, limit: Int = 15) throws -> [ProcessUsage] {
        try query(
            """
            SELECT process, SUM(bytes_in), SUM(bytes_out) FROM process_daily
            WHERE network_id = ? AND day >= ? AND day <= ?
            GROUP BY process ORDER BY SUM(bytes_in) + SUM(bytes_out) DESC LIMIT ?
            """,
            [.int(networkID), .text(fromDay), .text(toDay), .int(Int64(limit))]
        ) { row in
            ProcessUsage(process: row.string(0) ?? "?", bytesIn: UInt64(bitPattern: row.int64(1)), bytesOut: UInt64(bitPattern: row.int64(2)))
        }
    }

    // MARK: - Process baselines

    public func processBaseline(key: String) throws -> (bytesIn: UInt64, bytesOut: UInt64)? {
        try query("SELECT bytes_in, bytes_out FROM process_state WHERE key = ?", [.text(key)]) { row -> (bytesIn: UInt64, bytesOut: UInt64) in
            (bytesIn: UInt64(bitPattern: row.int64(0)), bytesOut: UInt64(bitPattern: row.int64(1)))
        }.first
    }

    public func setProcessBaseline(key: String, bytesIn: UInt64, bytesOut: UInt64, now: Date = Date()) throws {
        try run(
            """
            INSERT INTO process_state (key, bytes_in, bytes_out, updated) VALUES (?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET bytes_in = excluded.bytes_in, bytes_out = excluded.bytes_out, updated = excluded.updated
            """,
            [.text(key), .int(Int64(bitPattern: bytesIn)), .int(Int64(bitPattern: bytesOut)), .text(Self.iso(now))]
        )
    }

    /// Drops flow baselines not refreshed since `before`, so closed sockets do
    /// not accumulate rows forever.
    public func pruneProcessState(before date: Date) throws {
        try run("DELETE FROM process_state WHERE updated < ?", [.text(Self.iso(date))])
    }

    /// True when no flow baselines exist, i.e. no process sample has been taken.
    ///
    /// The first sample must baseline rather than count: sockets open since boot
    /// would otherwise contribute their entire history to one interval.
    public func processStateIsEmpty() throws -> Bool {
        (try scalarInt("SELECT COUNT(*) FROM process_state", []) ?? 0) == 0
    }

    /// Discards all per-process history and flow baselines.
    ///
    /// Interface totals in `usage_daily` are untouched — those come from netstat
    /// and were never affected by the attribution defects this clears up after.
    public func resetProcessHistory() throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try run("DELETE FROM process_daily", [])
            try run("DELETE FROM process_state", [])
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Budgets

    public func setBudget(_ budget: Budget) throws {
        try run(
            """
            INSERT INTO budgets (network_id, limit_bytes, cycle, cycle_start_day) VALUES (?, ?, ?, ?)
            ON CONFLICT(network_id) DO UPDATE SET
                limit_bytes = excluded.limit_bytes, cycle = excluded.cycle, cycle_start_day = excluded.cycle_start_day
            """,
            [.int(budget.networkID), .int(Int64(bitPattern: budget.limitBytes)), .text(budget.cycle.rawValue), .int(Int64(budget.cycleStartDay))]
        )
    }

    public func clearBudget(networkID: Int64) throws {
        try run("DELETE FROM budgets WHERE network_id = ?", [.int(networkID)])
    }

    public func budget(networkID: Int64) throws -> Budget? {
        try query("SELECT network_id, limit_bytes, cycle, cycle_start_day FROM budgets WHERE network_id = ?", [.int(networkID)]) { row in
            Budget(
                networkID: row.int64(0), limitBytes: UInt64(bitPattern: row.int64(1)),
                cycle: Budget.Cycle(rawValue: row.string(2) ?? "monthly") ?? .monthly,
                cycleStartDay: Int(row.int64(3))
            )
        }.first
    }

    /// Claims a threshold alert, returning true only for the first caller.
    /// The uniqueness constraint makes this safe against a duplicate poll.
    public func claimAlert(networkID: Int64, cycleKey: String, threshold: Int, now: Date = Date()) throws -> Bool {
        try run(
            "INSERT OR IGNORE INTO alerts_fired (network_id, cycle_key, threshold, fired_at) VALUES (?, ?, ?, ?)",
            [.int(networkID), .text(cycleKey), .int(Int64(threshold)), .text(Self.iso(now))]
        )
        return sqlite3_changes(db) > 0
    }

    // MARK: - Date helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Day keys are local-time so that "today" matches the user's day, and
    /// zero-padded so lexicographic comparison equals chronological order.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
    public static func date(_ s: String?) -> Date { s.flatMap { isoFormatter.date(from: $0) } ?? Date(timeIntervalSince1970: 0) }
    public static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    // MARK: - Thin SQLite plumbing

    enum Value {
        case text(String)
        case int(Int64)
        case null

        static func textOrNull(_ s: String?) -> Value { s.map { .text($0) } ?? .null }
    }

    struct Row {
        let stmt: OpaquePointer
        func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func string(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql("\(message) — while executing: \(sql.prefix(120))")
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sql("\(String(cString: sqlite3_errmsg(db))) — while preparing: \(sql.prefix(120))")
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case let .text(s): rc = sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
            case let .int(i): rc = sqlite3_bind_int64(stmt, index, i)
            case .null: rc = sqlite3_bind_null(stmt, index)
            }
            guard rc == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw StoreError.sql("bind \(index) failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError.sql("\(String(cString: sqlite3_errmsg(db))) — while running: \(sql.prefix(120))")
        }
    }

    private func query<T>(_ sql: String, _ values: [Value], _ map: (Row) -> T) throws -> [T] {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(map(Row(stmt: stmt)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw StoreError.sql("\(String(cString: sqlite3_errmsg(db))) — while querying: \(sql.prefix(120))")
            }
        }
        return out
    }

    private func scalarInt(_ sql: String, _ values: [Value]) throws -> Int64? {
        try query(sql, values) { $0.int64(0) }.first
    }
}

// SQLITE_TRANSIENT is a function-pointer sentinel that Swift's C importer does
// not surface, so it is reconstructed here. It tells SQLite to copy bound text
// rather than retain our pointer.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

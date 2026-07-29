import AppKit
import CoreLocation
import DataTrackCore
import SwiftUI

/// Menu bar front end.
///
/// Two jobs beyond display. First, it is the only place the SSID can be read:
/// Location Services authorization is granted per-application, so a signed
/// bundle that asks for it can name networks that the CLI cannot. Second, if the
/// launchd agent is not installed it samples in-process, so the app alone is a
/// complete install.
@main
struct DataTrackApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // The label is the whole point of a menu bar app: the number that
            // stops a surprise is the one you see without clicking.
            Text(model.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var networkName: String = "—"
    @Published var isMetered: Bool = false
    @Published var ssidVisible: Bool = false
    @Published var interfaceNote: String = ""
    @Published var todayIn: UInt64 = 0
    @Published var todayOut: UInt64 = 0
    @Published var budgetLimit: UInt64?
    @Published var budgetUsed: UInt64 = 0
    @Published var budgetCycleFrom: String = ""
    @Published var topProcesses: [ProcessUsage] = []
    @Published var otherNetworks: [(record: NetworkRecord, today: UInt64)] = []
    @Published var errorMessage: String?
    @Published var samplingInProcess = false

    private var store: Store?
    private var sampler: Sampler?
    private var timer: Timer?
    private let locationManager = CLLocationManager()
    private var currentNetworkID: Int64?

    var todayTotal: UInt64 { todayIn &+ todayOut }

    /// Percentage of budget consumed, or nil when no budget is set.
    var budgetFraction: Double? {
        guard let limit = budgetLimit, limit > 0 else { return nil }
        return min(1.0, Double(budgetUsed) / Double(limit))
    }

    var menuBarTitle: String {
        if let fraction = budgetFraction {
            let percent = Int((fraction * 100).rounded())
            return "\(percent > 99 ? "⚠︎ " : "")\(percent)%"
        }
        return ByteFormat.string(todayTotal)
    }

    init() {
        do {
            let store = try Store()
            self.store = store

            // Only sample here when nothing else is. The launchd agent and this
            // app share one counter baseline, so running both is merely
            // redundant rather than double-counting, but one owner is clearer.
            if !Self.launchAgentInstalled {
                sampler = Sampler(store: store)
                samplingInProcess = true
            }
        } catch {
            errorMessage = "\(error)"
        }

        // Asking for location is what unlocks the SSID. Declining costs only the
        // network's name; identity and accounting are unaffected.
        locationManager.requestWhenInUseAuthorization()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    static var launchAgentInstalled: Bool {
        FileManager.default.fileExists(
            atPath: ("~/Library/LaunchAgents/com.chriscurrin.datatrack.plist" as NSString).expandingTildeInPath
        )
    }

    func refresh() {
        guard let store else { return }
        do {
            if let sampler { try sampler.tick() }

            guard let identity = NetworkIdentityReader.current() else {
                networkName = "Offline"
                interfaceNote = "No default route"
                todayIn = 0; todayOut = 0; budgetLimit = nil; topProcesses = []
                return
            }

            let id = try store.upsertNetwork(identity)
            currentNetworkID = id
            let record = try store.network(id: id)

            networkName = record?.displayName ?? identity.inferredName
            isMetered = record?.isMetered ?? identity.looksMetered
            ssidVisible = identity.ssid != nil
            interfaceNote = identity.interface + (identity.isConstrained ? " · constrained" : "")

            let today = Store.dayKey(Date())
            let usage = try store.usage(networkID: id, fromDay: today, toDay: today)
            todayIn = usage.bytesIn
            todayOut = usage.bytesOut

            if let budget = try store.budget(networkID: id) {
                let range = BudgetCycle.currentRange(budget)
                let used = try store.usage(networkID: id, fromDay: range.from, toDay: range.to)
                budgetLimit = budget.limitBytes
                budgetUsed = used.bytesIn &+ used.bytesOut
                budgetCycleFrom = range.from
            } else {
                budgetLimit = nil
                budgetUsed = 0
            }

            topProcesses = try store.topProcesses(networkID: id, fromDay: today, toDay: today, limit: 5)

            otherNetworks = try store.networks()
                .filter { $0.id != id }
                .prefix(5)
                .map { record -> (record: NetworkRecord, today: UInt64) in
                    let usage = try? store.usage(networkID: record.id, fromDay: today, toDay: today)
                    return (record: record, today: (usage?.bytesIn ?? 0) &+ (usage?.bytesOut ?? 0))
                }

            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    func setBudget(_ text: String, cycle: Budget.Cycle) {
        guard let store, let id = currentNetworkID, let limit = ByteFormat.parse(text) else { return }
        try? store.setBudget(Budget(networkID: id, limitBytes: limit, cycle: cycle, cycleStartDay: 1))
        try? store.setMetered(networkID: id, metered: true)
        refresh()
    }

    func clearBudget() {
        guard let store, let id = currentNetworkID else { return }
        try? store.clearBudget(networkID: id)
        refresh()
    }

    func rename(_ label: String) {
        guard let store, let id = currentNetworkID, !label.isEmpty else { return }
        try? store.setLabel(networkID: id, label: label)
        refresh()
    }

    func toggleMetered() {
        guard let store, let id = currentNetworkID else { return }
        try? store.setMetered(networkID: id, metered: !isMetered)
        refresh()
    }
}

struct MenuContent: View {
    @ObservedObject var model: UsageModel
    @State private var budgetText = ""
    @State private var nameText = ""
    @State private var showingRename = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            todaySection
            if model.budgetFraction != nil { budgetSection } else { budgetEntry }
            if !model.topProcesses.isEmpty {
                Divider()
                processSection
            }
            if !model.otherNetworks.isEmpty {
                Divider()
                otherNetworksSection
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model.networkName)
                    .font(.headline)
                    .lineLimit(1)
                if model.isMetered {
                    Text("METERED")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            Text(model.interfaceNote).font(.caption).foregroundStyle(.secondary)
            if !model.ssidVisible {
                Text("macOS is hiding this network's name. Identified by its gateway.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var todaySection: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Today").font(.caption).foregroundStyle(.secondary)
                Text(ByteFormat.string(model.todayTotal)).font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("↓ \(ByteFormat.string(model.todayIn))").font(.caption)
                Text("↑ \(ByteFormat.string(model.todayOut))").font(.caption)
            }
        }
    }

    /// Amber past 80 %, red once over. Hoisted out of the ViewBuilder so the
    /// colour rule lives in one place.
    private var fraction: Double { model.budgetFraction ?? 0 }
    private var budgetTint: Color { fraction >= 1 ? .red : (fraction >= 0.8 ? .orange : .accentColor) }

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Budget").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(budgetTint)
            }
            ProgressView(value: fraction)
                .tint(budgetTint)
            HStack {
                Text("\(ByteFormat.string(model.budgetUsed)) of \(ByteFormat.string(model.budgetLimit ?? 0))")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clearBudget() }
                    .buttonStyle(.link).font(.caption2)
            }
            Text("Cycle from \(model.budgetCycleFrom)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var budgetEntry: some View {
        HStack(spacing: 6) {
            TextField("Set a limit, e.g. 5GB", text: $budgetText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            Button("Set") {
                model.setBudget(budgetText, cycle: .monthly)
                budgetText = ""
            }
            .disabled(ByteFormat.parse(budgetText) == nil)
            .font(.caption)
        }
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("What used it today").font(.caption).foregroundStyle(.secondary)
            ForEach(model.topProcesses, id: \.process) { process in
                HStack {
                    Text(process.process).font(.caption).lineLimit(1)
                    Spacer()
                    Text(ByteFormat.string(process.total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var otherNetworksSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Other networks today").font(.caption).foregroundStyle(.secondary)
            ForEach(model.otherNetworks, id: \.record.id) { entry in
                HStack {
                    Text(entry.record.displayName).font(.caption).lineLimit(1)
                    if entry.record.isMetered {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8)).foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(ByteFormat.string(entry.today)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
            if showingRename {
                HStack(spacing: 6) {
                    TextField("Name this network", text: $nameText)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    Button("Save") {
                        model.rename(nameText)
                        nameText = ""
                        showingRename = false
                    }.font(.caption)
                }
            }
            HStack {
                Button(showingRename ? "Cancel" : "Rename") { showingRename.toggle() }
                    .buttonStyle(.link).font(.caption)
                Button(model.isMetered ? "Unmark metered" : "Mark metered") { model.toggleMetered() }
                    .buttonStyle(.link).font(.caption)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link).font(.caption)
            }
            Text(model.samplingInProcess ? "Sampling in app" : "Sampling via background agent")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

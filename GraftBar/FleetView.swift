import SwiftUI
import GraftCore

/// The Fleet section — a live "canopy" view of an Orchard tree: the trunk (controller),
/// its branches (worker Macs) and their leaf capacity, and the leaves (VMs) graft owns on
/// the cluster. Queries the Orchard controller directly (independent of whether graft's own
/// supervisor is running locally), refreshing every few seconds. Only meaningful for Orchard
/// profiles — local-Tart profiles get a friendly nudge to the Dashboard instead.
struct FleetView: View {
    @ObservedObject var config: ConfigStore

    @State private var report: OrchardProvider.FleetReport?
    @State private var leaves: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var lastUpdated: Date?
    @State private var now = Date()

    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var selected: String? { config.selected }
    private var isOrchard: Bool { selected.map { config.isOrchard($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { load() }
        .onChange(of: config.selected) { load() }
        .onReceive(refresh) { _ in if isOrchard { load(silent: true) } }
        .onReceive(ticker) { now = $0 }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Canopy").font(.title2.weight(.semibold))
            if !config.profiles.isEmpty {
                Picker("", selection: Binding(
                    get: { config.selected ?? "" },
                    set: { config.selected = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(config.profiles, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            if let lastUpdated {
                Text("updated \(ageString(now.timeIntervalSince(lastUpdated))) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { load() } label: {
                if loading { ProgressView().controlSize(.small) }
                else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .disabled(loading || !isOrchard)
        }
        .padding(16)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if selected == nil {
            empty("No profile", "Create a profile first, over in the Profiles tab.")
        } else if !isOrchard {
            empty("Local Tart profile", "“\(selected ?? "")” runs VMs on this Mac — watch it live on the Dashboard. The canopy is for Orchard fleets.")
        } else if let error, report == nil {
            unreachable(error)
        } else if let report {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    trunkCard(report)
                    capacityCard(report)
                    branchesCard(report)
                    leavesCard(report)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reaching the trunk…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Cards

    private func trunkCard(_ r: OrchardProvider.FleetReport) -> some View {
        card {
            HStack(spacing: 10) {
                Image(systemName: "sailboat").font(.title3).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trunk").font(.headline)
                    Text(r.controllerURL).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Label("reachable", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }

    private func capacityCard(_ r: OrchardProvider.FleetReport) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Capacity", systemImage: "gauge.with.dots.needle.50percent").font(.headline)
                    Spacer()
                    Text("\(r.usedVMs) used · \(r.freeSlots) free · \(r.totalSlots) slots")
                        .font(.callout).foregroundStyle(.secondary)
                }
                capacityBar(used: r.usedVMs, total: r.totalSlots)
            }
        }
    }

    private func capacityBar(used: Int, total: Int) -> some View {
        GeometryReader { geo in
            let frac = total > 0 ? min(1, Double(used) / Double(total)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(used >= total && total > 0 ? Color.orange : Color.green)
                    .frame(width: max(0, geo.size.width * frac))
            }
        }
        .frame(height: 8)
    }

    private func branchesCard(_ r: OrchardProvider.FleetReport) -> some View {
        let stale = r.workers.filter(\.isStale).count
        let paused = r.workers.filter(\.paused).count
        return card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Branches", systemImage: "laptopcomputer").font(.headline)
                    Spacer()
                    Text(branchSummary(count: r.workers.count, stale: stale, paused: paused))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if r.workers.isEmpty {
                    Text("No branches yet — graft one on with `graft tree branch <trunk-url>`.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(r.workers, id: \.name) { w in
                        Divider()
                        branchRow(w)
                    }
                }
            }
        }
    }

    private func branchRow(_ w: OrchardProvider.OrchardWorker) -> some View {
        HStack(spacing: 10) {
            Circle().fill(branchColor(w)).frame(width: 8, height: 8)
            Text(w.name).font(.body.weight(.medium))
            Spacer()
            if let age = w.lastSeenAge {
                Text("seen \(ageString(age)) ago").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(w.slots) leaf\(w.slots == 1 ? "" : "es")")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(branchState(w))
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(branchColor(w).opacity(0.15), in: Capsule())
                .foregroundStyle(branchColor(w))
        }
        .padding(.vertical, 2)
    }

    private func leavesCard(_ r: OrchardProvider.FleetReport) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Leaves", systemImage: "leaf").font(.headline)
                    Spacer()
                    Text("\(r.graftVMNames.count) graft leaf\(r.graftVMNames.count == 1 ? "" : "es")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if r.graftVMNames.isEmpty {
                    Text("No leaves from this profile right now.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(r.graftVMNames, id: \.self) { name in
                        HStack(spacing: 8) {
                            Image(systemName: "leaf.fill").font(.caption).foregroundStyle(.green)
                            Text(name).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Bits

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.12)))
    }

    private func empty(_ title: String, _ note: String) -> some View {
        VStack(spacing: 10) {
            GraftMark(size: 40, color: Color(nsColor: .tertiaryLabelColor))
            Text(title).font(.headline)
            Text(note).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func unreachable(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text("Can't reach the trunk").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Retry") { load() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func branchColor(_ w: OrchardProvider.OrchardWorker) -> Color {
        if w.isStale { return .red }
        if w.paused { return .orange }
        return .green
    }

    private func branchState(_ w: OrchardProvider.OrchardWorker) -> String {
        if w.isStale { return "stale" }
        if w.paused { return "paused" }
        return "live"
    }

    private func branchSummary(count: Int, stale: Int, paused: Int) -> String {
        var parts = ["\(count) branch\(count == 1 ? "" : "es")"]
        if stale > 0 { parts.append("\(stale) stale") }
        if paused > 0 { parts.append("\(paused) paused") }
        return parts.joined(separator: " · ")
    }

    private func ageString(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    // MARK: Load

    private func load(silent: Bool = false) {
        guard let name = selected, config.isOrchard(name), let provider = config.orchardProvider(for: name) else {
            report = nil; leaves = []; error = nil
            return
        }
        if !silent { loading = true }
        Task {
            do {
                let r = try await provider.report()
                report = r
                leaves = r.graftVMNames
                error = nil
                lastUpdated = Date()
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

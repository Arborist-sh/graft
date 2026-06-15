import SwiftUI
import GraftCore

/// The full-window dashboard — graft's "mission control". A roomy live view of the pool:
/// status + profile + start/stop up top, then a table of every runner slot with its phase,
/// leaf, IP, and time-in-phase. Shares the one `GraftController` with the menu-bar extra, so
/// both reflect the same daemon state (refreshed every 3s from the state file).
struct DashboardView: View {
    @ObservedObject var controller: GraftController

    /// Ticks once a second so the Age column counts up live between the controller's
    /// 3s state refreshes.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var busy: Bool { controller.actionNote != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 360)
        .onReceive(ticker) { now = $0 }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.isRunning ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(controller.isRunning ? "Running" : "Stopped")
                    .font(.title3.weight(.semibold))
                if controller.isRunning {
                    let n = controller.slots.count
                    Text("· \(n) leaf\(n == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            }

            if let note = controller.actionNote {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Spacer()
            profilePicker
            startStopButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var profilePicker: some View {
        if !controller.profiles.isEmpty {
            Menu {
                ForEach(controller.profiles, id: \.self) { name in
                    Button {
                        controller.useProfile(name)
                    } label: {
                        if name == controller.activeProfile {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                Label(controller.activeProfile ?? "no profile", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy)
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        if controller.isRunning {
            Button(role: .destructive) {
                controller.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(controller.isStopping)
        } else {
            Button {
                controller.start()
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !controller.graftInstalled)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !controller.graftInstalled {
            emptyState("graft CLI not found",
                       "Install the graft CLI (brew install briancorbin/tap/graft) to get going.") {
                symbolIcon("exclamationmark.triangle")
            }
        } else if !controller.isRunning {
            VStack(spacing: 16) {
                emptyState("Not running",
                           "Start to boot this profile's runners.") {
                    GraftMark(size: 46, color: .secondary)
                }
                if !controller.orphans.isEmpty { orphanBanner.padding(.horizontal, 40) }
            }
        } else if controller.slots.isEmpty {
            emptyState("No leaves yet",
                       controller.actionNote ?? "Waiting for the supervisor to schedule runners…") {
                symbolIcon("hourglass")
            }
        } else {
            slotTable
        }
    }

    private var slotTable: some View {
        Table(controller.slots) {
            TableColumn("") { slot in
                Circle().fill(PhaseStyle.color(slot.phaseKind)).frame(width: 8, height: 8)
            }
            .width(18)
            TableColumn("Slot", value: \.tag).width(min: 70, ideal: 90)
            TableColumn("Pool", value: \.pool).width(min: 70, ideal: 90)
            TableColumn("Leaf") { slot in
                Text(PhaseStyle.shortLeaf(slot.vmName)).foregroundStyle(.secondary).monospaced()
            }
            .width(min: 80, ideal: 90)
            TableColumn("Status") { slot in
                Text(slot.phaseLabel).lineLimit(1).truncationMode(.tail)
            }
            .width(min: 160, ideal: 220)
            TableColumn("IP") { slot in
                Text(slot.ip ?? "—").foregroundStyle(.secondary).monospaced()
            }
            .width(min: 90, ideal: 110)
            TableColumn("Age") { slot in
                Text(PhaseStyle.age(since: slot.since, now: now))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 50, ideal: 60)
        }
    }

    private var orphanBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(controller.orphans.count) orphaned VM\(controller.orphans.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.medium))
                Text("A daemon didn't shut down cleanly. Start also sweeps these.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove") { controller.killOrphans() }.disabled(busy)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func emptyState<Icon: View>(_ title: String, _ subtitle: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 10) {
            icon()
            Text(title).font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func symbolIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 34)).foregroundStyle(.tertiary)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 5) {
            GraftMark(size: 12, color: .green)
            Text("Graft").font(.caption.weight(.medium))
            Spacer()
            Text(BuildInfo.footer).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

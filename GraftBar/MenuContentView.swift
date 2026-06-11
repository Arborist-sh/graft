import SwiftUI
import GraftCore

/// The menu-bar dropdown content. Status at a glance + the actions you actually
/// reach for: switch profile, start/stop.
struct MenuContentView: View {
    @ObservedObject var controller: GraftController

    private var busy: Bool { controller.actionNote != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            profileSwitcher

            if let note = controller.actionNote {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Divider()
            runnerList
            orphanSection
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 260)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(controller.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(controller.isRunning ? "Running" : "Stopped")
                .font(.headline)
            Spacer()
            if controller.isRunning {
                let n = controller.slots.count
                Text("\(n) runner\(n == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var profileSwitcher: some View {
        if controller.profiles.isEmpty {
            Text("No profiles — run graft init")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
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
                Label("Profile: \(controller.activeProfile ?? "—")", systemImage: "square.stack.3d.up")
            }
            .disabled(busy)
        }
    }

    @ViewBuilder
    private var runnerList: some View {
        if controller.slots.isEmpty {
            Text("No active runners")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(controller.slots) { slot in
                HStack(spacing: 7) {
                    Circle()
                        .fill(Self.phaseColor(slot.phaseKind))
                        .frame(width: 7, height: 7)
                    Text(slot.tag).font(.subheadline)
                    Spacer()
                    Text(slot.phaseLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(slot.ip.map { "\(slot.vmName ?? slot.tag) · \($0)" } ?? (slot.vmName ?? slot.tag))
            }
        }
    }

    /// Status-dot colour per phase kind.
    private static func phaseColor(_ kind: String) -> Color {
        switch kind {
        case "ready": return .green
        case "busy": return .blue
        case "acquiring", "provisioning", "starting", "connected": return .orange
        case "stopping", "deregistering", "retrying": return .secondary
        default: return .secondary
        }
    }

    @ViewBuilder
    private var orphanSection: some View {
        if !controller.orphans.isEmpty {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(controller.orphans.count) orphaned VM\(controller.orphans.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Text("a daemon didn't shut down cleanly — Start also sweeps these")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Remove orphans") { controller.killOrphans() }
                .disabled(busy)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.graftInstalled {
                Text("graft CLI not found")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            HStack {
                if controller.isRunning {
                    // Enabled during boot (so you can cancel), disabled only while
                    // already tearing down (no double-stop).
                    Button("Stop") { controller.stop() }.disabled(controller.isStopping)
                } else {
                    Button("Start") { controller.start() }
                        .disabled(busy || !controller.graftInstalled)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
    }
}

import SwiftUI
import GraftCore

/// The menu-bar dropdown content. Status at a glance + the handful of actions you
/// actually reach for: start/stop and switch profile.
struct MenuContentView: View {
    @ObservedObject var controller: GraftController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let profile = controller.activeProfile {
                Text("Profile: \(profile)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            runnerList

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
                Text("\(controller.runners.count) runner\(controller.runners.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var runnerList: some View {
        if controller.runners.isEmpty {
            Text("No active runners")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(controller.runners, id: \.vm.name) { runner in
                HStack {
                    Text(runner.pool).font(.subheadline)
                    Spacer()
                    Text(runner.vm.ip).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !controller.graftInstalled {
            Text("graft CLI not found")
                .font(.subheadline)
                .foregroundStyle(.red)
        }

        HStack {
            if controller.isRunning {
                Button("Stop") { controller.stop() }
            } else {
                Button("Start") { controller.start() }
                    .disabled(!controller.graftInstalled)
            }
            Spacer()
        }

        if controller.profiles.count > 1 {
            Menu("Switch profile") {
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
            }
        }

        Divider()

        Button("Quit Graft Bar") { NSApplication.shared.terminate(nil) }
    }
}

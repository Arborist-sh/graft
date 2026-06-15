import SwiftUI
import GraftCore

/// The Profiles section — list every profile, show which is active + a one-line summary,
/// switch the active one (restart-aware, via the runtime controller), create a skeleton
/// profile, or delete one. Pools + secrets for the selected profile live in their own
/// sections.
struct ProfilesView: View {
    @ObservedObject var config: ConfigStore
    @ObservedObject var controller: GraftController

    @State private var creating = false
    @State private var newName = ""
    @State private var pendingDelete: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Profiles").font(.title2.weight(.semibold))
                Spacer()
                Button { newName = ""; creating = true } label: {
                    Label("New profile", systemImage: "plus")
                }
            }
            .padding(16)
            Divider()

            if config.profiles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(config.profiles, id: \.self, content: row)
                }
                .listStyle(.inset)
            }
        }
        .onAppear { config.reload() }
        .sheet(isPresented: $creating) { createSheet }
        .confirmationDialog(
            "Delete profile “\(pendingDelete ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let n = pendingDelete { config.remove(n) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Removes the profile's config. Any secrets in the Keychain are left untouched.")
        }
    }

    private func row(_ name: String) -> some View {
        let isActive = name == config.active
        return HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.body.weight(.medium))
                    if isActive {
                        Text("active")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(summary(name)).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if !isActive {
                Button("Use") {
                    controller.useProfile(name)
                    config.reload()
                }
            }
            Button(role: .destructive) { pendingDelete = name } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isActive)
            .help(isActive ? "Can't delete the active profile" : "Delete profile")
        }
        .padding(.vertical, 4)
    }

    /// One-line "backend · N pools · target" summary, read live from the profile JSON.
    private func summary(_ name: String) -> String {
        guard let c = config.config(name) else { return "unreadable (old schema?)" }
        let pools = c.pools.count
        let target = c.github?.target ?? c.pools.first?.github?.target
        let tgt = target.map { " · \($0)" } ?? ""
        return "\(c.provider.typeName) · \(pools) pool\(pools == 1 ? "" : "s")\(tgt)"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            GraftMark(size: 40, color: Color(nsColor: .tertiaryLabelColor))
            Text("No profiles").font(.headline)
            Text("Create one to configure a fleet.").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New profile").font(.headline)
            TextField("Name (e.g. local, work-fleet)", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { if config.create(newName) { creating = false } }
            Text("Creates a local-Tart profile with no pools — add pools + secrets next.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { creating = false }
                Button("Create") { if config.create(newName) { creating = false } }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

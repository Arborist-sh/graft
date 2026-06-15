import SwiftUI

/// The app's sections — the sidebar items. Dashboard + config today; Fleet / Saplings /
/// Nests slot in here as they're built.
enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, profiles, pools, secrets
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .profiles:  return "Profiles"
        case .pools:     return "Pools"
        case .secrets:   return "Secrets"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .profiles:  return "square.stack.3d.up"
        case .pools:     return "circle.grid.2x2"
        case .secrets:   return "key"
        }
    }
}

/// The window root — a sidebar (NavigationSplitView) over the sections. The Dashboard reuses
/// the runtime `GraftController`; the config sections share one `ConfigStore`.
struct RootView: View {
    @ObservedObject var controller: GraftController
    @StateObject private var config = ConfigStore()
    @State private var section: AppSection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(AppSection.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 240)
            .navigationTitle("Graft")
        } detail: {
            switch section ?? .dashboard {
            case .dashboard: DashboardView(controller: controller)
            case .profiles:  ProfilesView(config: config, controller: controller)
            case .pools:     PoolsView(config: config)
            case .secrets:   SecretsView(config: config)
            }
        }
    }
}

/// Placeholder for sections not yet built — keeps the sidebar honest about what's coming.
struct ComingSoon: View {
    let title: String
    let note: String
    var body: some View {
        VStack(spacing: 10) {
            GraftMark(size: 40, color: Color(nsColor: .tertiaryLabelColor))
            Text(title).font(.headline)
            Text(note).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Coming next").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

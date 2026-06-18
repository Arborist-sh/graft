import SwiftUI

/// The app's sections — the sidebar items, grouped (see `SidebarGroup`) as Operate /
/// Configure / Images & Dev. Sapflow (health) slots into Operate next.
enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, canopy, profiles, pools, secrets, saplings, seeds, nests
    var id: String { rawValue }

    func title(_ vocab: Vocabulary) -> String {
        switch self {
        case .dashboard: return Lex.dashboard(vocab)
        case .canopy:    return Lex.canopy(vocab)
        case .nests:     return Lex.nests(vocab)
        case .saplings:  return Lex.images(vocab)
        case .seeds:     return Lex.seeds(vocab)
        case .profiles:  return Lex.profiles(vocab)
        case .pools:     return Lex.pools(vocab)
        case .secrets:   return Lex.secrets(vocab)
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .canopy:    return "tree"
        case .nests:     return "shippingbox"
        case .saplings:  return "leaf"
        case .seeds:     return "circle.hexagongrid"
        case .profiles:  return "square.stack.3d.up"
        case .pools:     return "circle.grid.2x2"
        case .secrets:   return "key"
        }
    }
}

/// Sidebar grouping — the headers the sections sit under. Order here is display order.
enum SidebarGroup: String, CaseIterable, Identifiable {
    case operate = "Operate"
    case configure = "Configure"
    case images = "Images & Dev"
    var id: String { rawValue }

    var sections: [AppSection] {
        switch self {
        case .operate:   return [.dashboard, .canopy]
        case .configure: return [.profiles, .pools, .secrets]
        case .images:    return [.saplings, .seeds, .nests]
        }
    }
}

/// The window root — a sidebar (NavigationSplitView) over the sections. The Dashboard reuses
/// the runtime `GraftController`; the config sections share one `ConfigStore`.
struct RootView: View {
    @ObservedObject var controller: GraftController
    @StateObject private var config = ConfigStore()
    @StateObject private var seedStore = SeedEditorModel()
    @State private var section: AppSection? = .dashboard
    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SidebarGroup.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(group.sections) { item in
                            Label(item.title(vocab), systemImage: item.symbol).tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 240)
            .navigationTitle("Graft")
        } detail: {
            switch section ?? .dashboard {
            case .dashboard: DashboardView(controller: controller, config: config)
            case .canopy:    CanopyView(config: config)
            case .nests:     NestsView(config: config)
            case .saplings:  SaplingsView(config: config)
            case .seeds:     SeedsView(config: config, store: seedStore)
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

import SwiftUI

/// Which set of names the UI shows. graft's concepts have a botanical theme, but not
/// everyone wants to learn new words for things they already know — so every term has a
/// plain "Standard" name and a themed "Graft" alias, switchable in Settings.
enum Vocabulary: String, CaseIterable, Identifiable {
    case standard, graft
    var id: String { rawValue }
    var label: String { self == .standard ? "Standard" : "Graft 🌱" }
}

/// One concept's two names. Call it with the active vocabulary to get the right string:
/// `Lex.pools(vocab)` → "Pools" or "Stands".
struct Term {
    let standard: String
    let graft: String
    func callAsFunction(_ v: Vocabulary) -> String { v == .standard ? standard : graft }
}

/// The lexicon — every concept that has a themed alias, in one place. Section names plus
/// the in-content nouns (a runner VM, a worker, the controller, an image) so the whole UI
/// speaks one chosen dialect. Add a row here, use it everywhere.
enum Lex {
    // Sections
    static let dashboard = Term(standard: "Dashboard", graft: "Tend")
    static let canopy    = Term(standard: "Fleet",     graft: "Canopy")
    static let profiles  = Term(standard: "Profiles",  graft: "Plots")
    static let pools     = Term(standard: "Pools",     graft: "Stands")
    static let secrets   = Term(standard: "Secrets",   graft: "Roots")
    static let images    = Term(standard: "Images",    graft: "Saplings")
    static let nests     = Term(standard: "Dev Boxes", graft: "Nests")
    static let health    = Term(standard: "Health",    graft: "Sapflow")
    static let hosts     = Term(standard: "Hosts",     graft: "Grounds")

    // In-content nouns (singular / plural pairs)
    static let vm        = Term(standard: "VM",       graft: "leaf")
    static let vms       = Term(standard: "VMs",      graft: "leaves")
    static let worker    = Term(standard: "Worker",   graft: "Branch")
    static let workers   = Term(standard: "Workers",  graft: "Branches")
    static let controller = Term(standard: "Controller", graft: "Trunk")
    static let image     = Term(standard: "Image",    graft: "Sapling")
}

/// Read the active vocabulary anywhere with `@AppStorageVocabulary var vocab`. Defaults to
/// Standard so newcomers see familiar words; flip to Graft in Settings for the full theme.
extension AppStorage where Value == Vocabulary {
    init(vocabulary key: String = Vocabulary.storageKey) {
        self.init(wrappedValue: .standard, key)
    }
}

extension Vocabulary {
    static let storageKey = "graft.vocabulary"
}

/// The Settings (⌘,) pane — currently just the vocabulary chooser, with a live preview of a
/// few terms so the difference is obvious before you commit.
struct SettingsView: View {
    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard

    var body: some View {
        Form {
            Section {
                Picker("Naming", selection: $vocab) {
                    ForEach(Vocabulary.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Use the standard software terms everyone knows, or graft's botanical theme. Affects the whole app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Preview") {
                preview(Lex.dashboard)
                preview(Lex.canopy)
                preview(Lex.pools)
                preview(Lex.secrets)
                preview(Lex.vms, suffix: " (a runner VM)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 360)
    }

    private func preview(_ term: Term, suffix: String = "") -> some View {
        LabeledContent {
            Text(term(vocab)).font(.body.weight(.medium))
        } label: {
            Text("\(term.standard) ↔ \(term.graft)\(suffix)").foregroundStyle(.secondary)
        }
    }
}

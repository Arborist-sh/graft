import GraftCore
import SwiftUI

/// Sapflow — the health section. A live board of active problems (from the monitor's
/// snapshot) over a chronological event feed (from its JSONL log), with severity colours and
/// graft's botanical category names. Reads both files directly via `HealthStore`; the only
/// CLI touch is the "Start tending" button, which boots the daemon with `--monitor`.
struct SapflowView: View {
    @ObservedObject var controller: GraftController
    @StateObject private var health = HealthStore()
    @AppStorage(Vocabulary.storageKey) private var vocab: Vocabulary = .standard
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !controller.isRunning { staleBanner }
            content
        }
        .onReceive(ticker) { now = $0 }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(Lex.health(vocab)).font(.title2.weight(.semibold))
            if controller.isRunning {
                Label("tending", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon).imageScale(.small)
                    .font(.caption).foregroundStyle(.green)
            }
            Spacer()
            if let at = health.lastEventAt {
                Text("as of \(PhaseStyle.age(since: at, now: now)) ago")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button { health.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Stale banner (monitor not running)

    private var staleBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not tending — health data may be stale").font(.caption.weight(.medium))
                Text("Start the monitor to collect live fleet health.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Start tending") { controller.start(monitor: true) }
                .controlSize(.small)
                .disabled(!controller.graftInstalled)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if health.problems.isEmpty && health.feed.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    problemsSection
                    feedSection
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            GraftMark(size: 40, color: Color(nsColor: .tertiaryLabelColor))
            Text(controller.isRunning ? "All clear" : "No health data yet").font(.headline)
            Text(controller.isRunning
                 ? "No active problems — the fleet looks healthy."
                 : "Start tending with the monitor to collect health.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: Sections

    @ViewBuilder
    private var problemsSection: some View {
        sectionHeader("Current problems", count: health.problems.count)
        if health.problems.isEmpty {
            Text(controller.isRunning ? "No active problems — all clear." : "—")
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                ForEach(health.problems) { ProblemRow(event: $0, vocab: vocab) }
            }
        }
    }

    @ViewBuilder
    private var feedSection: some View {
        sectionHeader("Event feed", count: health.feed.count)
        if health.feed.isEmpty {
            Text("No events logged yet.").font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(health.feed) { FeedRow(event: $0, vocab: vocab, now: now) }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            Text("\(count)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }
}

// MARK: - Rows

/// A card in the "current problems" board: severity glyph, botanical category, subject,
/// the message, and the monitor's own suggested action.
private struct ProblemRow: View {
    let event: HealthEvent
    let vocab: Vocabulary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.severity.symbol)
                .foregroundStyle(event.severity.color).imageScale(.medium).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Lex.category(event.category)(vocab))
                        .font(.caption.weight(.semibold)).foregroundStyle(event.severity.color)
                    if let subject = event.subject {
                        Text(subject).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(event.message).font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = event.suggestedAction {
                    Label(action, systemImage: "arrow.turn.down.right")
                        .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(event.severity.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(event.severity.color.opacity(0.25)))
    }
}

/// A compact line in the event feed: relative time, severity glyph, category·subject, message.
private struct FeedRow: View {
    let event: HealthEvent
    let vocab: Vocabulary
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Text(PhaseStyle.age(since: event.timestamp, now: now))
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
                Image(systemName: event.severity.symbol)
                    .foregroundStyle(event.severity.color).imageScale(.small).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(Lex.category(event.category)(vocab)).font(.caption.weight(.medium))
                        if let subject = event.subject {
                            Text(subject).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(event.message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            Divider().opacity(0.4)
        }
    }
}

// MARK: - Severity styling

private extension HealthEvent.Severity {
    var color: Color {
        switch self {
        case .critical:  return .red
        case .warn:      return .orange
        case .recovered: return .green
        case .info:      return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .critical:  return "exclamationmark.octagon.fill"
        case .warn:      return "exclamationmark.triangle.fill"
        case .recovered: return "checkmark.circle.fill"
        case .info:      return "info.circle"
        }
    }
}

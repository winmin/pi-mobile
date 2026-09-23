import SwiftUI

struct TimelineView: View {
    @Environment(AppModel.self) private var model

    private var entries: [TimelineEntry] {
        model.timelineEntries.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        let theme = model.theme
        if entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.system(size: 36))
                    .foregroundStyle(theme.textFaint)
                Text("No activity yet")
                    .font(.callout)
                    .foregroundStyle(theme.textMuted)
                Text("Your prompts, responses and approvals\nwill show up here.")
                    .font(.caption)
                    .foregroundStyle(theme.textFaint)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.appBG)
            .navigationTitle("Timeline")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        entryRow(entry, isLast: index == entries.count - 1, theme: theme)
                    }
                }
                .padding(16)
            }
            .background(theme.appBG)
            .navigationTitle("Timeline")
        }
    }

    private func entryRow(_ entry: TimelineEntry, isLast: Bool, theme: PiTheme) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(color(for: entry.kind, theme: theme).opacity(0.15))
                    Image(systemName: icon(for: entry.kind))
                        .font(.system(size: 12))
                        .foregroundStyle(color(for: entry.kind, theme: theme))
                }
                .frame(width: 28, height: 28)
                if !isLast {
                    Rectangle()
                        .fill(theme.borderStrong)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.callout.bold())
                    .foregroundStyle(theme.textPrimary)
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Text("\(entry.sessionTitle) · \(entry.timestamp.relativeShort)")
                    .font(.caption2)
                    .foregroundStyle(theme.textFaint)
            }
            .padding(.bottom, 20)
            Spacer(minLength: 0)
        }
    }

    private func icon(for kind: TimelineKind) -> String {
        switch kind {
        case .message: return "bubble.left.fill"
        case .toolCall: return "wrench.fill"
        case .fork: return "arrow.triangle.branch"
        case .approval: return "checkmark"
        case .error: return "xmark"
        }
    }

    private func color(for kind: TimelineKind, theme: PiTheme) -> Color {
        switch kind {
        case .message: return theme.accent
        case .toolCall: return theme.warning
        case .fork: return .purple
        case .approval: return theme.success
        case .error: return theme.error
        }
    }
}

#Preview {
    TimelineView()
        .environment(AppModel())
}

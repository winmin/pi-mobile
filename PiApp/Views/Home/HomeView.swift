import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var recentSessions: [ChatSession] {
        model.sessions
            .filter { !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        let theme = model.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(theme)
                statsRow(theme)
                heatmapCard(theme)
                modelUsageCard(theme)
                quickActions(theme)
                recentSessionsCard(theme)
            }
            .padding(16)
        }
        .background(theme.appBG)
        .navigationTitle("Home")
    }

    // MARK: - Header

    private func header(_ theme: PiTheme) -> some View {
        HStack(spacing: 12) {
            PiGlyph(size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("What should Pi work on?")
                    .font(.title2.bold())
                    .foregroundStyle(theme.textPrimary)
                Text(Date().formatted(date: .complete, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(theme.textMuted)
            }
        }
    }

    // MARK: - Stat cards

    private func statsRow(_ theme: PiTheme) -> some View {
        HStack(spacing: 10) {
            statCard("Sessions", "\(model.stats.totalSessions)", "bubble.left.and.bubble.right", theme)
            statCard("Tokens", formatTokenCount(model.stats.totalTokens), "number", theme)
            statCard("Cost", formatCost(model.stats.totalCostUSD), "dollarsign.circle", theme)
            statCard("Streak", "\(model.stats.currentStreakDays)d", "flame", theme)
        }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String, _ theme: PiTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(theme.textMuted)
            Text(value)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 0.5))
    }

    // MARK: - Heatmap

    private func heatmapCard(_ theme: PiTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Activity")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            let weeks = model.stats.heatmapWeeks.first?.count ?? 0
            HStack(spacing: 3) {
                ForEach(0..<weeks, id: \.self) { week in
                    VStack(spacing: 3) {
                        ForEach(0..<model.stats.heatmapWeeks.count, id: \.self) { day in
                            heatmapCell(value: week < model.stats.heatmapWeeks[day].count
                                ? model.stats.heatmapWeeks[day][week] : 0, theme)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .piCard(theme)
    }

    private func heatmapCell(value: Int, _ theme: PiTheme) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(value > 0
                ? theme.accent.opacity(0.15 + 0.85 * Double(min(value, 4)) / 4)
                : theme.surface2)
            .frame(height: 12)
    }

    // MARK: - Per-model usage

    private func modelUsageCard(_ theme: PiTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tokens by model")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            let maxTokens = model.stats.perModel.map(\.tokens).max() ?? 1
            ForEach(model.stats.perModel, id: \.model) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.model)
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text(formatTokenCount(entry.tokens))
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.textMuted)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.surface2)
                            Capsule()
                                .fill(theme.accent)
                                .frame(width: max(4, proxy.size.width * CGFloat(entry.tokens) / CGFloat(maxTokens)))
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
        .piCard(theme)
    }

    // MARK: - Quick actions

    private func quickActions(_ theme: PiTheme) -> some View {
        HStack(spacing: 10) {
            quickAction("New Session", "plus.bubble", theme) { model.newSession() }
            quickAction("Timeline", "point.topleft.down.to.point.bottomright.curvepath", theme) { model.route = .timeline }
            quickAction("Settings", "gearshape", theme) { model.route = .settings }
        }
    }

    private func quickAction(_ title: String, _ icon: String, _ theme: PiTheme,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .piCard(theme)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent sessions

    private func recentSessionsCard(_ theme: PiTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent sessions")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            if recentSessions.isEmpty {
                Text("No sessions yet")
                    .font(.callout)
                    .foregroundStyle(theme.textMuted)
            } else {
                ForEach(recentSessions) { session in
                    Button {
                        model.openSession(session)
                    } label: {
                        HStack(spacing: 8) {
                            SessionDot(session: session, theme: theme)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title)
                                    .font(.callout)
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                                Text("\(session.model) · \(formatTokenCount(session.usage.total)) tokens · \(session.updatedAt.relativeShort)")
                                    .font(.caption2)
                                    .foregroundStyle(theme.textMuted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(theme.textFaint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .piCard(theme)
    }

    // MARK: - Changed files

}

#Preview {
    HomeView()
        .environment(AppModel())
}

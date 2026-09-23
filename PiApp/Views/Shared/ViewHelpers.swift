import SwiftUI

// MARK: - Formatting

func formatTokenCount(_ n: Int) -> String {
    if n >= 1000 {
        return String(format: "%.1fk", Double(n) / 1000)
    }
    return "\(n)"
}

func formatCost(_ usd: Double) -> String {
    String(format: "$%.2f", usd)
}

extension Date {
    var relativeShort: String { formatted(.relative(presentation: .named)) }
}

// MARK: - Brand

let piOrange = Color(hex: "f59e0b")

struct PiGlyph: View {
    var size: Double = 28

    var body: some View {
        Text("π")
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(piOrange)
    }
}

// MARK: - Cards

struct CardStyle: ViewModifier {
    let theme: PiTheme
    var cornerRadius: Double = 12

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(theme.border, lineWidth: 0.5)
            )
    }
}

extension View {
    func piCard(_ theme: PiTheme, cornerRadius: Double = 12) -> some View {
        modifier(CardStyle(theme: theme, cornerRadius: cornerRadius))
    }
}

// MARK: - Sessions

func sessionDotColor(_ session: ChatSession, theme: PiTheme) -> Color {
    switch session.status {
    case .running, .waitingApproval:
        return piOrange
    case .idle:
        return session.messages.isEmpty ? theme.textFaint : theme.success
    }
}

struct SessionDot: View {
    let session: ChatSession
    let theme: PiTheme

    var body: some View {
        Circle()
            .fill(sessionDotColor(session, theme: theme))
            .frame(width: 8, height: 8)
    }
}

// MARK: - Files

func flattenFileTree(_ nodes: [FileNode]) -> [FileNode] {
    nodes.flatMap { [$0] + flattenFileTree($0.children ?? []) }
}

struct ModifiedBadge: View {
    var body: some View {
        Text("M")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(piOrange, in: Circle())
    }
}

// MARK: - Streaming cursor

struct StreamingCursor: View {
    @State private var lit = true

    var body: some View {
        Text("▍")
            .foregroundStyle(piOrange)
            .opacity(lit ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    lit = false
                }
            }
    }
}

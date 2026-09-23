import SwiftUI

/// Renders a unified diff with +/- line highlighting. Shared by chat tool cards and the Files changes view.
struct DiffView: View {
    @Environment(AppModel.self) private var model
    let diff: String

    private enum LineKind { case added, removed, hunk, header, context }

    private struct DiffLine: Identifiable {
        let id = UUID()
        let kind: LineKind
        let text: String
    }

    private var lines: [DiffLine] {
        diff.components(separatedBy: "\n").map { line in
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                return DiffLine(kind: .header, text: line)
            } else if line.hasPrefix("@@") {
                return DiffLine(kind: .hunk, text: line)
            } else if line.hasPrefix("+") {
                return DiffLine(kind: .added, text: line)
            } else if line.hasPrefix("-") {
                return DiffLine(kind: .removed, text: line)
            }
            return DiffLine(kind: .context, text: line)
        }
    }

    var body: some View {
        let theme = model.theme
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(for: line.kind, theme: theme))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(background(for: line.kind, theme: theme))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.vertical, 6)
        }
        .background(theme.codeBG, in: RoundedRectangle(cornerRadius: 8))
    }

    private func color(for kind: LineKind, theme: PiTheme) -> Color {
        switch kind {
        case .added: return theme.success
        case .removed: return theme.error
        case .hunk: return theme.accent
        case .header, .context: return theme.textMuted
        }
    }

    private func background(for kind: LineKind, theme: PiTheme) -> Color {
        switch kind {
        case .added: return theme.success.opacity(0.12)
        case .removed: return theme.error.opacity(0.12)
        default: return .clear
        }
    }
}

#Preview {
    DiffView(diff: """
        @@ -1,3 +1,4 @@
         context
        -old line
        +new line
        """)
    .environment(AppModel())
}

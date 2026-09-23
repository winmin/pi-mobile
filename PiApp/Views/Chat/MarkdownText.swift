import SwiftUI
import UIKit

/// A native SwiftUI Markdown renderer for chat output. Foundation's inline
/// parser handles emphasis, links and inline code; this view adds the block
/// structure that `Text(LocalizedStringKey(...))` does not render: headings,
/// lists, quotes, fenced code, rules and GitHub-style tables.
struct MarkdownText: View {
    @Environment(AppModel.self) private var model
    let text: String
    var fontSize: Double = 16

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(text) }

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block, theme: theme)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            UIApplication.shared.open(url)
            return .handled
        })
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, theme: PiTheme) -> some View {
        switch block {
        case .paragraph(let source):
            inlineText(source)
                .font(.system(size: fontSize))
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let source):
            inlineText(source)
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .padding(.top, level <= 2 ? 4 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", item: item, theme: theme)
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "\(item.number).", item: item.item, theme: theme)
                }
            }

        case .taskList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.checked ? theme.success : theme.textMuted)
                        inlineText(item.text)
                            .font(.system(size: fontSize))
                            .foregroundStyle(theme.textPrimary)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }

        case .quote(let source):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.accent.opacity(0.75))
                    .frame(width: 3)
                inlineText(source)
                    .font(.system(size: fontSize))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)

        case .code(let language, let source):
            codeBlock(language: language, source: source, theme: theme)

        case .table(let table):
            markdownTable(table, theme: theme)

        case .rule:
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func inlineText(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
        return Text(parsed)
    }

    private func headingSize(_ level: Int) -> Double {
        switch level {
        case 1: return fontSize + 10
        case 2: return fontSize + 6
        case 3: return fontSize + 3
        default: return fontSize + 1
        }
    }

    private func listRow(marker: String, item: MarkdownListItem, theme: PiTheme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(minWidth: 14, alignment: .trailing)
            inlineText(item.text)
                .font(.system(size: fontSize))
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(item.depth) * 16)
    }

    private func codeBlock(language: String?, source: String, theme: PiTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.textMuted)
                Spacer()
                Button {
                    UIPasteboard.general.string = source
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(theme.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.surface2)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(.system(size: max(fontSize - 2, 9), design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
        }
        .background(theme.codeBG)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.border, lineWidth: 0.5))
    }

    private func markdownTable(_ table: MarkdownTable, theme: PiTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { index, cell in
                        tableCell(cell, column: index, alignment: table.alignments[safe: index] ?? .leading,
                                  isHeader: true, theme: theme)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(table.headers.indices), id: \.self) { column in
                            tableCell(row[safe: column] ?? "", column: column,
                                      alignment: table.alignments[safe: column] ?? .leading,
                                      isHeader: false, alternate: rowIndex.isMultiple(of: 2), theme: theme)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func tableCell(_ source: String, column: Int, alignment: MarkdownAlignment,
                           isHeader: Bool, alternate: Bool = false, theme: PiTheme) -> some View {
        inlineText(source)
            .font(.system(size: max(fontSize - 1, 10), weight: isHeader ? .semibold : .regular))
            .foregroundStyle(theme.textPrimary)
            .frame(width: column == 0 ? 145 : 230, alignment: alignment.swiftUI)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isHeader ? theme.surface2 : (alternate ? theme.surface.opacity(0.65) : theme.appBG))
            .overlay(alignment: .trailing) {
                Rectangle().fill(theme.border).frame(width: 0.5)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.border).frame(height: 0.5)
            }
    }
}

// MARK: - Block model

private enum MarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case unorderedList([MarkdownListItem])
    case orderedList([(number: Int, item: MarkdownListItem)])
    case taskList([(checked: Bool, text: String, depth: Int)])
    case quote(String)
    case code(language: String?, source: String)
    case table(MarkdownTable)
    case rule
}

private struct MarkdownListItem {
    var text: String
    var depth: Int
}

private struct MarkdownTable {
    var headers: [String]
    var alignments: [MarkdownAlignment]
    var rows: [[String]]
}

private enum MarkdownAlignment {
    case leading, center, trailing

    var swiftUI: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Parser

private enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fenceStart(trimmed) {
                let language = String(trimmed.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(
                    language: language.isEmpty ? nil : language,
                    source: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if let heading = heading(line) {
                blocks.append(.heading(heading.level, heading.text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let table = table(startingAt: index, lines: lines) {
                blocks.append(.table(table.table))
                index = table.nextIndex
                continue
            }

            if quoteText(line) != nil {
                var quoted: [String] = []
                while index < lines.count, let value = quoteText(lines[index]) {
                    quoted.append(value)
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if let first = unorderedItem(line) {
                var ordinary: [MarkdownListItem] = []
                var tasks: [(checked: Bool, text: String, depth: Int)] = []
                var allTasks = first.task != nil
                while index < lines.count, let item = unorderedItem(lines[index]) {
                    ordinary.append(MarkdownListItem(text: item.text, depth: item.depth))
                    if let checked = item.task {
                        tasks.append((checked, item.text, item.depth))
                    } else {
                        allTasks = false
                    }
                    index += 1
                }
                blocks.append(allTasks ? .taskList(tasks) : .unorderedList(ordinary))
                continue
            }

            if orderedItem(line) != nil {
                var items: [(number: Int, item: MarkdownListItem)] = []
                while index < lines.count, let item = orderedItem(lines[index]) {
                    items.append((item.number, MarkdownListItem(text: item.text, depth: item.depth)))
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            var paragraph: [String] = [line]
            index += 1
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  !startsBlock(at: index, lines: lines) {
                paragraph.append(lines[index])
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    private static func startsBlock(at index: Int, lines: [String]) -> Bool {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return fenceStart(trimmed) != nil
            || heading(line) != nil
            || isRule(trimmed)
            || quoteText(line) != nil
            || unorderedItem(line) != nil
            || orderedItem(line) != nil
            || (index + 1 < lines.count && table(startingAt: index, lines: lines) != nil)
    }

    private static func fenceStart(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let count = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count) else { return nil }
        let remainder = trimmed.dropFirst(count)
        guard remainder.first == " " else { return nil }
        return (count, remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func quoteText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == ">" else { return nil }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func unorderedItem(_ line: String)
        -> (text: String, depth: Int, task: Bool?)? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(leading.count)
        guard body.count >= 2, let marker = body.first,
              marker == "-" || marker == "*" || marker == "+",
              body.dropFirst().first == " " else { return nil }
        var text = String(body.dropFirst(2))
        var task: Bool?
        let lower = text.lowercased()
        if lower.hasPrefix("[ ] ") {
            task = false
            text = String(text.dropFirst(4))
        } else if lower.hasPrefix("[x] ") {
            task = true
            text = String(text.dropFirst(4))
        }
        return (text, indentationDepth(leading), task)
    }

    private static func orderedItem(_ line: String)
        -> (number: Int, text: String, depth: Int)? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(leading.count)
        let digits = body.prefix(while: { $0.isNumber })
        guard let number = Int(digits), !digits.isEmpty else { return nil }
        let suffix = body.dropFirst(digits.count)
        guard suffix.count >= 2,
              suffix.first == "." || suffix.first == ")",
              suffix.dropFirst().first == " " else { return nil }
        return (number, String(suffix.dropFirst(2)), indentationDepth(leading))
    }

    private static func indentationDepth(_ whitespace: Substring) -> Int {
        let width = whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return max(0, width / 2)
    }

    private static func table(startingAt index: Int, lines: [String])
        -> (table: MarkdownTable, nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headers = splitCells(lines[index])
        let separators = splitCells(lines[index + 1])
        guard headers.count >= 2, headers.count == separators.count,
              separators.allSatisfy(isTableSeparator) else { return nil }

        let alignments = separators.map { cell -> MarkdownAlignment in
            let value = cell.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(":"), value.hasSuffix(":") { return .center }
            if value.hasSuffix(":") { return .trailing }
            return .leading
        }
        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !trimmed.contains("|") { break }
            rows.append(splitCells(lines[cursor]))
            cursor += 1
        }
        return (MarkdownTable(headers: headers, alignments: alignments, rows: rows), cursor)
    }

    private static func isTableSeparator(_ cell: String) -> Bool {
        var value = cell.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix(":") { value.removeFirst() }
        if value.hasSuffix(":") { value.removeLast() }
        return value.count >= 3 && value.allSatisfy { $0 == "-" }
    }

    private static func splitCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }

        var cells: [String] = []
        var cell = ""
        var escaped = false
        var inCode = false
        for character in value {
            if escaped {
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                cell.append(character)
            } else if character == "|", !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

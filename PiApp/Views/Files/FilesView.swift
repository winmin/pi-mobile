import SwiftUI

struct FilesView: View {
    @Environment(AppModel.self) private var model
    @State private var previewFile: FileNode?
    @State private var diffPresented = false

    private var modifiedFiles: [FileNode] {
        flattenFileTree(model.fileTree).filter { $0.isModified && !$0.isDirectory }
    }

    private var sampleDiff: String? {
        for session in model.sessions {
            for message in session.messages {
                for block in message.blocks {
                    if case .toolCall(let call) = block, let diff = call.diff {
                        return diff
                    }
                }
            }
        }
        return nil
    }

    var body: some View {
        let theme = model.theme
        List {
            if !modifiedFiles.isEmpty {
                Section("Changes") {
                    ForEach(modifiedFiles) { node in
                        Button {
                            diffPresented = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                    .foregroundStyle(theme.textMuted)
                                Text(node.name)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                ModifiedBadge()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(theme.surface)
            }
            Section("Files") {
                OutlineGroup(model.fileTree, children: \.children) { node in
                    if node.isDirectory {
                        Label(node.name, systemImage: "folder")
                            .foregroundStyle(theme.textPrimary)
                    } else {
                        Button {
                            previewFile = node
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                    .foregroundStyle(theme.textMuted)
                                Text(node.name)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                if node.isModified {
                                    ModifiedBadge()
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listRowBackground(theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.appBG)
        .navigationTitle("Files")
        .navigationDestination(item: $previewFile) { file in
            FilePreviewView(file: file)
        }
        .navigationDestination(isPresented: $diffPresented) {
            ChangesPreview(diff: sampleDiff ?? "")
        }
    }
}

struct FilePreviewView: View {
    @Environment(AppModel.self) private var model
    let file: FileNode

    var body: some View {
        let theme = model.theme
        ScrollView([.horizontal, .vertical]) {
            Text(file.content ?? "(empty file)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(theme.codeBG)
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChangesPreview: View {
    @Environment(AppModel.self) private var model
    let diff: String

    var body: some View {
        let theme = model.theme
        ScrollView {
            DiffView(diff: diff)
                .padding(16)
        }
        .background(theme.appBG)
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    FilesView()
        .environment(AppModel())
}

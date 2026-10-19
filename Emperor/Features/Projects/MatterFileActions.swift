import SwiftUI

/// One of the matter's documents in its Files section: the name, its status while it is still
/// being read, and — as on the web's matter Files — Rename and Delete, by swipe, long press and
/// VoiceOver action. Every rule is `ProjectDetailViewModel`'s; the confirmation is the one My
/// Files uses, worded for the matter (`FileDeletion.init(matterFile:)`).
struct MatterDocumentRow: View {
    @Environment(\.theme) private var theme
    let file: FileNode.StoredFile
    let model: ProjectDetailViewModel
    /// Opens the rename prompt for this document.
    let onRename: (FileNode.StoredFile) -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayText.fileName(file.name)).font(.brand(.subheadline))
                if !file.isReadable, let status = file.status, !status.isEmpty {
                    Text(status).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
            if model.isBusy(file) {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .modifier(MatterDocumentEditing(file: file, model: model, onRename: onRename))
    }
}

/// The swipe, the long press and the VoiceOver actions for a matter's document — only when the
/// matter was given the file routes.
private struct MatterDocumentEditing: ViewModifier {
    @Environment(\.theme) private var theme
    let file: FileNode.StoredFile
    let model: ProjectDetailViewModel
    let onRename: (FileNode.StoredFile) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if model.offersFileEditing {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        model.requestDeletion(of: file)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(theme.danger)
                    Button {
                        onRename(file)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(theme.accent)
                }
                .contextMenu {
                    Button {
                        onRename(file)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        model.requestDeletion(of: file)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .accessibilityAction(named: "Rename") { onRename(file) }
                .accessibilityAction(named: "Delete") { model.requestDeletion(of: file) }
                .disabled(model.isWriting)
        } else {
            content
        }
    }
}

/// The two prompts behind a matter's document rows: the new name, and the deletion's
/// confirmation. Hung once on the workspace rather than on every row.
struct MatterDocumentPrompts: ViewModifier {
    let model: ProjectDetailViewModel
    @Binding var renaming: FileNode.StoredFile?
    @Binding var renameText: String

    func body(content: Content) -> some View {
        content
            .alert(model.pendingFileDeletion?.title ?? "Delete", isPresented: Binding(
                get: { model.pendingFileDeletion != nil },
                set: { if !$0 { model.cancelFileDeletion() } }
            )) {
                // Captured now: the alert clears its binding after the action runs.
                let plan = model.pendingFileDeletion
                Button(plan?.confirmLabel ?? "Delete", role: .destructive) {
                    if let plan {
                        Task { await model.confirmFileDeletion(plan) }
                    }
                }
                Button("Cancel", role: .cancel) { model.cancelFileDeletion() }
            } message: {
                Text(model.pendingFileDeletion?.message ?? "")
            }
            .alert("Rename document", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameText)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    let name = renameText
                    if let file = renaming {
                        Task { await model.renameFile(file, to: name) }
                    }
                    renaming = nil
                }
            } message: {
                // Said before the fact: the type is not negotiable.
                Text("The file type stays the same, whatever you type.")
            }
    }
}

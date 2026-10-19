import SwiftUI

/// Deleting a matter, which cannot be walked back: its files are kept nowhere else, and its
/// conversations and their drafts go with it. Typing the name is the confirmation — the rule
/// (`deleteConfirmationMatches`) and the request are `ProjectDetailViewModel`'s.
struct MatterDeleteSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let model: ProjectDetailViewModel
    /// Told once the matter is gone, so the workspace can close.
    let onDeleted: () -> Void

    @State private var typed = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("This permanently deletes \(model.title) and everything in it:")
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(model.deleteConsequences, id: \.self) { line in
                        Label(line, systemImage: "minus")
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.textSecondary)
                    }
                } footer: {
                    Text(ProjectDetailViewModel.deleteFootnote)
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                }
                .listRowBackground(theme.surface)

                Section {
                    TextField(model.title, text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.brand(.body))
                        .accessibilityLabel("Type \(model.title) to confirm")
                        .onChange(of: typed) { model.deleteError = nil }
                    if let error = model.deleteError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.danger)
                    }
                } header: {
                    SectionHeader(title: "Type the matter name to confirm")
                }
                .listRowBackground(theme.surface)

                Section {
                    Button(role: .destructive) {
                        Task {
                            if await model.deleteMatter(confirmName: typed) {
                                dismiss()
                                onDeleted()
                            }
                        }
                    } label: {
                        HStack {
                            if model.isDeleting { ProgressView() }
                            Text("Delete matter").font(.brand(.body, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.deleteConfirmationMatches(typed) || model.isDeleting)
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle("Delete matter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isDeleting)
                }
            }
        }
        // Not closable mid-delete: the request is on its way, and a sheet that vanished would
        // leave it unclear whether it happened.
        .interactiveDismissDisabled(model.isDeleting)
    }
}

/// The destructive row at the foot of a matter's Overview that opens `MatterDeleteSheet`.
struct MatterDeleteRow: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    var body: some View {
        Section {
            Button(role: .destructive, action: action) {
                Label("Delete matter", systemImage: "trash")
            }
        } footer: {
            Text("Deletes the matter with its files, conversations and drafts. You are asked to type its name first.")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }
}

import SwiftUI

/// The documents a matter's conversation may read: the matter's own, never My Files.
///
/// The rules — which can be ticked, what Done hands back — are `MatterFilePickerViewModel`'s.
struct MatterFilePicker: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    let projectID: String
    let alreadyAttached: [ChatAttachment]
    let onAttach: ([ChatAttachment]) -> Void

    @State private var model: MatterFilePickerViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("This matter's documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let model { onAttach(model.selection) }
                        dismiss()
                    }
                    .disabled(model == nil)
                }
            }
            .task {
                guard model == nil else { return }
                let created = MatterFilePickerViewModel(
                    projectID: projectID, service: session.projects, alreadyAttached: alreadyAttached)
                model = created
                await created.load()
            }
        }
    }

    private func content(_ model: MatterFilePickerViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                Section {
                    ForEach(model.files) { file in row(file, model) }
                } footer: {
                    Text("A conversation in this matter reads only the matter's own documents.")
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        } empty: {
            EmptyStateView(
                "No documents",
                systemImage: "folder",
                message: MatterFilePickerViewModel.emptyLine,
                tone: .neutral)
        }
        .background(theme.groupedBackground)
    }

    private func row(_ file: MatterFile, _ model: MatterFilePickerViewModel) -> some View {
        let chosen = model.isChosen(file)
        return Button {
            model.toggle(file)
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? theme.accentText : theme.textTertiary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DisplayText.fileName(file.name))
                        .font(.brand(.subheadline))
                        .foregroundStyle(file.isReady ? theme.textPrimary : theme.textSecondary)
                        .dynamicLineLimit(2)
                    let detail = [file.sub.isEmpty ? nil : file.sub, file.notReadyLine].compactMap { $0 }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · "))
                            .font(.brand(.caption2))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!file.isReady && !chosen)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

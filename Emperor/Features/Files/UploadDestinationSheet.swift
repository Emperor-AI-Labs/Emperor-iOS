import SwiftUI

/// Asks where documents should go before they are picked, so an upload lands in the matter it
/// belongs to rather than in a catch-all folder. A new folder can be made here and is chosen at
/// once.
///
/// The documents themselves are picked after this sheet closes: presenting the system file
/// importer from inside a sheet that is dismissing is unreliable, so the caller starts it from
/// the sheet's `onDismiss`.
struct UploadDestinationSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Folder paths, `/`-joined, in the order to list them.
    let destinations: [String]
    /// The folder chosen when the sheet opens.
    var initial: String?
    /// Creates a folder and returns its stored path, or `nil` with the reason shown elsewhere.
    let createFolder: (String) async -> String?
    /// Called with the chosen folder; the caller dismisses and then picks documents.
    let onChoose: (String) -> Void

    @State private var chosen: String?
    @State private var newName = ""
    @State private var isCreating = false
    @State private var createFailed = false
    @State private var extraFolders: [String] = []

    private var all: [String] {
        var seen = Set<String>()
        return (destinations + extraFolders).filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(all, id: \.self) { path in
                        Button {
                            chosen = path
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "folder")
                                    .foregroundStyle(theme.accentText)
                                    .frame(width: 24)
                                Text(DisplayText.fileName(path))
                                    .foregroundStyle(theme.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if chosen == path {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(theme.accentText)
                                        .fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen == path ? [.isSelected] : [])
                    }
                } header: {
                    SectionHeader(title: "Folders")
                }
                .listRowBackground(theme.surface)

                Section {
                    HStack(spacing: Spacing.sm) {
                        TextField("New folder name", text: $newName)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { create() }
                        if isCreating {
                            ProgressView()
                        } else {
                            Button("Create") { create() }
                                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } header: {
                    SectionHeader(title: "Or make a new folder")
                } footer: {
                    Text(createFailed
                         ? "That folder could not be made. Try another name."
                         : "Letters, numbers, dots and dashes. Anything else becomes an underscore.")
                        .font(.brand(.footnote))
                        .foregroundStyle(createFailed ? theme.danger : theme.textTertiary)
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle("Upload to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose files") {
                        if let chosen { onChoose(chosen) }
                        dismiss()
                    }
                    .disabled(chosen == nil)
                }
            }
            .onAppear { if chosen == nil { chosen = initial } }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isCreating else { return }
        isCreating = true
        createFailed = false
        Task {
            let path = await createFolder(name)
            isCreating = false
            if let path {
                extraFolders.append(path)
                chosen = path
                newName = ""
            } else {
                createFailed = true
            }
        }
    }
}

/// A section header with a sort menu at its trailing edge: "Folders · 12" and "Newest first ⌄".
struct FolderSortHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    var count: Int?
    let sort: FolderSort
    let onSort: (FolderSort) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionHeader(title: title, detail: count.map { "\($0)" })
            Spacer(minLength: Spacing.sm)
            Menu {
                Picker("Sort folders", selection: Binding(get: { sort }, set: onSort)) {
                    ForEach(FolderSort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(sort.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.brand(.footnote, weight: .medium))
                .foregroundStyle(theme.accentText)
                .textCase(nil)
            }
            .accessibilityLabel("Sort folders, \(sort.label)")
        }
    }
}

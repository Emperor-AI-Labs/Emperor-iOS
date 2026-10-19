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
    /// Offers the top of My Files, as `""`. Only for a folder upload: a folder brings its own
    /// name and lands under it, where a loose file would sit with no matter at all.
    var allowsTopLevel = false
    /// The confirming button: "Choose files", or "Choose folder".
    var chooseLabel = "Choose files"

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
                    if allowsTopLevel {
                        DestinationRow(
                            title: "Top of My Files", systemImage: "tray.full",
                            isChosen: chosen == "") { chosen = "" }
                    }
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
                } footer: {
                    if allowsTopLevel {
                        Text("At the top, the folder keeps its own name. Inside a folder, it goes in under its own name.")
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.textTertiary)
                    }
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
                    Button(chooseLabel) {
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

/// One destination in the list: an icon, a name, and a tick on the chosen one.
private struct DestinationRow: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    let isChosen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(theme.accentText)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isChosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.accentText)
                        .fontWeight(.semibold)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
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
                // The words and chevron are small, but the control is a full touch target: 44
                // points each way, centred on them, without making the header any taller. The
                // chevron scales with the words rather than staying at a fixed 10 points.
                HStack(spacing: 4) {
                    Text(sort.label)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .fontWeight(.semibold)
                }
                .font(.brand(.footnote, weight: .medium))
                .foregroundStyle(theme.accentText)
                .textCase(nil)
                .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                .contentShape(Rectangle())
            }
            // Back to about the words' own height in the header's layout.
            .padding(.vertical, -(Layout.touchTarget - 20) / 2)
            .accessibilityLabel("Sort folders, \(sort.label)")
        }
    }
}

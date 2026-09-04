import SwiftUI

/// Asks before uploading a document the library already holds.
///
/// The default on every row is **skip**, which is the unusual choice and the deliberate one.
/// Everywhere else in this app the safe default is to keep going; here the user has already
/// said "upload these", so the question is not whether to act but whether to act *again*. A
/// second copy of an order filed under a second matter is the mess this exists to prevent, and
/// it is the outcome that cannot be undone from inside the app — there is no delete.
///
/// Skipping loses nothing: the document is already there.
struct DuplicateReviewSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let fileName: String
        let decision: DuplicateCheck.Decision
        var upload: Bool
    }

    @State var items: [Item]
    /// The files that need no question. Passed through untouched so the caller has one list.
    let cleared: [(url: URL, fileName: String)]
    let onConfirm: ([(url: URL, fileName: String)]) -> Void

    private var chosenCount: Int { items.filter(\.upload).count + cleared.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($items) { $item in
                        Toggle(isOn: $item.upload) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.fileName)
                                    .font(.brand(.subheadline))
                                    .lineLimit(1)
                                if let message = DuplicateCheck.message(
                                    for: item.decision, fileName: item.fileName) {
                                    Text(message)
                                        .font(.brand(.caption))
                                        .foregroundStyle(theme.textSecondary)
                                }
                            }
                        }
                        // The destructive one is worth colouring: replacing a different
                        // document with the same name is the only choice here that destroys
                        // something.
                        .tint(isOverwrite(item) ? theme.danger : theme.accent)
                    }
                } header: {
                    SectionHeader(
                        title: items.count == 1
                            ? "One of these is already in your library"
                            : "\(items.count) of these are already in your library")
                } footer: {
                    Text(cleared.isEmpty
                         ? "Turn on anything you want to upload again."
                         : "\(cleared.count) other \(cleared.count == 1 ? "document" : "documents") "
                           + "will be uploaded regardless.")
                        .font(.brand(.caption2))
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("Already in your library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosenCount == 0 ? "Upload nothing" : "Upload \(chosenCount)") {
                        onConfirm(
                            items.filter(\.upload).map { ($0.url, $0.fileName) } + cleared)
                        dismiss()
                    }
                    .disabled(chosenCount == 0)
                }
            }
        }
    }

    private func isOverwrite(_ item: Item) -> Bool {
        if case .wouldOverwrite = item.decision { return true }
        return false
    }
}

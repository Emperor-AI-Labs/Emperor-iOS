import SwiftUI

/// Fills in the `{{PLACEHOLDER}}` blanks a rewrite left behind.
///
/// The web renders these as inline chips inside a `contenteditable`, which is a good desktop
/// answer and a bad phone one: chips inside a growing text field fight the keyboard, the caret
/// and the autocorrect bar all at once. A short form above a live preview says the same thing
/// with none of that — and the preview matters, because what gets sent is the whole rewritten
/// prompt, not the answers.
struct EnhancedPromptSheet: View {
    let template: PromptTemplate
    /// Called with the answers when the user accepts, keyed by label. A label the user left
    /// blank may be absent or empty — `PromptTemplate.filled` treats both the same way.
    let onUse: ([String: String]) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(template.labels, id: \.self) { label in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(prompt(for: label))
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                            TextField("", text: binding(for: label), axis: .vertical)
                                .lineLimit(1...3)
                                .focused($focused, equals: label)
                                .submitLabel(.next)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(prompt(for: label))
                    }
                } header: {
                    Text("What's missing")
                } footer: {
                    Text(PromptEnhancerViewModel.Copy.fillFooter)
                }

                Section("Your question will read") {
                    Text(preview)
                        .font(.brand(.callout))
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                }
                .listRowBackground(theme.surfaceElevated)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle(PromptEnhancerViewModel.Copy.fillTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        onUse(values)
                        dismiss()
                    }
                }
            }
            .onAppear { focused = template.labels.first }
        }
    }

    private var preview: String { template.filled(with: values) }

    private func binding(for label: String) -> Binding<String> {
        Binding(
            get: { values[label] ?? "" },
            set: { values[label] = $0 })
    }

    /// The model writes labels in shouting caps because they are meant to be read as slots in
    /// a sentence, not as questions. Sentence-cased, they read as what they are: a question.
    private func prompt(for label: String) -> String {
        guard label == label.uppercased(), let first = label.first else { return label }
        return String(first) + label.dropFirst().lowercased()
    }
}

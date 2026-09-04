import SwiftUI

/// One tool's form, and the conversation it starts.
///
/// The form is built from `tool.inputs` rather than hand-laid-out per tool: twenty-nine
/// bespoke screens would drift from the registry the moment a field changed, and the registry is
/// the thing that is pinned against the platform.
///
/// **Run is enabled from the start.** Nearly every field is optional, and the platform made that
/// choice deliberately — these tools are meant to work off a record already attached to the
/// conversation, so a form that insists on being filled first turns a one-tap analysis into data
/// entry. Where a value is missing the prompt says so in words the model can act on, which is
/// why `ToolValues.text` takes a fallback rather than returning an empty string.
struct ToolFormView: View {
    @Environment(\.theme) private var theme

    let tool: ToolSpec

    @State private var values: [String: String] = [:]
    @State private var startedChatID: String?

    var body: some View {
        Form {
            Section {
                Text(tool.blurb)
                    .font(.brand(.callout))
                    .foregroundStyle(theme.textSecondary)
            }

            Section {
                ForEach(tool.inputs) { field in
                    self.field(field)
                }
            } footer: {
                Text("Everything here is optional. Anything you leave blank, the assistant works out from the record.")
                    .font(.brand(.caption2))
            }

            Section {
                Button {
                    // A fresh conversation each run. Threading a second tool prompt into an
                    // existing thread would send the whole prior history back with it, and
                    // `POST /chat` rewrites what it receives.
                    startedChatID = ChatListViewModel.newChatID()
                } label: {
                    Text("Run")
                        .font(.brand(.headline))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $startedChatID) { id in
            ChatThreadView(chatID: id, seed: tool.prompt(ToolValues(values)))
        }
    }

    @ViewBuilder
    private func field(_ field: ToolField) -> some View {
        switch field.type {
        case .text:
            TextField(field.placeholder ?? field.label, text: binding(field.key))
                .accessibilityLabel(field.label)

        case .textarea:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
                TextField(
                    field.placeholder ?? field.label,
                    text: binding(field.key),
                    axis: .vertical)
                    // `big` marks the one field a whole record gets pasted into.
                    .lineLimit(field.big ? 6...14 : 2...6)
                    .accessibilityLabel(field.label)
            }

        case .select:
            Picker(field.label, selection: binding(field.key)) {
                // The registry's selects have no "unset" member, and the prompts read a blank
                // as "work it out from the record" — so an empty tag has to exist or the form
                // would silently commit to the first option on open.
                Text("Not specified").tag("")
                ForEach(field.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 })
    }
}

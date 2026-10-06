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
            // The tool's own tile beside what it does — the same tile it wears in the list.
            Section {
                HStack(alignment: .top, spacing: Spacing.md) {
                    IconTile(
                        systemImage: ToolSymbol.symbol(for: tool.id),
                        hue: TileHue.forTool(tool.id),
                        size: .large)
                    Text(tool.blurb)
                        .font(.brand(.callout))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Spacing.xs)
            }
            .listRowBackground(theme.surface)

            Section {
                ForEach(tool.inputs) { field in
                    self.field(field)
                }
            } footer: {
                Text("Everything here is optional. Anything you leave blank, the assistant works out from the record.")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
            .listRowBackground(theme.surface)

            Section {
                Button {
                    // A fresh conversation each run. Threading a second tool prompt into an
                    // existing thread would send the whole prior history back with it, and
                    // `POST /chat` rewrites what it receives.
                    startedChatID = ChatListViewModel.newChatID()
                } label: {
                    Text("Run")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryAction)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .font(.brand(.body))
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
            // A short answer, but one that wraps rather than scrolling out of sight sideways at
            // a large text size — "the Respondent, a statutory authority" is still one answer.
            TextField(
                field.label, text: binding(field.key), prompt: prompt(for: field), axis: .vertical)
                .lineLimit(1...4)
                .accessibilityLabel(field.label)

        case .textarea:
            VStack(alignment: .leading, spacing: Spacing.xs + 2) {
                // For the eye. The field below carries the same name for VoiceOver, so the label
                // is not read twice, once as text and once as the field.
                Text(field.label)
                    .font(.brand(.caption, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
                TextField(
                    field.label,
                    text: binding(field.key),
                    prompt: prompt(for: field),
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

    /// The field's example, in the palette's tertiary: the system's placeholder grey is too faint
    /// on a dark card to read.
    private func prompt(for field: ToolField) -> Text {
        Text(verbatim: field.placeholder ?? field.label).foregroundStyle(theme.textTertiary)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 })
    }
}

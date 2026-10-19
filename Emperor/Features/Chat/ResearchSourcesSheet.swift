import SwiftUI

/// The web's research "Sources" menu: Web search, then the jurisdictions and the repositories,
/// each a switch.
///
/// Web search is the same switch as "Always search the web" in the conversation's menu — one
/// value, `ResearchSources.webID`. The rest are remembered and sent nowhere, as on the web, and
/// the footer says so rather than letting a switch imply it narrows an answer.
struct ResearchSourcesSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let model: ResearchSourcesModel
    /// Told after every change, so the open conversation can follow the web-search switch.
    var onChange: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row(ResearchSources.web)
                } footer: {
                    footnote("Asks for a web search with every question while it is on.")
                }
                .listRowBackground(theme.surface)

                Section {
                    ForEach(ResearchSources.jurisdictions) { row($0) }
                } header: {
                    SectionHeader(title: "Jurisdictions")
                }
                .listRowBackground(theme.surface)

                Section {
                    ForEach(ResearchSources.repositories) { row($0) }
                } header: {
                    SectionHeader(title: "Repositories")
                } footer: {
                    footnote(ResearchSources.footer)
                }
                .listRowBackground(theme.surface)
            }
            .font(.brand(.body))
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ source: ResearchSource) -> some View {
        Toggle(isOn: Binding(
            get: { model.isOn(source.id) },
            set: { on in
                guard on != model.isOn(source.id) else { return }
                Haptics.selection()
                model.toggle(source.id)
                onChange()
            }
        )) {
            HStack(spacing: Spacing.md) {
                Group {
                    if let flag = source.flag {
                        Text(verbatim: flag)
                    } else if let symbol = source.systemImage {
                        Image(systemName: symbol)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .frame(width: 24)
                .accessibilityHidden(true)
                Text(source.label)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(theme.accentText)
        .accessibilityLabel(source.label)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.brand(.caption))
            .foregroundStyle(theme.textTertiary)
    }
}

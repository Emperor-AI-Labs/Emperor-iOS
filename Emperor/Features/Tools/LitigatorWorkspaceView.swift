import SwiftUI

/// Litigator's workspace — the platform's drafting taxonomy, laid out for a phone.
///
/// On the web this role's Home is not a card deck. It is a matter chooser (`MatterSeg`: Civil,
/// Criminal, then ten practice areas) over heading cards, one per section, and a page per matter
/// that narrows Civil and Criminal to a proceeding and lists every document
/// (`pages/home/RoleCards.jsx`, `pages/LitigatorMatter.jsx`). Here those are one screen, top to
/// bottom: the matter as a strip of chips, the proceeding where the matter has them, then each
/// section's documents under its heading — with the heading card's own form as the section's last
/// row, for "one of these, I will say which on the form".
///
/// A document opens in `ToolFormView`, like every other tool, and runs the prompt the web sends
/// for the same id; `LitigatorGoldenTests` holds every one of them to the platform's output. What
/// the screen shows, and in what order, is `LitigatorWorkspaceModel`'s.
struct LitigatorWorkspaceView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// The matter is a device preference, as the web keeps it — so it is read from, and written
    /// to, the same store as the role and the appearance.
    @State private var model = LitigatorWorkspaceModel(store: Preferences())

    var body: some View {
        NavigationStack {
            List {
                Section {
                    matterStrip
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    matterHeader
                    if !model.proceedings.isEmpty {
                        proceedingPicker
                    }
                } footer: {
                    Text(model.stageNote ?? "Pick a document to open its form.")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
                .listRowBackground(theme.surface)

                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.documents) { document in
                            documentRow(document)
                        }
                        anyDocumentRow(group)
                    } header: {
                        SectionHeader(title: group.title, detail: "\(group.documents.count)")
                    }
                    .listRowBackground(theme.surface)
                }

                if model.groups.isEmpty {
                    // Unreachable by construction — `LitigatorWorkspaceTests` walks every matter
                    // and proceeding — but if the platform's taxonomy ever leaves a stage with
                    // nothing in it, this says so and offers the way back rather than going blank.
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Nothing is drafted at this stage.")
                                .font(.brand(.subheadline, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                            Button("Show every stage") { model.select(proceeding: nil) }
                                .font(.brand(.subheadline))
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle(PractitionerRole.litigator.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { toolID in
                if let tool = roleTool(toolID) {
                    ToolFormView(tool: tool)
                } else {
                    // Ids arrive off a navigation route, so an unknown one says so rather than
                    // showing an empty form.
                    ContentUnavailableView("Document unavailable", systemImage: "doc.text")
                }
            }
        }
    }

    // MARK: - The matter

    /// Civil, Criminal and the practice areas, as chips — the web's `MatterSeg`, which wraps to
    /// rows on a wide screen. A phone scrolls it sideways instead, and keeps the chosen chip in
    /// view: the remembered matter may be the last of twelve.
    private var matterStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.matters) { matter in
                        chip(matter)
                            .id(matter.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .onAppear {
                proxy.scrollTo(model.matter.id, anchor: .center)
            }
            .onChange(of: model.matter.id) { _, id in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func chip(_ matter: LitigatorMatter) -> some View {
        let isSelected = model.matter.id == matter.id
        // Spelled out rather than an implicit member on each side of the ternary: `brand` takes
        // an `Optional` weight, which `-parse` accepts and the type checker then argues with.
        let weight: Font.Weight? = isSelected ? Font.Weight.semibold : Font.Weight.regular
        return Button {
            model.select(matter)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: matter.systemImage)
                Text(matter.chipLabel)
            }
            .font(.brand(.subheadline, weight: weight))
            .foregroundStyle(isSelected ? theme.onAccent : theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? theme.accent : theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
        // The chip may say "Labour"; VoiceOver says what it is.
        .accessibilityLabel(matter.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("matter-\(matter.id)")
    }

    private var matterHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(model.matter.label)
                        .font(.brand(.title3, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                } icon: {
                    Image(systemName: model.matter.systemImage)
                        .foregroundStyle(theme.accentText)
                }
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                StatusPill(text: "\(model.documentCount) documents", tone: .accent)
            }
            Text(model.summary)
                .font(.brand(.footnote))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    /// The web's "Selector 2": the proceeding a Civil or Criminal matter is narrowed to, which
    /// hides the stages that kind of case never reaches.
    private var proceedingPicker: some View {
        Picker(
            "Proceeding / case type",
            selection: Binding(
                get: { model.proceeding ?? "" },
                set: { model.select(proceeding: $0.isEmpty ? nil : $0) }
            )
        ) {
            Text("All / any stage").tag("")
            ForEach(model.proceedings, id: \.self) { proceeding in
                Text(proceeding).tag(proceeding)
            }
        }
        .pickerStyle(.menu)
        .font(.brand(.subheadline))
        .accessibilityIdentifier("litigator-proceeding")
    }

    // MARK: - The documents

    private func documentRow(_ document: LitigatorDocumentRow) -> some View {
        NavigationLink(value: document.id) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.accentText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.label)
                        .font(.brand(.subheadline, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = document.note {
                        Text(note)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier(document.id)
    }

    /// The section's heading form — the web's heading card — whose first field chooses which of
    /// the section's documents to draft.
    private func anyDocumentRow(_ group: LitigatorSectionGroup) -> some View {
        NavigationLink(value: group.id) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.accentText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.anyDocumentLabel)
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("One form — choose the document on it")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier(group.id)
    }
}

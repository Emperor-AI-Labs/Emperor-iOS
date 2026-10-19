import SwiftUI

/// New matter, as quick as adding a case: a name, a banner, a folder colour, then the court case —
/// found in the court records, not filed yet, or added later. Everything it decides is
/// `NewMatterViewModel`'s; this lays it out.
struct NewMatterSheet: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// The user's matters, so a new one gets the banner they have used least.
    var existing: [Project] = []
    /// Called with the new matter's id once it exists, and the web's word on it.
    let onCreated: (_ projectID: String, _ message: String?) -> Void

    @State private var model: NewMatterViewModel?
    @State private var isFinding = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    form(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(NewMatterViewModel.Copy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task {
                guard model == nil else { return }
                model = NewMatterViewModel(
                    projects: session.projects, cases: session.cases, courts: session.courtSearch,
                    existing: existing)
            }
            .sheet(isPresented: $isFinding) {
                CourtSearchView(purpose: .pick, onSaved: {}, onPick: { model?.usePick($0) })
                    .pageSizedSheet()
            }
        }
        .interactiveDismissDisabled(model?.isBusy ?? false)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .disabled(model?.isBusy ?? false)
        }
        ToolbarItem(placement: .confirmationAction) {
            if let model, model.isBusy {
                ProgressView()
            } else {
                Button("Create matter") { create() }
                    .disabled(!(model?.canCreate ?? false))
            }
        }
    }

    private func create() {
        guard let model else { return }
        Task {
            if let id = await model.create() {
                onCreated(id, model.toast)
                dismiss()
            }
        }
    }

    private func form(_ model: NewMatterViewModel) -> some View {
        Form {
            nameSection(model)
            lookSection(model)
            courtSection(model)
            statusSection(model)
        }
        .scrollContentBackground(.hidden)
        .background(theme.groupedBackground)
    }

    private func nameSection(_ model: NewMatterViewModel) -> some View {
        @Bindable var bindable = model
        return Section {
            TextField(model.namePlaceholder, text: $bindable.name, axis: .vertical)
                .accessibilityLabel("Matter name")
                .submitLabel(.done)
        } header: {
            Text("Matter name")
        } footer: {
            if model.showsNamedAfterCase {
                Text(NewMatterViewModel.Copy.namedAfterCase)
            }
        }
    }

    private func lookSection(_ model: NewMatterViewModel) -> some View {
        @Bindable var bindable = model
        return Section {
            BannerPreview(preset: model.banner, name: model.shownName)
                .listRowInsets(EdgeInsets())
            BannerPresetPicker(selection: $bindable.banner)
            FolderColourPicker(selection: $bindable.color)
        } header: {
            Text("Banner and folder colour")
        }
    }

    private func courtSection(_ model: NewMatterViewModel) -> some View {
        Section {
            Picker("Court case", selection: Binding(get: { model.court }, set: { model.choose($0) })) {
                ForEach(NewMatterCourtChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            if model.isFinding {
                pickedCase(model)
            }
        } header: {
            Text("Court case")
        } footer: {
            Text(model.courtNote)
        }
    }

    @ViewBuilder
    private func pickedCase(_ model: NewMatterViewModel) -> some View {
        if let pick = model.pick {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(pick.displayTitle)
                    .font(.brand(.body, weight: .semibold))
                    .dynamicLineLimit(3)
                Text([pick.courtName, pick.reference].compactMap { $0 }.joined(separator: " · "))
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Button("Change") { isFinding = true }
            Button("Clear", role: .destructive) { model.clearPick() }
        } else {
            Button {
                isFinding = true
            } label: {
                Label("Find in court records", systemImage: "magnifyingglass")
            }
        }
    }

    @ViewBuilder
    private func statusSection(_ model: NewMatterViewModel) -> some View {
        if let busy = model.busy {
            Section {
                Label(busy, systemImage: "hourglass")
                    .foregroundStyle(theme.textSecondary)
            }
        } else if let error = model.error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(theme.danger)
            }
        } else {
            Section {
                EmptyView()
            } footer: {
                Text(NewMatterViewModel.Copy.footnote)
            }
        }
    }
}

/// The banner as the matter will wear it, with its name on a dark plate.
private struct BannerPreview: View {
    let preset: BannerPreset
    let name: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BannerGradient(preset: preset)
            Text(name)
                .font(.brand(.headline, weight: .semibold))
                .foregroundStyle(.white)
                .dynamicLineLimit(2)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(Spacing.md)
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Banner preview: \(name)")
    }
}

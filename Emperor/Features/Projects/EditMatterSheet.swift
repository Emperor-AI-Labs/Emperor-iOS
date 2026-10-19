import SwiftUI

/// "Edit matter details" — every field a matter has, as the web's form lists them, saved with
/// `POST /project`. Everything it decides is `EditMatterViewModel`'s and `MatterEditDraft`'s.
///
/// Reached from a row's context menu in the matter list. The matter workspace's toolbar menu is
/// the other place the web offers it.
struct EditMatterSheet: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    let project: Project
    /// The saved matter, and the web's word on it.
    let onSaved: (_ project: Project, _ message: String?) -> Void

    @State private var model: EditMatterViewModel?
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
            .navigationTitle(EditMatterViewModel.Copy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task {
                guard model == nil else { return }
                model = EditMatterViewModel(
                    project: project, service: session.projects,
                    tracker: CaseTracker(cases: session.cases, courts: session.courtSearch))
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
                Button("Save changes") { save() }
                    .disabled(!(model?.canSave ?? false))
            }
        }
    }

    private func save() {
        guard let model else { return }
        Task {
            if let saved = await model.save() {
                onSaved(saved, model.toast)
                dismiss()
            }
        }
    }

    private func form(_ model: EditMatterViewModel) -> some View {
        Form {
            partiesSection(model)
            courtSection(model)
            progressSection(model)
            lookSection(model)
            if let busy = model.busy {
                Section { Label(busy, systemImage: "hourglass").foregroundStyle(theme.textSecondary) }
            } else if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.groupedBackground)
    }

    private func partiesSection(_ model: EditMatterViewModel) -> some View {
        @Bindable var bindable = model
        return Section {
            TextField("Matter name", text: $bindable.draft.name, axis: .vertical)
            TextField("Client — who you act for", text: $bindable.draft.client)
            TextField("Opposite party", text: $bindable.draft.oppositeParty)
            optionPicker("Your side", options: model.ourSideOptions, selection: $bindable.draft.ourSide)
            if model.draft.ourSide == "other" {
                TextField("Your side, in words — Caveator, intervenor…", text: $bindable.draft.ourSideText)
            }
            optionPicker("Practice area", options: model.practiceAreaOptions, selection: $bindable.draft.practiceArea)
        } header: {
            Text("The matter")
        }
    }

    private func courtSection(_ model: EditMatterViewModel) -> some View {
        @Bindable var bindable = model
        return Section {
            if model.canFindCase {
                Button {
                    isFinding = true
                } label: {
                    Label(model.attached == nil ? "Find in court records" : "Change the case", systemImage: "magnifyingglass")
                }
            }
            if model.attached != nil {
                Button("Clear the case", role: .destructive) { model.clearCase() }
            }
            if model.offersNotFiled {
                Toggle("Not filed yet", isOn: $bindable.draft.notFiled)
            }
            optionPicker("Forum", options: MatterForum.options, selection: $bindable.draft.forumType)
            TextField("Court / forum name", text: $bindable.draft.forumName)
            TextField("Case type — CS(OS)", text: $bindable.draft.caseType)
            TextField("Case number", text: $bindable.draft.caseNumber)
            TextField("Year", text: $bindable.draft.caseYear)
                .keyboardType(.numberPad)
            TextField("CNR / diary no.", text: $bindable.draft.cnr)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        } header: {
            Text("Court and case")
        } footer: {
            if model.attached != nil {
                Text(EditMatterViewModel.Copy.attachedNote)
            } else if model.hasLinkedCase {
                Text(EditMatterViewModel.Copy.linkedNote)
            } else if model.draft.notFiled {
                Text(EditMatterViewModel.Copy.notFiledNote)
            }
        }
    }

    private func progressSection(_ model: EditMatterViewModel) -> some View {
        @Bindable var bindable = model
        return Section {
            TextField("Stage — Pleadings / Evidence / Arguments", text: $bindable.draft.stage)
            NextHearingField(day: $bindable.draft.nextHearingDate)
            optionPicker(
                "Status",
                options: MatterStatusFilter.allCases.filter { $0 != .all }.map { ($0.rawValue, $0.label) },
                selection: $bindable.draft.status)
            optionPicker("Priority", options: MatterPriority.options, selection: $bindable.draft.priority)
            TextField(
                "What the dispute is about and the relief sought — what a colleague should know first.",
                text: $bindable.draft.description, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityLabel("Description")
        } header: {
            Text("Where it stands")
        }
    }

    private func lookSection(_ model: EditMatterViewModel) -> some View {
        @Bindable var bindable = model
        return Section {
            BannerPresetPicker(selection: Binding(
                get: { model.bannerPreset },
                set: { model.pickPreset($0) }))
            if model.hasImageBanner {
                Text("The uploaded picture is kept until you pick a preset.")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
            }
            FolderColourPicker(selection: $bindable.draft.color)
        } header: {
            Text("Banner and folder colour")
        }
    }

    private func optionPicker(
        _ title: String, options: [MatterVocabulary.Option], selection: Binding<String>
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(options, id: \.key) { option in
                Text(option.label).tag(option.key)
            }
        }
    }
}

/// A next-hearing day that may be blank: a switch, then the date, held as `YYYY-MM-DD` in India.
private struct NextHearingField: View {
    @Binding var day: String

    var body: some View {
        Toggle("Next hearing", isOn: Binding(
            get: { !day.isEmpty },
            set: { on in day = on ? (day.isEmpty ? WireDate.todayKey() : day) : "" }))
        if !day.isEmpty {
            DatePicker(
                "Date",
                selection: Binding(
                    get: { WireDate.parseDay(day) ?? Date() },
                    set: { day = WireDate.dayKey($0) }),
                displayedComponents: .date)
                .environment(\.timeZone, WireDate.india)
        }
    }
}

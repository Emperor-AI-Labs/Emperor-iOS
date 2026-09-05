import SwiftUI
import UIKit

/// Looks a case up at the court and pins it to the dashboard.
///
/// This is the screen that turns the app from a viewer into a client: before it, a matter could
/// only be added from a desktop. It is presented as a sheet from the docket rather than a tab,
/// because adding a case is something you do occasionally and finish, not somewhere you live.
struct CourtSearchView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Called after a case is pinned, so the docket behind this sheet reloads.
    let onSaved: () -> Void

    @State private var model: CourtSearchViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(CourtSearchViewModel.Copy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard model == nil else { return }
                model = CourtSearchViewModel(
                    service: session.courtSearch,
                    metadata: session.courtMetadata,
                    onSaved: onSaved)
            }
        }
    }

    private func content(_ model: CourtSearchViewModel) -> some View {
        @Bindable var model = model

        return Form {
            Section {
                NavigationLink {
                    CourtPicker(model: model)
                } label: {
                    LabeledContent("Court") {
                        Text(model.court?.name ?? "Choose")
                            .foregroundStyle(
                                model.court == nil ? theme.textTertiary : theme.textPrimary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                // Only where there is a choice. Ten tribunals and three consumer fora publish no
                // pre-registration lookup, so offering the pill and refusing it would be worse
                // than never showing it.
                if model.query.forum.availableModes.count > 1 {
                    Picker("Search by", selection: Binding(
                        get: { model.query.mode },
                        set: { model.setMode($0) }
                    )) {
                        ForEach(model.query.forum.availableModes) { mode in
                            Text(mode.label(for: model.query.forum)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
            }

            fields(model)
            searchSection(model)

            if let notice = model.notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle")
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.success)
                }
            }

            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.danger)
                }
            }

            resultsSection(model)
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .sheet(isPresented: Binding(
            get: { model.isShowingCaptcha },
            set: { if !$0 { model.dismissCaptcha() } }
        )) {
            CaptchaSheet(model: model)
        }
    }

    // MARK: - The form

    /// The form, built from what the court said it needs rather than from a list of courts.
    ///
    /// The web branches per court here; this reads the fetched contract instead. There are 48
    /// courts and the shape of the form is the server's answer, so a `switch` would be 48 cases
    /// that drift the moment a tribunal gains a bench.
    @ViewBuilder
    private func fields(_ model: CourtSearchViewModel) -> some View {
        @Bindable var model = model

        if let court = model.court {
            if !court.isSearchable {
                Section {
                    Label(CourtSearchViewModel.Copy.notSearchable, systemImage: "info.circle")
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                Section {
                    // DCDRC only. Its commissions are not published flat — they are reached a
                    // state at a time, which is the one two-hop cascade in this form.
                    if model.query.benchCascade {
                        optionPicker(
                            "State", options: model.consumerStates,
                            selection: model.query.consumerStateID,
                            isLoading: model.loadingBenches && model.benches.isEmpty
                        ) { option in
                            Task { await model.selectConsumerState(option) }
                        }
                    }

                    if model.query.requiresBench {
                        optionPicker(
                            model.query.benchLabel, options: model.benches,
                            selection: model.query.bench,
                            isLoading: model.loadingBenches
                        ) { option in
                            Task { await model.selectBench(option) }
                        }
                    }

                    if model.contract.takesCaseType {
                        optionPicker(
                            "Case type", options: model.caseTypes,
                            selection: model.query.caseType,
                            isLoading: model.loadingCaseTypes
                        ) { option in
                            model.selectCaseType(option)
                        }
                    }

                    numberField(model)

                    // A consumer-forum case number carries its own year, and a tribunal filing
                    // number goes straight to the matter. Neither takes one.
                    if model.query.forum != .consumerForum,
                       !(model.query.mode == .diaryNumber
                         && (model.query.forum == .nclt || model.query.forum == .nclat)) {
                        yearField(model)
                    }
                } header: {
                    Text(court.name)
                } footer: {
                    if model.expectsLongWait {
                        Text(CourtSearchViewModel.Copy.captchaWait)
                    }
                }
            }
        }
    }

    /// A dropdown that shows its own loading state.
    ///
    /// Per control rather than one flag over the whole form: the case types arrive after the
    /// bench, and greying the number field while they load stops someone typing a number they
    /// already know.
    @ViewBuilder
    private func optionPicker(
        _ label: String,
        options: [CourtOption],
        selection: String,
        isLoading: Bool,
        onSelect: @escaping (CourtOption) -> Void
    ) -> some View {
        if isLoading {
            HStack {
                Text(label)
                Spacer()
                ProgressView().controlSize(.small)
            }
        } else if options.isEmpty {
            // Distinguished from "still loading": the court answered and had none. Saying so
            // beats an empty menu that looks broken.
            LabeledContent(label) {
                Text("None offered").foregroundStyle(theme.textTertiary)
            }
        } else {
            Picker(label, selection: Binding(
                get: { selection },
                set: { value in
                    guard let option = options.first(where: { $0.value == value }) else { return }
                    onSelect(option)
                }
            )) {
                Text("Choose").tag("")
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
        }
    }

    private func numberField(_ model: CourtSearchViewModel) -> some View {
        @Bindable var model = model
        return TextField(
            model.query.forum.numberLabel(for: model.query.mode), text: $model.query.number)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
    }

    private func yearField(_ model: CourtSearchViewModel) -> some View {
        @Bindable var model = model
        return TextField("Year", text: $model.query.year)
            .keyboardType(.numberPad)
    }

    @ViewBuilder
    private func searchSection(_ model: CourtSearchViewModel) -> some View {
        Section {
            Button {
                model.search()
            } label: {
                HStack {
                    Spacer()
                    if model.isSearching {
                        ProgressView().controlSize(.small)
                        Text(CourtSearchViewModel.Copy.searching)
                    } else {
                        Text(CourtSearchViewModel.Copy.searchButton)
                    }
                    Spacer()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canSearch)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            // Only while it is running. A High Court lookup opens up to eight sessions with the
            // court and can hold the screen for most of a minute; someone who spots a typo two
            // seconds in should not have to sit out the other fifty-eight.
            if model.isSearching {
                Button(role: .cancel) {
                    model.cancelSearch()
                } label: {
                    HStack {
                        Spacer()
                        Text("Stop searching")
                        Spacer()
                    }
                }
                .buttonStyle(.borderless)
                .listRowBackground(Color.clear)
            }
        } footer: {
            // Said out loud, because the server reports an incomplete form as "could not reach
            // the court" — so without this the user blames the court and retries forever.
            if let notice = model.incompleteNotice {
                Text(notice)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultsSection(_ model: CourtSearchViewModel) -> some View {
        if model.hasSearched, model.results.isEmpty, !model.isSearching {
            Section {
                Text(model.emptyMessage)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
            }
        } else if !model.results.isEmpty {
            Section("Found at the court") {
                ForEach(model.results) { result in
                    resultRow(model, result)
                }
            }
        }
    }

    private func resultRow(
        _ model: CourtSearchViewModel, _ result: CourtSearchResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.displayTitle)
                .font(.brand(.callout, weight: .medium))
                .foregroundStyle(theme.textPrimary)

            if let reference = result.reference {
                Text(reference)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }

            HStack(spacing: 8) {
                if let status = result.status, !status.isEmpty {
                    StatusPill(text: status)
                }
                if let court = result.courtName, !court.isEmpty {
                    Text(court)
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                }
            }

            if let warning = model.collisionWarning(for: result) {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.warning)
            }

            saveButton(model, result)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func saveButton(
        _ model: CourtSearchViewModel, _ result: CourtSearchResult
    ) -> some View {
        if model.isSaved(result) {
            Label(CourtSearchViewModel.Copy.savedLabel, systemImage: "checkmark.circle.fill")
                .font(.brand(.caption, weight: .medium))
                .foregroundStyle(theme.success)
        } else {
            Button {
                model.save(result)
            } label: {
                HStack(spacing: 6) {
                    if model.savingID == result.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle")
                    }
                    Text(CourtSearchViewModel.Copy.saveButton)
                }
                .font(.brand(.caption, weight: .medium))
            }
            .buttonStyle(.borderless)
            // Saving re-scrapes the court before it answers, so one at a time.
            .disabled(model.savingID != nil)
        }
    }
}

/// Choosing one of forty-eight courts.
///
/// A searchable pushed list rather than a wheel or a segmented control. The web uses a single
/// grouped `<select>`, which is workable with a mouse and unusable on a phone — nobody scrolls
/// fifty rows to find "Debts Recovery Appellate Tribunal".
///
/// The district and subordinate courts are **listed and disabled**. Hiding them would be easier
/// and worse: a great deal of Indian litigation happens there, and a picker that silently omits
/// them reads as a product that has not heard of district courts rather than one that knows
/// exactly what it cannot do yet.
private struct CourtPicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let model: CourtSearchViewModel

    @State private var query = ""

    private var sections: [(title: String, courts: [Court])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CourtCatalogue.sections }
        return CourtCatalogue.sections.compactMap { section in
            let matching = section.courts.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
            }
            return matching.isEmpty ? nil : (section.title, matching)
        }
    }

    var body: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.courts) { court in
                        row(court)
                    }
                } footer: {
                    if section.courts.contains(where: { !$0.isSearchable }) {
                        Text(CourtSearchViewModel.Copy.notSearchable)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .searchable(text: $query, prompt: "Search courts")
        .navigationTitle("Court")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    @ViewBuilder
    private func row(_ court: Court) -> some View {
        Button {
            Task { await model.selectCourt(court) }
            dismiss()
        } label: {
            HStack {
                Text(court.name)
                    .foregroundStyle(court.isSearchable ? theme.textPrimary : theme.textTertiary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if model.court?.id == court.id {
                    Image(systemName: "checkmark").foregroundStyle(theme.accent)
                } else if !court.isSearchable {
                    // Says which of the two it is: not "coming soon", but "this app cannot look
                    // this one up". The section footer carries the reason.
                    Text("Not yet searchable")
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!court.isSearchable)
    }
}

/// Where a person solves the Supreme Court's CAPTCHA because the server could not.
///
/// Reached only when `/court/sc/auto` has already spent six attempts on it, so nobody is being
/// asked to do this routinely — it is the recovery path for the one forum that has one, and
/// without it a failed OCR is a dead end.
///
/// The image is drawn on white deliberately. The court serves a transparent PNG, which on a dark
/// background renders as dark strokes on dark and cannot be read at all.
private struct CaptchaSheet: View {
    @Environment(\.theme) private var theme
    let model: CourtSearchViewModel

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(.white)
                            if let image = model.captcha?.image,
                               let rendered = UIImage(data: image) {
                                Image(uiImage: rendered)
                                    .resizable()
                                    .scaledToFit()
                                    .padding(4)
                                    .accessibilityLabel("CAPTCHA image")
                            } else {
                                ProgressView()
                            }
                        }
                        .frame(width: 180, height: 60)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)

                    Button {
                        Task { await model.loadCaptcha() }
                    } label: {
                        Label("Show a different one", systemImage: "arrow.clockwise")
                            .font(.brand(.footnote))
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isLoadingCaptcha || model.isSubmittingCaptcha)
                } header: {
                    Text("Solve the Supreme Court CAPTCHA")
                } footer: {
                    Text(
                        "The court asks for this to prove a person is searching. "
                        + "Emperor tried and could not read it.")
                }

                Section {
                    TextField("Type the answer", text: $model.captchaAnswer)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { Task { await model.submitCaptcha() } }
                } footer: {
                    if let error = model.captchaError {
                        Text(error).foregroundStyle(theme.danger)
                    }
                }

                Section {
                    Button {
                        Task { await model.submitCaptcha() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isSubmittingCaptcha {
                                ProgressView().controlSize(.small)
                            }
                            Text("Find the case")
                            Spacer()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.canSubmitCaptcha)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("CAPTCHA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.dismissCaptcha() }
                }
            }
        }
    }
}

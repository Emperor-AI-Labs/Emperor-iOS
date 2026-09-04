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
                model = CourtSearchViewModel(service: session.courtSearch, onSaved: onSaved)
            }
        }
    }

    private func content(_ model: CourtSearchViewModel) -> some View {
        @Bindable var model = model

        return Form {
            Section {
                Picker("Court", selection: $model.query.forum) {
                    ForEach(CourtForum.allCases) { forum in
                        Text(forum.name).tag(forum)
                    }
                }
                .pickerStyle(.segmented)

                // Which number you have, not which route this calls. Most people looking a
                // matter up have the case number — it is what is printed on everything after
                // registration — so it leads.
                Picker("Search by", selection: Binding(
                    get: { model.query.mode },
                    set: { model.setMode($0) }
                )) {
                    ForEach(CourtSearchMode.allCases) { mode in
                        Text(mode.label(for: model.query.forum)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)

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

    @ViewBuilder
    private func fields(_ model: CourtSearchViewModel) -> some View {
        @Bindable var model = model

        Section {
            switch model.query.forum {
            case .supremeCourt:
                // A diary number identifies a matter on its own; a case number is only unique
                // within its type, so `SLP(C) 1234/2025` and `C.A. 1234/2025` are different
                // matters and the type is required.
                if model.query.mode == .caseNumber {
                    TextField("Case type", text: $model.query.caseType)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                numberField(model)
                yearField(model)
            case .highCourt:
                // Codes rather than names because eCourts identifies courts by them and the
                // server passes them straight through. A name-to-code list would have to be
                // shipped and would go stale silently.
                TextField("State code", text: $model.query.stateCode)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Court code", text: $model.query.courtCode)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Court complex code (optional)", text: $model.query.courtComplexCode)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Case type", text: $model.query.caseType)
                    .textInputAutocapitalization(.characters)
                numberField(model)
                yearField(model)
            case .nclt, .nclat:
                TextField("Bench", text: $model.query.bench)
                // `/search` filters the bench's listing on an exact number *and* year, so both
                // are required here — where a filing-number lookup goes straight to the matter
                // and needs neither.
                if model.query.mode == .caseNumber {
                    TextField("Case type", text: $model.query.caseType)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                numberField(model)
                if model.query.mode == .caseNumber {
                    yearField(model)
                }
            }
        } header: {
            Text(model.query.forum.name)
        } footer: {
            if model.expectsLongWait {
                Text(CourtSearchViewModel.Copy.captchaWait)
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

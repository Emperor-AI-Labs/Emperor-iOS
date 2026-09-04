import SwiftUI

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
    }

    // MARK: - The form

    @ViewBuilder
    private func fields(_ model: CourtSearchViewModel) -> some View {
        @Bindable var model = model

        Section {
            switch model.query.forum {
            case .supremeCourt:
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
                numberField(model)
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
        return TextField(model.query.forum.numberLabel, text: $model.query.number)
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

import SwiftUI

/// The web's Team dialog: make a team, and add someone to one by their email address.
///
/// A team is who shares tracked court cases — a member sees every case the team tracks under
/// Matters. Everything this sheet decides lives in `TeamsViewModel`.
struct TeamsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var model: TeamsViewModel?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    form(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(TeamsViewModel.Copy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard model == nil else { return }
                let created = TeamsViewModel(service: TeamService(client: session.client))
                model = created
                await created.load()
            }
        }
        .recordToast($toast)
    }

    private func form(_ model: TeamsViewModel) -> some View {
        Form {
            createSection(model)
            inviteSection(model)
            teamsSection(model)
        }
        .scrollContentBackground(.hidden)
        .background(theme.groupedBackground)
        .onChange(of: model.toast) { _, text in
            guard let text else { return }
            toast = text
            model.clearToast()
        }
    }

    private func createSection(_ model: TeamsViewModel) -> some View {
        @Bindable var bindable = model
        return Section {
            TextField(TeamsViewModel.Copy.createPlaceholder, text: $bindable.newTeamName)
                .accessibilityLabel("New team name")
                .submitLabel(.done)
                .onSubmit { Task { await model.create() } }
            Button("Create") { Task { await model.create() } }
                .disabled(!model.canCreate)
        } header: {
            Text(TeamsViewModel.Copy.createHeading)
        }
    }

    private func inviteSection(_ model: TeamsViewModel) -> some View {
        @Bindable var bindable = model
        return Section {
            if model.offersTeamPicker {
                Picker("Team", selection: Binding(
                    get: { model.inviteTeamID ?? "" },
                    set: { model.pickedTeamID = $0 })
                ) {
                    ForEach(model.invitable) { team in
                        Text(team.optionLabel).tag(team.id)
                    }
                }
            }
            TextField(TeamsViewModel.Copy.emailPlaceholder, text: $bindable.email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Email of the person to add")
                .onSubmit { Task { await model.invite() } }
            Button("Invite") { Task { await model.invite() } }
                .disabled(!model.canInvite)
            if let message = model.message {
                Label(message, systemImage: model.messageIsSuccess ? "checkmark" : "exclamationmark.triangle")
                    .font(.brand(.footnote))
                    .foregroundStyle(model.messageIsSuccess ? theme.success : theme.danger)
            }
        } header: {
            Text(model.inviteHeading)
        } footer: {
            Text(TeamsViewModel.Copy.footnote)
        }
    }

    @ViewBuilder
    private func teamsSection(_ model: TeamsViewModel) -> some View {
        if let failure = model.state.failure, model.teams.isEmpty {
            Section {
                Text(failure.message)
                    .foregroundStyle(theme.textSecondary)
                Button("Retry") { Task { await model.load() } }
            }
        } else if !model.teams.isEmpty {
            Section {
                ForEach(model.teams) { team in
                    ValueRow(team.displayName, value: memberLine(team))
                }
            } header: {
                Text("Your teams")
            }
        }
    }

    private func memberLine(_ team: Team) -> String {
        guard let count = team.memberCount else { return "" }
        return count == 1 ? "Just you" : "\(count) members"
    }
}

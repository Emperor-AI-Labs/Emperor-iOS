import SwiftUI

/// Add company / Edit company — the web's `CompanyModal`: a name, the six switches that decide
/// which statutory deadlines apply, the state (for Professional Tax) and the AGM date. Nothing is
/// assumed: a new company starts with every switch off.
///
/// The profile is kept on this device (`CompanyProfileStore`), as the web keeps it in the
/// browser; the sheet hands it back and the view model saves it.
struct CompanyProfileSheet: View {
    /// What the sheet starts from: a new company with a fresh id, or a copy of a saved one.
    let initial: CompanyProfile
    let isNew: Bool
    /// Saves, or returns the form's complaint.
    let onSave: (CompanyProfile) -> String?
    let onDelete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var company: CompanyProfile
    @State private var error: String?
    @State private var isConfirmingDelete = false

    init(
        initial: CompanyProfile, isNew: Bool,
        onSave: @escaping (CompanyProfile) -> String?, onDelete: @escaping (String) -> Void
    ) {
        self.initial = initial
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _company = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                switchesSection
                datesSection
                if !isNew { deleteSection }
            }
            .font(.brand(.body))
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle(isNew ? "Add company" : "Edit company")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .confirmationDialog(
                "Delete \(company.displayName)?", isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete company", role: .destructive) {
                    onDelete(company.id)
                    dismiss()
                }
            } message: {
                Text("Its deadlines leave this calendar. Anything already marked done stays recorded.")
            }
        }
    }

    private var nameSection: some View {
        Section {
            TextField("e.g. Acme Private Limited", text: $company.name)
                .textInputAutocapitalization(.words)
                .onChange(of: company.name) { _, _ in error = nil }
                .accessibilityLabel("Company name")
        } header: {
            Text("Company name")
        } footer: {
            if let error {
                Text(error)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.danger)
            } else {
                Text("Tell us about the company and the calendar tailors which statutory deadlines it shows. Everything else is filled in automatically.")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .listRowBackground(theme.surface)
    }

    private var switchesSection: some View {
        Section {
            ForEach(CompanyProfileSwitch.allCases) { flag in
                CompanySwitchRow(flag: flag, isOn: Binding(
                    get: { company[flag] },
                    set: { company[flag] = $0 }))
            }
        }
        .listRowBackground(theme.surface)
    }

    private var datesSection: some View {
        Section {
            Picker("State (for Professional Tax)", selection: $company.state) {
                Text("Not set").tag("")
                ForEach(ComplianceSchedule.indianStates, id: \.self) { Text($0).tag($0) }
            }
            Picker("AGM month", selection: agmMonth) {
                ForEach(1...12, id: \.self) { Text(CourtCalendar.monthNames[$0 - 1]).tag($0) }
            }
            Picker("AGM day", selection: $company.agmDay) {
                ForEach(Array(CompanyProfile.agmDays(inMonth: company.agmMonth)), id: \.self) {
                    Text("\($0)").tag($0)
                }
            }
        } footer: {
            Text("AOC-4, MGT-7, ADT-1 and CSR-2 run from the AGM date (\(company.agmLabel)).")
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
        }
        .listRowBackground(theme.surface)
    }

    /// Changing the month pulls the day back inside it, as a date picker would.
    private var agmMonth: Binding<Int> {
        Binding(
            get: { company.agmMonth },
            set: { month in
                company.agmMonth = month
                company.agmDay = min(company.agmDay, CompanyProfile.agmDays(inMonth: month).upperBound)
            })
    }

    private var deleteSection: some View {
        Section {
            Button("Delete company", role: .destructive) { isConfirmingDelete = true }
        }
        .listRowBackground(theme.surface)
    }

    private func save() {
        if let complaint = onSave(company) {
            error = complaint
        } else {
            dismiss()
        }
    }
}

/// One switch, with the line saying what it adds.
private struct CompanySwitchRow: View {
    let flag: CompanyProfileSwitch
    @Binding var isOn: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.label)
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(flag.hint)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

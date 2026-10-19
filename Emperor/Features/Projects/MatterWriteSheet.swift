import SwiftUI

/// Adding to a matter: a task, a chronology entry, a fee / payment / expense, or a person.
///
/// One sheet, one form per kind. Every field a kind does not need is simply not shown, and a
/// blank optional is never sent — `ProjectService` omits it, so a save cannot clear anything.
/// The vocabularies are the web's (`MatterVocabulary`), so a kind chosen here is a kind the
/// web shows.
struct MatterWriteSheet: View {
    enum Kind: String, Identifiable {
        case task, event, fee, payment, expense, person
        var id: String { rawValue }

        var title: String {
            switch self {
            case .task: return "Add a task"
            case .event: return "Add to the chronology"
            case .fee: return "Record a fee"
            case .payment: return "Record a payment"
            case .expense: return "Record an expense"
            case .person: return "Add a person"
            }
        }
    }

    /// What the sheet hands back, ready for the view model.
    enum Draft {
        case task(TaskDraft)
        case event(UpdateDraft)
        case ledger(LedgerDraft)
        case person(PersonDraft)
    }

    let kind: Kind
    /// Unused by the forms today; carried so the Files destination picker can share this sheet.
    let destinations: [String]
    let onSave: (Draft) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var title = ""
    @State private var notes = ""
    @State private var hasDate = false
    @State private var date = Date()
    @State private var taskKind = MatterVocabulary.taskKinds[0].key
    @State private var priority = "normal"
    @State private var updateKind = MatterVocabulary.updateKinds[0].key
    @State private var amountText = ""
    @State private var mode = MatterVocabulary.paymentModes[0].key
    @State private var reference = ""
    @State private var category = MatterVocabulary.expenseCategories[0].key
    @State private var role = MatterVocabulary.peopleRoles[0].key
    @State private var phone = ""
    @State private var email = ""
    @State private var isSaving = false

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Rupees typed with or without commas and a ₹.
    private var amount: Double? {
        let cleaned = amountText.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "₹", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    private var canSave: Bool {
        switch kind {
        case .task, .event, .person: return !trimmedTitle.isEmpty
        case .fee, .payment, .expense: return amount != nil
        }
    }

    /// The day as the server stores it — in India, because that is where the court sits.
    private var dayKey: String? { hasDate ? WireDate.dayKey(date) : nil }

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .task: taskFields
                case .event: eventFields
                case .fee, .payment, .expense: moneyFields
                case .person: personFields
                }
            }
            .font(.brand(.body))
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave || isSaving)
                }
            }
        }
    }

    // MARK: - Forms

    private var taskFields: some View {
        Section {
            TextField("What needs doing", text: $title)
            Picker("Kind", selection: $taskKind) {
                ForEach(MatterVocabulary.taskKinds, id: \.key) { Text($0.label).tag($0.key) }
            }
            Picker("Priority", selection: $priority) {
                Text("Low").tag("low")
                Text("Normal").tag("normal")
                Text("High").tag("high")
            }
            Toggle("Due date", isOn: $hasDate)
            if hasDate {
                DatePicker("Due", selection: $date, displayedComponents: .date)
            }
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(2...6)
        } footer: {
            Text("A limitation or filing date here is a reminder on this matter. It does not change the court's record.")
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
        }
        .listRowBackground(theme.surface)
    }

    private var eventFields: some View {
        Section {
            TextField("What happened", text: $title)
            Picker("Kind", selection: $updateKind) {
                ForEach(MatterVocabulary.updateKinds, id: \.key) { Text($0.label).tag($0.key) }
            }
            Toggle("Date", isOn: $hasDate)
            if hasDate {
                DatePicker("On", selection: $date, displayedComponents: .date)
            }
            TextField("Details (optional)", text: $notes, axis: .vertical)
                .lineLimit(2...8)
        } footer: {
            Text("A hearing dated today or later becomes the matter's next hearing.")
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
        }
        .listRowBackground(theme.surface)
    }

    private var moneyFields: some View {
        Section {
            TextField("Amount in rupees", text: $amountText)
                .keyboardType(.decimalPad)
            TextField(kind == .expense ? "What for (optional)" : "Title (optional)", text: $title)
            if kind == .payment {
                Picker("Paid by", selection: $mode) {
                    ForEach(MatterVocabulary.paymentModes, id: \.key) { Text($0.label).tag($0.key) }
                }
                TextField("Reference (optional)", text: $reference)
            }
            if kind == .expense {
                Picker("Head", selection: $category) {
                    ForEach(MatterVocabulary.expenseCategories, id: \.key) { Text($0.label).tag($0.key) }
                }
            }
            Toggle("Date", isOn: $hasDate)
            if hasDate {
                DatePicker("On", selection: $date, displayedComponents: .date)
            }
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(2...6)
        } footer: {
            Text(kind == .fee
                 ? "A fee is what has been billed or agreed with the client."
                 : kind == .payment ? "A payment is money received from the client."
                 : "An expense is money spent on the matter.")
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
        }
        .listRowBackground(theme.surface)
    }

    private var personFields: some View {
        Section {
            TextField("Name", text: $title)
            Picker("Role", selection: $role) {
                ForEach(MatterVocabulary.peopleRoles, id: \.key) { Text($0.label).tag($0.key) }
            }
            TextField("Phone (optional)", text: $phone)
                .keyboardType(.phonePad)
            TextField("Email (optional)", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(2...6)
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        let draft = makeDraft()
        Task {
            await onSave(draft)
            isSaving = false
            dismiss()
        }
    }

    private func makeDraft() -> Draft {
        let optionalNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .task:
            return .task(TaskDraft(
                title: trimmedTitle, notes: optionalNotes.isEmpty ? nil : optionalNotes,
                dueDate: dayKey, kind: taskKind, priority: priority, status: "open"))
        case .event:
            return .event(UpdateDraft(
                kind: updateKind, title: trimmedTitle,
                body: optionalNotes.isEmpty ? nil : optionalNotes, eventDate: dayKey))
        case .fee, .payment, .expense:
            let ledgerKind: LedgerEntry.Kind = kind == .fee ? .fee : kind == .payment ? .payment : .expense
            return .ledger(LedgerDraft(
                kind: ledgerKind,
                title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                amount: amount ?? 0,
                entryDate: dayKey,
                mode: kind == .payment ? mode : nil,
                reference: kind == .payment && !reference.isEmpty ? reference : nil,
                category: kind == .expense ? category : nil,
                notes: optionalNotes.isEmpty ? nil : optionalNotes))
        case .person:
            return .person(PersonDraft(
                role: role, name: trimmedTitle,
                phone: phone.isEmpty ? nil : phone, email: email.isEmpty ? nil : email,
                address: nil, notes: optionalNotes.isEmpty ? nil : optionalNotes))
        }
    }
}

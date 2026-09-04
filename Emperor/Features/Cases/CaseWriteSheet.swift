import SwiftUI

/// Adding a note or a task to a matter.
///
/// The only two writes this app offers on a case, and both are insert-only. `POST /case-item`
/// upserts on `id` and its update branch is a **full replace** — every omitted field is set to
/// NULL (`sync-server.js:9857-9861`) — so there is no safe partial-edit path against this
/// server. Creating is safe; editing is not offered, rather than being offered and quietly
/// destructive.
struct CaseWriteSheet: View {
    enum Kind {
        case note, task

        var title: String {
            switch self {
            case .note: return "Add a note"
            case .task: return "Add a task"
            }
        }
    }

    let kind: Kind
    /// `(title, noteBody, dueDate)` — the caller uses the fields its kind needs.
    let onSave: (String?, String, Date?) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    /// Not named `body`: that would collide with the `View.body` requirement.
    @State private var noteBody = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var isSaving = false

    private var canSave: Bool {
        switch kind {
        case .note: return !noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .task: return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .note:
                    Section {
                        TextField("Title (optional)", text: $title)
                        TextField("What happened", text: $noteBody, axis: .vertical)
                            .lineLimit(4...12)
                    } footer: {
                        Text("Notes appear on this matter's timeline. They are yours — a court sync never overwrites them.")
                    }
                case .task:
                    Section {
                        TextField("What needs doing", text: $title)
                        Toggle("Due date", isOn: $hasDueDate)
                        if hasDueDate {
                            DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                        }
                    }
                }
            }
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

    private func save() {
        isSaving = true
        Task {
            await onSave(
                title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title,
                noteBody,
                hasDueDate ? dueDate : nil)
            isSaving = false
            dismiss()
        }
    }
}

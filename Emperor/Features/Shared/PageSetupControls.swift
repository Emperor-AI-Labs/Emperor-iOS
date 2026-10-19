import SwiftUI

/// "Page setup", inside the download menu: the paper with its dimensions, the orientation, and a
/// way to the margins — the web's `PageSetupMenu`, which sets the page every Word and PDF download
/// of a draft is laid out on. The choice is the account's on this device (`DocumentPageSetup`).
struct PageSetupSubmenu: View {
    let setup: DocumentPageSetup
    let onChange: (DocumentPageSetup) -> Void
    let onEditMargins: () -> Void

    var body: some View {
        Menu {
            Picker(selection: Binding(
                get: { setup.size.id },
                set: { id in
                    guard let size = DocumentPageSize.withID(id) else { return }
                    var next = setup
                    next.size = size
                    onChange(next)
                }
            )) {
                ForEach(DocumentPageSize.all) { size in
                    // The dimensions, so Legal and Letter are not a guess.
                    Text("\(size.label) · \(size.dimensionsLabel)").tag(size.id)
                }
            } label: {
                Text("Page size")
            }
            .pickerStyle(.inline)

            Picker(selection: Binding(
                get: { setup.orientation },
                set: { orientation in
                    var next = setup
                    next.orientation = orientation
                    onChange(next)
                }
            )) {
                ForEach(DocumentPageOrientation.allCases) { orientation in
                    Text(orientation.label).tag(orientation)
                }
            } label: {
                Text("Orientation")
            }
            .pickerStyle(.inline)

            Button(action: onEditMargins) {
                Label("Margins…", systemImage: "square.dashed")
            }
        } label: {
            Label {
                Text("Page setup")
                Text(setup.label)
            } icon: {
                Image(systemName: "doc.plaintext")
            }
        }
    }
}

/// The four margins, in millimetres, typed rather than dragged — a registry's rule is a number.
struct PageMarginsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let setup: DocumentPageSetup
    let onSave: (DocumentPageSetup) -> Void

    @State private var top: Double = DocumentPageMargins.default.top
    @State private var right: Double = DocumentPageMargins.default.right
    @State private var bottom: Double = DocumentPageMargins.default.bottom
    @State private var left: Double = DocumentPageMargins.default.left

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MarginField(title: "Top", value: $top)
                    MarginField(title: "Bottom", value: $bottom)
                    MarginField(title: "Left", value: $left)
                    MarginField(title: "Right", value: $right)
                } header: {
                    SectionHeader(title: "Margins in millimetres")
                } footer: {
                    Text("\(setup.size.label) · \(setup.orientation.label). A margin outside 0–80 mm goes back to its default.")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                }
                .listRowBackground(theme.surface)

                Section {
                    Button("Use the default margins") {
                        let d = DocumentPageMargins.default
                        top = d.top; right = d.right; bottom = d.bottom; left = d.left
                    }
                } footer: {
                    Text("25 mm top, bottom and left; 20 mm right — the same page the web sets up.")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                }
                .listRowBackground(theme.surface)
            }
            .font(.brand(.body))
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle("Margins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(setup.with(margins: DocumentPageMargins(
                            top: top, right: right, bottom: bottom, left: left)))
                        dismiss()
                    }
                }
            }
            .onAppear {
                top = setup.margins.top
                right = setup.margins.right
                bottom = setup.margins.bottom
                left = setup.margins.left
            }
        }
    }
}

/// One margin: its name, and the number in millimetres.
private struct MarginField: View {
    @Environment(\.theme) private var theme
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: Spacing.md)
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
                .accessibilityLabel("\(title) margin, millimetres")
            Text("mm")
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
        }
    }
}

import SwiftUI

/// The Limitation Landmine Radar: is the suit in time, and by how much?
///
/// The web's `/w/limitation-radar`, as a form and a result card. Everything it decides — the
/// completeness check, the request, every line of the answer — is `LimitationRadarViewModel` and
/// `LimitationAudit`; this lays them out.
///
/// - Important: owns its own `NavigationStack` and "Done", because it is presented — from
///   You → Tools and from a matter's Tasks — never pushed. See `ToolDestination`.
struct LimitationRadarView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var model: LimitationRadarViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    LimitationRadarForm(model: model)
                } else {
                    ProgressView()
                }
            }
            .background(theme.groupedBackground)
            .navigationTitle("Limitation Radar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            guard model == nil else { return }
            model = LimitationRadarViewModel(service: session.limitationRadar)
        }
    }
}

/// The dispute timeline, the button, and the answer under it.
private struct LimitationRadarForm: View {
    @Environment(\.theme) private var theme
    @Bindable var model: LimitationRadarViewModel

    var body: some View {
        List {
            suitSection
            datesSection
            mediationSection
            runSection
            if let result = model.result {
                LimitationResultSections(audit: result)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var suitSection: some View {
        Section {
            Picker("Nature of the suit", selection: $model.profileKey) {
                ForEach(model.profiles) { profile in
                    Text(profile.pickerLabel).tag(profile.key)
                }
            }
            .pickerStyle(.navigationLink)
            .disabled(model.isRunning)
        } header: {
            SectionHeader(title: "Dispute timeline")
        } footer: {
            Text("Establish whether the limitation period has shut, and by how much, before you invest in the draft.")
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }

    private var datesSection: some View {
        Section {
            DayField(title: "Date time began to run", day: $model.causeOfAction)
            DayField(title: "Date of filing the suit", day: $model.intendedFiling)
        } footer: {
            Text("\(model.profile.runsFromHint) The filing date is the date you intend to file, or the date actually filed.")
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
        }
        .disabled(model.isRunning)
        .listRowBackground(theme.surface)
    }

    private var mediationSection: some View {
        Section {
            DayField(title: "Mediation application made", day: $model.mediationStart, isOptional: true)
            DayField(title: "Mediation concluded", day: $model.mediationEnd, isOptional: true)
        } header: {
            SectionHeader(title: "Pre-institution mediation (optional)")
        } footer: {
            Text("Section 12A, Commercial Courts Act, 2015 — commercial disputes only. The time spent is excluded from limitation, up to five months. If the end is left blank, the five-month maximum or the filing date is used, whichever is earlier.")
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
        }
        .disabled(model.isRunning)
        .listRowBackground(theme.surface)
    }

    private var runSection: some View {
        Section {
            Button {
                Task { await model.run() }
            } label: {
                HStack(spacing: Spacing.sm) {
                    if model.isRunning { ProgressView() }
                    Text(model.runLabel)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryAction)
            .disabled(model.isRunning)
            if let error = model.error {
                Text(error)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.danger)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .listRowBackground(Color.clear)
    }
}

/// A day, as a bare `YYYY-MM-DD`, chosen on a date picker shown in India's zone — so the day
/// picked is the day sent, wherever the phone is. An empty day shows a button to set one; an
/// optional one can be cleared again.
private struct DayField: View {
    @Environment(\.theme) private var theme
    let title: String
    @Binding var day: String
    var isOptional = false

    var body: some View {
        if let date = LimitationRadarViewModel.date(forDay: day) {
            HStack {
                DatePicker(title, selection: dateBinding(date), displayedComponents: .date)
                    .environment(\.timeZone, WireDate.india)
                if isOptional {
                    Button {
                        day = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear \(title)")
                }
            }
        } else {
            Button {
                day = LimitationRadarViewModel.today()
            } label: {
                LabeledContent(title) {
                    Text(isOptional ? "Add" : "Choose")
                        .foregroundStyle(theme.accentText)
                }
            }
        }
    }

    private func dateBinding(_ current: Date) -> Binding<Date> {
        Binding(
            get: { LimitationRadarViewModel.date(forDay: day) ?? current },
            set: { day = LimitationRadarViewModel.day(for: $0) })
    }
}

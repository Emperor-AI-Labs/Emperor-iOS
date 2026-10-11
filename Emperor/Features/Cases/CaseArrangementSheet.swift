import SwiftUI

// MARK: - Filter chips

/// The filters that are on, under the search bar, each removable on its own, with a way to clear
/// them all. Scrolls sideways rather than wrapping, so however many are on it takes one line and
/// leaves the docket where it was.
struct FilterChipBar: View {
    @Environment(\.theme) private var theme

    let chips: [CaseFilterChip]
    let remove: (CaseFilterChip) -> Void
    let clearAll: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.sm) {
                ForEach(chips) { chip in
                    Button {
                        remove(chip)
                    } label: {
                        HStack(spacing: Spacing.xs + 1) {
                            Text(chip.label)
                                .lineLimit(1)
                            Image(systemName: "xmark")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                        }
                        .font(.brand(.footnote, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 6)
                        .background(theme.accentWash, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.accentText.opacity(0.22), lineWidth: 0.5))
                        // Drawn as a small capsule, answering a touch across the full 44 points.
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove filter: \(chip.label)")
                    .accessibilityIdentifier("case-filter-chip-\(chip.id)")
                }

                // The padding and the 44-point frame inside the label, so the whole of it takes
                // the tap rather than the words alone.
                Button(action: clearAll) {
                    Text(CaseListViewModel.Copy.clearAll)
                        .font(.brand(.footnote, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, Spacing.xs)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("case-filters-clear-all")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
        }
        .scrollIndicators(.hidden)
        .background(theme.canvas)
    }
}

// MARK: - Sort & filter

/// Sort, grouping and every filter, in one sheet.
///
/// A sheet rather than a `Menu`, for three reasons. The court filter is several choices made at
/// once, and a menu closes on every tap, so choosing three courts would mean opening it three
/// times. Five sorts, three groupings and up to thirteen filters is more than a menu can show
/// without scrolling inside a popover. And a sheet has room to say how many cases each choice
/// holds, which is what tells someone a filter is worth choosing.
///
/// Full height, not a half-height detent. Twenty-odd choices do not fit in half a phone, and on
/// iPad a detent turns the sheet into a small panel with the grouping and every filter below the
/// fold — the screen shows its first section and looks like a sort menu. The standard sheet is
/// the whole list on a phone and a form sheet on iPad.
struct CaseArrangementSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let model: CaseListViewModel

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                Section {
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(CaseSort.allCases) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    SectionHeader(title: "Sort by")
                }
                .listRowBackground(theme.surface)

                Section {
                    Picker("Group by", selection: $model.grouping) {
                        ForEach(CaseGrouping.allCases) { grouping in
                            Text(grouping.label).tag(grouping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                } header: {
                    SectionHeader(title: "Group by")
                }

                filterSection("Court", options: model.courtTierOptions.map(CaseFilterChip.court))
                filterSection("Hearing", options: HearingFilter.allCases.map(CaseFilterChip.hearing))
                filterSection("Source", options: SourceFilter.allCases.map(CaseFilterChip.source))
            }
            .font(.brand(.body))
            // Named so the UI tests can scroll this list, never the docket behind the sheet.
            .accessibilityIdentifier("case-arrangement-form")
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle(CaseListViewModel.Copy.arrangeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { model.resetOptions() }
                        .disabled(model.isAtDefaults)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Checkmark rows, each with the number of cases it holds across the whole docket.
    @ViewBuilder
    private func filterSection(_ title: String, options: [CaseFilterChip]) -> some View {
        if !options.isEmpty {
            Section {
                ForEach(options) { option in
                    filterRow(option)
                }
            } header: {
                SectionHeader(title: title)
            }
            .listRowBackground(theme.surface)
        }
    }

    private func filterRow(_ option: CaseFilterChip) -> some View {
        let isOn = model.isOn(option)
        let count = model.count(for: option)
        let spokenCount: String = count == 1 ? "1 case" : "\(count) cases"
        return Button {
            model.toggle(option)
        } label: {
            HStack(spacing: Spacing.md) {
                Text(option.optionLabel)
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: Spacing.sm)
                Text("\(count)")
                    .font(.brand(.subheadline))
                    .monospacedDigit()
                    .foregroundStyle(theme.textTertiary)
                // Always laid out, shown only when on, so the counts stay in one column.
                Image(systemName: "checkmark")
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                    .opacity(isOn ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.optionLabel)
        .accessibilityValue(spokenCount)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("case-filter-\(option.id)")
    }
}

import SwiftUI

/// One hearing, in full: court, date and time, room, item, coram, purpose, and its history on the
/// list — with the way into the matter, and "Ask about it" as the one primary action.
///
/// Opened from a hearing row on Matters and from the "Next sitting" card on Ask. Every value is
/// the cause list's own; where the list printed no bench, it says so rather than leaving a gap
/// that reads like an oversight.
struct HearingSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let listing: CauseListing
    /// Every listing, for the history.
    let allListings: [CauseListing]
    let onOpenMatter: (String) -> Void
    let onAsk: (String) -> Void

    var body: some View {
        let display = listing.display
        VStack(spacing: 0) {
            RecordSheetHeader(
                title: listing.displayTitle,
                subtitle: display.reference,
                onClose: { dismiss() })

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    badges(display)
                        .padding(.bottom, Spacing.lg)

                    facts(display)

                    let history = MattersOverview.history(of: listing, in: allListings)
                    if !history.isEmpty {
                        RecordSectionLabel(title: "History")
                        VStack(spacing: 0) {
                            ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                                Rectangle().fill(theme.separator).frame(height: 1)
                                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                                    Text(entry.day)
                                        .monospacedDigit()
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: 84, alignment: .leading)
                                    Text(entry.text)
                                        .foregroundStyle(theme.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .font(.brand(size: 13.5, relativeTo: .footnote))
                                .padding(.vertical, Spacing.sm)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }

                    Text(CauseListViewModel.Copy.confirmWithCourt)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.top, Spacing.xl)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.xl)
            }

            footer
        }
        .background(theme.elevated.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
    }

    private func badges(_ display: CauseListingDisplay) -> some View {
        HStack(spacing: 6) {
            if let court = listing.courtName.flatMap(CauseListText.trimmed) {
                StatusPill(text: court, tone: .accent)
            }
            if MattersOverview.isSupplementary(listing) {
                StatusPill(text: "Supplementary list", tone: .warning)
            }
        }
    }

    private func facts(_ display: CauseListingDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fact("Date", value: [DisplayText.longDay(listing.date), display.time]
                .compactMap { $0 }.joined(separator: " · "))
            fact("Court", value: display.room ?? "Not printed on the list")
            fact("Item", value: display.item ?? "Not numbered yet")
            fact("Coram", value: display.coram ?? "No coram printed on the list")
            if let note = display.note {
                fact("Purpose", value: note)
            }
            if let advocates = display.advocates {
                fact("Counsel", value: advocates)
            }
        }
    }

    private func fact(_ label: String, value: String) -> some View {
        AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Spacing.lg) {
            Text(label)
                .font(.brand(size: 14, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(theme.textTertiary)
                .frame(minWidth: 72, alignment: .leading)
            Text(value)
                .font(.brand(size: 14, relativeTo: .subheadline))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                dismiss()
                onOpenMatter(listing.caseID)
            } label: {
                Text("Open matter")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondaryAction)
            .layoutPriority(1)

            Button {
                dismiss()
                onAsk(MattersOverview.askPrompt(for: listing))
            } label: {
                Label("Ask about it", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryAction)
            .layoutPriority(1.6)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .background(theme.elevated)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }
}

/// A hearing as the design draws it in a list: the item number in the serif, then the case
/// number, the parties, the court and room, SUPPL where it came from a supplementary list, and the
/// time.
struct HearingRow: View {
    @Environment(\.theme) private var theme
    let listing: CauseListing

    var body: some View {
        let display = listing.display
        HStack(alignment: .top, spacing: Spacing.md) {
            ItemNumberBadge(item: display.item)
            VStack(alignment: .leading, spacing: 2) {
                Text(display.reference ?? listing.displayTitle)
                    .font(.brand(.body, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(1)
                if display.reference != nil {
                    Text(listing.displayTitle)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                badges(display)
                    .padding(.top, Spacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spoken(listing))
    }

    private func badges(_ display: CauseListingDisplay) -> some View {
        // Wraps rather than truncates: a long room or a long court is still read whole.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badgeItems(display) }
            VStack(alignment: .leading, spacing: 4) { badgeItems(display) }
        }
    }

    @ViewBuilder
    private func badgeItems(_ display: CauseListingDisplay) -> some View {
        let court = MattersOverview.courtShortName(listing.courtName)
        let place = [court, display.room].compactMap { $0 }.joined(separator: " · ")
        if !place.isEmpty {
            StatusPill(text: place, tone: .accent)
        }
        if MattersOverview.isSupplementary(listing) {
            StatusPill(text: "SUPPL", tone: .warning)
        }
        if let time = display.time {
            StatusPill(text: time)
        }
    }
}

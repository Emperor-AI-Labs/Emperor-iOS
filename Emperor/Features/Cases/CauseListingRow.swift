import SwiftUI

/// One listing, read the way a litigator reads a list in a corridor: where first — item and
/// courtroom in the badge — then which matter, then the bench, then the rest.
///
/// Home's cause list and the Calendar's day both draw a listing with this one view, so the two
/// can never disagree about what a listing says or how it says it.
///
/// The web's Home card puts the courtroom in the same left-hand gutter
/// (`TodayCauseList.jsx`, `Row`); this adds the item number above it, which is the number
/// that decides when to be in the room. Neither is ever made up: an unnumbered listing
/// shows the scales instead, because a plausible "3" is read as where the matter is listed.
/// See `CauseListingDisplay` for the rules.
struct CauseListingRow: View {
    @Environment(\.theme) private var theme

    let listing: CauseListing
    /// Whether the sitting time leads the row rather than riding in the detail line. The Calendar
    /// orders a day by the clock, so there the time is the first thing read.
    var leadsWithTime = false

    /// The badge's width, scaled with Dynamic Type so a three-digit item still fits at the
    /// largest sizes rather than truncating to "1…".
    @ScaledMetric(relativeTo: .title3) private var badgeWidth: CGFloat = 58

    var body: some View {
        row(listing.display)
    }

    private func row(_ display: CauseListingDisplay) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            locationBadge(display)

            VStack(alignment: .leading, spacing: 3) {
                // Only where the published list printed one. Nothing here is ever inferred,
                // because a plausible "10:30" for a hearing a lawyer has to attend is exactly the
                // helpful guess that gets a matter dismissed.
                if leadsWithTime, let time = display.time {
                    Label {
                        Text(time)
                            .foregroundStyle(theme.textPrimary)
                    } icon: {
                        Image(systemName: "clock")
                            .foregroundStyle(theme.accentText)
                    }
                    .font(.brand(.subheadline, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                }

                if let forum = display.forum(courtName: listing.courtName) {
                    Text(forum)
                        .font(.brand(.caption2, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .lineLimit(2)
                }

                Text(listing.displayTitle)
                    .font(.brand(.headline))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)

                // Number, sitting time and counsel — the time only where it has not already led
                // the row.
                if let detail = leadsWithTime ? display.detailLineWithoutTime : display.detailLine {
                    Text(detail)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }

                if let note = display.note {
                    Text(note)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                }

                if let remarks = listing.remarks {
                    StatusPill(text: remarks, tone: .warning)
                }
            }
        }
        .padding(.vertical, Spacing.xs + 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            leadsWithTime ? display.spokenLeadingWithTime(listing) : display.spoken(listing))
    }

    /// Item over courtroom, or whichever of the two the list gave.
    private func locationBadge(_ display: CauseListingDisplay) -> some View {
        VStack(spacing: 1) {
            if let item = display.item {
                badgeCaption("Item")
                badgeValue(item)
                if let room = display.roomNumber {
                    Text("Court \(room)")
                        .font(.brand(.caption2, weight: .semibold).monospacedDigit())
                        .foregroundStyle(theme.accentText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else if let room = display.roomNumber {
                badgeCaption("Court")
                badgeValue(room)
            } else {
                Image(systemName: "scalemass")
                    .font(.brand(.title3))
                    .foregroundStyle(theme.accentText)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: badgeWidth)
        .padding(.vertical, Spacing.sm)
        // A wash of the accent, so the gutter reads as the listing's address at a glance — the
        // one thing on the row that says where to be — rather than as another grey box. The
        // citation badge's wash, because that is the strength `CitationTests` holds accent text
        // to 4.5:1 on, in both appearances; "Court 12" is accent text at caption size.
        .background(
            theme.accentWash,
            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(theme.accentMuted, lineWidth: 0.5))
    }

    private func badgeCaption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.brand(.caption2, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
            .lineLimit(1)
    }

    private func badgeValue(_ text: String) -> some View {
        Text(text)
            .font(.brand(.title3, weight: .bold).monospacedDigit())
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

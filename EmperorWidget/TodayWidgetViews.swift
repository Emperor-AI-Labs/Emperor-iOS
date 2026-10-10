import SwiftUI
import WidgetKit

/// The widget, laid out for each place it can be put.
///
/// Every word comes from `TodayCopy` and every decision from `TodayGlance`, both in the core and
/// tested; this only arranges them. Home Screen sizes wear the app's palette and face
/// (`WidgetStyle`); the Lock Screen ones use the system's, as the Lock Screen expects, and let
/// iOS tint them.
struct TodayWidgetView: View {
    let entry: TodayEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .widgetURL(entry.glance.link.url)
            .containerBackground(for: .widget) {
                isLockScreen ? Color.clear : style.canvas
            }
    }

    private var style: WidgetStyle { WidgetStyle(colorScheme) }

    private var isLockScreen: Bool {
        family == .accessoryRectangular || family == .accessoryInline
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            Text(TodayCopy.inline(entry.glance))
        case .accessoryRectangular:
            LockScreenTodayView(entry: entry)
        case .systemMedium:
            HomeTodayView(entry: entry, style: style, rows: 3)
        case .systemLarge, .systemExtraLarge:
            HomeTodayView(entry: entry, style: style, rows: 6)
        default:
            SmallTodayView(entry: entry, style: style)
        }
    }
}

// MARK: - Home Screen, small

/// The count, or the next listed day, in large type — the glance a small square has room for.
private struct SmallTodayView: View {
    let entry: TodayEntry
    let style: WidgetStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            WidgetHeading(entry: entry, style: style)
            Spacer(minLength: 4)
            switch entry.glance {
            case .today(let day):
                // A number people scan for, so in the serif, as Record sets item numbers.
                Text("\(day.total)")
                    .font(style.display(38, relativeTo: .largeTitle))
                    .foregroundStyle(style.textPrimary)
                    .minimumScaleFactor(0.7)
                Text(day.total == 1 ? "matter listed today" : "matters listed today")
                    .font(style.brand(12, .medium, relativeTo: .caption))
                    .foregroundStyle(style.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let first = day.matters.first {
                    Spacer(minLength: 4)
                    Text(first.title)
                        .font(style.brand(12, .medium, relativeTo: .caption))
                        .foregroundStyle(style.textPrimary)
                        .lineLimit(2)
                        .privacySensitive()
                }
            case .next(let day):
                Text(TodayCopy.nothingToday)
                    .font(style.brand(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(style.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text("Next")
                    .font(style.brand(11, .medium, relativeTo: .caption2))
                    .foregroundStyle(style.textTertiary)
                Text(IndianDay.short(day.day))
                    .font(style.brand(17, .semibold, relativeTo: .headline))
                    .foregroundStyle(style.accentText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(TodayCopy.count(day.total))
                    .font(style.brand(12, .regular, relativeTo: .caption))
                    .foregroundStyle(style.textSecondary)
            case .clear(let through):
                Text(TodayCopy.nothingToday)
                    .font(style.brand(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(style.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(TodayCopy.clear(through: through))
                    .font(style.brand(12, .regular, relativeTo: .caption))
                    .foregroundStyle(style.textSecondary)
                    .lineLimit(3)
            case .openApp:
                Text(TodayCopy.openApp)
                    .font(style.brand(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(style.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Home Screen, medium and large

/// A heading, then the day's matters one to a line, with where and when each is heard.
private struct HomeTodayView: View {
    let entry: TodayEntry
    let style: WidgetStyle
    /// How many matters fit: three in a medium widget, six in a large one.
    let rows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                WidgetHeading(entry: entry, style: style)
                Spacer(minLength: 8)
                if let total = listedToday {
                    Text("\(total) listed")
                        .font(style.brand(12, .medium, relativeTo: .caption))
                        .foregroundStyle(style.textSecondary)
                }
            }
            switch entry.glance {
            case .today(let day):
                matterList(day)
            case .next(let day):
                Text(TodayCopy.nothingToday)
                    .font(style.brand(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(style.textPrimary)
                Text(TodayCopy.next(day))
                    .font(style.brand(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(style.accentText)
                matterList(day, limit: max(1, rows - 1))
            case .clear(let through):
                Text(TodayCopy.nothingToday)
                    .font(style.brand(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(style.textPrimary)
                Text(TodayCopy.clear(through: through))
                    .font(style.brand(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(style.textSecondary)
            case .openApp:
                Spacer(minLength: 0)
                Text(TodayCopy.openApp)
                    .font(style.brand(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(style.textPrimary)
            }
            Spacer(minLength: 0)
            if rows > 3, entry.glance != .openApp {
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// How many are listed today, when today has any.
    private var listedToday: Int? {
        guard case .today(let day) = entry.glance else { return nil }
        return day.total
    }

    /// The day's first matters, as many as fit in `limit` lines — one of them given over to "and
    /// 4 more" when the day has more than fit.
    @ViewBuilder
    private func matterList(_ day: TodayDay, limit: Int? = nil) -> some View {
        let lines = limit ?? rows
        let count = day.total > lines ? max(1, lines - 1) : lines
        let shown = Array(day.matters.prefix(count))
        VStack(alignment: .leading, spacing: 5) {
            ForEach(shown) { matter in
                MatterLine(matter: matter, style: style, showsCourt: rows > 3)
            }
            if let more = TodayCopy.more(shown: shown.count, of: day.total) {
                Text(more)
                    .font(style.brand(11, .medium, relativeTo: .caption2))
                    .foregroundStyle(style.textTertiary)
            }
        }
    }

    /// Whose matters these are, and how old the list is once it is old enough to matter.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let age = TodayCopy.age(fetchedAt: entry.fetchedAt, now: entry.date) {
                Text(age)
                    .font(style.brand(11, .medium, relativeTo: .caption2))
                    .foregroundStyle(style.textSecondary)
            }
            Text(TodayCopy.framing)
                .font(style.brand(11, .regular, relativeTo: .caption2))
                .foregroundStyle(style.textTertiary)
                .lineLimit(2)
        }
    }
}

/// One matter: its title, then where and when — redacted together on a locked phone.
private struct MatterLine: View {
    let matter: TodayMatter
    let style: WidgetStyle
    /// The forum as well as the room — in the large widget, which has the width for it.
    let showsCourt: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(style.accent)
                .frame(width: 3)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(matter.title)
                    .font(style.brand(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(style.textPrimary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(style.brand(11, .regular, relativeTo: .caption2))
                        .foregroundStyle(style.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .privacySensitive()
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        let place = TodayCopy.location(matter)
        guard showsCourt, let court = matter.court else { return place ?? matter.court }
        return place.map { "\(court) · \($0)" } ?? court
    }
}

/// "TUE 13 OCT" in the accent — the day in India the widget speaks for — or the app's name when
/// there is nothing to show yet.
private struct WidgetHeading: View {
    let entry: TodayEntry
    let style: WidgetStyle

    var body: some View {
        Text(entry.glance == .openApp ? "Emperor" : TodayCopy.heading(at: entry.date))
            .font(style.brand(11, .semibold, relativeTo: .caption2))
            .textCase(.uppercase)
            .foregroundStyle(style.accentText)
            .lineLimit(1)
    }
}

// MARK: - Lock Screen

/// Three short lines in the system's face, tinted by iOS.
private struct LockScreenTodayView: View {
    let entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch entry.glance {
            case .today(let day):
                Text(TodayCopy.listedToday(day.total))
                    .font(.headline)
                    .widgetAccentable()
                if let first = day.matters.first {
                    Text(first.title)
                        .font(.caption)
                        .lineLimit(1)
                        .privacySensitive()
                    if let place = TodayCopy.location(first) {
                        Text(place)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .privacySensitive()
                    }
                }
            case .next(let day):
                Text(TodayCopy.nothingToday)
                    .font(.headline)
                    .widgetAccentable()
                Text("Next: \(IndianDay.short(day.day))")
                    .font(.caption)
                Text(TodayCopy.count(day.total))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .clear(let through):
                Text(TodayCopy.nothingToday)
                    .font(.headline)
                    .widgetAccentable()
                Text(TodayCopy.clear(through: through))
                    .font(.caption)
                    .lineLimit(2)
            case .openApp:
                Text("Emperor")
                    .font(.headline)
                    .widgetAccentable()
                Text(TodayCopy.openApp)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

import SwiftUI

/// One company in the registry: what its CIN says, what is not held here, and every liquidation
/// notice that names it — each opening the eAuctions notice screen.
///
/// Pushed inside `McaRegistryView`'s stack. No "Watch company" control, deliberately — see the
/// note at the top of `McaRegistry.swift`.
struct McaCompanyView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let route: McaCompanyRoute

    @State private var model: McaCompanyViewModel?

    var body: some View {
        Group {
            if let model {
                McaCompanyList(model: model)
            } else {
                ProgressView()
            }
        }
        .background(theme.groupedBackground)
        .navigationTitle(route.company.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let created = McaCompanyViewModel(
                company: route.company, total: route.total, service: session.auctions)
            model = created
            await created.load()
        }
    }
}

private struct McaCompanyList: View {
    @Environment(\.theme) private var theme
    let model: McaCompanyViewModel

    var body: some View {
        List {
            identitySection
            McaGapsSection()
            noticesSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private var identitySection: some View {
        Section {
            Text(model.company.name)
                .font(.brand(.title3, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(model.cinLine)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
            if model.decoded.shapeValid {
                McaDecodeResult(result: model.decoded)
            } else {
                McaNote(
                    title: "This company's CIN could not be decoded",
                    text: model.decoded.reason
                        ?? "The auction notice did not carry a well-formed CIN, so nothing can be read from it.",
                    tone: theme.warning)
            }
        }
        .listRowBackground(theme.surface)
    }

    private var noticesSection: some View {
        Section {
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if model.showsNoNotices {
                McaNote(
                    title: "No notices found for this CIN",
                    text: "The notice this company was found on could not be re-fetched by CIN. Open eAuctions and search the company name directly.",
                    tone: theme.textSecondary)
            } else {
                ForEach(model.notices) { notice in
                    NavigationLink(value: notice.id) {
                        McaNoticeRow(notice: notice)
                    }
                }
            }
        } header: {
            SectionHeader(title: "Liquidation notices", detail: model.countLine)
        }
        .listRowBackground(theme.surface)
    }
}

/// A notice under its company: what is sold, the reserve price, and when.
private struct McaNoticeRow: View {
    @Environment(\.theme) private var theme
    let notice: AuctionNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusPill(text: notice.type.label, tone: notice.type.amends ? .warning : .accent)
                if let reference = notice.displayReference {
                    Text(reference)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            if let assets = notice.natureOfAssets, !assets.isEmpty {
                Text(assets)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
                    .dynamicLineLimit(3)
            }
            Text(notice.reservePriceText.map { "Reserve \($0)" } ?? "Reserve price not published")
                .font(.brand(.subheadline, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if let day = notice.auctionDayKey {
                Label("Auction \(DisplayText.longDay(day))", systemImage: "calendar")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

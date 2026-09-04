import SwiftUI

/// One auction notice.
///
/// Read-only apart from the company watch. Two things dominate the layout, and both are about
/// not letting a stale figure be read as a current one:
///
/// - **An amendment warning above everything else.** A corrigendum exists to change a number,
///   usually the reserve price or the auction date. Showing the original's figures without
///   saying one was issued presents superseded terms as current.
/// - **Absences stated rather than hidden.** A row scraped from the IBBI listing page alone
///   carries almost nothing, and a blank where a reserve price should be must not read as zero.
struct AuctionDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let noticeID: String

    @State private var model: AuctionDetailViewModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model?.title ?? "Auction notice")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let created = AuctionDetailViewModel(noticeID: noticeID, service: session.auctions)
            model = created
            await created.load()
        }
    }

    @ViewBuilder
    private func content(_ model: AuctionDetailViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                if let notice = model.notice {
                    amendmentBanner(model)
                    headline(notice, model)
                    figures(notice)
                    assets(notice)
                    liquidator(notice)
                    documents(notice)
                    provenance(notice)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
        } empty: {
            ContentUnavailableView(
                "Notice unavailable",
                systemImage: "questionmark.folder",
                description: Text(AuctionService.noticeGoneMessage))
        }
        .refreshable { await model.load() }
        .alert(model.announcementTitle, isPresented: Binding(
            get: { model.isShowingAnnouncement },
            set: { if !$0 { model.dismissAnnouncement() } }
        )) {
            Button("OK") { model.dismissAnnouncement() }
        } message: {
            Text(model.announcementMessage)
        }
    }

    // MARK: - Sections

    /// Above everything, including the debtor's name. If a reader takes only one thing off this
    /// screen it must be that the figures below are not the operative ones.
    @ViewBuilder
    private func amendmentBanner(_ model: AuctionDetailViewModel) -> some View {
        if let warning = model.supersededWarning {
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.warning)
                    Text(warning)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textPrimary)
                }
                ForEach(model.amendments) { amendment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(amendment.type.label)
                            .font(.brand(.subheadline, weight: .semibold))
                        if let issued = amendment.dateIssuedRaw {
                            Text("Issued \(DisplayText.longDay(issued))")
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                        }
                        if let reserve = amendment.reservePriceText {
                            Text("Reserve price \(reserve)")
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                        }
                        if let day = amendment.auctionDayKey {
                            Text("Auction \(DisplayText.longDay(day))")
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func headline(
        _ notice: AuctionNotice, _ model: AuctionDetailViewModel
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(notice.displayDebtor)
                    .font(.brand(.title3, weight: .semibold))
                HStack(spacing: 6) {
                    StatusPill(text: notice.type.label, tone: .accent)
                    StatusPill(
                        text: model.status.label,
                        tone: model.status.isOpen ? .success : .neutral)
                }
                if let explanation = model.amendsExplanation {
                    // Text, not a link. The earlier notice can only be addressed by its unique
                    // number, and that lookup is unreachable through this API.
                    Text(explanation)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.vertical, 2)

            if let cin = notice.cin, !cin.isEmpty {
                LabeledContent("CIN", value: cin)
            }
            if let reference = notice.displayReference {
                LabeledContent("Notice number", value: reference)
                    .font(.brand(.caption))
            }
            // "Watch this company" belonged here and is held back. See `AuctionListView`.
        }
    }

    private func figures(_ notice: AuctionNotice) -> some View {
        Section("The auction") {
            // Absent figures are named rather than omitted. A missing reserve price on a
            // liquidation notice is information; a blank row is not.
            LabeledContent(
                "Reserve price", value: notice.reservePriceText ?? "Not published")
            LabeledContent("EMD", value: notice.emdAmountText ?? "Not published")
            LabeledContent(
                "Auction date",
                value: notice.auctionDayKey.map { DisplayText.longDay($0) } ?? "Not published")
            LabeledContent(
                "Last date for EMD",
                value: notice.emdLastDateRaw.map { DisplayText.longDay($0) } ?? "Not published")
            if let platform = notice.auctionPlatform, !platform.isEmpty {
                LabeledContent("Platform", value: platform)
            }
            if let url = notice.platformURL {
                Link(destination: url) {
                    Label("Open the auction platform", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    @ViewBuilder
    private func assets(_ notice: AuctionNotice) -> some View {
        if notice.natureOfAssets?.isEmpty == false || notice.assetLocation?.isEmpty == false {
            Section("Assets") {
                if let nature = notice.natureOfAssets, !nature.isEmpty {
                    Text(nature).font(.brand(.subheadline))
                }
                if let location = notice.assetLocation, !location.isEmpty {
                    LabeledContent("Location", value: location)
                }
            }
        }
    }

    @ViewBuilder
    private func liquidator(_ notice: AuctionNotice) -> some View {
        Section("Liquidation") {
            if let name = notice.liquidatorName, !name.isEmpty {
                LabeledContent("Liquidator", value: name)
            }
            if let registration = notice.ipRegistrationNumber, !registration.isEmpty {
                LabeledContent("IP registration", value: registration)
            }
            if let raw = notice.liquidationCommencementDateRaw, !raw.isEmpty {
                LabeledContent("Liquidation commenced", value: DisplayText.longDay(raw))
            }
            if let raw = notice.insolvencyCommencementDateRaw, !raw.isEmpty {
                LabeledContent("Insolvency commenced", value: DisplayText.longDay(raw))
            }
            if let process = notice.processNumber, !process.isEmpty {
                LabeledContent("Process number", value: process)
            }
            if let raw = notice.dateIssuedRaw, !raw.isEmpty {
                LabeledContent("Notice issued", value: DisplayText.longDay(raw))
            }
        }
    }

    @ViewBuilder
    private func documents(_ notice: AuctionNotice) -> some View {
        Section {
            if let url = notice.documentURL {
                Link(destination: url) {
                    Label("Open the notice (PDF)", systemImage: "doc.text")
                }
            }
            if let url = notice.scannedNoticeURL {
                Link(destination: url) {
                    Label("Open the scanned notice", systemImage: "doc.on.doc")
                }
            }
            if notice.documentURL == nil {
                Text("No notice document is linked from this row.")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
        } header: {
            SectionHeader(title: "Documents")
        } footer: {
            Text(AuctionListViewModel.Copy.confirmWithNotice)
                .font(.brand(.caption2))
        }
    }

    @ViewBuilder
    private func provenance(_ notice: AuctionNotice) -> some View {
        if let caveat = notice.provenanceCaveat {
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "doc.badge.ellipsis")
                        .foregroundStyle(theme.textSecondary)
                    Text(caveat)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
            } header: {
                SectionHeader(title: "Where this came from")
            }
        }
    }
}

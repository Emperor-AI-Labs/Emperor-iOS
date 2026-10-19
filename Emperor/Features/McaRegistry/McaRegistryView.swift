import SwiftUI

/// A company opened from the registry, as a navigation value. Identified by its grouping key.
struct McaCompanyRoute: Hashable {
    let company: McaCompany
    /// How many notices name it in all, when the opener knew.
    var total: Int?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.company.key == rhs.company.key }
    func hash(into hasher: inout Hasher) { hasher.combine(company.key) }
}

/// The MCA Registry (the web's `/mca-registry`): decode any CIN offline, and open the companies
/// on record here from IBBI liquidation notices.
///
/// Everything it decides is `McaRegistryViewModel`. No watch control — see the note at the top of
/// `McaRegistry.swift`.
///
/// - Important: owns its own `NavigationStack` and "Done", because You → Tools presents rather
///   than pushes. See `ToolDestination`.
struct McaRegistryView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var model: McaRegistryViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    McaRegistryList(model: model)
                } else {
                    ProgressView()
                }
            }
            .background(theme.groupedBackground)
            .navigationTitle("MCA Registry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: McaCompanyRoute.self) { route in
                McaCompanyView(route: route)
            }
            .navigationDestination(for: String.self) { noticeID in
                AuctionDetailView(noticeID: noticeID)
            }
        }
        .task {
            guard model == nil else { return }
            model = McaRegistryViewModel(service: session.auctions)
        }
    }
}

/// The decoder, the master-data gap, and the companies on record.
private struct McaRegistryList: View {
    @Environment(\.theme) private var theme
    @Bindable var model: McaRegistryViewModel

    var body: some View {
        List {
            McaDecoderSection(model: model)
            McaGapsSection()
            companiesSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .searchable(text: $model.searchText, prompt: "Search a corporate debtor by name…")
        // Debounced as the web does, and run once on appear with the empty search.
        .task(id: model.searchText) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await model.search(model.searchText)
        }
        .refreshable { await model.load() }
    }

    private var companiesSection: some View {
        Section {
            if model.isLoading && model.companies.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error = model.loadError {
                Text(error)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.danger)
            } else if model.showsEmpty {
                Text(model.emptyMessage)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(model.companies) { company in
                    NavigationLink(value: McaCompanyRoute(company: company)) {
                        McaCompanyRow(company: company)
                    }
                }
            }
        } header: {
            SectionHeader(title: "Companies on record")
        } footer: {
            companiesFooter
        }
        .listRowBackground(theme.surface)
    }

    private var companiesFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if !model.companies.isEmpty {
                Text(model.countLine)
                if let cap = model.capLine {
                    Text(cap).foregroundStyle(theme.warning)
                }
            }
            Text("Corporate debtors named in IBBI liquidation e-auction notices held here. This is not a copy of the MCA register — a company appears only once a liquidator has published an auction notice against it.")
        }
        .font(.brand(.caption))
        .foregroundStyle(theme.textTertiary)
    }
}

/// One company: its name, its CIN, what the CIN says at a glance, and its notices.
private struct McaCompanyRow: View {
    @Environment(\.theme) private var theme
    let company: McaCompany

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(company.name)
                .font(.brand(.headline))
                .foregroundStyle(theme.textPrimary)
                .dynamicLineLimit(2)
            Text(company.cin ?? "No CIN on the notice")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
            if let fields = company.decoded.fields {
                pills(fields)
            }
            Text(company.noticesLine)
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func pills(_ fields: CinFields) -> some View {
        HStack(spacing: 6) {
            if fields.companyClass.known { StatusPill(text: fields.companyClass.label) }
            if fields.roc.known, let seat = fields.rocOffice ?? fields.rocState {
                StatusPill(text: seat)
            }
            if fields.year.known, let year = fields.yearValue { StatusPill(text: "Inc. \(year)") }
        }
    }
}

/// "MCA master data is not available here", with the full list of what is missing and why.
struct McaGapsSection: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            Text("Registered office address, directors and DIN, charges, and filing history are not shown — not because the company has none, but because this product has no licensed source for them. Nothing here is inferred to fill the gap.")
                .font(.brand(.footnote))
                .foregroundStyle(theme.textSecondary)
            DisclosureGroup("What is missing, and why") {
                Text(Cin.masterDataGapReason)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                ForEach(Cin.masterDataGaps, id: \.field) { gap in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gap.field).font(.brand(.subheadline, weight: .semibold))
                        Text(gap.why)
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
            if let portal = URL(string: Cin.portalURL) {
                Link(destination: portal) {
                    Label("Look it up on mca.gov.in", systemImage: "arrow.up.right.square")
                }
            }
        } header: {
            SectionHeader(title: "MCA master data is not available here")
        }
        .listRowBackground(theme.surface)
    }
}

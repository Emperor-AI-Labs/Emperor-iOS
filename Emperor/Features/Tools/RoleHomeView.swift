import SwiftUI

/// The role's own deck — what the web puts on its Home.
///
/// A card is not a shortcut to one of the twenty-nine tools. It resolves to a *synthetic* tool of
/// its own, built from the card and the role's framing, and that framing carries the guardrail:
/// a paralegal's output is labelled a draft for advocate review, a student's teaches rather than
/// ghostwrites, an arbitral scaffold leaves the findings to the arbitrator. See `RoleCard`.
///
/// Litigator has no deck. Its Home on the web is the drafting taxonomy, so that is what it is
/// shown here — `LitigatorWorkspaceView`, which owns its own stack and its own Done.
struct RoleHomeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.practice) private var practice
    @Environment(\.dismiss) private var dismiss

    /// Which mode, tag, level or context the grid is filtered to. `nil` until the role's own
    /// first filter is applied on appear — a grid has no "all" for the roles that gate.
    @State private var filterID: String?

    var body: some View {
        if practice.role.usesDraftingTaxonomy {
            LitigatorWorkspaceView()
        } else {
            deck
        }
    }

    private var deck: some View {
        NavigationStack {
            List {
                if !practice.role.cardFilters.isEmpty {
                    Section {
                        filterStrip
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                ForEach(groups, id: \.name) { group in
                    Section {
                        ForEach(group.cards) { card in
                            row(card)
                        }
                    } header: {
                        SectionHeader(title: group.name, detail: "\(group.cards.count)")
                    }
                    .listRowBackground(theme.surface)
                }

                if groups.isEmpty {
                    Section {
                        Label {
                            Text("Nothing in this part of the deck.")
                        } icon: {
                            Image(systemName: "rectangle.stack")
                        }
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textSecondary)
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle(practice.role.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { toolID in
                if let tool = roleTool(toolID) {
                    ToolFormView(tool: tool)
                } else {
                    EmptyStateView(
                        "Card unavailable", systemImage: "rectangle.on.rectangle.slash",
                        tone: .neutral)
                }
            }
            .onAppear {
                // The platform's grids open on their first filter, not on everything: for
                // Arbitrators & Judges the two lists are a compliance boundary, so there is no
                // combined view to fall back to.
                if filterID == nil { filterID = practice.role.cardFilters.first?.id }
            }
        }
    }

    /// Cards grouped as the platform groups them, dropping empty sections. Roles whose deck is
    /// ungrouped get one unnamed run.
    private var groups: [(name: String, cards: [RoleCard])] {
        let visible = practice.role.cards(matching: filterID)
        let order = practice.role.cardSections
        guard !order.isEmpty else {
            return visible.isEmpty ? [] : [(name: practice.role.tagline, cards: visible)]
        }
        return order.compactMap { section in
            let cards = visible.filter { $0.section == section }
            return cards.isEmpty ? nil : (name: section, cards: cards)
        }
    }

    private var filterStrip: some View {
        let active = filterID
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(practice.role.cardFilters) { filter in
                    let isSelected = active == filter.id
                    Button {
                        filterID = filter.id
                    } label: {
                        ChipLabel(title: filter.label, isSelected: isSelected)
                    }
                    .buttonStyle(ChipButtonStyle(isSelected: isSelected))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm + 2)
        }
    }

    /// A card as the web's deck draws it: a tile in the colour `toolColor` gives the card's tool
    /// id, with the document the web puts on it, then the card's words.
    private func row(_ card: RoleCard) -> some View {
        NavigationLink(value: card.toolID) {
            HStack(alignment: .top, spacing: Spacing.md) {
                IconTile(
                    systemImage: ToolSymbol.symbol(for: card.toolID),
                    hue: TileHue.forTool(card.toolID))
                cardText(card)
            }
            .padding(.vertical, Spacing.xxs)
        }
    }

    private func cardText(_ card: RoleCard) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // The flag under the title at the accessibility sizes, so neither is cut short.
            AdaptiveStack(spacing: 6) {
                Text(card.title)
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                if card.isSafetyFirst {
                    // The platform flags these rows; they are the ones where getting the
                    // answer wrong has a person on the other end of it.
                    StatusPill(text: "Safety first", tone: .warning)
                }
            }
            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
            if !card.dropdown.isEmpty {
                Text(card.dropdown.prefix(3).joined(separator: " · "))
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
                    .dynamicLineLimit(2)
            }
        }
    }
}

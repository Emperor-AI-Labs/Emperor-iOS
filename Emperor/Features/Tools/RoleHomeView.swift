import SwiftUI

/// The role's own deck — what the web puts on its Home.
///
/// A card is not a shortcut to one of the twenty-nine tools. It resolves to a *synthetic* tool of
/// its own, built from the card and the role's framing, and that framing carries the guardrail:
/// a paralegal's output is labelled a draft for advocate review, a student's teaches rather than
/// ghostwrites, an arbitral scaffold leaves the findings to the arbitrator. See `RoleCard`.
struct RoleHomeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.practice) private var practice
    @Environment(\.dismiss) private var dismiss

    /// Which mode, tag, level or context the grid is filtered to. `nil` until the role's own
    /// first filter is applied on appear — a grid has no "all" for the roles that gate.
    @State private var filterID: String?

    var body: some View {
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
                        Text("Nothing in this part of the deck.")
                            .font(.brand(.subheadline))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle(practice.role.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { toolID in
                if let card = roleCard(toolID) {
                    ToolFormView(tool: card.toolSpec)
                } else {
                    ContentUnavailableView(
                        "Card unavailable", systemImage: "rectangle.on.rectangle.slash")
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
            HStack(spacing: 8) {
                ForEach(practice.role.cardFilters) { filter in
                    let isSelected = active == filter.id
                    let weight: Font.Weight? =
                        isSelected ? Font.Weight.semibold : Font.Weight.regular
                    Button {
                        filterID = filter.id
                    } label: {
                        Text(filter.label)
                            .font(.brand(.subheadline, weight: weight))
                            .foregroundStyle(isSelected ? theme.onAccent : theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? theme.accent : theme.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func row(_ card: RoleCard) -> some View {
        NavigationLink(value: card.toolID) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
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
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

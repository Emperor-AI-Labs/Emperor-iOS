import SwiftUI

/// You → Plan → Billing: the plan held and its standing, "Redeem a coupon", the payment history
/// with an invoice for each paid order, and the plans on offer — the web's Billing page.
///
/// Nothing here takes money. A purchase, a renewal and a discount code are all used on the web,
/// which "View plans" opens (`WebPlans`); coming back reads the account again. The coupon box and
/// the plans with their prices are behind the same build switch as that button, because a code
/// that unlocks a plan and a price list beside a way to pay elsewhere are both what App Review
/// asks about. The plan, the history and the invoices are the account's own records and always
/// show. Every decision is `BillingViewModel`'s; this lays it out.
struct BillingView: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: BillingViewModel?

    var body: some View {
        Group {
            if let model {
                BillingContent(model: model, offersPlans: session.webPlans.isOffered)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.groupedBackground)
            }
        }
        .navigationTitle(BillingCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                let session = session
                model = BillingViewModel(
                    service: session.billing,
                    onRedeemed: { await session.refreshAccount() })
            }
            if let model, model.state == .idle {
                await model.load()
            }
        }
        // Back from the plans page in the browser: the plan and its order may be new.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let model, model.state != .loading else { return }
            Task { await model.load() }
        }
    }
}

/// The list itself, split from `BillingView` so neither body is too long to type-check.
private struct BillingContent: View {
    @Environment(\.theme) private var theme

    let model: BillingViewModel
    let offersPlans: Bool

    var body: some View {
        ListStateView(
            presentation: ListPresentation(state: model.state, isEmpty: model.account == nil),
            retry: { await model.load() }
        ) {
            List {
                BillingPlanSection(model: model, offersPlans: offersPlans)
                if offersPlans {
                    BillingCouponSection(model: model)
                }
                BillingOrdersSection(model: model)
                if offersPlans, !model.offeredPlans.isEmpty {
                    BillingCatalogueSection(model: model)
                }
            }
            .font(.brand(.body))
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
        } empty: {
            EmptyView()
        }
        .refreshable { await model.load() }
        .modifier(BillingInvoicePresenter(model: model))
    }
}

/// The open invoice as a sheet, and an invoice that would not open as an alert.
private struct BillingInvoicePresenter: ViewModifier {
    let model: BillingViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { model.invoice != nil },
                set: { if !$0 { model.invoice = nil } }
            )) {
                if let layout = model.invoiceLayout {
                    BillingInvoiceView(layout: layout)
                }
            }
            .alert("Invoice unavailable", isPresented: Binding(
                get: { model.invoiceError != nil },
                set: { if !$0 { model.invoiceError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.invoiceError ?? "")
            }
    }
}

// MARK: - The plan

private struct BillingPlanSection: View {
    @Environment(\.theme) private var theme

    let model: BillingViewModel
    let offersPlans: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(model.planTitle)
                        .font(.display(size: 24, relativeTo: .title2))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Spacing.sm)
                    StatusPill(
                        text: model.standing.text,
                        tone: BillingTone.pill(model.standing.tone),
                        systemImage: model.standing.tone == .success ? "checkmark" : nil)
                }
                Text(model.planLine)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Spacing.xs)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("billing-plan")

            if offersPlans {
                ViewPlansButton(style: .row)
            }
        } header: {
            SectionHeader(title: "Current plan")
        } footer: {
            if offersPlans {
                Text(WebPlans.settingsNote)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .listRowBackground(theme.surface)
    }
}

// MARK: - Coupon

private struct BillingCouponSection: View {
    @Environment(\.theme) private var theme

    let model: BillingViewModel

    var body: some View {
        Section {
            HStack(spacing: Spacing.sm) {
                TextField(BillingCopy.codePlaceholder, text: Binding(
                    get: { model.code },
                    set: { model.setCode($0) }))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { apply() }
                    .accessibilityLabel("Coupon code")
                    .accessibilityIdentifier("billing-coupon-code")
                Button {
                    apply()
                } label: {
                    if model.coupon == .checking {
                        ProgressView()
                    } else {
                        Text("Apply")
                    }
                }
                .buttonStyle(.secondaryAction)
                .disabled(!model.canApply)
                .accessibilityIdentifier("billing-coupon-apply")
            }

            BillingCouponOutcome(model: model)
        } header: {
            SectionHeader(title: "Redeem a coupon")
        }
        .listRowBackground(theme.surface)
        .onChange(of: model.coupon) { _, phase in
            switch phase {
            case .redeemed(let line): VoiceOver.announce(line)
            case .failed(let message, _): VoiceOver.announce(message)
            default: break
            }
        }
    }

    private func apply() {
        let model = model
        Task { await model.applyCoupon() }
    }
}

/// What the last code did: a preview to redeem, a discount to use on the web, a refusal, or done.
private struct BillingCouponOutcome: View {
    @Environment(\.theme) private var theme

    let model: BillingViewModel

    var body: some View {
        switch model.coupon {
        case .idle, .checking:
            EmptyView()
        case .preview(let preview), .redeeming(let preview):
            previewCard(preview, isRedeeming: model.coupon == .redeeming(preview))
        case .redeemed(let line):
            Label {
                Text(line).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
            }
            .font(.brand(.footnote, weight: .semibold))
            .foregroundStyle(theme.success)
        case .failed(let message, let offersPlans):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(message)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if offersPlans {
                    ViewPlansButton(style: .inline)
                }
            }
            .padding(.vertical, Spacing.xxs)
        }
    }

    private func previewCard(_ preview: CouponPreview, isRedeeming: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(preview.label ?? preview.code)
                .font(.brand(.subheadline, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(BillingViewModel.previewLine(preview))
                .font(.brand(.footnote))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if preview.isRedeemableHere {
                Button {
                    let model = model
                    Task { await model.redeemCoupon() }
                } label: {
                    Text(isRedeeming ? "Redeeming…" : "Redeem this code")
                }
                .buttonStyle(.primaryAction)
                .disabled(isRedeeming)
                .accessibilityIdentifier("billing-coupon-redeem")
            } else {
                ViewPlansButton(style: .inline)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Payment history

private struct BillingOrdersSection: View {
    @Environment(\.theme) private var theme

    let model: BillingViewModel

    var body: some View {
        Section {
            if model.orders.isEmpty {
                Text(BillingCopy.noPaymentsYet)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(model.orders) { order in
                    if order.hasInvoice {
                        Button {
                            let model = model
                            Task { await model.openInvoice(orderID: order.id) }
                        } label: {
                            BillingOrderRow(order: order, isLoading: model.loadingInvoiceID == order.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.loadingInvoiceID != nil)
                        .accessibilityHint("Opens the invoice")
                    } else {
                        BillingOrderRow(order: order, isLoading: false)
                    }
                }
            }
        } header: {
            SectionHeader(title: "Payment history")
        } footer: {
            Text(BillingCopy.footer)
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
        }
        .listRowBackground(theme.surface)
    }
}

private struct BillingOrderRow: View {
    @Environment(\.theme) private var theme

    let order: BillingViewModel.OrderRow
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(order.plan)
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(2)
                Text(order.date)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: Spacing.sm)
            VStack(alignment: .trailing, spacing: Spacing.xxs) {
                Text(order.amount)
                    .font(.brand(.subheadline, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                StatusPill(text: order.status, tone: BillingTone.pill(order.statusTone))
            }
            if order.hasInvoice {
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "doc.text")
                        .foregroundStyle(theme.accentText)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("billing-order-\(order.id)")
    }
}

// MARK: - Plans on offer

private struct BillingCatalogueSection: View {
    @Environment(\.theme) private var theme

    let model: BillingViewModel

    var body: some View {
        Section {
            ForEach(model.offeredPlans) { plan in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text(plan.label ?? plan.key)
                            .font(.brand(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Spacer(minLength: Spacing.sm)
                        if model.isCurrent(plan) {
                            StatusPill(text: "Current", tone: .accent)
                        }
                    }
                    if let total = plan.totalPaise {
                        Text(BillingMoney.rupees(paise: total) + plan.periodCaption)
                            .font(.brand(.footnote, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.textSecondary)
                    }
                    if let tagline = plan.tagline {
                        Text(tagline)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Spacing.xxs)
                .accessibilityElement(children: .combine)
            }
        } header: {
            SectionHeader(title: "Available plans")
        }
        .listRowBackground(theme.surface)
    }
}

// MARK: - The invoice

/// One invoice: who it was billed to, the plan line, GST where it was charged, any discount with
/// its code, the total, and the order and payment ids. Shared as text where the web prints.
struct BillingInvoiceView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let layout: BillingInvoiceLayout

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(layout.billedToName)
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(layout.billedToEmail)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textSecondary)
                } header: {
                    SectionHeader(title: "Billed to")
                }
                .listRowBackground(theme.surface)

                Section {
                    ForEach(layout.lines) { line in
                        BillingInvoiceLineRow(line: line)
                    }
                } header: {
                    SectionHeader(title: layout.issued)
                }
                .listRowBackground(theme.surface)

                Section {
                    Text(layout.orderLine)
                        .textSelection(.enabled)
                    if let payment = layout.paymentLine {
                        Text(payment)
                            .textSelection(.enabled)
                    }
                }
                .font(.brand(.caption).monospaced())
                .foregroundStyle(theme.textSecondary)
                .listRowBackground(theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle(layout.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: layout.plainText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share invoice")
                }
            }
        }
    }
}

private struct BillingInvoiceLineRow: View {
    @Environment(\.theme) private var theme

    let line: BillingInvoiceLayout.Line

    var body: some View {
        AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(line.label)
                .font(.brand(.subheadline, weight: line.kind == .total ? .semibold : .regular))
                .foregroundStyle(line.kind == .total ? theme.textPrimary : theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.sm)
            Text(line.value)
                .font(.brand(.subheadline, weight: line.kind == .total ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(line.kind == .discount ? theme.success : theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The view model's tones as the app's pill tones.
private enum BillingTone {
    static func pill(_ tone: BillingViewModel.Tone) -> StatusPill.Tone {
        switch tone {
        case .neutral: return .neutral
        case .success: return .success
        case .warning: return .warning
        case .danger: return .danger
        }
    }
}

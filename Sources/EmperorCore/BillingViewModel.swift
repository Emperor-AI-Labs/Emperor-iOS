import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The Billing screen: the plan and its standing, the payment history, an invoice per paid
/// order, and "Redeem a coupon" — the web's Billing page (`src/pages/Billing.jsx`) without the
/// purchase, which is the web's (`WebPlans`).
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class BillingViewModel {

    /// How the standing pill is drawn.
    enum Tone: Equatable, Sendable { case neutral, success, warning, danger }

    struct Standing: Equatable, Sendable {
        var text: String
        var tone: Tone
    }

    /// A row of the payment history.
    struct OrderRow: Equatable, Identifiable, Sendable {
        var id: String
        var date: String
        var plan: String
        var amount: String
        var status: String
        var statusTone: Tone
        /// Only a paid order has an invoice.
        var hasInvoice: Bool
    }

    /// Where the coupon box is.
    enum CouponPhase: Equatable, Sendable {
        case idle
        case checking
        /// Checked and good. Redeemable here only when it owes nothing (`isRedeemableHere`).
        case preview(CouponPreview)
        case redeeming(CouponPreview)
        /// Redeemed; the sentence to show.
        case redeemed(String)
        /// Refused or failed. `offersPlans` when the way on is the plans page.
        case failed(String, offersPlans: Bool)
    }

    private(set) var account: BillingAccount?
    private(set) var catalogue: BillingCatalogue?
    private(set) var state: LoadState = .idle

    /// The coupon box's text. Set through `setCode`, which clears whatever the last code said.
    private(set) var code = ""
    private(set) var coupon: CouponPhase = .idle

    /// The invoice open on screen; set to `nil` to close it.
    var invoice: BillingInvoice?
    /// The order whose invoice is being fetched.
    private(set) var loadingInvoiceID: String?
    var invoiceError: String?

    private let service: any BillingProviding
    private let now: @Sendable () -> Date
    /// Called after a code grants a plan — `Session.refreshAccount`, so the rest of the app
    /// learns the plan at once.
    private let onRedeemed: @MainActor () async -> Void

    init(
        service: any BillingProviding,
        now: @escaping @Sendable () -> Date = { Date() },
        onRedeemed: @escaping @MainActor () async -> Void = {}
    ) {
        self.service = service
        self.now = now
        self.onRedeemed = onRedeemed
    }

    // MARK: - Loading

    /// Both reads at once. The catalogue only names and prices plans, so its failure never costs
    /// the account's own billing, which is what the screen is for.
    func load() async {
        state = .loading
        async let accountRead = service.account()
        async let catalogueRead = service.catalogue()
        do {
            account = try await accountRead
            catalogue = (try? await catalogueRead) ?? catalogue
            state = .loaded
        } catch {
            _ = try? await catalogueRead
            state = .failed(LoadFailure(error))
        }
    }

    // MARK: - The plan

    var plan: BillingPlanStatus? { account?.plan }
    var hasPlan: Bool { plan?.hasPlan ?? false }

    /// The plan's name, as the web's "Current plan" card writes it.
    var planTitle: String {
        if let label = plan?.displayLabel { return label }
        if let label = catalogue?.offered.first(where: { $0.key == plan?.marketingPlan })?.label {
            return label
        }
        return hasPlan ? "Your plan" : "No plan yet"
    }

    /// "Purchased · Active until 12 October 2026", "Included · No expiry".
    var planLine: String {
        guard let plan, plan.hasPlan, let source = plan.planSource else { return BillingCopy.noPlanLine }
        let how = Self.sourceWords[source] ?? "active"
        let when: String
        if source == "grandfathered" || plan.expiresAt == nil {
            when = "No expiry"
        } else {
            when = "\(plan.expired ? "Expired on" : "Active until") \(BillingMoney.day(plan.expiresAt))"
        }
        return how.prefix(1).uppercased() + how.dropFirst() + " · " + when
    }

    var standing: Standing { Self.standing(of: plan, now: now()) }

    /// The web's `statusOf`.
    nonisolated static func standing(of plan: BillingPlanStatus?, now: Date) -> Standing {
        guard let plan, plan.hasPlan else { return Standing(text: "No plan", tone: .neutral) }
        if plan.expired { return Standing(text: "Expired", tone: .danger) }
        guard let days = BillingMoney.daysLeft(plan.expiresAt, now: now) else {
            return Standing(text: "Active", tone: .success)
        }
        if days <= 0 { return Standing(text: "Expires today", tone: .warning) }
        if days < 14 {
            return Standing(text: "Expires in \(days) day\(days == 1 ? "" : "s")", tone: .warning)
        }
        return Standing(text: "Active", tone: .success)
    }

    /// How a plan was come by, as the web says it.
    nonisolated static let sourceWords: [String: String] = [
        "purchase": "purchased",
        "coupon": "free trial",
        "admin": "granted by admin",
        "grandfathered": "included",
    ]

    // MARK: - Plans

    /// The plans the web lists here — none below the one held. Shown only where the build sends
    /// anyone to buy one (`WebPlans`).
    var offeredPlans: [BillingCataloguePlan] { catalogue?.offered ?? [] }

    func isCurrent(_ catalogued: BillingCataloguePlan) -> Bool {
        hasPlan && catalogued.key == plan?.marketingPlan
    }

    // MARK: - Payment history

    var orders: [OrderRow] {
        (account?.orders ?? []).map { order in
            let status = Self.orderStatus(order.status)
            return OrderRow(
                id: order.orderID,
                date: BillingMoney.day(order.paidAt ?? order.createdAt),
                plan: catalogue?.label(for: order.planKey) ?? order.planKey ?? "—",
                amount: BillingMoney.rupees(paise: order.amountPaise),
                status: status.text,
                statusTone: status.tone,
                hasInvoice: order.isPaid)
        }
    }

    nonisolated static func orderStatus(_ raw: String?) -> Standing {
        switch raw {
        case "paid": return Standing(text: "paid", tone: .success)
        case "created": return Standing(text: "pending", tone: .neutral)
        case "failed": return Standing(text: "failed", tone: .danger)
        default: return Standing(text: raw ?? "—", tone: .neutral)
        }
    }

    // MARK: - Invoices

    func openInvoice(orderID: String) async {
        guard loadingInvoiceID == nil else { return }
        loadingInvoiceID = orderID
        invoiceError = nil
        defer { loadingInvoiceID = nil }
        do {
            invoice = try await service.invoice(orderID: orderID)
        } catch {
            invoiceError = DisplayText.message(for: error)
        }
    }

    /// The open invoice, laid out.
    var invoiceLayout: BillingInvoiceLayout? {
        invoice.map { BillingInvoiceLayout($0, planLabel: catalogue?.label(for: $0.plan?.key)) }
    }

    // MARK: - Coupon

    func setCode(_ text: String) {
        guard text != code else { return }
        code = text
        if !isCouponBusy { coupon = .idle }
    }

    var isCouponBusy: Bool {
        switch coupon {
        case .checking, .redeeming: return true
        default: return false
        }
    }

    var canApply: Bool {
        !BillingCopy.normalisedCode(code).isEmpty && !isCouponBusy
    }

    /// The plan a code is checked against: the one held, or else the first on offer — a
    /// percentage is worth a different amount on each, so the web always names one.
    var couponPlanKey: String? {
        plan?.marketingPlan ?? offeredPlans.first?.key
    }

    func applyCoupon() async {
        guard canApply else { return }
        coupon = .checking
        do {
            let preview = try await service.previewCoupon(code: code, planKey: couponPlanKey)
            coupon = .preview(preview)
        } catch {
            coupon = Self.failure(error)
        }
    }

    /// Redeems the previewed code, then reads the account again here and everywhere else.
    func redeemCoupon() async {
        guard case .preview(let preview) = coupon, preview.isRedeemableHere else { return }
        coupon = .redeeming(preview)
        do {
            let result = try await service.redeemCoupon(preview)
            code = ""
            coupon = .redeemed(Self.redeemedLine(code: preview.code, days: result.days))
            await onRedeemed()
            await reloadQuietly()
        } catch {
            coupon = Self.failure(error)
        }
    }

    /// "WELCOME30 applied. 30 days added."
    nonisolated static func redeemedLine(code: String, days: Int?) -> String {
        guard let days, days > 0 else { return "\(code) applied." }
        return "\(code) applied. \(days) day\(days == 1 ? "" : "s") added."
    }

    /// What a checked code would do, in words — the web's preview box.
    nonisolated static func previewLine(_ preview: CouponPreview) -> String {
        if preview.isRedeemableHere {
            let grant = preview.freeDays > 0
                ? "Grants \(preview.freeDays) day\(preview.freeDays == 1 ? "" : "s") at no charge."
                : "Grants this plan at no charge."
            return grant + " No payment is needed."
        }
        var line = "This is a discount, applied when a plan is bought on the web."
        if preview.discountPaise > 0 {
            line += " Worth \(BillingMoney.rupees(paise: preview.discountPaise)) off."
        }
        return line
    }

    private static func failure(_ error: Error) -> CouponPhase {
        if let refusal = error as? CouponRefusal {
            return .failed(refusal.message, offersPlans: refusal.pointsToPlans)
        }
        return .failed(DisplayText.message(for: error), offersPlans: false)
    }

    /// After a redemption: the new plan and its order, without the screen going back to a
    /// spinner or losing what it shows if the read fails.
    private func reloadQuietly() async {
        if let fresh = try? await service.account() { account = fresh }
        if let fresh = try? await service.catalogue() { catalogue = fresh }
    }
}

/// An invoice as rows — the web's `InvoiceModal`: who it was billed to, the plan line, GST only
/// where it was charged, the discount with its code, the total, and the order and payment ids.
struct BillingInvoiceLayout: Equatable, Sendable {
    struct Line: Equatable, Sendable, Identifiable {
        enum Kind: Equatable, Sendable { case charge, discount, total }
        var label: String
        var value: String
        var kind: Kind
        var id: String { label }
    }

    var title: String
    var issued: String
    var billedToName: String
    var billedToEmail: String
    var lines: [Line]
    var orderLine: String
    var paymentLine: String?

    init(_ invoice: BillingInvoice, planLabel: String? = nil) {
        title = "Invoice \(invoice.number ?? "—")"
        issued = "Issued \(BillingMoney.day(invoice.issuedAt))"
        billedToName = invoice.billTo?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        billedToEmail = invoice.billTo?.email.flatMap { $0.isEmpty ? nil : $0 } ?? "—"

        let l = invoice.lines
        var rows = [Line(label: Self.planLabel(invoice.plan, name: planLabel),
                         value: BillingMoney.rupees(paise: l.basePaise), kind: .charge)]
        // No "GST ₹0.00" line: on an invoice that reads as a claim about tax treatment, and an
        // order placed while GST was off simply has none.
        if let gst = l.gstPaise, gst > 0 {
            rows.append(Line(label: "GST", value: BillingMoney.rupees(paise: gst), kind: .charge))
        }
        if l.discountPaise > 0 {
            rows.append(Line(
                label: "Discount" + (l.couponCode.map { " — \($0)" } ?? ""),
                value: "−" + BillingMoney.rupees(paise: l.discountPaise), kind: .discount))
        }
        rows.append(Line(label: "Total (\(invoice.currency ?? "INR"))",
                         value: BillingMoney.rupees(paise: l.totalPaise), kind: .total))
        lines = rows
        orderLine = "Order \(invoice.orderId ?? "—")"
        paymentLine = invoice.paymentId.flatMap { $0.isEmpty ? nil : "Payment \($0)" }
    }

    /// The invoice as plain text, for the share sheet — the phone's stand-in for the web's Print.
    var plainText: String {
        var parts = [title, issued, "", "Billed to", billedToName, billedToEmail, ""]
        parts += lines.map { "\($0.label): \($0.value)" }
        parts += ["", orderLine]
        if let paymentLine { parts.append(paymentLine) }
        return parts.joined(separator: "\n")
    }

    /// "Plan — Premium (1 month)", "Plan — day_pass (1 day)". The plan's name where the catalogue
    /// knows it, else the key the web prints.
    static func planLabel(_ plan: BillingInvoice.Plan?, name: String?) -> String {
        var label = "Plan — \(name ?? plan?.key ?? "—")"
        if let days = plan?.periodDays, days > 0 {
            label += " (\(days) day\(days == 1 ? "" : "s"))"
        } else if let months = plan?.periodMonths, months > 0 {
            label += " (\(months) month\(months == 1 ? "" : "s"))"
        }
        return label
    }
}

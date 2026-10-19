import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The account's billing, as the web's Billing page shows it (`src/pages/Billing.jsx`): the plan
// held and its standing, the payment history, an invoice for each paid order, and "Redeem a
// coupon". Every figure is read from the server. Nothing here computes a charge, and nothing
// here takes one — a purchase is made on the web (`WebPlans`).

// MARK: - Money and dates

/// Paise for display, as the web's `fmtPaise` prints them: two decimals, Indian grouping —
/// `299900` → `2,999.00`, `12345678900` → `12,34,56,789.00`.
///
/// Amounts arrive as paise integers and are divided only here, at the moment of display, so no
/// rounding can travel anywhere else. `BillingGolden` holds this to the web's own function.
enum BillingMoney {
    /// "2,999.00".
    static func figure(paise: Int) -> String {
        let negative = paise < 0
        let magnitude = paise.magnitude
        let whole = DisplayText.grouped(Int(magnitude / 100))
        let fraction = magnitude % 100
        return (negative ? "-" : "") + whole + "." + (fraction < 10 ? "0" : "") + String(fraction)
    }

    /// "₹2,999.00".
    static func rupees(paise: Int) -> String {
        "₹" + figure(paise: paise)
    }

    /// "12 October 2026" — a billing date, in India. SQLite's zoneless timestamps are UTC
    /// (`WireDate.parse`), which is the drift the web's `toDate` guards against too.
    static func day(_ raw: String?) -> String {
        guard let date = WireDate.parse(raw) ?? WireDate.parseDay(raw) else { return "—" }
        return dayFormatter.string(from: date)
    }

    /// Whole days until an instant, rounded up — the web's `daysLeft`. `nil` without a date.
    static func daysLeft(_ raw: String?, now: Date = Date()) -> Int? {
        guard let date = WireDate.parse(raw) ?? WireDate.parseDay(raw) else { return nil }
        return Int((date.timeIntervalSince(now) / 86_400).rounded(.up))
    }

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy"
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = WireDate.india
        return f
    }()
}

// MARK: - The wire

/// A number the server may write as `30` or `30.0`, or leave out.
private func lenientInt<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
    if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
    if let value = try? c.decodeIfPresent(Double.self, forKey: key), value.isFinite {
        return Int(value.rounded())
    }
    return nil
}

/// `billing.planStatus` (`lib/billingStore.js`), plus the `displayLabel` `/billing/me` adds.
struct BillingPlanStatus: Decodable, Equatable, Sendable {
    /// The tier: `lite`, `pro`, `ultra`, `none`. Every account has one, so it says nothing about
    /// whether a plan was ever chosen — `planSource` does.
    var plan: String?
    /// `purchase`, `coupon`, `admin`, `grandfathered`; `nil` when no plan was ever held.
    var planSource: String?
    var expiresAt: String?
    var expired: Bool
    /// The plan the account bought (`users.plan_key`).
    var marketingPlan: String?
    var marketingPlanLabel: String?
    /// What the top bar calls the plan.
    var displayLabel: String?
    var feeTier: String?

    init(plan: String? = nil, planSource: String? = nil, expiresAt: String? = nil,
         expired: Bool = false, marketingPlan: String? = nil, marketingPlanLabel: String? = nil,
         displayLabel: String? = nil, feeTier: String? = nil) {
        self.plan = plan
        self.planSource = planSource
        self.expiresAt = expiresAt
        self.expired = expired
        self.marketingPlan = marketingPlan
        self.marketingPlanLabel = marketingPlanLabel
        self.displayLabel = displayLabel
        self.feeTier = feeTier
    }

    enum CodingKeys: String, CodingKey {
        case plan, planSource, expiresAt, expired, marketingPlan, marketingPlanLabel, displayLabel, feeTier
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try? c.decodeIfPresent(String.self, forKey: .plan)
        planSource = (try? c.decodeIfPresent(String.self, forKey: .planSource))?.billingNonBlank
        expiresAt = (try? c.decodeIfPresent(String.self, forKey: .expiresAt))?.billingNonBlank
        expired = (try? c.decodeIfPresent(Bool.self, forKey: .expired)) ?? false
        marketingPlan = (try? c.decodeIfPresent(String.self, forKey: .marketingPlan))?.billingNonBlank
        marketingPlanLabel = (try? c.decodeIfPresent(String.self, forKey: .marketingPlanLabel))?.billingNonBlank
        displayLabel = (try? c.decodeIfPresent(String.self, forKey: .displayLabel))?.billingNonBlank
        feeTier = try? c.decodeIfPresent(String.self, forKey: .feeTier)
    }

    /// Whether a plan was ever chosen. Keyed off `planSource`, as the web does: reading the tier
    /// would tell a brand-new account it is on a plan it never chose.
    var hasPlan: Bool { planSource != nil }
}

/// One row of `billing.listOrdersForUser`: an order as it was placed, newest first.
struct BillingOrder: Decodable, Equatable, Identifiable, Sendable {
    var orderID: String
    var planKey: String?
    var tier: String?
    var amountPaise: Int
    var currency: String?
    /// `created`, `paid` or `failed`.
    var status: String?
    var createdAt: String?
    var paidAt: String?

    var id: String { orderID }
    var isPaid: Bool { status == "paid" }

    init(orderID: String, planKey: String? = nil, tier: String? = nil, amountPaise: Int = 0,
         currency: String? = "INR", status: String? = nil, createdAt: String? = nil,
         paidAt: String? = nil) {
        self.orderID = orderID
        self.planKey = planKey
        self.tier = tier
        self.amountPaise = amountPaise
        self.currency = currency
        self.status = status
        self.createdAt = createdAt
        self.paidAt = paidAt
    }

    enum CodingKeys: String, CodingKey {
        case orderID = "razorpay_order_id"
        case planKey = "plan_key"
        case tier
        case amountPaise = "amount_paise"
        case currency, status
        case createdAt = "created_at"
        case paidAt = "paid_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orderID = try c.decode(String.self, forKey: .orderID)
        planKey = try? c.decodeIfPresent(String.self, forKey: .planKey)
        tier = try? c.decodeIfPresent(String.self, forKey: .tier)
        amountPaise = lenientInt(c, .amountPaise) ?? 0
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        paidAt = try? c.decodeIfPresent(String.self, forKey: .paidAt)
    }
}

/// `GET /billing/me`: `{success, plan, orders}`.
struct BillingAccount: Decodable, Equatable, Sendable {
    var plan: BillingPlanStatus?
    var orders: [BillingOrder]

    init(plan: BillingPlanStatus?, orders: [BillingOrder]) {
        self.plan = plan
        self.orders = orders
    }

    enum CodingKeys: String, CodingKey { case success, plan, orders, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let success = try? c.decodeIfPresent(Bool.self, forKey: .success)
        guard success == true else {
            let error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil
            throw APIError.server(status: 200, message: error ?? BillingCopy.couldNotLoad)
        }
        plan = try? c.decodeIfPresent(BillingPlanStatus.self, forKey: .plan)
        // One unreadable order costs that order, not the history.
        let rows = (try? c.decodeIfPresent([LenientOrder].self, forKey: .orders)) ?? []
        orders = rows.compactMap(\.order)
    }

    private struct LenientOrder: Decodable {
        let order: BillingOrder?
        init(from decoder: Decoder) throws { order = try? BillingOrder(from: decoder) }
    }
}

/// One plan in `/billing/config`'s catalogue — the parts this client reads: the name an order's
/// `plan_key` is shown under, the price, and where it sits against the account's plan.
struct BillingCataloguePlan: Decodable, Equatable, Identifiable, Sendable {
    var key: String
    var label: String?
    var periodMonths: Int?
    var periodDays: Int?
    var totalPaise: Int?
    var tagline: String?
    /// `upgrade`, `renew` or `downgrade` — advisory, against the signed-in account.
    var action: String?

    var id: String { key }

    init(key: String, label: String? = nil, periodMonths: Int? = nil, periodDays: Int? = nil,
         totalPaise: Int? = nil, tagline: String? = nil, action: String? = nil) {
        self.key = key
        self.label = label
        self.periodMonths = periodMonths
        self.periodDays = periodDays
        self.totalPaise = totalPaise
        self.tagline = tagline
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case key, label, periodMonths, periodDays, totalPaise, tagline, action
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = (try? c.decodeIfPresent(String.self, forKey: .label))?.billingNonBlank
        periodMonths = lenientInt(c, .periodMonths)
        periodDays = lenientInt(c, .periodDays)
        totalPaise = lenientInt(c, .totalPaise)
        tagline = (try? c.decodeIfPresent(String.self, forKey: .tagline))?.billingNonBlank
        action = try? c.decodeIfPresent(String.self, forKey: .action)
    }

    /// "/mo", " · 3 months", " · 1 day" — the web's caption beside a price.
    var periodCaption: String {
        if let days = periodDays, days > 0 { return days == 1 ? " · 1 day" : " · \(days) days" }
        if let months = periodMonths, months > 1 { return " · \(months) months" }
        return "/mo"
    }
}

/// `GET /billing/config`, read for its plans. A failure here never costs the screen: the
/// catalogue only names plans and prices them.
struct BillingCatalogue: Decodable, Equatable, Sendable {
    var plans: [BillingCataloguePlan]

    init(plans: [BillingCataloguePlan]) { self.plans = plans }

    enum CodingKeys: String, CodingKey { case plans }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = (try? c.decodeIfPresent([LenientPlan].self, forKey: .plans)) ?? []
        plans = rows.compactMap(\.plan)
    }

    private struct LenientPlan: Decodable {
        let plan: BillingCataloguePlan?
        init(from decoder: Decoder) throws { plan = try? BillingCataloguePlan(from: decoder) }
    }

    /// What the web lists: nothing below the plan already held. The current plan is `renew`,
    /// not `downgrade`, so it stays.
    var offered: [BillingCataloguePlan] {
        plans.filter { ($0.action ?? "upgrade") != "downgrade" }
    }

    func label(for key: String?) -> String? {
        guard let key else { return nil }
        return plans.first { $0.key == key }?.label
    }
}

/// `billing.invoiceFor` (`lib/billingStore.js`): one order as an invoice, built from the order
/// row — what was charged then, never the catalogue's price now.
struct BillingInvoice: Decodable, Equatable, Sendable {
    struct BillTo: Decodable, Equatable, Sendable {
        var name: String?
        var email: String?
    }

    struct Plan: Decodable, Equatable, Sendable {
        var key: String?
        var tier: String?
        var periodMonths: Int?
        var periodDays: Int?

        init(key: String? = nil, tier: String? = nil, periodMonths: Int? = nil, periodDays: Int? = nil) {
            self.key = key
            self.tier = tier
            self.periodMonths = periodMonths
            self.periodDays = periodDays
        }

        enum CodingKeys: String, CodingKey { case key, tier, periodMonths, periodDays }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = (try? c.decodeIfPresent(String.self, forKey: .key))?.billingNonBlank
            tier = try? c.decodeIfPresent(String.self, forKey: .tier)
            periodMonths = lenientInt(c, .periodMonths)
            periodDays = lenientInt(c, .periodDays)
        }
    }

    struct Lines: Decodable, Equatable, Sendable {
        var basePaise: Int
        /// `nil` or zero for an order placed while GST was not charged.
        var gstPaise: Int?
        var discountPaise: Int
        var couponCode: String?
        var totalPaise: Int

        init(basePaise: Int, gstPaise: Int? = nil, discountPaise: Int = 0,
             couponCode: String? = nil, totalPaise: Int) {
            self.basePaise = basePaise
            self.gstPaise = gstPaise
            self.discountPaise = discountPaise
            self.couponCode = couponCode
            self.totalPaise = totalPaise
        }

        enum CodingKeys: String, CodingKey { case basePaise, gstPaise, discountPaise, couponCode, totalPaise }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            basePaise = lenientInt(c, .basePaise) ?? 0
            gstPaise = lenientInt(c, .gstPaise)
            discountPaise = lenientInt(c, .discountPaise) ?? 0
            couponCode = (try? c.decodeIfPresent(String.self, forKey: .couponCode))?.billingNonBlank
            totalPaise = lenientInt(c, .totalPaise) ?? 0
        }
    }

    var number: String?
    var orderId: String?
    var paymentId: String?
    var status: String?
    var issuedAt: String?
    var billTo: BillTo?
    var plan: Plan?
    var lines: Lines
    var currency: String?
}

/// `POST /billing/coupon/preview`: what a code would do, against one plan. Writes nothing.
struct CouponPreview: Equatable, Sendable {
    /// `free_period`, `percent_off` or `amount_off`.
    var kind: String?
    /// "30 days free", "20% off", "₹500.00 off".
    var label: String?
    var discountPaise: Int
    var finalPaise: Int?
    var freeDays: Int
    var grantsPlanKey: String?
    var fullyDiscounted: Bool
    /// The code as it will be redeemed: trimmed and upper-cased, as the web sends it.
    var code: String
    /// The plan it was checked against, sent again on redemption.
    var planKey: String?

    /// Owes nothing: a free period, or a discount that takes the price below the gateway's
    /// minimum. Only these are redeemed here; anything else is used where a plan is bought.
    var isRedeemableHere: Bool { kind == "free_period" || fullyDiscounted }
}

/// The preview's wire shape: `{success, valid, …}` or `{success, valid:false, reason}`.
struct CouponPreviewResponse: Decodable, Sendable {
    var valid: Bool
    var reason: String?
    var kind: String?
    var label: String?
    var discountPaise: Int
    var finalPaise: Int?
    var freeDays: Int
    var grantsPlanKey: String?
    var fullyDiscounted: Bool

    enum CodingKeys: String, CodingKey {
        case valid, reason, kind, label, discountPaise, finalPaise, freeDays, grantsPlanKey, fullyDiscounted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        valid = (try? c.decodeIfPresent(Bool.self, forKey: .valid)) ?? false
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason))?.billingNonBlank
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        label = (try? c.decodeIfPresent(String.self, forKey: .label))?.billingNonBlank
        discountPaise = lenientInt(c, .discountPaise) ?? 0
        finalPaise = lenientInt(c, .finalPaise)
        freeDays = lenientInt(c, .freeDays) ?? 0
        grantsPlanKey = (try? c.decodeIfPresent(String.self, forKey: .grantsPlanKey))?.billingNonBlank
        fullyDiscounted = (try? c.decodeIfPresent(Bool.self, forKey: .fullyDiscounted)) ?? false
    }
}

/// `POST /billing/coupon/redeem`, 200: `{success, granted, planKey, days, expiresAt, plan}`.
struct CouponRedemption: Decodable, Equatable, Sendable {
    var granted: Bool
    var planKey: String?
    var days: Int?
    var expiresAt: String?

    init(granted: Bool, planKey: String? = nil, days: Int? = nil, expiresAt: String? = nil) {
        self.granted = granted
        self.planKey = planKey
        self.days = days
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case granted, planKey, days, expiresAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        granted = (try? c.decodeIfPresent(Bool.self, forKey: .granted)) ?? false
        planKey = try? c.decodeIfPresent(String.self, forKey: .planKey)
        days = lenientInt(c, .days)
        expiresAt = try? c.decodeIfPresent(String.self, forKey: .expiresAt)
    }
}

/// Why a code was not redeemed. Each is worded by this client (`BillingCopy`), except where the
/// coupon's own reason is specific and says nothing about buying ("That code has expired.").
enum CouponRefusal: Error, Equatable, Sendable {
    /// 400 `COUPON_INVALID`: not recognised, expired, used, for another plan. Carries the reason.
    case invalid(String?)
    /// 400 `NEEDS_PAYMENT`: a discount, which is used when a plan is bought.
    case needsPayment
    /// 409 `PLAN_DOWNGRADE`: the code is for a plan below the one the account holds.
    case planDowngrade
    /// 409 `COUPON_SPENT`: the last use went to someone else, or this account has used it.
    case spent(String?)
    /// Any other refusal, with the server's sentence where it gave one.
    case other(String?)

    static func parse(status: Int, body: Data) -> CouponRefusal? {
        struct Body: Decodable { var error: String?; var code: String? }
        guard !(200..<300).contains(status) else { return nil }
        let decoded = try? JSONDecoder().decode(Body.self, from: body)
        let reason = decoded?.error?.trimmingCharacters(in: .whitespacesAndNewlines).billingNonBlank
        switch decoded?.code {
        case "COUPON_INVALID": return .invalid(reason)
        case "NEEDS_PAYMENT": return .needsPayment
        case "PLAN_DOWNGRADE": return .planDowngrade
        case "COUPON_SPENT": return .spent(reason)
        default: return status == 400 ? .other(reason) : nil
        }
    }

    var message: String {
        switch self {
        case .invalid(let reason): return reason ?? BillingCopy.codeNotValid
        case .needsPayment: return BillingCopy.needsPayment
        case .planDowngrade: return BillingCopy.planDowngrade
        case .spent(let reason): return reason ?? BillingCopy.codeSpent
        case .other(let reason): return reason ?? BillingCopy.couldNotRedeem
        }
    }

    /// Whether the plans page is the way on. Only for a discount, which is used there.
    var pointsToPlans: Bool { self == .needsPayment }
}

// MARK: - The service

protocol BillingProviding: Sendable {
    func account() async throws -> BillingAccount
    func catalogue() async throws -> BillingCatalogue
    func invoice(orderID: String) async throws -> BillingInvoice
    func previewCoupon(code: String, planKey: String?) async throws -> CouponPreview
    func redeemCoupon(_ preview: CouponPreview) async throws -> CouponRedemption
}

/// The `/billing/*` reads and the coupon routes. All of them identify the caller by the bearer
/// token; a dead token answers 401 and signs out as anywhere else.
struct BillingService: BillingProviding {
    let client: APIClient

    func account() async throws -> BillingAccount {
        let request = try await client.makeRequest("GET", "/billing/me")
        return try await client.send(request, as: BillingAccount.self)
    }

    /// Signed, as the web's Billing page sends it: each plan's `action` is about this account.
    func catalogue() async throws -> BillingCatalogue {
        let request = try await client.makeRequest("GET", "/billing/config")
        return try await client.send(request, as: BillingCatalogue.self)
    }

    private struct InvoiceEnvelope: Decodable {
        var success: Bool?
        var invoice: BillingInvoice?
    }

    func invoice(orderID: String) async throws -> BillingInvoice {
        let request = try await client.makeRequest("GET", "/billing/invoice", query: ["orderId": orderID])
        do {
            let reply = try await client.send(request, as: InvoiceEnvelope.self)
            guard let invoice = reply.invoice else {
                throw APIError.server(status: 200, message: BillingCopy.invoiceUnavailable)
            }
            return invoice
        } catch APIError.server(let status, _) where status == 403 || status == 404 {
            // "Forbidden" and "No such invoice" are the server's words for a log; this is the
            // person's.
            throw APIError.server(status: status, message: BillingCopy.invoiceUnavailable)
        }
    }

    private struct CouponBody: Encodable {
        let code: String
        let plan: String?
    }

    func previewCoupon(code: String, planKey: String?) async throws -> CouponPreview {
        let normalised = BillingCopy.normalisedCode(code)
        let request = try await client.makeRequest(
            "POST", "/billing/coupon/preview", body: CouponBody(code: normalised, plan: planKey))
        let (data, response) = try await client.perform(request)
        if response.statusCode == 401 {
            await client.noteAuthenticationLost()
            throw APIError.invalidCredentials
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.server(status: response.statusCode, message: BillingCopy.couldNotCheck)
        }
        guard let reply = try? JSONDecoder().decode(CouponPreviewResponse.self, from: data) else {
            throw APIError.server(status: response.statusCode, message: BillingCopy.couldNotCheck)
        }
        guard reply.valid else { throw CouponRefusal.invalid(reply.reason) }
        return CouponPreview(
            kind: reply.kind, label: reply.label, discountPaise: reply.discountPaise,
            finalPaise: reply.finalPaise, freeDays: reply.freeDays,
            grantsPlanKey: reply.grantsPlanKey, fullyDiscounted: reply.fullyDiscounted,
            code: normalised, planKey: planKey)
    }

    /// Redeems a code that owes nothing. Refusals come back as `CouponRefusal`, read from the
    /// response's `code` — which is why this reads the response itself rather than through
    /// `send`, whose error keeps only the sentence.
    func redeemCoupon(_ preview: CouponPreview) async throws -> CouponRedemption {
        let request = try await client.makeRequest(
            "POST", "/billing/coupon/redeem", body: CouponBody(code: preview.code, plan: preview.planKey))
        let (data, response) = try await client.perform(request)
        if response.statusCode == 401 {
            await client.noteAuthenticationLost()
            throw APIError.invalidCredentials
        }
        if let refusal = CouponRefusal.parse(status: response.statusCode, body: data) {
            throw refusal
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.classify(status: response.statusCode, body: data)
        }
        guard let reply = try? JSONDecoder().decode(CouponRedemption.self, from: data), reply.granted else {
            throw CouponRefusal.other(nil)
        }
        return reply
    }
}

// MARK: - Wording

enum BillingCopy {
    static let title = "Billing"
    static let subtitle = "Your plan, your payments and your invoices."
    static let couldNotLoad = "Your billing details couldn't be loaded."
    static let noPaymentsYet = "No payments yet."
    static let invoiceUnavailable = "That invoice couldn't be opened."
    static let codePlaceholder = "e.g. WELCOME30"
    static let couldNotCheck = "That code couldn't be checked. Try again in a moment."
    static let codeNotValid = "That code is not valid."
    static let codeSpent = "That code has already been used."
    static let couldNotRedeem = "That code couldn't be redeemed."
    /// `NEEDS_PAYMENT`, worded here: the server's sentence sends the reader to a payment step.
    static let needsPayment =
        "This code is a discount. It is applied when a plan is bought on the web, not redeemed here."
    /// `PLAN_DOWNGRADE`, worded here.
    static let planDowngrade =
        "This code is for a plan below the one this account already holds, so it was not used. Your plan is unchanged."
    static let footer =
        "Every amount is what was charged, taken from the order itself. Repricing a plan never changes an invoice already issued."
    static let noPlanLine = "No plan has been taken on this account."

    /// The code as the web sends it to redemption: trimmed and upper-cased.
    static func normalisedCode(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

private extension String {
    /// `nil` for a blank string, so an empty field reads as absent.
    var billingNonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}

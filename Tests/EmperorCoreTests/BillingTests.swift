import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

// MARK: - Golden: the web's own formatting

/// `BillingMoney` and the standing pill held to `src/pages/Billing.jsx`, run under Node.
final class BillingGoldenTests: XCTestCase {

    private struct Golden: Decodable {
        struct Money: Decodable { let paise: Int; let text: String }
        struct Day: Decodable { let raw: String; let text: String; let daysLeft: Int? }
        struct Plan: Decodable {
            let planSource: String?
            let expired: Bool?
            let expiresAt: String?
        }
        struct StandingCase: Decodable {
            let plan: Plan?
            let standing: Pill
        }
        struct Pill: Decodable { let tone: String; let text: String }
        let now: String
        let money: [Money]
        let dates: [Day]
        let standings: [StandingCase]
        let sourceWords: [String: String]
        let orderStatus: [String: String]
    }

    private func golden() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: Data(BillingGolden.json.utf8))
    }

    func testPaiseArePrintedAsTheWebPrintsThem() throws {
        let golden = try golden()
        XCTAssertFalse(golden.money.isEmpty)
        for row in golden.money {
            XCTAssertEqual(BillingMoney.figure(paise: row.paise), row.text, "\(row.paise)")
            XCTAssertEqual(BillingMoney.rupees(paise: row.paise), "₹" + row.text)
        }
    }

    func testBillingDatesAndDaysLeftMatchTheWebInIndia() throws {
        let golden = try golden()
        let now = try XCTUnwrap(WireDate.parse(golden.now))
        for row in golden.dates {
            XCTAssertEqual(BillingMoney.day(row.raw), row.text, row.raw)
            XCTAssertEqual(BillingMoney.daysLeft(row.raw, now: now), row.daysLeft, row.raw)
        }
        XCTAssertEqual(BillingMoney.day(nil), "—")
        XCTAssertNil(BillingMoney.daysLeft(nil, now: now))
    }

    @MainActor
    private static func standing(_ plan: Golden.Plan?, now: Date) -> BillingViewModel.Standing {
        let status = plan.map {
            BillingPlanStatus(planSource: $0.planSource, expiresAt: $0.expiresAt, expired: $0.expired ?? false)
        }
        return BillingViewModel.standing(of: status, now: now)
    }

    func testTheStandingPillIsTheWebsStatusOf() async throws {
        let golden = try golden()
        let now = try XCTUnwrap(WireDate.parse(golden.now))
        for row in golden.standings {
            let mine = await Self.standing(row.plan, now: now)
            XCTAssertEqual(mine.text, row.standing.text)
            let tone: BillingViewModel.Tone = switch row.standing.tone {
            case "success": .success
            case "warn": .warning
            case "danger": .danger
            default: .neutral
            }
            XCTAssertEqual(mine.tone, tone, row.standing.text)
        }
    }

    func testSourceWordsAndOrderStatusesAreTheWebs() async throws {
        let golden = try golden()
        let words = await MainActor.run { BillingViewModel.sourceWords }
        XCTAssertEqual(words, golden.sourceWords)
        for (raw, text) in golden.orderStatus {
            let mine = await MainActor.run { BillingViewModel.orderStatus(raw).text }
            XCTAssertEqual(mine, text)
        }
    }
}

// MARK: - The wire

final class BillingServiceWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> (BillingService, APIClient) {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return (BillingService(client: client), client)
    }

    func testTheAccountIsReadFromBillingMe() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(#"""
        {"success":true,"plan":{"plan":"ultra","planSource":"purchase","expiresAt":"2026-11-18T10:00:00.000Z","expired":false,"effectivePlan":"ultra","marketingPlan":"premium_monthly","marketingPlanLabel":"Premium","feeTier":"premium","legacy":false,"cycle":"monthly","limits":{},"displayLabel":"Premium"},
         "orders":[{"razorpay_order_id":"order_A","plan_key":"premium_monthly","tier":"ultra","amount_paise":589882,"currency":"INR","status":"paid","created_at":"2026-10-18 09:00:00","paid_at":"2026-10-18 09:02:11"},
                   {"razorpay_order_id":"order_B","plan_key":"premium_monthly","amount_paise":589882.0,"status":"created","created_at":"2026-10-17 09:00:00","paid_at":null},
                   {"plan_key":"broken"}]}
        """#))

        let account = try await service.account()

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.path, "/api/billing/me")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
        XCTAssertEqual(account.plan?.displayLabel, "Premium")
        XCTAssertEqual(account.plan?.marketingPlan, "premium_monthly")
        XCTAssertTrue(account.plan?.hasPlan ?? false)
        // The row with no order id is dropped; the rest survive it.
        XCTAssertEqual(account.orders.map(\.orderID), ["order_A", "order_B"])
        XCTAssertEqual(account.orders[0].amountPaise, 589882)
        XCTAssertEqual(account.orders[1].amountPaise, 589882)
        XCTAssertTrue(account.orders[0].isPaid)
        XCTAssertFalse(account.orders[1].isPaid)
    }

    func testANeverChosenPlanIsNoPlan() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(#"{"success":true,"plan":{"plan":"lite","planSource":null,"expiresAt":null,"expired":false},"orders":[]}"#))
        let account = try await service.account()
        XCTAssertEqual(account.plan?.plan, "lite")
        XCTAssertFalse(account.plan?.hasPlan ?? true)
    }

    func testTheCatalogueIsReadForItsPlans() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(#"""
        {"success":true,"configured":true,"plans":[
          {"key":"essential_monthly","label":"Junior Associate","periodMonths":1,"periodDays":0,"basePaise":299900,"totalPaise":299900,"action":"downgrade"},
          {"key":"premium_monthly","label":"Premium","periodMonths":1,"totalPaise":499900,"tagline":"For a busy chamber","action":"renew"},
          {"key":"premium_annual","label":"Premium (annual)","periodMonths":12,"totalPaise":4999900,"action":"upgrade"},
          {"key":"day_pass","label":"Day pass","periodDays":1,"totalPaise":19900}
        ],"currentPlan":{"key":"premium_monthly"}}
        """#))

        let catalogue = try await service.catalogue()

        XCTAssertEqual(HTTPStub.lastRequest?.path, "/api/billing/config")
        XCTAssertEqual(HTTPStub.lastRequest?.header("Authorization"), "Bearer tok-abc")
        XCTAssertEqual(catalogue.plans.count, 4)
        XCTAssertEqual(catalogue.offered.map(\.key), ["premium_monthly", "premium_annual", "day_pass"])
        XCTAssertEqual(catalogue.label(for: "essential_monthly"), "Junior Associate")
        XCTAssertEqual(catalogue.offered.map(\.periodCaption), ["/mo", " · 12 months", " · 1 day"])
    }

    func testAnInvoiceIsAskedForByOrderID() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(#"""
        {"success":true,"invoice":{"number":"EA-000012","orderId":"order_A","paymentId":"pay_9","status":"paid","issuedAt":"2026-10-18 09:02:11",
         "billTo":{"name":"Asha Rao","email":"asha@chambers.in"},"plan":{"key":"premium_monthly","tier":"ultra","periodMonths":1,"periodDays":0},
         "lines":{"basePaise":499900,"gstPaise":89982,"discountPaise":0,"couponCode":null,"totalPaise":589882},"currency":"INR"}}
        """#))

        let invoice = try await service.invoice(orderID: "order_A")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/billing/invoice")
        XCTAssertEqual(sent.queryItems["orderId"], "order_A")
        XCTAssertEqual(invoice.number, "EA-000012")
        XCTAssertEqual(invoice.lines.gstPaise, 89982)
        XCTAssertNil(invoice.lines.couponCode)
        XCTAssertEqual(invoice.billTo?.email, "asha@chambers.in")
    }

    func testAnInvoiceThatIsNotThereOrNotOursIsWordedHere() async throws {
        let (service, _) = await makeService()
        for status in [403, 404] {
            HTTPStub.always(.json(#"{"error":"No such invoice"}"#, status: status))
            do {
                _ = try await service.invoice(orderID: "order_Z")
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(DisplayText.message(for: error), BillingCopy.invoiceUnavailable)
            }
        }
    }

    func testAPreviewSendsTheCodeAndThePlan() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(#"{"success":true,"valid":true,"kind":"free_period","label":"30 days free","discountPaise":0,"finalPaise":0,"freeDays":30,"grantsPlanKey":"premium_monthly","fullyDiscounted":false,"duration":null}"#))

        let preview = try await service.previewCoupon(code: "  welcome30 ", planKey: "premium_monthly")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.path, "/api/billing/coupon/preview")
        XCTAssertEqual(sent.bodyJSON["code"] as? String, "WELCOME30")
        XCTAssertEqual(sent.bodyJSON["plan"] as? String, "premium_monthly")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
        XCTAssertEqual(preview.code, "WELCOME30")
        XCTAssertEqual(preview.freeDays, 30)
        XCTAssertTrue(preview.isRedeemableHere)
    }

    func testAnInvalidCodeCarriesTheCouponsOwnReason() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(#"{"success":true,"valid":false,"reason":"That code has expired."}"#))
        do {
            _ = try await service.previewCoupon(code: "OLD", planKey: nil)
            XCTFail("expected a refusal")
        } catch let refusal as CouponRefusal {
            XCTAssertEqual(refusal, .invalid("That code has expired."))
            XCTAssertEqual(refusal.message, "That code has expired.")
        }
    }

    func testADiscountIsNotRedeemableHere() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(#"{"success":true,"valid":true,"kind":"percent_off","label":"20% off","discountPaise":99980,"finalPaise":399920,"freeDays":0,"grantsPlanKey":null,"fullyDiscounted":false,"duration":"once"}"#))
        let preview = try await service.previewCoupon(code: "SAVE20", planKey: "premium_monthly")
        XCTAssertFalse(preview.isRedeemableHere)
        XCTAssertEqual(preview.discountPaise, 99980)
    }

    func testARedemptionGrantsThePlan() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(#"{"success":true,"granted":true,"planKey":"premium_monthly","days":30,"expiresAt":"2026-11-18T10:00:00.000Z","plan":{"planSource":"coupon"}}"#))
        let preview = CouponPreview(kind: "free_period", label: nil, discountPaise: 0, finalPaise: 0,
                                    freeDays: 30, grantsPlanKey: nil, fullyDiscounted: false,
                                    code: "WELCOME30", planKey: "premium_monthly")

        let result = try await service.redeemCoupon(preview)

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/billing/coupon/redeem")
        XCTAssertEqual(sent.bodyJSON["code"] as? String, "WELCOME30")
        XCTAssertEqual(sent.bodyJSON["plan"] as? String, "premium_monthly")
        XCTAssertEqual(result, CouponRedemption(granted: true, planKey: "premium_monthly", days: 30, expiresAt: "2026-11-18T10:00:00.000Z"))
    }

    func testEachCodedRefusalIsRecognised() async throws {
        let (service, _) = await makeService()
        let preview = CouponPreview(kind: "free_period", label: nil, discountPaise: 0, finalPaise: 0,
                                    freeDays: 30, grantsPlanKey: nil, fullyDiscounted: false,
                                    code: "X", planKey: nil)
        let cases: [(Int, String, CouponRefusal)] = [
            (400, #"{"error":"That code is not recognised.","code":"COUPON_INVALID"}"#, .invalid("That code is not recognised.")),
            (400, #"{"error":"This code is a discount — continue to payment to use it.","code":"NEEDS_PAYMENT"}"#, .needsPayment),
            (409, #"{"error":"This code is for Junior Associate, which is below the Premium plan your account is already on.","code":"PLAN_DOWNGRADE"}"#, .planDowngrade),
            (409, #"{"error":"You have already used that code.","code":"COUPON_SPENT"}"#, .spent("You have already used that code.")),
            (400, #"{"error":"That code points at a plan that no longer exists."}"#, .other("That code points at a plan that no longer exists.")),
        ]
        for (status, body, expected) in cases {
            HTTPStub.always(.json(body, status: status))
            do {
                _ = try await service.redeemCoupon(preview)
                XCTFail("expected \(expected)")
            } catch let refusal as CouponRefusal {
                XCTAssertEqual(refusal, expected)
            }
        }
    }

    func testThePaymentAndDowngradeRefusalsAreWordedByThisClient() {
        // The server's sentences send the reader to a payment step; these never do.
        for refusal in [CouponRefusal.needsPayment, .planDowngrade] {
            XCTAssertFalse(refusal.message.lowercased().contains("upgrade"))
            XCTAssertFalse(refusal.message.lowercased().contains("continue to payment"))
        }
        XCTAssertTrue(CouponRefusal.needsPayment.pointsToPlans)
        XCTAssertFalse(CouponRefusal.planDowngrade.pointsToPlans)
        XCTAssertEqual(CouponRefusal.invalid(nil).message, BillingCopy.codeNotValid)
        XCTAssertEqual(CouponRefusal.spent(nil).message, BillingCopy.codeSpent)
    }

    func testA401OnRedemptionSignsOut() async throws {
        let (service, client) = await makeService()
        let lost = LostFlag()
        await client.setAuthenticationLostHandler { lost.set() }
        HTTPStub.always(.json(#"{"error":"Please sign in first.","code":"AUTH_REQUIRED"}"#, status: 401))
        let preview = CouponPreview(kind: "free_period", label: nil, discountPaise: 0, finalPaise: 0,
                                    freeDays: 1, grantsPlanKey: nil, fullyDiscounted: false,
                                    code: "X", planKey: nil)
        do {
            _ = try await service.redeemCoupon(preview)
            XCTFail("expected a sign-out")
        } catch {
            XCTAssertEqual(error as? APIError, .invalidCredentials)
        }
        XCTAssertTrue(lost.value)
    }
}

private final class LostFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

// MARK: - The screen

private final class FakeBilling: BillingProviding, @unchecked Sendable {
    var account = BillingAccount(plan: nil, orders: [])
    var accountError: Error?
    var catalogue = BillingCatalogue(plans: [])
    var catalogueError: Error?
    var invoiceResult: Result<BillingInvoice, Error> = .failure(APIError.server(status: 404, message: BillingCopy.invoiceUnavailable))
    var previewResult: Result<CouponPreview, Error> = .failure(CouponRefusal.invalid(nil))
    var redeemResult: Result<CouponRedemption, Error> = .success(CouponRedemption(granted: true, days: 30))
    private(set) var previewed: [(String, String?)] = []
    private(set) var redeemed: [CouponPreview] = []
    private(set) var accountReads = 0

    func account() async throws -> BillingAccount {
        accountReads += 1
        if let accountError { throw accountError }
        return account
    }
    func catalogue() async throws -> BillingCatalogue {
        if let catalogueError { throw catalogueError }
        return catalogue
    }
    func invoice(orderID: String) async throws -> BillingInvoice { try invoiceResult.get() }
    func previewCoupon(code: String, planKey: String?) async throws -> CouponPreview {
        previewed.append((code, planKey))
        return try previewResult.get()
    }
    func redeemCoupon(_ preview: CouponPreview) async throws -> CouponRedemption {
        redeemed.append(preview)
        return try redeemResult.get()
    }
}

private func freePreview(days: Int = 30) -> CouponPreview {
    CouponPreview(kind: "free_period", label: "\(days) days free", discountPaise: 0, finalPaise: 0,
                  freeDays: days, grantsPlanKey: nil, fullyDiscounted: false,
                  code: "WELCOME30", planKey: "premium_monthly")
}

private let fixedNow = Date(timeIntervalSince1970: 1_792_391_400) // 2026-10-19 06:30 UTC

@MainActor
private func withBilling(
    _ configure: (FakeBilling) -> Void = { _ in },
    _ body: @MainActor (FakeBilling, BillingViewModel, RedeemCounter) async -> Void
) async {
    let fake = FakeBilling()
    configure(fake)
    let counter = RedeemCounter()
    let model = BillingViewModel(service: fake, now: { fixedNow }, onRedeemed: { counter.count += 1 })
    await body(fake, model, counter)
}

@MainActor
private final class RedeemCounter { var count = 0 }

private let premium = BillingPlanStatus(
    plan: "ultra", planSource: "purchase", expiresAt: "2026-11-18T10:00:00.000Z", expired: false,
    marketingPlan: "premium_monthly", marketingPlanLabel: "Premium", displayLabel: nil)

private let catalogue = BillingCatalogue(plans: [
    BillingCataloguePlan(key: "essential_monthly", label: "Junior Associate", periodMonths: 1, totalPaise: 299900, action: "downgrade"),
    BillingCataloguePlan(key: "premium_monthly", label: "Premium", periodMonths: 1, totalPaise: 499900, action: "renew"),
    BillingCataloguePlan(key: "premium_annual", label: "Premium (annual)", periodMonths: 12, totalPaise: 4999900, action: "upgrade"),
])

final class BillingViewModelTests: XCTestCase {

    func testThePlanReadsAsTheWebsCurrentPlanCard() async {
        await withBilling({
            $0.account = BillingAccount(plan: premium, orders: [])
            $0.catalogue = catalogue
        }) { _, model, _ in
            await model.load()
            XCTAssertEqual(model.state, .loaded)
            XCTAssertEqual(model.planTitle, "Premium")
            XCTAssertEqual(model.planLine, "Purchased · Active until 18 November 2026")
            XCTAssertEqual(model.standing, .init(text: "Active", tone: .success))
            XCTAssertEqual(model.offeredPlans.map(\.key), ["premium_monthly", "premium_annual"])
            XCTAssertTrue(model.isCurrent(catalogue.plans[1]))
            XCTAssertFalse(model.isCurrent(catalogue.plans[2]))
        }
    }

    func testDisplayLabelWinsAndNoPlanIsSaidPlainly() async {
        await withBilling({
            $0.account = BillingAccount(plan: BillingPlanStatus(plan: "lite"), orders: [])
        }) { _, model, _ in
            await model.load()
            XCTAssertEqual(model.planTitle, "No plan yet")
            XCTAssertEqual(model.planLine, BillingCopy.noPlanLine)
            XCTAssertEqual(model.standing, .init(text: "No plan", tone: .neutral))
        }
        await withBilling({
            var status = premium
            status.displayLabel = "Premium (legacy)"
            status.planSource = "grandfathered"
            status.expiresAt = nil
            $0.account = BillingAccount(plan: status, orders: [])
        }) { _, model, _ in
            await model.load()
            XCTAssertEqual(model.planTitle, "Premium (legacy)")
            XCTAssertEqual(model.planLine, "Included · No expiry")
        }
    }

    func testAnExpiredPlanSaysWhenItEnded() async {
        await withBilling({
            var status = premium
            status.expired = true
            status.expiresAt = "2026-09-01 00:00:00"
            status.planSource = "coupon"
            $0.account = BillingAccount(plan: status, orders: [])
        }) { _, model, _ in
            await model.load()
            XCTAssertEqual(model.planLine, "Free trial · Expired on 1 September 2026")
            XCTAssertEqual(model.standing.tone, .danger)
        }
    }

    func testACatalogueFailureDoesNotCostTheAccount() async {
        await withBilling({
            $0.account = BillingAccount(plan: premium, orders: [BillingOrder(orderID: "o1", planKey: "premium_monthly", amountPaise: 499900, status: "paid", createdAt: "2026-10-18 09:00:00")])
            $0.catalogueError = APIError.transport("down")
        }) { _, model, _ in
            await model.load()
            XCTAssertEqual(model.state, .loaded)
            XCTAssertEqual(model.orders.first?.plan, "premium_monthly")
            XCTAssertEqual(model.planTitle, "Your plan")
        }
    }

    func testAnAccountFailureFailsTheScreen() async {
        await withBilling({ $0.accountError = APIError.transport("down") }) { _, model, _ in
            await model.load()
            XCTAssertNotNil(model.state.failure)
        }
    }

    func testOrdersReadAsTheWebsPaymentHistory() async {
        await withBilling({
            $0.account = BillingAccount(plan: premium, orders: [
                BillingOrder(orderID: "o1", planKey: "premium_monthly", amountPaise: 589882, status: "paid",
                             createdAt: "2026-10-18 09:00:00", paidAt: "2026-10-18 20:00:00"),
                BillingOrder(orderID: "o2", planKey: "gone_plan", amountPaise: 100, status: "created", createdAt: "2026-10-17 09:00:00"),
                BillingOrder(orderID: "o3", planKey: nil, amountPaise: 0, status: "failed"),
            ])
            $0.catalogue = catalogue
        }) { _, model, _ in
            await model.load()
            XCTAssertEqual(model.orders, [
                .init(id: "o1", date: "19 October 2026", plan: "Premium", amount: "₹5,898.82", status: "paid", statusTone: .success, hasInvoice: true),
                .init(id: "o2", date: "17 October 2026", plan: "gone_plan", amount: "₹1.00", status: "pending", statusTone: .neutral, hasInvoice: false),
                .init(id: "o3", date: "—", plan: "—", amount: "₹0.00", status: "failed", statusTone: .danger, hasInvoice: false),
            ])
        }
    }

    func testAnInvoiceOpensAndAFailureIsSaid() async {
        let invoice = BillingInvoice(
            number: "EA-000012", orderId: "o1", paymentId: "pay_9", status: "paid",
            issuedAt: "2026-10-18 09:02:11", billTo: .init(name: "Asha Rao", email: "asha@chambers.in"),
            plan: .init(key: "premium_monthly", periodMonths: 1, periodDays: 0),
            lines: .init(basePaise: 499900, gstPaise: 89982, discountPaise: 0, totalPaise: 589882),
            currency: "INR")
        await withBilling({
            $0.invoiceResult = .success(invoice)
            $0.catalogue = catalogue
        }) { _, model, _ in
            await model.load()
            await model.openInvoice(orderID: "o1")
            XCTAssertEqual(model.invoice, invoice)
            XCTAssertNil(model.loadingInvoiceID)
            let layout = model.invoiceLayout
            XCTAssertEqual(layout?.title, "Invoice EA-000012")
            XCTAssertEqual(layout?.lines.first?.label, "Plan — Premium (1 month)")
        }
        await withBilling { _, model, _ in
            await model.openInvoice(orderID: "o1")
            XCTAssertNil(model.invoice)
            XCTAssertEqual(model.invoiceError, BillingCopy.invoiceUnavailable)
        }
    }

    func testTheInvoiceRowsAreTheWebs() {
        let withEverything = BillingInvoice(
            number: "EA-000007", orderId: "order_A", paymentId: "pay_1", status: "paid",
            issuedAt: "2026-10-18T09:02:11.000Z", billTo: .init(name: "", email: "asha@chambers.in"),
            plan: .init(key: "day_pass", periodMonths: 0, periodDays: 1),
            lines: .init(basePaise: 19900, gstPaise: 3582, discountPaise: 5000, couponCode: "LAUNCH", totalPaise: 18482),
            currency: nil)
        let layout = BillingInvoiceLayout(withEverything)
        XCTAssertEqual(layout.issued, "Issued 18 October 2026")
        XCTAssertEqual(layout.billedToName, "—")
        XCTAssertEqual(layout.billedToEmail, "asha@chambers.in")
        XCTAssertEqual(layout.lines.map(\.label), ["Plan — day_pass (1 day)", "GST", "Discount — LAUNCH", "Total (INR)"])
        XCTAssertEqual(layout.lines.map(\.value), ["₹199.00", "₹35.82", "−₹50.00", "₹184.82"])
        XCTAssertEqual(layout.lines.map(\.kind), [.charge, .charge, .discount, .total])
        XCTAssertEqual(layout.orderLine, "Order order_A")
        XCTAssertEqual(layout.paymentLine, "Payment pay_1")
        XCTAssertEqual(layout.plainText, """
            Invoice EA-000007
            Issued 18 October 2026

            Billed to
            —
            asha@chambers.in

            Plan — day_pass (1 day): ₹199.00
            GST: ₹35.82
            Discount — LAUNCH: −₹50.00
            Total (INR): ₹184.82

            Order order_A
            Payment pay_1
            """)

        // No GST charged, no discount, no payment id: none of those lines.
        let bare = BillingInvoice(
            number: nil, orderId: nil, paymentId: nil, status: nil, issuedAt: nil, billTo: nil,
            plan: .init(key: "premium_monthly", periodMonths: 3),
            lines: .init(basePaise: 100, gstPaise: 0, discountPaise: 0, totalPaise: 100), currency: "INR")
        let plain = BillingInvoiceLayout(bare)
        XCTAssertEqual(plain.title, "Invoice —")
        XCTAssertEqual(plain.lines.map(\.label), ["Plan — premium_monthly (3 months)", "Total (INR)"])
        XCTAssertNil(plain.paymentLine)
        XCTAssertEqual(plain.orderLine, "Order —")
    }

    func testACodeIsCheckedAgainstThePlanHeldOrTheFirstOnOffer() async {
        await withBilling({
            $0.account = BillingAccount(plan: premium, orders: [])
            $0.catalogue = catalogue
            $0.previewResult = .success(freePreview())
        }) { fake, model, _ in
            await model.load()
            XCTAssertFalse(model.canApply)
            model.setCode("welcome30")
            XCTAssertTrue(model.canApply)
            await model.applyCoupon()
            XCTAssertEqual(fake.previewed.first?.1, "premium_monthly")
            XCTAssertEqual(model.coupon, .preview(freePreview()))
        }
        await withBilling({
            $0.account = BillingAccount(plan: BillingPlanStatus(plan: "lite"), orders: [])
            $0.catalogue = catalogue
        }) { fake, model, _ in
            await model.load()
            model.setCode("X")
            await model.applyCoupon()
            XCTAssertEqual(fake.previewed.first?.1, "premium_monthly")
        }
    }

    func testEditingTheCodeClearsWhatTheLastOneSaid() async {
        await withBilling({ $0.previewResult = .failure(CouponRefusal.invalid("That code has expired.")) }) { _, model, _ in
            model.setCode("OLD")
            await model.applyCoupon()
            XCTAssertEqual(model.coupon, .failed("That code has expired.", offersPlans: false))
            model.setCode("OLDE")
            XCTAssertEqual(model.coupon, .idle)
        }
    }

    func testAFreeCodeIsRedeemedAndTheAccountReadAgain() async {
        await withBilling({
            $0.account = BillingAccount(plan: BillingPlanStatus(plan: "lite"), orders: [])
            $0.previewResult = .success(freePreview())
        }) { fake, model, counter in
            await model.load()
            let readsBefore = fake.accountReads
            model.setCode("welcome30")
            await model.applyCoupon()
            fake.account = BillingAccount(plan: premium, orders: [])
            await model.redeemCoupon()
            XCTAssertEqual(fake.redeemed, [freePreview()])
            XCTAssertEqual(model.coupon, .redeemed("WELCOME30 applied. 30 days added."))
            XCTAssertEqual(model.code, "")
            XCTAssertEqual(counter.count, 1)
            XCTAssertEqual(fake.accountReads, readsBefore + 1)
            XCTAssertTrue(model.hasPlan)
        }
    }

    func testADiscountIsNeverRedeemedHere() async {
        var discount = freePreview()
        discount.kind = "percent_off"
        discount.freeDays = 0
        discount.discountPaise = 99980
        let preview = discount
        await withBilling({ $0.previewResult = .success(preview) }) { fake, model, counter in
            model.setCode("SAVE20")
            await model.applyCoupon()
            await model.redeemCoupon()
            XCTAssertTrue(fake.redeemed.isEmpty)
            XCTAssertEqual(counter.count, 0)
            XCTAssertEqual(BillingViewModel.previewLine(preview),
                           "This is a discount, applied when a plan is bought on the web. Worth ₹999.80 off.")
        }
    }

    func testARefusedRedemptionSaysWhyAndOffersPlansOnlyForADiscount() async {
        for (refusal, offers) in [(CouponRefusal.needsPayment, true), (.planDowngrade, false), (.spent("You have already used that code."), false)] {
            await withBilling({
                $0.previewResult = .success(freePreview())
                $0.redeemResult = .failure(refusal)
            }) { _, model, counter in
                model.setCode("X")
                await model.applyCoupon()
                await model.redeemCoupon()
                XCTAssertEqual(model.coupon, .failed(refusal.message, offersPlans: offers))
                XCTAssertEqual(counter.count, 0)
            }
        }
    }

    func testPreviewAndRedeemedWording() {
        XCTAssertEqual(BillingViewModel.previewLine(freePreview(days: 1)), "Grants 1 day at no charge. No payment is needed.")
        var full = freePreview()
        full.kind = "amount_off"
        full.freeDays = 0
        full.fullyDiscounted = true
        XCTAssertEqual(BillingViewModel.previewLine(full), "Grants this plan at no charge. No payment is needed.")
        XCTAssertEqual(BillingViewModel.redeemedLine(code: "A", days: nil), "A applied.")
        XCTAssertEqual(BillingViewModel.redeemedLine(code: "A", days: 1), "A applied. 1 day added.")
    }
}

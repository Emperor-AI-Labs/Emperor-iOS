import Foundation

/// Where a plan is bought: the web app, opened in the browser.
///
/// This app takes no money. When someone wants a plan — or has just been told new work needs
/// one — it opens the web app's own plans page in Safari, where the account is the same account
/// and the plan lands on it. Coming back to the app reads the account again straight away
/// (`Session.noteOpenedPlans`), so the plan is in force here without signing in again.
///
/// The refusals themselves still never say "upgrade" or "buy" (`DisplayText.message(for:)`):
/// they say what happened. The way to the plans page is a separate, plainly labelled button
/// beside them, offered only where a plan is the answer — never for a paused account or the
/// hourly ceiling, which no plan changes.
///
/// ## A build switch, on by default
///
/// `EMPEROR_WEB_PLANS` in `project.yml`. App Review restricts buttons that lead to a purchase
/// made outside the app (guidelines 3.1.1 and 3.1.3), and what is allowed differs by
/// storefront. A build for a storefront where it is not allowed sets the switch to `NO`, and
/// every button disappears; nothing else changes. Check the current guidelines before each
/// submission.
struct WebPlans: Equatable, Sendable {
    var isOffered: Bool
    /// The plans page on the same host as the API this build talks to, so the account that buys
    /// is the account that is signed in — a development build buys on the development server.
    var url: URL

    init(isOffered: Bool, apiBaseURL: URL) {
        self.isOffered = isOffered
        self.url = Self.plansURL(apiBaseURL: apiBaseURL)
    }

    /// Read from the app's Info.plist key `EmperorWebPlans`, which the build setting of the same
    /// name fills in. Absent or unexpanded is the default, which is on.
    init(info: [String: Any], apiBaseURL: URL) {
        let flag = info["EmperorWebPlans"]
        let offered: Bool
        if let bool = flag as? Bool {
            offered = bool
        } else if let text = (flag as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, !text.hasPrefix("$(") {
            offered = !["no", "false", "0"].contains(text.lowercased())
        } else {
            offered = true
        }
        self.init(isOffered: offered, apiBaseURL: apiBaseURL)
    }

    /// `https://host/api` → `https://host/buy`: the web app is served from the same origin as
    /// the API, and `/buy` is the page its own paywall sends people to. It works signed in or
    /// out — signed out, it asks for the account before taking any payment.
    static func plansURL(apiBaseURL: URL) -> URL {
        var root = apiBaseURL
        if root.lastPathComponent == "api" { root.deleteLastPathComponent() }
        return root.appendingPathComponent("buy")
    }

    /// Whether to offer the plans page beside this refusal: only where a plan changes the answer.
    func isOffered(for refusal: Refusal) -> Bool {
        guard isOffered else { return false }
        switch refusal.code {
        case .planRequired, .queryLimit, .featureNotInPlan, .documentLimit, .storageLimit,
             .matterLimit, .scanLimit:
            return true
        case .accountSuspended, .rateLimit, .providerAccount, .emailUnverified, .accountExists,
             .invalidCode:
            return false
        }
    }

    /// Whether to offer the plans page with this account standing. A paused account is the
    /// administrator's to restore; a plan does not change it.
    func isOffered(for standing: Session.Standing) -> Bool {
        isOffered && standing == .noPlan
    }

    // MARK: - Wording

    static let buttonTitle = "View plans"
    /// Said under the button in Settings, so it is plain that the browser is about to open and
    /// that nothing more is needed on return.
    static let settingsNote =
        "Plans are bought on the Emperor web app, which opens in your browser. When you come back, the app picks up the change."
}

import XCTest
@testable import EmperorCore

final class APIEnvironmentTests: XCTestCase {

    // MARK: - The safety property

    /// The reason this type exists: a TestFlight or App Store build must never be able to reach
    /// a development deployment, whatever the build settings say.
    ///
    /// So a release build asking for development does not get a warning — it gets production.
    func testAReleaseBuildCanNeverResolveToTheDevTunnel() {
        for override in ["development", "DEVELOPMENT", " development ", nil] {
            let resolved = APIConfig.resolveEnvironment(override: override, isDebugBuild: false)
            XCTAssertEqual(
                resolved, .production,
                "release + override \(override ?? "nil") must not reach the dev tunnel")
        }
    }

    /// Belt and braces: whatever the resolver returns for a release build must be a host that
    /// is safe to distribute, so adding a new non-distributable environment later cannot
    /// quietly slip through.
    func testEveryReleaseResolutionIsDistributable() {
        for override in APIEnvironment.allCases.map(\.rawValue) + ["", "nonsense", "staging"] {
            let resolved = APIConfig.resolveEnvironment(override: override, isDebugBuild: false)
            XCTAssertTrue(resolved.isDistributable, "override \(override) resolved to \(resolved)")
        }
    }

    func testTheTwoHostsAreDistinctAndCorrect() {
        XCTAssertEqual(
            APIEnvironment.production.baseURL.absoluteString,
            "https://backend.emperorailabs.com/api")
        XCTAssertEqual(
            APIEnvironment.development.baseURL.absoluteString,
            "https://dev.emperorailabs.com/api")
        XCTAssertFalse(APIEnvironment.development.isDistributable)
        XCTAssertTrue(APIEnvironment.production.isDistributable)
    }

    /// Both hosts must keep the `/api` prefix: a set of routes is registered only in bare form
    /// on port 3001, so the prefixed form is the only one that reaches every route.
    func testEveryEnvironmentKeepsTheApiPrefix() {
        for environment in APIEnvironment.allCases {
            XCTAssertTrue(
                environment.baseURL.path.hasSuffix("/api"),
                "\(environment) is missing the /api prefix")
        }
    }

    // MARK: - Resolution

    func testDebugBuildsDefaultToDevelopment() {
        XCTAssertEqual(
            APIConfig.resolveEnvironment(override: nil, isDebugBuild: true), .development)
    }

    func testAnExplicitOverrideWinsInDebug() {
        XCTAssertEqual(
            APIConfig.resolveEnvironment(override: "production", isDebugBuild: true), .production)
    }

    /// A typo in a build setting must not silently pick something surprising.
    func testAnUnrecognisedOverrideFallsBackToTheBuildDefault() {
        XCTAssertEqual(
            APIConfig.resolveEnvironment(override: "prod", isDebugBuild: true), .development)
        XCTAssertEqual(
            APIConfig.resolveEnvironment(override: "prod", isDebugBuild: false), .production)
    }

    func testConfigCarriesTheEnvironmentsHost() {
        XCTAssertEqual(
            APIConfig.config(for: .production).baseURL, APIEnvironment.production.baseURL)
        XCTAssertEqual(APIConfig.production.baseURL, APIEnvironment.production.baseURL)
        XCTAssertEqual(APIConfig.development.baseURL, APIEnvironment.development.baseURL)
    }

    /// The long timeout is load-bearing: the server allows 600 s for a chat run, and a default
    /// 60 s would abort long drafts mid-answer.
    func testTheDefaultTimeoutSurvivesLongDrafts() {
        XCTAssertGreaterThanOrEqual(APIConfig.production.requestTimeout, 600)
    }
}

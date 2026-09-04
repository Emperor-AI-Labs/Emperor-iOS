import Foundation

/// Which deployment the app talks to.
///
/// There is no staging host today. When one exists, add a case here rather than pointing a
/// distributed build at `development` — see the resolution rule below for why that is refused.
enum APIEnvironment: String, CaseIterable, Sendable {
    /// The Cloudflare tunnel in front of a developer's box.
    ///
    /// - Warning: a development convenience, never a destination for a build that leaves this
    ///   machine. `isDistributable` is `false` for exactly this reason.
    case development

    /// The real deployment: nginx in front of the API, per `sync-server.js:3899-3903`.
    case production

    var baseURL: URL {
        switch self {
        case .development: return URL(string: "https://dev.emperorailabs.com/api")!
        case .production: return URL(string: "https://backend.emperorailabs.com/api")!
        }
    }

    /// Whether this environment is safe to ship to someone else's device.
    var isDistributable: Bool {
        switch self {
        case .development: return false
        case .production: return true
        }
    }
}

extension APIConfig {
    static let development = APIConfig(baseURL: APIEnvironment.development.baseURL)
    static let production = APIConfig(baseURL: APIEnvironment.production.baseURL)

    static func config(for environment: APIEnvironment) -> APIConfig {
        APIConfig(baseURL: environment.baseURL)
    }

    /// Picks the environment for a build.
    ///
    /// Two rules, in order:
    ///
    /// 1. An explicit `override` wins — this is the `EmperorEnvironment` Info.plist key, which
    ///    `project.yml` drives from a build setting, so a scheme can select a target without a
    ///    code change.
    /// 2. **A release build never resolves to a non-distributable environment.** If a Release
    ///    configuration asks for `development` — by a stale build setting, a copied scheme, a
    ///    merge — it gets `production` instead. This is deliberately not a warning: the failure
    ///    mode being prevented is a distributed build pointed at a development deployment, and
    ///    that must not be reachable by mistake.
    ///
    /// Absent an override, Debug builds get `development` and everything else `production`.
    static func resolveEnvironment(override: String?, isDebugBuild: Bool) -> APIEnvironment {
        let requested = override
            .flatMap { APIEnvironment(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
            ?? (isDebugBuild ? .development : .production)

        if !isDebugBuild && !requested.isDistributable { return .production }
        return requested
    }

    /// The environment this running build should use.
    static var resolvedEnvironment: APIEnvironment {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return resolveEnvironment(
            override: Bundle.main.object(forInfoDictionaryKey: "EmperorEnvironment") as? String,
            isDebugBuild: isDebugBuild)
    }

    /// The config this running build should use. This is what `Session` takes by default.
    static var current: APIConfig { config(for: resolvedEnvironment) }
}

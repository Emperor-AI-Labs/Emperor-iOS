import Foundation

/// Where the app and its widget meet: an app-group container, found at run time rather than
/// assumed.
///
/// ## Why it is looked for
///
/// The group is an entitlement, and entitlements are whatever the signature says. Signed by the
/// project's own team, both targets carry `group.com.emperorailabs.emperor` (the
/// `.entitlements` files). Installed by a sideloading tool with a free Apple ID, the tool
/// re-signs the app with an identity of its own: it typically renames the bundle identifiers and
/// gives the app a group named after the new one — `group.` + the bundle identifier it chose —
/// or no group at all.
///
/// So the candidates are tried in order and the first one the system actually has a container
/// for wins:
///
/// 1. the group named in Info.plist (`EmperorAppGroup`, the build setting `EMPEROR_APP_GROUP`);
/// 2. `group.` + the host app's bundle identifier *as installed* — read from the app itself, or,
///    in the widget, from the app that contains it.
///
/// When none has a container, there is none: the app carries on exactly as before and the widget
/// shows "Open Emperor to load your listings". Nothing here can crash for want of an
/// entitlement — `FileManager` answers `nil` for a group the process is not entitled to.
enum AppGroup {

    /// The Info.plist key both targets carry.
    static let infoKey = "EmperorAppGroup"

    /// The group the project declares, used when Info.plist says nothing.
    static let defaultIdentifier = "group.com.emperorailabs.emperor"

    /// The groups to try, in order, without repeats or blanks.
    ///
    /// - Parameters:
    ///   - configured: Info.plist's `EmperorAppGroup`. An unexpanded `$(…)` — a plist built
    ///     without the setting — counts as absent, and the default stands in for it.
    ///   - hostBundleIdentifier: the containing app's bundle identifier as installed.
    static func candidates(configured: String?, hostBundleIdentifier: String?) -> [String] {
        let named = configured.flatMap(usable) ?? defaultIdentifier
        let derived = hostBundleIdentifier.flatMap(usable).map { "group.\($0)" }
        var seen = Set<String>()
        return [named, derived].compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    /// The first candidate with a container, and the container.
    ///
    /// `container` is `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` in the
    /// app (`systemContainer`); a test passes its own.
    static func resolve(
        candidates: [String], container: (String) -> URL?
    ) -> (identifier: String, url: URL)? {
        for identifier in candidates {
            if let url = container(identifier) { return (identifier, url) }
        }
        return nil
    }

    /// The containing app's bundle identifier, from inside one of its extensions.
    ///
    /// The app's own Info.plist is read first (`containingAppIdentifier`, found two directories up
    /// from the extension, `Emperor.app/PlugIns/EmperorWidget.appex`) because a re-signing tool
    /// may rename identifiers in any pattern it likes. Failing that, an extension's identifier is
    /// its app's plus one component (`….emperor.widget`), and that component is dropped.
    static func hostBundleIdentifier(
        containingAppIdentifier: String?, extensionIdentifier: String?
    ) -> String? {
        if let host = containingAppIdentifier.flatMap(usable) { return host }
        guard let own = extensionIdentifier.flatMap(usable),
              let dot = own.lastIndex(of: "."), dot != own.startIndex
        else { return nil }
        return String(own[..<dot])
    }

    /// The app bundle that contains an extension at `extensionURL`, if that is where it sits.
    static func containingAppURL(ofExtensionAt extensionURL: URL) -> URL? {
        let plugIns = extensionURL.deletingLastPathComponent()
        let app = plugIns.deletingLastPathComponent()
        guard plugIns.lastPathComponent == "PlugIns", app.pathExtension == "app" else { return nil }
        return app
    }

    #if canImport(Darwin)
    /// The system's answer: a container for a group this process is entitled to, else `nil`.
    static func systemContainer(_ identifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
    #endif

    private static func usable(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
    }
}

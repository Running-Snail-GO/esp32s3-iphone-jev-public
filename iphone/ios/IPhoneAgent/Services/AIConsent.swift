import Foundation

/// App Store builds (IA_STORE_BUILD, set only by fastlane): nothing goes to a model endpoint until the user
/// agrees to send screenshots and task text to that host, per host; withdrawn in Settings › Privacy.
/// Builds from source have no gate (the developer chose the endpoint). Every request passes `check`.
enum AIConsent {
    /// The old single-host value is read until the first change migrates it.
    static let key = "aiConsentHost"
    static let hostsKey = "aiConsentHosts"
    static let store = (Bundle.main.object(forInfoDictionaryKey: "IAStoreBuild") as? String) == "YES"

    static func host(_ baseURL: String) -> String {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return (URL(string: value)?.host ?? value).lowercased()
    }

    /// Each destination needs its own agreement. A planner and Jev may be used
    /// in one run without either agreement overwriting the other one.
    static func allowedHosts(defaults: UserDefaults = .standard) -> [String] {
        if let values = defaults.stringArray(forKey: hostsKey) {
            return Array(Set(values.map(host).filter { !$0.isEmpty })).sorted()
        }
        guard let legacy = defaults.string(forKey: key), !host(legacy).isEmpty else { return [] }
        return [host(legacy)]
    }

    static func granted(_ baseURL: String, defaults: UserDefaults = .standard,
                        storeBuild: Bool = AIConsent.store) -> Bool {
        !storeBuild || allowedHosts(defaults: defaults).contains(host(baseURL))
    }

    static func grant(_ baseURL: String, defaults: UserDefaults = .standard) {
        let destination = host(baseURL)
        guard !destination.isEmpty else { return }
        save(Set(allowedHosts(defaults: defaults)).union([destination]), defaults: defaults)
    }

    /// Withdraw all agreements, including the legacy value, so none can return
    /// after a restart or a downgrade to the old storage format.
    static func revoke(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: hostsKey)
    }

    static func revoke(_ baseURL: String, defaults: UserDefaults = .standard) {
        save(Set(allowedHosts(defaults: defaults)).subtracting([host(baseURL)]), defaults: defaults)
    }

    static var grantedHosts: [String] { allowedHosts() }
    /// Kept for callers that display a single host; new views show every host.
    static var grantedHost: String? { grantedHosts.first }

    private static func save(_ hosts: Set<String>, defaults: UserDefaults) {
        defaults.set(hosts.sorted(), forKey: hostsKey)
        defaults.removeObject(forKey: key)
    }

    /// Thrown before any request the user has not agreed to.
    static func check(_ baseURL: String, defaults: UserDefaults = .standard,
                      storeBuild: Bool = AIConsent.store) throws {
        guard granted(baseURL, defaults: defaults, storeBuild: storeBuild) else {
            throw LLMError(message: String(localized: "Allow sending screenshots and your task to \(host(baseURL)) first (Settings › Model)."))
        }
    }
}

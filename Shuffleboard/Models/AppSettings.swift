import Foundation

/// The settings in Shuffleboard > Settings… (#165), kept in `UserDefaults`. No credentials are kept here; an
/// account is only named by its id. The notification settings live with `CardReminderSync`, and the update
/// settings are Sparkle's own.
enum AppSettings {
    static let refreshIntervalKey = "refreshInterval"
    static let refreshWhenActivatedKey = "refreshWhenActivated"
    static let launchAccountKey = "launchAccount"

    /// The background refresh intervals offered, in seconds; 0 is never.
    static let refreshIntervals = [30, 60, 300, 900, 0]
    static let defaultRefreshInterval = 60

    /// Seconds between background refreshes, or nil to refresh only when asked. A stored value that isn't one of
    /// `refreshIntervals` counts as the default.
    static func refreshInterval(in defaults: UserDefaults = .standard) -> TimeInterval? {
        let stored = defaults.object(forKey: refreshIntervalKey) as? Int ?? defaultRefreshInterval
        let seconds = refreshIntervals.contains(stored) ? stored : defaultRefreshInterval
        return seconds > 0 ? TimeInterval(seconds) : nil
    }

    /// Whether to look for changes when the app comes to the front; on by default.
    static func refreshesWhenActivated(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: refreshWhenActivatedKey) as? Bool ?? true
    }

    /// The account to open at launch, or nil for the one used last.
    static func launchAccountId(in defaults: UserDefaults = .standard) -> String? {
        guard let id = defaults.string(forKey: launchAccountKey), !id.isEmpty else { return nil }
        return id
    }

    /// How `seconds` from `refreshIntervals` reads in Settings.
    static func refreshIntervalTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0:
            "Never"

        case ..<60:
            "Every \(seconds) seconds"

        case 60:
            "Every minute"

        default:
            "Every \(seconds / 60) minutes"
        }
    }
}

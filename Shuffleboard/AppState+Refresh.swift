import Foundation

// MARK: - Background refresh

/// Picking up changes made elsewhere, as set in Settings (#165).
@MainActor
extension AppState {
    /// Looks for changes every `AppSettings.refreshInterval` until cancelled, reading the setting each time; returns
    /// at once when it's never. Tests pass a `sleep` that doesn't wait.
    func refreshPeriodically(
        defaults: UserDefaults = .standard,
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async {
        while let interval = AppSettings.refreshInterval(in: defaults) {
            do {
                try await sleep(interval)
            } catch {
                return
            }
            await refreshIfChanged()
            await updateReminders()
        }
    }

    /// The app came to the front: looks for changes, unless that's turned off in Settings.
    func appDidBecomeActive(defaults: UserDefaults = .standard) async {
        guard AppSettings.refreshesWhenActivated(in: defaults) else { return }
        await refreshIfChanged()
        await updateReminders()
    }
}

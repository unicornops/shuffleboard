import Combine
import Sparkle
import SwiftUI

// MARK: - SoftwareUpdater

/// In-app updates via [Sparkle](https://sparkle-project.org).
///
/// The feed (`SUFeedURL`) is the `appcast.xml` attached to the latest GitHub release, and every update is
/// verified against `SUPublicEDKey` (both in Info.plist). The release workflow signs the update with the
/// matching private key and generates the appcast.
@MainActor
final class SoftwareUpdater: ObservableObject {
    /// False while a check is already running, so "Check for Updates…" can be disabled.
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        // The app also hosts the unit tests; don't check for updates or show update UI there. UI tests launch
        // the app as a separate process without XCTest's variable, so they are recognised by their own.
        var isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        isRunningTests = isRunningTests || UITestLaunch.isActive
        #endif
        self.controller = SPUStandardUpdaterController(
            startingUpdater: !isRunningTests,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Whether Sparkle checks for updates on its own, once a day; Sparkle keeps the setting (#165).
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Whether an update found by an automatic check is downloaded and installed when the app quits, rather than
    /// offered first.
    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }
}

// MARK: - Menu item

/// The "Check for Updates…" menu item.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: SoftwareUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}

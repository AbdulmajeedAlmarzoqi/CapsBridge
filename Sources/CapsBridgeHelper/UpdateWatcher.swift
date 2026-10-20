import AppKit
import CapsBridgeKit

/// Looks for a new version of CapsBridge once a day, since the app itself is rarely open, and
/// brings it to the user's attention when they're on the Mac rather than working in Windows: it
/// opens CapsBridge, whose updater shows the release notes and installs the update.
@MainActor
final class UpdateWatcher {
    private let store: SharedStore
    /// An update found and not yet shown, waiting for the user to leave the VM.
    private var pending: UpdateFeedItem?
    private var timer: Timer?
    /// Whether the user is at the Mac and not working in a VM right now.
    var isUserAvailable: () -> Bool = { false }

    /// The app around the helper: `CapsBridge.app/Contents/Library/LoginItems/CapsBridgeHelper.app`.
    private let appURL = Bundle.main.bundleURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var appDefaults: UserDefaults? { UserDefaults(suiteName: CapsBridgeIdentifiers.app) }

    init(store: SharedStore) {
        self.store = store
    }

    func start() {
        // A while after login rather than at once, then every hour to see whether a day has passed.
        Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    /// Shows a pending update, when the user is somewhere it won't interrupt them.
    func userIsAvailable(_ available: Bool) {
        guard available, let pending else { return }
        announce(pending)
    }

    private func checkIfDue() {
        // The user's choice in CapsBridge's settings, which Sparkle keeps in the app's defaults.
        guard appDefaults?.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true else { return }
        let interval = appDefaults?.object(forKey: "SUScheduledCheckInterval") as? Double ?? 86_400
        if let last = store.loadUpdateCheckState().lastCheck, Date().timeIntervalSince(last) < interval { return }
        Task { await check() }
    }

    private func check() async {
        guard let app = Bundle(url: appURL), let feed = feedURL(of: app) else { return }
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("CapsBridge/\(app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { return }

        var state = store.loadUpdateCheckState()
        state.lastCheck = Date()
        store.save(state)

        // Read from disk each time: the app may have been updated since the helper started.
        let installed = Bundle(url: appURL).flatMap { $0.object(forInfoDictionaryKey: "CFBundleVersion") as? String } ?? "0"
        guard let newest = UpdateFeed.newestItem(in: data), newest.isNewer(than: installed), newest.runs() else {
            pending = nil
            return
        }
        if appDefaults?.string(forKey: "SUSkippedVersion") == newest.version { return }
        // Shown already in the last three days: Sparkle reminds the user from there.
        if state.announcedVersion == newest.version, let at = state.announcedAt, Date().timeIntervalSince(at) < 3 * 86_400 { return }
        pending = newest
        userIsAvailable(isUserAvailable())
    }

    private func announce(_ item: UpdateFeedItem) {
        pending = nil
        var state = store.loadUpdateCheckState()
        state.announcedVersion = item.version
        state.announcedAt = Date()
        store.save(state)

        if !NSRunningApplication.runningApplications(withBundleIdentifier: CapsBridgeIdentifiers.app).isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                CapsBridgeIdentifiers.updateAvailable, object: nil, userInfo: nil, deliverImmediately: true)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [CapsBridgeIdentifiers.showUpdateArgument]
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }

    private func feedURL(of app: Bundle) -> URL? {
        let override = appDefaults?.string(forKey: CapsBridgeIdentifiers.updateFeedOverrideKey)
        let published = app.object(forInfoDictionaryKey: "SUFeedURL") as? String
        return (override ?? published).flatMap(URL.init(string:))
    }
}

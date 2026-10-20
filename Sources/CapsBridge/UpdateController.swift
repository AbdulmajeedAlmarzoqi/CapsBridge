import AppKit
import CapsBridgeKit
import Observation
import Sparkle

/// Keeps CapsBridge up to date with Sparkle: it checks the update feed once a day while the app
/// runs, shows the release notes of a new version in the app's language, and downloads, verifies
/// and installs the update, then opens the new version. The feed and every update are signed,
/// and an update has to be signed by the same developer as the app it replaces.
@MainActor
@Observable
final class UpdateController: NSObject {
    private(set) var canCheckForUpdates = false {
        didSet {
            if canCheckForUpdates, showWhenReady { showAvailableUpdate() }
        }
    }
    /// An update to show once the updater has started, which it does a moment after the app.
    @ObservationIgnored private var showWhenReady = false

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
        // The helper found an update while the app was open.
        DistributedNotificationCenter.default().addObserver(forName: CapsBridgeIdentifiers.updateAvailable, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showAvailableUpdate() }
        }
    }

    /// Checks now, and says so when CapsBridge is up to date.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Shows an update the helper found: the release notes and the button to install it, or nothing
    /// when there's no update after all.
    func showAvailableUpdate() {
        guard updater.canCheckForUpdates else {
            showWhenReady = true
            return
        }
        showWhenReady = false
        updater.checkForUpdatesInBackground()
    }
}

extension UpdateController: SPUUpdaterDelegate {
    /// A feed set in the app's defaults takes the place of the published one, to try a release first.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: CapsBridgeIdentifiers.updateFeedOverrideKey)
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    /// Release notes are written in Markdown. They're shown in the system's text style, and Arabic
    /// ones read right to left.
    nonisolated func standardUserDriverWillShowReleaseNotesText(
        _ releaseNotesText: NSAttributedString,
        forUpdate update: SUAppcastItem,
        withBundleDisplayVersion bundleDisplayVersion: String,
        bundleVersion: String
    ) -> NSAttributedString? {
        let text = NSMutableAttributedString(attributedString: releaseNotesText)
        let whole = NSRange(location: 0, length: text.length)
        let rightToLeft = Locale.Language(identifier: Bundle.main.preferredLocalizations.first ?? "en").characterDirection == .rightToLeft
        text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
            style.alignment = .natural
            style.paragraphSpacing = max(style.paragraphSpacing, 6)
            style.lineHeightMultiple = 1.15
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            // Headings keep their weight and size; body text takes the system's.
            if let font = value as? NSFont, font.pointSize > NSFont.systemFontSize + 1 { return }
            let bold = (value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            text.addAttribute(.font, value: bold ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) : NSFont.systemFont(ofSize: NSFont.systemFontSize), range: range)
        }
        return text
    }
}

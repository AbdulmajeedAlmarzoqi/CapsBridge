import AppKit

/// Where this copy of the app runs from. The helper is started from inside the app, so the app
/// has to stay in one place, and macOS runs an app opened straight from a download in a
/// temporary, read-only copy that's gone at the next launch.
@MainActor
enum AppLocation {
    static var bundleURL: URL { Bundle.main.bundleURL }

    static var isInApplications: Bool {
        let path = bundleURL.resolvingSymlinksInPath().path
        let folders = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        return folders.contains { path.hasPrefix($0) }
    }

    /// Whether this is a build run from Xcode, which stays where it is.
    static var isDevelopmentBuild: Bool {
        bundleURL.path.contains("/DerivedData/") || bundleURL.path.contains("/Build/Products/")
    }

    static var shouldOfferToMove: Bool { !isInApplications && !isDevelopmentBuild }

    /// Copies the app into /Applications, in place of a copy that's there, and returns the new copy.
    static func copyToApplications() throws -> URL {
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleURL.lastPathComponent)
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.trashItem(at: destination, resultingItemURL: nil)
        }
        try manager.copyItem(at: bundleURL, to: destination)
        return destination
    }

    static func relaunch(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    static func moveToTrashAndQuit() {
        try? FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
        NSApp.terminate(nil)
    }
}

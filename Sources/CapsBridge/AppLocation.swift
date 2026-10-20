import AppKit
import CapsBridgeKit

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

    /// Copies the app into the Applications folder, in place of a copy that's there, opens the new
    /// copy, and quits. Nothing changes in the Applications folder unless the whole copy succeeded.
    static func moveToApplicationsAndRelaunch() async throws {
        let manager = FileManager.default
        let folder = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let destination = folder.appendingPathComponent("CapsBridge.app")
        let staging = folder.appendingPathComponent(".CapsBridge-\(UUID().uuidString).app")
        try manager.copyItem(at: bundleURL, to: staging)
        do {
            // A copy keeps the download's quarantine, and macOS would run it from a temporary place again.
            _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", staging.path])
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
        NSApp.terminate(nil)
    }

    static func moveToTrashAndQuit() {
        try? FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
        NSApp.terminate(nil)
    }
}

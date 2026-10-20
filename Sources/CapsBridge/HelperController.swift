import CapsBridgeKit
import CoreServices
import Foundation
import ServiceManagement

/// Installs, checks and removes the background helper, which macOS runs as a login item of this app.
@MainActor
struct HelperController {
    enum State: Equatable {
        case notInstalled
        /// The user turned CapsBridge off under Login Items, and only they can turn it back on.
        case needsApproval
        case notRunning
        /// The helper running was started from an older copy of the app.
        case outdated
        case running
    }

    enum Failure: Error {
        case needsApproval
        case couldNotStart(String)
    }

    /// The helper's executable inside this copy of the app.
    private static var bundledHelper: URL? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/CapsBridgeHelper.app")
        return Bundle(url: helper)?.executableURL?.resolvingSymlinksInPath()
    }

    private let service = SMAppService.agent(plistName: CapsBridgeIdentifiers.helperPropertyList)
    private let store = SharedStore.standard

    func state() -> State {
        switch service.status {
        case .requiresApproval: return .needsApproval
        case .enabled: break
        default: return .notInstalled
        }
        guard let status = store.loadHelperStatus(), isHelper(status) else { return .notRunning }
        return isCurrent(status) ? .running : .outdated
    }

    /// Whether Caps Lock is forwarded right now, which is so only while a VM that was set up is in front.
    var reportedStatus: HelperStatus? {
        store.loadHelperStatus().flatMap { isHelper($0) ? $0 : nil }
    }

    func ensureRunning() async throws {
        switch state() {
        case .running:
            return
        case .needsApproval:
            throw Failure.needsApproval
        case .notInstalled:
            try register()
        case .notRunning, .outdated:
            // launchd starts the copy inside this app again.
            if await restart(), await isRunning(within: 5) { return }
            // launchd holds on to the signature of the copy that registered, and refuses to start one
            // signed otherwise, as after the app was replaced. Registering anew gives it this copy's,
            // though the system can take a moment to let go of the old registration.
            for pause in [1, 3] {
                try? await service.unregister()
                try? await Task.sleep(for: .seconds(pause))
                try register()
                if await isRunning(within: 8) { return }
            }
        }
        if await isRunning(within: 10) { return }
        if state() == .needsApproval { throw Failure.needsApproval }
        throw Failure.couldNotStart("")
    }

    private func isRunning(within seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 4) {
            if state() == .running { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return state() == .running
    }

    func remove() async {
        try? await service.unregister()
        for _ in 0..<20 {
            guard let status = store.loadHelperStatus(), isHelper(status) else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func register() throws {
        // The system takes the helper's code requirement from its record of this app, which can still
        // describe the copy this one replaced. Bringing the record up to date first avoids launchd
        // refusing the helper as signed otherwise.
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval { throw Failure.needsApproval }
            throw Failure.couldNotStart(error.localizedDescription)
        }
    }

    private func restart() async -> Bool {
        let target = "gui/\(getuid())/\(CapsBridgeIdentifiers.helper)"
        let output = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["kickstart", "-k", target])
        return output?.status == 0
    }

    /// Whether the process a status names still runs and is the helper: process IDs get reused.
    private func isHelper(_ status: HelperStatus) -> Bool {
        guard status.isAlive else { return false }
        let name = ProcessArguments.of(processID: status.processID).first.map { URL(fileURLWithPath: $0).lastPathComponent }
        return name == URL(fileURLWithPath: status.executablePath).lastPathComponent
    }

    /// Whether the helper running is the one inside this copy of the app, as it is on disk now.
    private func isCurrent(_ status: HelperStatus) -> Bool {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard status.version == version,
              let bundled = Self.bundledHelper, bundled.path == status.executablePath else { return false }
        let modified = (try? FileManager.default.attributesOfItem(atPath: bundled.path))?[.modificationDate] as? Date
        return modified.map { $0 <= status.startedAt } ?? true
    }
}

// CapsBridge's background helper.
//
// macOS tells apps that Caps Lock changed state, not that it went down and came up, so a VM never
// sees it held and a screen reader in Windows can't use it as its modifier key. While a VM that
// CapsBridge set up is the frontmost app, this helper maps Caps Lock to F18, which does arrive as
// a real press and release, and Windows turns F18 back into Caps Lock. In every other app Caps
// Lock stays what it is.

import AppKit
import CapsBridgeKit

@MainActor
final class Helper {
    private let store = SharedStore.standard
    private let remapper = KeyRemapper()
    private let startedAt = Date()
    private var configuration = BridgeConfiguration()
    private var configurationDate: Date?
    private var activeMachine: BridgeMachine?
    private var reportedStatus: HelperStatus?
    private var signalSources: [DispatchSourceSignal] = []

    func start() {
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = application?.bundleIdentifier
            let processID = application?.processIdentifier
            MainActor.assumeIsolated { self?.update(bundleIdentifier: bundleIdentifier, processID: processID) }
        }
        workspace.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateForFrontmostApplication() }
        }
        DistributedNotificationCenter.default().addObserver(forName: CapsBridgeIdentifiers.configurationChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateForFrontmostApplication() }
        }

        // Caps Lock goes back to itself when the helper is stopped.
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.remapper.deactivateBridge()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }

        updateForFrontmostApplication()
    }

    private func updateForFrontmostApplication() {
        let application = NSWorkspace.shared.frontmostApplication
        update(bundleIdentifier: application?.bundleIdentifier, processID: application?.processIdentifier)
    }

    private func update(bundleIdentifier: String?, processID: pid_t?) {
        reloadConfigurationIfChanged()
        let machine = FrontmostMachine.machine(
            bundleIdentifier: bundleIdentifier,
            arguments: processID.map(ProcessArguments.of(processID:)) ?? [],
            configuration: configuration)

        if machine != nil {
            // A mapping left behind by a run that was killed counts as on, and comes off below like any other.
            activeMachine = remapper.activateBridge() ? machine : nil
        } else {
            remapper.deactivateBridge()
            activeMachine = nil
        }
        report()
    }

    private func reloadConfigurationIfChanged() {
        let date = store.configurationModificationDate()
        guard date != configurationDate || configurationDate == nil else { return }
        configurationDate = date
        configuration = store.loadConfiguration()
    }

    /// Writes the helper's state for the app to read, when it changed.
    private func report() {
        let status = HelperStatus(
            processID: ProcessInfo.processInfo.processIdentifier,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            executablePath: Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0],
            startedAt: startedAt,
            bridgeActive: remapper.isBridgeActive,
            activeMachineID: activeMachine?.id)
        guard status != reportedStatus else { return }
        reportedStatus = status
        try? store.save(status)
    }
}

let helper = Helper()
helper.start()

NSApplication.shared.run()

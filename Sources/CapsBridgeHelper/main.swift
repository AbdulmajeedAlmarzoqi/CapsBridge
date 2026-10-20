// CapsBridge's background helper.
//
// macOS tells apps that Caps Lock changed state, not that it went down and came up, so a VM never
// sees it held and a screen reader in Windows can't use it as its modifier key. While a VM that
// CapsBridge set up is the frontmost app, this helper maps Caps Lock to F18, which does arrive as
// a real press and release, and Windows turns F18 back into Caps Lock. On ISO keyboards it also
// swaps § and the key next to the left Shift, which reach the VM as each other. In every other app
// the keys stay what they are.

import AppKit
import CapsBridgeKit
import IOKit

@MainActor
final class Helper {
    private enum Pause: Hashable {
        case screenLocked, sessionInactive, asleep
    }

    private let store = SharedStore.standard
    private lazy var remapper = KeyRemapper(store: store)
    /// While the screen is locked, another user has the Mac, or it sleeps, Caps Lock is Caps Lock:
    /// the frontmost app stays the same then, and a password may need capitals.
    private var pauses: Set<Pause> = []
    private let startedAt = Date()
    private var configuration = BridgeConfiguration()
    private var configurationDate: Date?
    private var activeMachine: BridgeMachine?
    private var reportedStatus: HelperStatus?
    private var signalSources: [DispatchSourceSignal] = []
    private var keyboardNotifications: IONotificationPortRef?
    private var keyboardIterator: io_iterator_t = 0
    private lazy var updates = UpdateWatcher(store: store)

    func start() {
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = application?.bundleIdentifier
            let processID = application?.processIdentifier
            MainActor.assumeIsolated { self?.update(bundleIdentifier: bundleIdentifier, processID: processID) }
        }
        observe(workspace.notificationCenter, NSWorkspace.willSleepNotification) { $0.pause(.asleep) }
        observe(workspace.notificationCenter, NSWorkspace.didWakeNotification) { $0.resume(.asleep) }
        observe(workspace.notificationCenter, NSWorkspace.sessionDidResignActiveNotification) { $0.pause(.sessionInactive) }
        observe(workspace.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification) { $0.resume(.sessionInactive) }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.pause(.screenLocked) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.resume(.screenLocked) }
        observe(distributed, CapsBridgeIdentifiers.configurationChanged) { $0.updateForFrontmostApplication() }

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

        updates.isUserAvailable = { [weak self] in
            guard let self else { return false }
            return pauses.isEmpty && !Self.isVirtualMachine(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
        updates.start()
        watchKeyboards()
        updateForFrontmostApplication()
    }

    /// A keyboard connected while a VM is in front gets the mapping every keyboard has, and an ISO one
    /// needs its own as well.
    private func watchKeyboards() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        keyboardNotifications = port
        IONotificationPortSetDispatchQueue(port, .main)
        let connected: IOServiceMatchingCallback = { context, iterator in
            releaseAll(iterator)
            guard let context else { return }
            let helper = Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue()
            // The HID event system takes the keyboard on a moment after it appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { helper.updateForFrontmostApplication() }
            }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"),
                                         connected, Unmanaged.passUnretained(self).toOpaque(), &keyboardIterator)
        // The services there already; going through them arms the notification.
        releaseAll(keyboardIterator)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @Sendable @MainActor (Helper) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
    }

    private func pause(_ reason: Pause) {
        pauses.insert(reason)
        updateForFrontmostApplication()
    }

    private func resume(_ reason: Pause) {
        pauses.remove(reason)
        updateForFrontmostApplication()
    }

    private func updateForFrontmostApplication() {
        let application = NSWorkspace.shared.frontmostApplication
        update(bundleIdentifier: application?.bundleIdentifier, processID: application?.processIdentifier)
    }

    private func update(bundleIdentifier: String?, processID: pid_t?) {
        reloadConfigurationIfChanged()
        let machine = pauses.isEmpty ? FrontmostMachine.machine(
            bundleIdentifier: bundleIdentifier,
            arguments: processID.map(ProcessArguments.of(processID:)) ?? [],
            configuration: configuration) : nil

        if machine != nil {
            // A mapping left behind by a run that was killed counts as on, and comes off below like any other.
            activeMachine = remapper.activateBridge() ? machine : nil
        } else {
            remapper.deactivateBridge()
            activeMachine = nil
        }
        report()
        // An update waits while the user works in a VM, or isn't at the Mac.
        updates.userIsAvailable(pauses.isEmpty && !Self.isVirtualMachine(bundleIdentifier))
    }

    private static func isVirtualMachine(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == CapsBridgeIdentifiers.vmpalMachine
            || bundleIdentifier?.hasPrefix(CapsBridgeIdentifiers.vmpalMachineStubPrefix) == true
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

private func releaseAll(_ iterator: io_iterator_t) {
    while case let service = IOIteratorNext(iterator), service != 0 {
        IOObjectRelease(service)
    }
}

let helper = Helper()
helper.start()

NSApplication.shared.run()

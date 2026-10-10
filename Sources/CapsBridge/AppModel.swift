import AppKit
import CapsBridgeKit
import Observation
import OSLog
import SwiftUI

/// A question the app puts to the user before it goes on.
struct Prompt: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirm: String
    var cancel: String
    var isDestructive = false
    fileprivate var answer: CheckedContinuation<Bool, Never>
}

@MainActor
@Observable
final class AppModel {
    enum Activity: Equatable {
        case checking
        case idle
        case working
    }

    private(set) var activity: Activity = .checking
    private(set) var inspection = Inspection()
    /// What the app is doing right now, while it works.
    private(set) var progress: String?
    /// Why the last thing it tried didn't work.
    private(set) var failure: String?
    /// The VM the window is about, when VMPal has more than one Windows VM.
    var selectedMachineID: String?
    private(set) var prompt: Prompt?
    var isPromptPresented = false

    private let store = SharedStore.standard
    private let helper = HelperController()
    private var journal: [String] = []
    private let logger = Logger(subsystem: CapsBridgeIdentifiers.app, category: "app")
    private var lastRefresh = Date.distantPast
    private var quietRefresh: Task<Void, Never>?
    private var hasStarted = false

    // MARK: - What the window shows

    var summary: Inspection.Summary { inspection.summary }
    var checks: [Check] { inspection.checks }

    var headline: String {
        if activity == .checking && !hasStarted { return String(localized: "Checking this Mac and Windows…") }
        switch summary {
        case .vmpalMissing: return String(localized: "VMPal isn't installed")
        case .noWindowsMachine: return String(localized: "No Windows virtual machine yet")
        case .notSetUp: return String(localized: "Caps Lock isn't set up yet")
        case .needsAttention: return String(localized: "Something needs fixing")
        case .restartNeeded: return String(localized: "Restart Windows to finish")
        case .startNeeded: return String(localized: "Start Windows to finish")
        case .ready: return String(localized: "Caps Lock is ready")
        }
    }

    var explanation: String {
        if activity == .checking && !hasStarted { return "" }
        switch summary {
        case .vmpalMissing:
            return String(localized: "CapsBridge works with Windows virtual machines in VMPal. Install VMPal, create a Windows virtual machine, then open CapsBridge again.")
        case .noWindowsMachine:
            return String(localized: "Create a Windows virtual machine in VMPal, then check again.")
        case .notSetUp:
            return String(localized: "Set Up prepares this Mac and Windows, so you can hold Caps Lock as your screen reader's key.")
        case .needsAttention:
            return String(localized: "Fix takes care of what's marked below.")
        case .restartNeeded:
            return String(localized: "Windows learns the Caps Lock key when it starts. Save your work in Windows first.")
        case .startNeeded:
            return String(localized: "The setup completes when Windows starts.")
        case .ready:
            return String(localized: "In Windows, hold Caps Lock as your screen reader's key. Press it twice quickly to turn Caps Lock on or off.")
        }
    }

    var primaryTitle: String {
        switch summary {
        case .vmpalMissing: String(localized: "Get VMPal")
        case .noWindowsMachine, .ready: String(localized: "Check Again")
        case .notSetUp: String(localized: "Set Up")
        case .needsAttention: String(localized: "Fix")
        case .restartNeeded: String(localized: "Restart Windows")
        case .startNeeded: String(localized: "Start Windows")
        }
    }

    /// Whether there's anything of CapsBridge's to take away.
    var canRemove: Bool {
        inspection.helper != .notInstalled
            || !inspection.configuration.machines.isEmpty
            || !inspection.configuration.awaitingRestart.isEmpty
            || inspection.guest?.hasCapsBridgeTraces == true
    }

    // MARK: - Starting and checking

    func start() async {
        guard !hasStarted else { return }
        let direction = NSApp.userInterfaceLayoutDirection == .rightToLeft ? "right to left" : "left to right"
        note("Language \(Bundle.main.preferredLocalizations.first ?? "?"), \(direction)")
        if AppLocation.shouldOfferToMove {
            let move = await ask(
                title: String(localized: "Move CapsBridge to the Applications folder?"),
                message: String(localized: "CapsBridge runs a small helper from inside the app, so the app needs to stay in one place."),
                confirm: String(localized: "Move to Applications"),
                cancel: String(localized: "Not Now"))
            if move {
                do {
                    AppLocation.relaunch(at: try AppLocation.copyToApplications())
                    return
                } catch {
                    failure = String(localized: "CapsBridge couldn't be moved to the Applications folder: \(error.localizedDescription)")
                }
            }
        }
        await refresh()
        hasStarted = true
        announce(headline)
    }

    /// Checks again when the user comes back to the app, as after restarting Windows by hand.
    /// It runs behind the window as it is: the buttons stay usable, and what they start waits for it.
    func refreshAfterReturning() {
        guard hasStarted, activity == .idle, quietRefresh == nil, Date().timeIntervalSince(lastRefresh) > 15 else { return }
        quietRefresh = Task {
            let before = summary
            let inspection = await inspect()
            if activity == .idle {
                show(inspection)
                if summary != before { announce(headline) }
            }
            quietRefresh = nil
        }
    }

    func checkAgain() async {
        guard activity == .idle else { return }
        failure = nil
        await refresh()
        announce(headline)
    }

    func refresh() async {
        if activity == .idle { activity = .checking }
        await quietRefresh?.value
        show(await inspect())
        if activity == .checking { activity = .idle }
    }

    private func show(_ inspection: Inspection) {
        self.inspection = inspection
        selectedMachineID = inspection.machine?.id
        lastRefresh = Date()
        note("Checked: \(inspection.summary), helper \(inspection.helper), reach \(inspection.reach)")
    }

    /// Finds out how things stand, and puts right what needs no question.
    private func inspect() async -> Inspection {
        var inspection = Inspection()
        inspection.configuration = store.loadConfiguration()
        inspection.installation = VMPalInstallation.find()
        inspection.helper = helper.state()

        if let installation = inspection.installation {
            let vmpal = VMPalCommandLine(installation: installation)
            do {
                let machines = try await vmpal.machines()
                inspection.configuration = forgettingDeletedMachines(in: inspection.configuration, listed: machines)
                inspection.windowsMachines = machines.filter { $0.isWindows && $0.installed != false }
                inspection.machine = preferredMachine(in: inspection)
                if let machine = inspection.machine, machine.isRunning, machine.allowsControl {
                    inspection.machineStatus = try? await vmpal.status(of: machine.id)
                    if inspection.reach == .ready {
                        inspection.guest = try? await configurator(vmpal, machine).inspect()
                    }
                }
            } catch {
                note("Listing VMs failed: \(error)")
                failure = message(for: error)
            }
        }

        await settle(&inspection)
        return inspection
    }

    /// Puts right what needs no question: forwarding follows what Windows can take, and the helper
    /// of a setup that was made keeps running.
    private func settle(_ inspection: inout Inspection) async {
        var configuration = inspection.configuration
        if let machine = inspection.machine {
            if inspection.reach == .ready, let guest = inspection.guest {
                if guest.keyMapping == .active, inspection.isAwaitingRestart {
                    configuration.enable(machine.bridgeMachine)
                    note("Windows restarted since setup: forwarding to \(machine.name) is on")
                } else if guest.keyMapping != .active, inspection.isEnabled {
                    // With forwarding left on, Caps Lock would do nothing at all in this Windows.
                    configuration.markAwaitingRestart(machine.bridgeMachine)
                    note("Windows no longer maps the key: forwarding to \(machine.name) is off")
                }
            }
            // A VM that was renamed or moved keeps its ID.
            if let index = configuration.machines.firstIndex(where: { $0.hasID(machine.id) }) {
                configuration.machines[index] = machine.bridgeMachine
            }
        }
        if configuration != store.loadConfiguration() {
            save(configuration)
        }
        inspection.configuration = configuration

        let needsHelper = !configuration.machines.isEmpty || !configuration.awaitingRestart.isEmpty
        if needsHelper, [.notInstalled, .notRunning, .outdated].contains(inspection.helper) {
            try? await helper.ensureRunning()
            inspection.helper = helper.state()
            note("Helper restarted: now \(inspection.helper)")
        }
    }

    private func forgettingDeletedMachines(in configuration: BridgeConfiguration, listed: [VirtualMachine]) -> BridgeConfiguration {
        var configuration = configuration
        for machine in configuration.machines + configuration.awaitingRestart where !listed.contains(where: { machine.hasID($0.id) }) {
            configuration.forget(machineID: machine.id)
        }
        return configuration
    }

    /// The VM chosen in the window, else one that was set up, else one that runs, else the first.
    private func preferredMachine(in inspection: Inspection) -> VirtualMachine? {
        let machines = inspection.windowsMachines
        let configuration = inspection.configuration
        return machines.first { $0.id == selectedMachineID }
            ?? machines.first { configuration.isEnabled(machineID: $0.id) || configuration.isAwaitingRestart(machineID: $0.id) }
            ?? machines.first(where: \.isRunning)
            ?? machines.first
    }

    // MARK: - Setting up

    func performPrimaryAction() async {
        guard activity == .idle else { return }
        switch summary {
        case .vmpalMissing:
            NSWorkspace.shared.open(CapsBridgeLinks.vmpal)
        case .noWindowsMachine, .ready:
            await checkAgain()
        case .notSetUp, .needsAttention, .startNeeded:
            await setUp(restartConfirmed: false)
        case .restartNeeded:
            await setUp(restartConfirmed: true)
        }
    }

    /// Does whatever is still missing, in order, and stops with a reason at the first thing that fails.
    private func setUp(restartConfirmed: Bool) async {
        guard let installation = inspection.installation, var machine = inspection.machine else { return }
        let vmpal = VMPalCommandLine(installation: installation)

        await work {
            step(String(localized: "Installing the helper on this Mac…"))
            try await ensureHelper()

            if !machine.isRunning {
                step(String(localized: "Starting Windows. This can take a minute…"))
                try await vmpal.start(machine.id)
            }
            if !machine.allowsControl {
                try await allowControl(of: machine, with: vmpal)
            }
            machine = try await vmpal.machines().first { $0.id == machine.id } ?? machine

            step(String(localized: "Waiting for Windows to be ready…"))
            try await waitUntilReady(machine, with: vmpal)

            let guest = configurator(vmpal, machine)
            var snapshot = try await guest.inspect()
            if snapshot.keyMapping == .missing {
                step(String(localized: "Setting up the Caps Lock key in Windows…"))
                try await guest.applyKeyMapping(to: snapshot)
                snapshot = try await guest.inspect()
            }

            var restart = false
            if snapshot.keyMapping == .awaitingRestart {
                restart = restartConfirmed ? true : await ask(
                    title: String(localized: "Restart Windows now?"),
                    message: String(localized: "Windows needs to restart to learn the Caps Lock key. Save any open work in Windows first."),
                    confirm: String(localized: "Restart Now"),
                    cancel: String(localized: "Later"))
            }

            if snapshot.nvda == .capsLockOff {
                step(String(localized: "Turning on Caps Lock as an NVDA key…"))
                try await guest.enableNVDACapsLock(relaunch: !restart)
            }

            var configuration = store.loadConfiguration()
            if snapshot.keyMapping == .awaitingRestart {
                configuration.markAwaitingRestart(machine.bridgeMachine)
                save(configuration)
                if restart {
                    step(String(localized: "Restarting Windows. This can take a few minutes…"))
                    try await vmpal.restart(machine.id)
                    snapshot = try await waitForRestart(of: machine, with: vmpal)
                }
            }
            if snapshot.keyMapping == .active {
                configuration.enable(machine.bridgeMachine)
                save(configuration)
            }
        }
        await refresh()
        if failure == nil { announce([headline, explanation].joined(separator: ". ")) }
    }

    private func ensureHelper() async throws {
        do {
            try await helper.ensureRunning()
        } catch HelperController.Failure.needsApproval {
            let open = await ask(
                title: String(localized: "Turn CapsBridge on in Login Items"),
                message: String(localized: "CapsBridge's helper is turned off in System Settings. Under General, Login Items & Extensions, turn CapsBridge on, then come back and try again."),
                confirm: String(localized: "Open Login Items"),
                cancel: String(localized: "Cancel"))
            if open { helper.openLoginItems() }
            throw Stop.cancelled
        }
    }

    private func allowControl(of machine: VirtualMachine, with vmpal: VMPalCommandLine) async throws {
        let allow = await ask(
            title: String(localized: "Let CapsBridge set up Windows?"),
            message: String(localized: "VMPal's “Allow agent control of this VM” setting is off for \(machine.name). CapsBridge needs it on to change settings inside Windows."),
            confirm: String(localized: "Turn On and Continue"),
            cancel: String(localized: "Cancel"))
        guard allow else { throw Stop.cancelled }
        try await vmpal.setControlAllowed(true, for: machine.id)
    }

    /// Waits for Windows to take commands, administrator ones included, which it does a while after it starts.
    private func waitUntilReady(_ machine: VirtualMachine, with vmpal: VMPalCommandLine) async throws {
        var status = try await vmpal.status(of: machine.id)
        for _ in 0..<90 where !(status.canRunCommands && status.canRunAdministratorCommands) {
            try await Task.sleep(for: .seconds(2))
            status = try await vmpal.status(of: machine.id)
        }
        guard status.canRunCommands else { throw Stop.windowsNotReady }
        guard status.canRunAdministratorCommands else { throw Stop.administratorUnavailable }
    }

    /// Waits until Windows has started anew, which the registry tells: VMPal answers that a restart
    /// is under way while the Windows that's shutting down still takes commands.
    private func waitForRestart(of machine: VirtualMachine, with vmpal: VMPalCommandLine) async throws -> GuestSnapshot {
        let guest = configurator(vmpal, machine)
        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(3))
            // Commands fail while Windows is down, which is what's being waited out.
            guard let status = try? await vmpal.status(of: machine.id), status.canRunCommands,
                  let snapshot = try? await guest.inspect(), snapshot.keyMapping != .awaitingRestart else { continue }
            return snapshot
        }
        throw Stop.restartTookTooLong
    }

    // MARK: - Removing

    func remove() async {
        guard activity == .idle else { return }
        let confirmed = await ask(
            title: String(localized: "Remove CapsBridge?"),
            message: String(localized: "This removes the helper from this Mac, takes the Caps Lock key out of Windows, and puts NVDA's setting back if CapsBridge changed it. Nothing else is touched."),
            confirm: String(localized: "Remove"),
            cancel: String(localized: "Cancel"),
            isDestructive: true)
        guard confirmed else { return }

        var leftAsIs: [String] = []
        await work {
            if let installation = inspection.installation {
                let vmpal = VMPalCommandLine(installation: installation)
                for machine in try await machinesToClean(with: vmpal) {
                    if try await !clean(machine, with: vmpal) { leftAsIs.append(machine.name) }
                }
            }
            step(String(localized: "Removing the helper from this Mac…"))
            await helper.remove()
            KeyRemapper().deactivateBridge()
            try store.removeAll()
        }
        await refresh()
        guard failure == nil else { return }

        var message = String(localized: "Windows goes back to its usual Caps Lock the next time it restarts.")
        if !leftAsIs.isEmpty {
            message = String(localized: "Windows in \(leftAsIs.formatted(.list(type: .and))) was left as it is. Its key mapping does nothing without CapsBridge.")
        }
        announce(String(localized: "CapsBridge was removed"))
        let trash = await ask(
            title: String(localized: "CapsBridge was removed"),
            message: message + " " + String(localized: "Do you want to move the CapsBridge app to the Trash as well?"),
            confirm: String(localized: "Move to Trash"),
            cancel: String(localized: "Keep the App"))
        if trash { AppLocation.moveToTrashAndQuit() }
    }

    /// The Windows VMs that hold something of CapsBridge's, as far as this Mac knows.
    private func machinesToClean(with vmpal: VMPalCommandLine) async throws -> [VirtualMachine] {
        let configuration = store.loadConfiguration()
        return try await vmpal.machines().filter { machine in
            guard machine.isWindows else { return false }
            if configuration.isEnabled(machineID: machine.id) || configuration.isAwaitingRestart(machineID: machine.id) { return true }
            return machine.id == inspection.machine?.id && inspection.guest?.hasCapsBridgeTraces == true
        }
    }

    /// Takes CapsBridge's changes out of one VM's Windows. Returns false when the user chose to leave it.
    private func clean(_ machine: VirtualMachine, with vmpal: VMPalCommandLine) async throws -> Bool {
        if !machine.isRunning {
            let start = await ask(
                title: String(localized: "Start Windows to clean it up?"),
                message: String(localized: "\(machine.name) isn't running. CapsBridge can start it to take its key mapping out, or leave Windows as it is: the mapping does nothing without CapsBridge."),
                confirm: String(localized: "Start Windows"),
                cancel: String(localized: "Leave Windows As It Is"))
            guard start else { return false }
            step(String(localized: "Starting Windows. This can take a minute…"))
            try await vmpal.start(machine.id)
        }
        if !machine.allowsControl {
            try await allowControl(of: machine, with: vmpal)
        }
        step(String(localized: "Waiting for Windows to be ready…"))
        try await waitUntilReady(machine, with: vmpal)

        let guest = configurator(vmpal, machine)
        if try await guest.inspect().recordedNVDAChange != nil {
            step(String(localized: "Putting NVDA's setting back…"))
            try await guest.restoreNVDASetting(relaunch: true)
        }
        step(String(localized: "Taking the Caps Lock key out of Windows…"))
        try await guest.removeKeyMapping(from: try await guest.inspect())
        return true
    }

    // MARK: - Questions

    func answer(_ confirmed: Bool) {
        guard let prompt else { return }
        self.prompt = nil
        isPromptPresented = false
        note("Answered: \(confirmed ? prompt.confirm : prompt.cancel)")
        prompt.answer.resume(returning: confirmed)
    }

    private func ask(title: String, message: String, confirm: String, cancel: String, isDestructive: Bool = false) async -> Bool {
        note("Asking: \(title)")
        return await withCheckedContinuation { continuation in
            prompt = Prompt(title: title, message: message, confirm: confirm, cancel: cancel, isDestructive: isDestructive, answer: continuation)
            isPromptPresented = true
        }
    }

    // MARK: - Working

    private enum Stop: Error {
        case cancelled
        case windowsNotReady
        case administratorUnavailable
        case restartTookTooLong
    }

    private func work(_ operation: () async throws -> Void) async {
        activity = .working
        failure = nil
        await quietRefresh?.value
        do {
            try await operation()
        } catch Stop.cancelled {
            note("Stopped by the user")
        } catch {
            note("Failed: \(error)")
            failure = message(for: error)
            announce(failure ?? "")
        }
        progress = nil
        activity = .idle
    }

    private func step(_ message: String) {
        progress = message
        note(message)
        announce(message)
    }

    private func save(_ configuration: BridgeConfiguration) {
        do {
            try store.save(configuration)
            DistributedNotificationCenter.default().postNotificationName(
                CapsBridgeIdentifiers.configurationChanged, object: nil, userInfo: nil, deliverImmediately: true)
        } catch {
            note("Saving the configuration failed: \(error)")
        }
    }

    private func configurator(_ vmpal: VMPalCommandLine, _ machine: VirtualMachine) -> GuestConfigurator {
        GuestConfigurator(shell: VMPalGuestShell(controller: vmpal, machineID: machine.id))
    }

    private func message(for error: Error) -> String {
        switch error {
        case Stop.windowsNotReady:
            return String(localized: "Windows didn't become ready in time. Sign in to Windows in the virtual machine's window, then try again.")
        case Stop.restartTookTooLong:
            return String(localized: "Windows is taking a long time to restart. Once it's back, open CapsBridge again and it finishes by itself.")
        case Stop.administratorUnavailable:
            return String(localized: "Windows can't run administrator commands yet. Open the virtual machine, sign in, and let VMPal Tools finish installing, then try again.")
        case HelperController.Failure.couldNotStart(let reason):
            return reason.isEmpty
                ? String(localized: "The helper couldn't be started. Try again, or restart this Mac.")
                : String(localized: "The helper couldn't be installed: \(reason)")
        case VMPalError.commandFailed(_, _, let reason):
            return String(localized: "VMPal couldn't do that: \(reason)")
        case VMPalError.unreadableAnswer:
            return String(localized: "VMPal answered in a way CapsBridge doesn't understand. Updating VMPal and CapsBridge may help.")
        case GuestError.scriptFailed(let reason):
            return String(localized: "A step failed inside Windows: \(reason)")
        case GuestError.unreadableProbe:
            return String(localized: "Windows answered in a way CapsBridge doesn't understand.")
        case GuestError.nvdaStillRunning:
            return String(localized: "NVDA didn't quit, so its settings weren't changed. Quit NVDA in Windows and try again.")
        case GuestError.nvdaConfigUnreadable:
            return String(localized: "NVDA's settings file couldn't be read, so it was left alone.")
        default:
            return error.localizedDescription
        }
    }

    private func announce(_ message: String) {
        guard !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: - Diagnostics

    private func note(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        journal.append("\(Date().formatted(.iso8601)) \(line)")
        if journal.count > 200 { journal.removeFirst(journal.count - 200) }
    }

    /// What happened, in plain text, for a problem report. Nothing from Windows' files goes in it.
    var diagnosticReport: String {
        let info = Bundle.main.infoDictionary ?? [:]
        var lines = [
            "CapsBridge \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "VMPal: \(inspection.installation?.version ?? "not installed")",
            "Windows VM: \(inspection.machine.map { "\($0.system ?? "Windows"), \($0.state)" } ?? "none") (\(inspection.windowsMachines.count) in all)",
            "Reach: \(inspection.reach)",
            "Helper: \(inspection.helper)",
            "Summary: \(inspection.summary)",
            "Key mapping: \(inspection.guest.map { "\($0.keyMapping)" } ?? "unknown")",
            "NVDA: \(inspection.guest.map { "\($0.nvda), version \($0.nvdaVersion ?? "none")" } ?? "unknown")",
            "Windows build: \(inspection.guest?.build ?? "unknown")",
            "Forwarding to \(inspection.configuration.machines.count) VM(s), \(inspection.configuration.awaitingRestart.count) waiting for a restart",
            "",
        ]
        lines += journal
        return lines.joined(separator: "\n")
    }

    func copyDiagnosticReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport, forType: .string)
        announce(String(localized: "Report copied"))
    }
}

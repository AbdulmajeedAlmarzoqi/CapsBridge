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
    private var shownListingFailure: String?
    private var helperRecovery: Task<Void, Never>?
    private var hasStarted = false
    /// Set when the user quit while the app was working: it quits as soon as the work is done.
    var quitWhenDone = false

    /// Whether the user can start something: nothing is under way and no question is waiting.
    var canAct: Bool { activity == .idle && prompt == nil }

    // MARK: - What the window shows

    /// Whether the first check is still under way, and there's nothing to show or press yet.
    var isStarting: Bool { !hasStarted }

    var summary: Inspection.Summary { inspection.summary }
    var checks: [Check] { inspection.checks }

    var headline: String {
        if isStarting { return String(localized: "Checking configuration…") }
        switch summary {
        case .vmpalMissing: return String(localized: "VMPal is not installed")
        case .vmpalNotResponding: return String(localized: "VMPal is not responding")
        case .noWindowsMachine: return String(localized: "No Windows virtual machine was found")
        case .notSetUp: return String(localized: "CapsBridge is not set up")
        case .needsAttention: return String(localized: "Some items need attention")
        case .restartNeeded: return String(localized: "Restart Windows to complete setup")
        case .startNeeded: return String(localized: "Start Windows to complete setup")
        case .ready: return String(localized: "Caps Lock is ready to use")
        }
    }

    var explanation: String {
        if isStarting { return "" }
        switch summary {
        case .vmpalMissing:
            return String(localized: "CapsBridge requires VMPal and a Windows virtual machine. Install VMPal, create a Windows virtual machine, and then open CapsBridge again.")
        case .vmpalNotResponding:
            return String(localized: "Make sure VMPal is running, and then check again.")
        case .noWindowsMachine:
            return String(localized: "Create a Windows virtual machine in VMPal, and then check again.")
        case .notSetUp:
            return String(localized: "Set up CapsBridge to use Caps Lock as the screen reader modifier key in Windows.")
        case .needsAttention:
            return String(localized: "Click Fix to resolve the items that need attention.")
        case .restartNeeded:
            return String(localized: "Windows applies the Caps Lock mapping when it restarts. Save any open documents in Windows before restarting.")
        case .startNeeded:
            return String(localized: "Setup completes the next time Windows starts.")
        case .ready:
            return String(localized: "In Windows, hold Caps Lock as the screen reader modifier key. To turn Caps Lock on or off, press it twice quickly.")
        }
    }

    var primaryTitle: String {
        switch summary {
        case .vmpalMissing: String(localized: "Get VMPal")
        case .noWindowsMachine, .vmpalNotResponding, .ready: String(localized: "Check Again")
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
        if AppLocation.shouldOfferToMove, await offerToMove() { return }
        await refresh()
        hasStarted = true
        announce(headline)
    }

    /// Asks to move the app into the Applications folder, and moves it. Returns whether it's on its way
    /// there: the copy in the Applications folder is opened, and this one quits.
    private func offerToMove() async -> Bool {
        let move = await ask(
            title: String(localized: "Move CapsBridge to the Applications folder?"),
            message: String(localized: "CapsBridge runs a helper from within the app, so the app must remain in the Applications folder."),
            confirm: String(localized: "Move to Applications Folder"),
            cancel: String(localized: "Don’t Move"))
        guard move else { return false }
        do {
            try await AppLocation.moveToApplicationsAndRelaunch()
            return true
        } catch {
            note("Moving failed: \(error)")
            failure = String(localized: "CapsBridge could not be moved to the Applications folder. \(error.localizedDescription)")
            return false
        }
    }

    /// Checks again when the user comes back to the app, as after restarting Windows by hand.
    /// It runs behind the window as it is: the buttons stay usable, and what they start waits for it.
    func refreshAfterReturning() {
        guard hasStarted, canAct, quietRefresh == nil, Date().timeIntervalSince(lastRefresh) > 15 else { return }
        quietRefresh = Task {
            let before = summary
            let selection = selectedMachineID
            let inspection = await inspect()
            if canAct, selectedMachineID == selection {
                show(inspection)
                if summary != before { announce(headline) }
            }
            quietRefresh = nil
        }
    }

    func checkAgain() async {
        guard canAct else { return }
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
        // A problem reaching VMPal is shown until a check gets through; the failure of an action stays.
        if let problem = inspection.listingFailure {
            failure = problem
            shownListingFailure = problem
        } else if let shown = shownListingFailure, failure == shown {
            failure = nil
            shownListingFailure = nil
        }
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
                inspection.listingFailure = message(for: error)
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
            if inspection.helper != .running, inspection.helper != .needsApproval { recoverHelperLater() }
        }
    }

    /// Keeps trying to start the helper for a few minutes. Right after the app was replaced by a copy
    /// signed otherwise, the system takes a minute or two before it lets the new helper start.
    private func recoverHelperLater() {
        guard helperRecovery == nil else { return }
        helperRecovery = Task {
            defer { helperRecovery = nil }
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { return }
                guard canAct else { continue }
                if helper.state() != .running { try? await helper.ensureRunning() }
                guard helper.state() == .running else { continue }
                note("Helper recovered")
                if canAct { show(await inspect()) }
                return
            }
        }
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
        guard canAct else { return }
        switch summary {
        case .vmpalMissing:
            NSWorkspace.shared.open(CapsBridgeLinks.vmpal)
        case .noWindowsMachine, .vmpalNotResponding, .ready:
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

        if AppLocation.shouldOfferToMove {
            guard await offerToMove() else {
                failure = String(localized: "To set up CapsBridge, move it to the Applications folder.")
                announce(failure ?? "")
                return
            }
            return
        }

        await work {
            step(String(localized: "Installing the helper…"))
            try await ensureHelper()

            // Set up before and shut down since: only the helper needed attention, and Windows is
            // checked again when it runs.
            if !machine.isRunning, inspection.isEnabled, !restartConfirmed { return }

            if !machine.isRunning {
                step(String(localized: "Starting Windows. This may take a minute…"))
                try await start(machine, with: vmpal)
            }
            if !machine.allowsControl {
                guard try await allowControl(of: machine, with: vmpal) else { throw Stop.cancelled }
            }
            machine = try await vmpal.machines().first { $0.id == machine.id } ?? machine

            step(String(localized: "Waiting for Windows…"))
            try await waitUntilReady(machine, with: vmpal)

            let guest = configurator(vmpal, machine)
            var snapshot = try await guest.inspect()
            if snapshot.keyMapping == .missing {
                step(String(localized: "Configuring Caps Lock in Windows…"))
                try await guest.applyKeyMapping(to: snapshot)
                snapshot = try await guest.inspect()
            }
            var configuration = store.loadConfiguration()
            if snapshot.keyMapping == .awaitingRestart {
                // Recorded at once, so a setup interrupted from here on still completes after a restart.
                configuration.markAwaitingRestart(machine.bridgeMachine)
                save(configuration)
            }

            var restart = false
            if snapshot.keyMapping == .awaitingRestart {
                restart = restartConfirmed ? true : await ask(
                    title: String(localized: "Restart Windows now?"),
                    message: String(localized: "Windows must restart to apply the Caps Lock mapping. Save any open documents in Windows before continuing."),
                    confirm: String(localized: "Restart"),
                    cancel: String(localized: "Later"))
            }

            if snapshot.nvda == .capsLockOff {
                step(String(localized: "Turning on Caps Lock as an NVDA modifier key…"))
                try await guest.enableNVDACapsLock()
            }

            if snapshot.keyMapping == .awaitingRestart, restart {
                step(String(localized: "Restarting Windows. This may take a few minutes…"))
                try await vmpal.restart(machine.id)
                snapshot = try await waitForRestart(of: machine, with: vmpal)
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
                title: String(localized: "CapsBridge Helper is turned off"),
                message: String(localized: "Turn on CapsBridge in System Settings > General > Login Items & Extensions, and then try again."),
                confirm: String(localized: "Open System Settings"),
                cancel: String(localized: "Cancel"))
            if open { helper.openLoginItems() }
            throw Stop.cancelled
        }
    }

    /// Asks to turn on VMPal's agent control for a VM, and does. Returns false when the user declines.
    private func allowControl(of machine: VirtualMachine, with vmpal: VMPalCommandLine) async throws -> Bool {
        let allow = await ask(
            title: String(localized: "Allow CapsBridge to configure Windows?"),
            message: String(localized: "To change settings in Windows, CapsBridge requires the “Allow agent control of this VM” setting in VMPal, which is turned off for \(machine.name)."),
            confirm: String(localized: "Turn On and Continue"),
            cancel: String(localized: "Cancel"))
        guard allow else { return false }
        try await vmpal.setControlAllowed(true, for: machine.id)
        return true
    }

    /// Starts a VM. VMPal gives up waiting when it can't sign in to Windows by itself, and the user
    /// can still sign in in the VM's window, which the wait that follows allows for.
    private func start(_ machine: VirtualMachine, with vmpal: VMPalCommandLine) async throws {
        do {
            try await vmpal.start(machine.id)
        } catch {
            note("Starting \(machine.name) ended with: \(error)")
            guard try await vmpal.machines().first(where: { $0.id == machine.id })?.isRunning == true else { throw error }
        }
    }

    /// Waits for Windows to take commands, administrator ones included, which it does a while after it starts.
    private func waitUntilReady(_ machine: VirtualMachine, with vmpal: VMPalCommandLine) async throws {
        var status = try await vmpal.status(of: machine.id)
        let deadline = Date().addingTimeInterval(180)
        while !(status.canRunCommands && status.canRunAdministratorCommands), Date() < deadline {
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
        guard canAct else { return }
        let confirmed = await ask(
            title: String(localized: "Remove CapsBridge?"),
            message: String(localized: "The helper will be removed from this Mac, the Caps Lock mapping will be removed from Windows, and the NVDA setting will be restored if CapsBridge changed it. No other settings are affected."),
            confirm: String(localized: "Remove"),
            cancel: String(localized: "Cancel"),
            isDestructive: true)
        guard confirmed else { return }

        var leftAsIs: [String] = []
        await work {
            let configured = store.loadConfiguration()
            if let installation = inspection.installation, let machines = try? await machinesToClean(with: VMPalCommandLine(installation: installation)) {
                let vmpal = VMPalCommandLine(installation: installation)
                for machine in machines {
                    do {
                        guard try await clean(machine, with: vmpal) else {
                            leftAsIs.append(machine.name)
                            continue
                        }
                        var configuration = store.loadConfiguration()
                        configuration.forget(machineID: machine.id)
                        save(configuration)
                    } catch Stop.cancelled {
                        leftAsIs.append(machine.name)
                    } catch {
                        // One VM that can't be reached doesn't keep the others, or this Mac, from being cleaned.
                        note("Cleaning \(machine.name) failed: \(error)")
                        leftAsIs.append(machine.name)
                    }
                }
            } else {
                leftAsIs = (configured.machines + configured.awaitingRestart).map(\.name)
            }

            step(String(localized: "Removing the helper…"))
            await helper.remove()
            KeyRemapper(store: store).deactivateBridge()
            // Saved empty first: a configuration left behind would bring the helper back at the next check.
            try? store.save(BridgeConfiguration())
            try? store.removeAll()
            DistributedNotificationCenter.default().postNotificationName(
                CapsBridgeIdentifiers.configurationChanged, object: nil, userInfo: nil, deliverImmediately: true)
        }
        await refresh()
        guard failure == nil else { return }

        var message = String(localized: "Caps Lock returns to its usual behavior in Windows after the next restart.")
        if !leftAsIs.isEmpty {
            message = String(localized: "\(leftAsIs.formatted(.list(type: .and))) was left unchanged. The remaining Caps Lock mapping has no effect without CapsBridge.")
        }
        let trash = await ask(
            title: String(localized: "CapsBridge has been removed"),
            message: message + " " + String(localized: "Do you also want to move CapsBridge to the Trash?"),
            confirm: String(localized: "Move to Trash"),
            cancel: String(localized: "Keep"))
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
            let startWindows = await ask(
                title: String(localized: "Start Windows to complete removal?"),
                message: String(localized: "\(machine.name) is not running. CapsBridge can start it to remove the Caps Lock mapping, or leave Windows unchanged. The mapping has no effect without CapsBridge."),
                confirm: String(localized: "Start Windows"),
                cancel: String(localized: "Leave Unchanged"))
            guard startWindows else { return false }
            step(String(localized: "Starting Windows. This may take a minute…"))
            try await start(machine, with: vmpal)
        }
        if !machine.allowsControl {
            guard try await allowControl(of: machine, with: vmpal) else { return false }
        }
        step(String(localized: "Waiting for Windows…"))
        try await waitUntilReady(machine, with: vmpal)

        let guest = configurator(vmpal, machine)
        if try await guest.inspect().recordedNVDAChange != nil {
            step(String(localized: "Restoring the NVDA setting…"))
            try await guest.restoreNVDASetting()
        }
        step(String(localized: "Removing the Caps Lock mapping from Windows…"))
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
        if quitWhenDone { NSApp.reply(toApplicationShouldTerminate: true) }
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
            return String(localized: "Windows did not become available in time. Sign in to Windows in the virtual machine window, and then try again.")
        case Stop.restartTookTooLong:
            return String(localized: "Windows is taking longer than expected to restart. When Windows is available, open CapsBridge again to complete setup.")
        case Stop.administratorUnavailable:
            return String(localized: "Windows cannot run administrator commands yet. Open the virtual machine, sign in, wait for VMPal Tools to finish installing, and then try again.")
        case HelperController.Failure.couldNotStart(let reason):
            return reason.isEmpty
                ? String(localized: "The helper could not be started. Try again, or restart your Mac.")
                : String(localized: "The helper could not be installed. \(reason)")
        case VMPalError.commandFailed(_, _, let reason):
            return String(localized: "VMPal could not complete the request. \(reason)")
        case VMPalError.unreadableAnswer:
            return String(localized: "VMPal returned an unexpected response. Updating VMPal and CapsBridge may resolve the issue.")
        case GuestError.scriptFailed(let reason):
            return String(localized: "An operation in Windows failed. \(reason)")
        case GuestError.unreadableProbe:
            return String(localized: "Windows returned an unexpected response.")
        case GuestError.nvdaNotRestarted:
            return String(localized: "NVDA could not be restarted. To start NVDA, press Control-Alt-N in Windows.")
        case GuestError.nvdaConfigChanged:
            return String(localized: "The NVDA configuration changed while CapsBridge was updating it, so it was left unchanged. Try again.")
        case GuestError.nvdaStillRunning:
            return String(localized: "NVDA did not quit, so its settings were not changed. Quit NVDA in Windows, and then try again.")
        case GuestError.nvdaConfigUnreadable:
            return String(localized: "The NVDA configuration file could not be read and was left unchanged.")
        default:
            return error.localizedDescription
        }
    }

    func announce(_ message: String) {
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
        announce(String(localized: "Diagnostic report copied"))
    }
}

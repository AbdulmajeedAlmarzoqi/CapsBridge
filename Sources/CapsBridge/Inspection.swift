import CapsBridgeKit
import Foundation

/// Everything the app found out about this Mac, VMPal and one Windows VM, at one moment.
struct Inspection {
    var installation: VMPalInstallation?
    var windowsMachines: [VirtualMachine] = []
    /// The VM the window is about.
    var machine: VirtualMachine?
    var machineStatus: MachineStatus?
    var guest: GuestSnapshot?
    var helper: HelperController.State = .notInstalled
    var configuration = BridgeConfiguration()

    /// Whether commands can run in the VM's Windows now, and if not, why.
    enum Reach: Equatable {
        case ready
        case shutDown
        /// VMPal's "Allow agent control of this VM" is off, so it refuses commands in the VM.
        case controlOff
        /// Windows is starting, or nobody is signed in.
        case notReady
    }

    var reach: Reach {
        guard let machine, machine.isRunning else { return .shutDown }
        guard machine.allowsControl else { return .controlOff }
        return machineStatus?.canRunCommands == true ? .ready : .notReady
    }

    var isEnabled: Bool { machine.map { configuration.isEnabled(machineID: $0.id) } ?? false }
    var isAwaitingRestart: Bool { machine.map { configuration.isAwaitingRestart(machineID: $0.id) } ?? false }

    enum Summary: Equatable {
        case vmpalMissing
        case noWindowsMachine
        case notSetUp
        /// It was set up, and something has changed since.
        case needsAttention
        case restartNeeded
        /// Set up while Windows was shut down, or shut down since: it completes at Windows' next start.
        case startNeeded
        case ready
    }

    var summary: Summary {
        guard installation != nil else { return .vmpalMissing }
        guard machine != nil else { return .noWindowsMachine }
        let helperRuns = helper == .running

        switch reach {
        case .ready:
            switch guest?.keyMapping {
            case .active?:
                if isEnabled { return helperRuns && guest?.nvda != .capsLockOff ? .ready : .needsAttention }
                return .notSetUp
            case .awaitingRestart?:
                return .restartNeeded
            case .missing?:
                return isEnabled || isAwaitingRestart ? .needsAttention : .notSetUp
            case nil:
                // Windows didn't answer the questions. What was set up is taken to still be.
                if isEnabled { return helperRuns ? .ready : .needsAttention }
                return .notSetUp
            }
        case .shutDown:
            if isAwaitingRestart { return .startNeeded }
            if isEnabled { return helperRuns ? .ready : .needsAttention }
            return .notSetUp
        case .controlOff, .notReady:
            if isEnabled { return helperRuns ? .ready : .needsAttention }
            return isAwaitingRestart ? .restartNeeded : .notSetUp
        }
    }
}

/// One line of the window's list of checks.
struct Check: Identifiable, Equatable {
    enum Kind: String {
        case vmpal, machine, helper, keyMapping, nvda
    }

    enum Mark {
        case good
        /// Not done yet, or waiting for something.
        case pending
        case problem
        /// Neither good nor bad: there's nothing to do about it.
        case neutral
    }

    var kind: Kind
    var title: String
    var detail: String
    var mark: Mark

    var id: Kind { kind }
}

extension Inspection {
    var checks: [Check] {
        var checks: [Check] = []

        if let installation {
            checks.append(Check(
                kind: .vmpal,
                title: String(localized: "VMPal"),
                detail: String(localized: "Version \(installation.version)"),
                mark: .good))
        } else {
            checks.append(Check(
                kind: .vmpal,
                title: String(localized: "VMPal"),
                detail: String(localized: "Not installed"),
                mark: .problem))
            return checks
        }

        guard let machine else {
            checks.append(Check(
                kind: .machine,
                title: String(localized: "Windows virtual machine"),
                detail: String(localized: "None found"),
                mark: .problem))
            return checks
        }

        checks.append(Check(
            kind: .machine,
            title: String(localized: "Windows virtual machine"),
            detail: machineDetail(for: machine),
            mark: reach == .ready ? .good : .neutral))
        checks.append(helperCheck(for: machine))
        checks.append(keyMappingCheck)
        if let nvdaCheck { checks.append(nvdaCheck) }
        return checks
    }

    private func machineDetail(for machine: VirtualMachine) -> String {
        switch reach {
        case .ready: String(localized: "\(machine.name) is running")
        case .shutDown: String(localized: "\(machine.name) isn't running")
        case .controlOff: String(localized: "\(machine.name) is running, with VMPal's “Allow agent control of this VM” turned off")
        case .notReady: String(localized: "\(machine.name) is starting, or waiting for someone to sign in")
        }
    }

    private func helperCheck(for machine: VirtualMachine) -> Check {
        let title = String(localized: "Helper on this Mac")
        switch helper {
        case .running:
            if isEnabled {
                return Check(kind: .helper, title: title, detail: String(localized: "Running, and sending Caps Lock to \(machine.name)"), mark: .good)
            }
            return Check(kind: .helper, title: title, detail: String(localized: "Running, and not sending Caps Lock to \(machine.name) yet"), mark: .pending)
        case .notInstalled:
            return Check(kind: .helper, title: title, detail: String(localized: "Not installed yet"), mark: isEnabled ? .problem : .pending)
        case .needsApproval:
            return Check(kind: .helper, title: title, detail: String(localized: "Turned off in System Settings, under Login Items"), mark: .problem)
        case .notRunning:
            return Check(kind: .helper, title: title, detail: String(localized: "Not running"), mark: .problem)
        case .outdated:
            return Check(kind: .helper, title: title, detail: String(localized: "Running an older version"), mark: .problem)
        }
    }

    private var keyMappingCheck: Check {
        let title = String(localized: "Caps Lock key in Windows")
        switch reach {
        case .ready:
            break
        case .shutDown:
            if isAwaitingRestart {
                return Check(kind: .keyMapping, title: title, detail: String(localized: "Set up, and ready the next time Windows starts"), mark: .pending)
            }
            if isEnabled {
                return Check(kind: .keyMapping, title: title, detail: String(localized: "Set up. It's checked again when Windows runs"), mark: .good)
            }
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Not set up"), mark: .pending)
        case .controlOff, .notReady:
            if isEnabled {
                return Check(kind: .keyMapping, title: title, detail: String(localized: "Set up. It can't be checked right now"), mark: .neutral)
            }
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Can't be checked right now"), mark: .pending)
        }

        switch guest?.keyMapping {
        case .active?:
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Ready"), mark: .good)
        case .awaitingRestart?:
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Set up, and waiting for Windows to restart"), mark: .pending)
        case .missing?:
            if isEnabled || isAwaitingRestart {
                return Check(kind: .keyMapping, title: title, detail: String(localized: "Missing. Windows may have been reset or taken back to a snapshot"), mark: .problem)
            }
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Not set up"), mark: .pending)
        case nil:
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Windows didn't answer, so it couldn't be checked"), mark: .neutral)
        }
    }

    private var nvdaCheck: Check? {
        guard reach == .ready, let guest else { return nil }
        let title = String(localized: "NVDA")
        switch guest.nvda {
        case .notInstalled:
            return Check(kind: .nvda, title: title, detail: String(localized: "Not installed in this Windows"), mark: .neutral)
        case .capsLockOn:
            return Check(kind: .nvda, title: title, detail: String(localized: "Caps Lock is an NVDA key"), mark: .good)
        case .capsLockOff:
            return Check(kind: .nvda, title: title, detail: String(localized: "Caps Lock isn't an NVDA key yet"), mark: isEnabled ? .problem : .pending)
        case .unreadable:
            return Check(kind: .nvda, title: title, detail: String(localized: "Its settings file can't be read, so it's left alone. In NVDA's Keyboard settings, choose Caps Lock as an NVDA modifier key"), mark: .neutral)
        }
    }
}

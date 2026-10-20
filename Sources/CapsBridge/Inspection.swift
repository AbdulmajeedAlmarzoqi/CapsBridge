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
    /// Why VMPal couldn't be asked about its virtual machines, when it couldn't.
    var listingFailure: String?

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
        /// VMPal is there, and didn't answer.
        case vmpalNotResponding
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
        guard listingFailure == nil else { return .vmpalNotResponding }
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
                return isAwaitingRestart ? .restartNeeded : .notSetUp
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
                detail: String(localized: "Installed (version \(installation.version))"),
                mark: .good))
        } else {
            checks.append(Check(
                kind: .vmpal,
                title: String(localized: "VMPal"),
                detail: String(localized: "Not installed"),
                mark: .problem))
            return checks
        }
        guard listingFailure == nil else { return checks }

        guard let machine else {
            checks.append(Check(
                kind: .machine,
                title: String(localized: "Windows Virtual Machine"),
                detail: String(localized: "None found"),
                mark: .problem))
            return checks
        }

        checks.append(Check(
            kind: .machine,
            title: String(localized: "Windows Virtual Machine"),
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
        case .shutDown: String(localized: "\(machine.name) is not running")
        case .controlOff: String(localized: "\(machine.name) is running, but “Allow agent control of this VM” is turned off in VMPal")
        case .notReady: String(localized: "\(machine.name) is starting up or waiting for a user to sign in")
        }
    }

    private func helperCheck(for machine: VirtualMachine) -> Check {
        let title = String(localized: "CapsBridge Helper")
        switch helper {
        case .running:
            if isEnabled {
                return Check(kind: .helper, title: title, detail: String(localized: "Running and forwarding Caps Lock to \(machine.name)"), mark: .good)
            }
            return Check(kind: .helper, title: title, detail: String(localized: "Running; not yet forwarding Caps Lock to \(machine.name)"), mark: .pending)
        case .notInstalled:
            return Check(kind: .helper, title: title, detail: String(localized: "Not installed"), mark: isEnabled ? .problem : .pending)
        case .needsApproval:
            return Check(kind: .helper, title: title, detail: String(localized: "Turned off in Login Items"), mark: .problem)
        case .notRunning:
            return Check(kind: .helper, title: title, detail: String(localized: "Not running"), mark: .problem)
        case .outdated:
            return Check(kind: .helper, title: title, detail: String(localized: "An earlier version is running"), mark: .problem)
        }
    }

    private var keyMappingCheck: Check {
        let title = String(localized: "Caps Lock in Windows")
        switch reach {
        case .ready:
            break
        case .shutDown:
            if isAwaitingRestart {
                return Check(kind: .keyMapping, title: title, detail: String(localized: "Configured; takes effect the next time Windows starts"), mark: .pending)
            }
            if isEnabled {
                return Check(kind: .keyMapping, title: title, detail: String(localized: "Configured; verified when Windows is running"), mark: .good)
            }
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Not configured"), mark: .pending)
        case .controlOff, .notReady:
            if isEnabled {
                return Check(kind: .keyMapping, title: title, detail: String(localized: "Configured; cannot be verified right now"), mark: .neutral)
            }
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Cannot be verified right now"), mark: .pending)
        }

        switch guest?.keyMapping {
        case .active?:
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Ready"), mark: .good)
        case .awaitingRestart?:
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Configured; takes effect after Windows restarts"), mark: .pending)
        case .missing?:
            if isEnabled || isAwaitingRestart {
                return Check(kind: .keyMapping, title: title, detail: String(localized: "Missing. Windows may have been reset or restored from a snapshot."), mark: .problem)
            }
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Not configured"), mark: .pending)
        case nil:
            return Check(kind: .keyMapping, title: title, detail: String(localized: "Windows did not respond; the mapping could not be verified"), mark: .neutral)
        }
    }

    private var nvdaCheck: Check? {
        guard reach == .ready, let guest else { return nil }
        let title = String(localized: "NVDA")
        switch guest.nvda {
        case .notInstalled:
            return Check(kind: .nvda, title: title, detail: String(localized: "Not installed in Windows"), mark: .neutral)
        case .capsLockOn:
            return Check(kind: .nvda, title: title, detail: String(localized: "Caps Lock is an NVDA modifier key"), mark: .good)
        case .capsLockOff:
            return Check(kind: .nvda, title: title, detail: String(localized: "Caps Lock is not yet an NVDA modifier key"), mark: isEnabled ? .problem : .pending)
        case .unreadable:
            return Check(kind: .nvda, title: title, detail: String(localized: "The NVDA configuration file could not be read and was left unchanged. In NVDA, choose Preferences > Settings > Keyboard, and then select Caps Lock as an NVDA modifier key."), mark: .neutral)
        }
    }
}

import Foundation

/// Names shared by the app and its background helper.
public enum CapsBridgeIdentifiers {
    public static let app = "com.abdulmajeedalmarzoqi.capsbridge"
    public static let helper = "com.abdulmajeedalmarzoqi.capsbridge.helper"
    /// The launchd property list inside the app's `Contents/Library/LaunchAgents`.
    public static let helperPropertyList = helper + ".plist"
    /// Posted by the app after it rewrites the configuration, so the helper picks it up at once.
    public static let configurationChanged = Notification.Name(app + ".configurationChanged")

    public static let vmpal = "com.tableplus.VMPal"
    /// The process that runs a VM and owns its window.
    public static let vmpalMachine = "com.tableplus.VMPal.Machine"
    /// VMPal's per-VM Dock app: this prefix followed by the VM's ID in lowercase hex.
    public static let vmpalMachineStubPrefix = "com.tableplus.VMPal.vm."
}

public enum CapsBridgeLinks {
    public static let website = URL(string: "https://abdulmajeedalmarzoqi.github.io/CapsBridge/")!
    public static let repository = URL(string: "https://github.com/AbdulmajeedAlmarzoqi/CapsBridge")!
    public static let issues = URL(string: "https://github.com/AbdulmajeedAlmarzoqi/CapsBridge/issues")!
    public static let vmpal = URL(string: "https://vmpal.com")!
}

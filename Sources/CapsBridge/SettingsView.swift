import SwiftUI

struct SettingsView: View {
    @Bindable var updates: UpdateController

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
                Toggle("Download and install updates automatically", isOn: $updates.automaticallyDownloadsUpdates)
                    .disabled(!updates.automaticallyChecksForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("CapsBridge checks for updates once a day, including while only its helper is running. When an update is available, its release notes are shown before anything is installed, unless updates are installed automatically.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button("Check for Updates Now") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

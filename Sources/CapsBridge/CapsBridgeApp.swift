import CapsBridgeKit
import SwiftUI

@main
struct CapsBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("CapsBridge", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Check Again") {
                    Task { await model.checkAgain() }
                }
                .keyboardShortcut("r")
                .disabled(model.activity != .idle)
            }
            CommandGroup(replacing: .help) {
                Link("CapsBridge Website", destination: CapsBridgeLinks.website)
                Link("Report a Problem", destination: CapsBridgeLinks.issues)
                Divider()
                Button("Copy Diagnostic Report") {
                    model.copyDiagnosticReport()
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The window is the app: closing it quits. The helper runs on its own.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

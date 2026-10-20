import CapsBridgeKit
import SwiftUI

@main
struct CapsBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

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
                .disabled(!model.canAct)
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// The window is the app: closing it quits. The helper runs on its own.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting halfway could leave NVDA closed in Windows, so the work under way finishes first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.prompt != nil { model.answer(false) }
        guard model.activity == .working else { return .terminateNow }
        model.quitWhenDone = true
        model.announce(String(localized: "CapsBridge will quit when the current operation is complete."))
        return .terminateLater
    }
}

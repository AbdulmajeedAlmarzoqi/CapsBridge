import CapsBridgeKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @AccessibilityFocusState private var headlineIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if model.inspection.windowsMachines.count > 1 {
                machinePicker
            }
            if !model.isStarting, !model.checks.isEmpty {
                checkList
            }
            if let failure = model.failure {
                FailureView(message: failure)
            }
            footer
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .alert(model.prompt?.title ?? "", isPresented: $model.isPromptPresented, presenting: model.prompt) { prompt in
            Button(prompt.confirm, role: prompt.isDestructive ? .destructive : nil) { model.answer(true) }
                .keyboardShortcut(.defaultAction)
            Button(prompt.cancel, role: .cancel) { model.answer(false) }
        } message: { prompt in
            Text(prompt.message)
        }
        .task { await model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAfterReturning()
        }
        .onChange(of: model.summary) {
            headlineIsFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            SummaryIcon(summary: model.summary, isChecking: model.isStarting)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.headline)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headlineIsFocused)
                if !model.explanation.isEmpty {
                    Text(model.explanation)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var machinePicker: some View {
        Picker("Windows virtual machine", selection: $model.selectedMachineID) {
            ForEach(model.inspection.windowsMachines) { machine in
                Text(machine.name).tag(Optional(machine.id))
            }
        }
        .disabled(model.activity != .idle)
        .onChange(of: model.selectedMachineID) { _, selected in
            guard selected != model.inspection.machine?.id else { return }
            Task { await model.checkAgain() }
        }
    }

    private var checkList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.checks) { check in
                CheckRow(check: check)
                if check.id != model.checks.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var footer: some View {
        if model.isStarting {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        } else if model.activity == .working {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(model.progress ?? "")
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack {
                Button(model.primaryTitle) {
                    Task { await model.performPrimaryAction() }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.activity != .idle)

                Spacer()

                if model.canRemove {
                    Button("Remove CapsBridge…") {
                        Task { await model.remove() }
                    }
                    .controlSize(.large)
                    .disabled(model.activity != .idle)
                }
            }
        }
    }
}

private struct SummaryIcon: View {
    var summary: Inspection.Summary
    var isChecking: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 34))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(width: 44)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        if isChecking { return "capslock" }
        return switch summary {
        case .ready: "checkmark.seal.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .restartNeeded, .startNeeded: "arrow.clockwise.circle.fill"
        case .vmpalMissing, .noWindowsMachine: "questionmark.circle.fill"
        case .notSetUp: "capslock.fill"
        }
    }

    private var color: Color {
        if isChecking { return .secondary }
        return switch summary {
        case .ready: .green
        case .needsAttention: .orange
        case .restartNeeded, .startNeeded, .notSetUp: .accentColor
        case .vmpalMissing, .noWindowsMachine: .secondary
        }
    }
}

private struct CheckRow: View {
    var check: Check

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .fontWeight(.medium)
                Text(check.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(check.title): \(check.detail)"))
        .accessibilityValue(status)
        .accessibilityAddTraits(.isStaticText)
    }

    private var symbol: String {
        switch check.mark {
        case .good: "checkmark.circle.fill"
        case .pending: "circle.dashed"
        case .problem: "exclamationmark.triangle.fill"
        case .neutral: "minus.circle"
        }
    }

    private var color: Color {
        switch check.mark {
        case .good: .green
        case .pending: .secondary
        case .problem: .orange
        case .neutral: .secondary
        }
    }

    /// What the mark shows, in words.
    private var status: Text {
        switch check.mark {
        case .good: Text("OK")
        case .pending: Text("Not done yet")
        case .problem: Text("Needs attention")
        case .neutral: Text(verbatim: "")
        }
    }
}

private struct FailureView: View {
    var message: String

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

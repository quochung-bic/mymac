import AppKit
import MyMacCore
import Observation
import SwiftUI

/// Handles quitting a process, with the confirmation that has to come first.
@MainActor
@Observable
final class ProcessActionModel {
    struct Pending: Identifiable, Equatable {
        let id: pid_t
        let name: String
        let isApplication: Bool
    }

    private(set) var pending: Pending?
    private(set) var message: String?
    /// Set when a polite request was made and the process is still there.
    private(set) var awaitingForce: Pending?

    func confirm(_ process: ProcessSample) {
        pending = Pending(id: process.id, name: process.name,
                          isApplication: process.kind == .application)
        message = nil
    }

    func cancel() {
        pending = nil
        awaitingForce = nil
    }

    func quit(force: Bool) {
        guard let target = pending ?? awaitingForce else { return }
        pending = nil

        // A GUI app is asked through AppKit first: that lets it save open
        // documents, which a bare signal does not. `terminate()` returns whether
        // the request could even be made, and ignoring that meant a refusal
        // looked exactly like a request the app was still thinking about.
        var asked = false
        if target.isApplication, !force,
           let app = NSRunningApplication(processIdentifier: target.id) {
            asked = app.terminate()
            if !asked {
                Log.app.error("NSRunningApplication refused to ask \(target.name, privacy: .public) to quit; falling back to a signal")
            }
        }

        if !asked {
            do {
                try ProcessTerminator.terminate(pid: target.id, force: force)
            } catch let failure as ProcessTerminator.Failure {
                message = failure.message
                awaitingForce = nil
                return
            } catch {
                message = error.localizedDescription
                awaitingForce = nil
                return
            }
        }

        Task {
            // Give it a moment to go quietly before offering the blunt option.
            try? await Task.sleep(for: .seconds(3))
            if ProcessTerminator.isRunning(pid: target.id) {
                self.awaitingForce = target
                self.message = "\(target.name) has not quit yet."
            } else {
                self.awaitingForce = nil
                self.message = "\(target.name) has quit."
            }
        }
    }

    func dismissMessage() {
        message = nil
        awaitingForce = nil
    }
}

/// Surfaces processes worth a second look, without shouting about them.
struct ProcessAttentionBanner: View {
    @Environment(MetricsStore.self) private var store
    @Environment(ProcessActionModel.self) private var actions

    var body: some View {
        if !store.alerts.isEmpty {
            VStack(spacing: 6) {
                ForEach(store.alerts.prefix(3)) { alert in
                    row(alert)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
            )
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
    }

    private func row(_ alert: ProcessAlert) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .imageScale(.small)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(alert.process.name).fontWeight(.medium)
                    Text(verbatim: "PID \(alert.process.pid)")
                        .font(.note)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(alert.headline)
                    .font(.note)
                    .foregroundStyle(.secondary)
                Text(alert.advice)
                    .font(.note)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button("Quit…") { actions.confirm(alert.process) }
                .controlSize(.small)
        }
        .font(.callout)
    }
}

struct QuitConfirmationSheet: View {
    @Environment(ProcessActionModel.self) private var actions
    let pending: ProcessActionModel.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Quit \(pending.name)?")
                .font(.headline)
            Text(pending.isApplication
                 ? "\(pending.name) will be asked to quit, so it can save anything open. If it does not respond, you can force it afterwards."
                 : "A termination signal will be sent to PID \(pending.id). Unsaved work in that process is lost.")
                .font(.note)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { actions.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Quit") { actions.quit(force: false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

struct QuitOutcomeSheet: View {
    @Environment(ProcessActionModel.self) private var actions
    let message: String
    let canForce: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(message)
                .font(.callout)
            if canForce {
                Text("Forcing it will end the process immediately. Anything unsaved is lost.")
                    .font(.note)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if canForce {
                    Button("Force Quit", role: .destructive) { actions.quit(force: true) }
                }
                Button("Done") { actions.dismissMessage() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}

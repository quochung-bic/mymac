import AppKit
import MyMacCore
import ServiceManagement
import SwiftUI

enum SettingsKey {
    /// Widens every sampling interval. Kept in defaults rather than on the store
    /// so the store can read it without the settings page having to exist.
    static let relaxedUpdates = "relaxedUpdates"
}

struct SettingsView: View {
    /// Tabs rather than one long column: each group fits without scrolling, and
    /// a settings pane that scrolls hides half of itself.
    private enum Tab: String, CaseIterable, Identifiable {
        case general, menuBar, permissions

        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "General"
            case .menuBar: "Menu Bar"
            case .permissions: "Permissions"
            }
        }
    }

    @State private var tab: Tab = .general

    @AppStorage(MenuBarPreference.showsCPU) private var showsCPU = true
    @AppStorage(MenuBarPreference.showsMemory) private var showsMemory = true
    @AppStorage(SettingsKey.relaxedUpdates) private var relaxedUpdates = false

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    private let system = SystemInfo.current

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)

            switch tab {
            case .general: general
            case .menuBar: menuBarTab
            case .permissions: PermissionsPanel()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
    }

    private var general: some View {
        VStack(spacing: 12) {
            updates.frame(height: 116)
            startup.frame(height: loginItemError == nil ? 92 : 116)
            about.frame(maxHeight: .infinity)
        }
    }

    /// One card filling the pane reads as deliberate; a small card floating in
    /// an empty pane reads as something that failed to load.
    private var menuBarTab: some View {
        menuBar.frame(maxHeight: .infinity)
    }

    // MARK: - Menu bar

    private var menuBar: some View {
        Card(title: "Menu Bar", symbol: "menubar.rectangle", fillsHeight: true) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show CPU", isOn: $showsCPU)
                    Toggle("Show memory", isOn: $showsMemory)
                }
                Spacer(minLength: 8)
                preview
            }
            Divider().padding(.vertical, 4)

            Text(showsCPU && showsMemory
                 ? "Both readouts are stacked on two lines, which keeps the item about half the width it would need side by side."
                 : showsCPU || showsMemory
                 ? "A single readout is drawn on one line at full size."
                 : "With both off the item is a single icon, and sampling stops until you open a window — the lowest power the app can run at.")
                .font(.note)
                .foregroundStyle(.secondary)

            Text("The readout is drawn as one image so the symbols render correctly and the item keeps a constant width as the numbers change.")
                .font(.note)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    /// Shows the actual rendered item rather than describing it. It is the same
    /// drawing code the menu bar uses, so the preview cannot drift.
    private var preview: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("Preview")
                .font(.note)
                .foregroundStyle(.secondary)
            Image(nsImage: MenuBarIcon.render(previewSegments))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                )
        }
    }

    private var previewSegments: [MenuBarIcon.Segment] {
        var segments: [MenuBarIcon.Segment] = []
        if showsCPU { segments.append(.init(symbol: "cpu", text: "38%")) }
        if showsMemory { segments.append(.init(symbol: "memorychip", text: "84%")) }
        if segments.isEmpty {
            segments.append(.init(symbol: "gauge.with.dots.needle.33percent", text: ""))
        }
        return segments
    }

    // MARK: - Updates

    private var updates: some View {
        Card(title: "Updates", symbol: "timer", fillsHeight: true) {
            Picker("", selection: $relaxedUpdates) {
                Text("Standard").tag(false)
                Text("Relaxed").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 18) {
                InlineStat(label: "Window open", value: relaxedUpdates ? "every 2s" : "every 1s")
                InlineStat(label: "Menu bar only", value: relaxedUpdates ? "every 6s" : "every 3s")
                InlineStat(label: "Filesystem", value: "only when you ask")
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
            Text("Sampling stops entirely when nothing is displaying metrics, whichever setting you pick.")
                .font(.note)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Startup

    private var startup: some View {
        Card(title: "Startup", symbol: "power", fillsHeight: true) {
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled: enabled) }
            if let loginItemError {
                Text(loginItemError)
                    .font(.note)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - About

    private var about: some View {
        Card(title: "About", symbol: "info.circle", fillsHeight: true) {
            InlineStat(label: "Version", value: appVersion)
            InlineStat(label: "Machine", value: "\(system.chip) · \(system.coreSummary) · \(Format.bytes(system.physicalMemory))")
            InlineStat(label: "System", value: system.operatingSystem)
            Spacer(minLength: 0)
            Text("Diagnostics go to the unified log under the subsystem \(Log.subsystem).")
                .font(.note)
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// `SMAppService` is the supported replacement for login-item hacks. It needs
    /// a signed, bundled app, so failure is reported rather than hidden.
    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError = "macOS refused this change: \(error.localizedDescription)"
            Log.app.error("login item change failed: \(error.localizedDescription)")
        }
    }
}

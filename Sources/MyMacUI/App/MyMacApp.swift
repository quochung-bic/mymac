import AppKit
import MyMacCore
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, cpu, memory, storage, network, battery, processes, cleaner, uninstaller, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .network: "Network"
        case .battery: "Battery"
        case .processes: "Processes"
        case .cleaner: "Cleaner"
        case .uninstaller: "Uninstaller"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .network: "network"
        case .battery: "battery.100"
        case .processes: "list.bullet"
        case .cleaner: "sparkles"
        case .uninstaller: "trash"
        case .settings: "gearshape"
        }
    }
}

extension MainSection {
    /// Watching the machine, changing it, and configuring the app are three
    /// different intentions. Ten flat rows read as a list; three named groups
    /// read as a structure, which is also what every native app with a sidebar
    /// does. The order inside each group is unchanged, so ⌘1…⌘0 still land
    /// where they always did.
    enum Group: String, CaseIterable, Identifiable {
        case monitor, tools, app

        var id: String { rawValue }

        var title: String {
            switch self {
            case .monitor: "Monitor"
            case .tools: "Tools"
            case .app: "App"
            }
        }

        var sections: [MainSection] {
            switch self {
            case .monitor: [.dashboard, .cpu, .memory, .storage, .network, .battery, .processes]
            case .tools: [.cleaner, .uninstaller]
            case .app: [.settings]
            }
        }
    }
}

enum MainWindow {
    static let identifier = "main"
}

enum MenuBarPreference {
    static let showsCPU = "menuBarShowsCPU"
    static let showsMemory = "menuBarShowsMemory"
}

/// Cross-scene state that does not belong to any one view.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()
    /// Set by the menu bar just before it opens the window, so the window can
    /// land on the section the user actually asked for.
    var pendingSection: MainSection?
    /// What the app should show next.
    enum Request: Equatable {
        case mainWindow
    }

    /// Requests are routed through the menu bar label rather than performed
    /// where they originate. `openWindow` and `openSettings` are only reachable
    /// from a view, and the popover's own view is torn down the moment it
    /// closes — which is exactly when these actions run. The label is the one
    /// view guaranteed to still be alive.
    private(set) var requestCount = 0
    private(set) var request: Request = .mainWindow

    func perform(_ request: Request, section: MainSection? = nil) {
        if let section { pendingSection = section }
        self.request = request
        requestCount += 1
    }

    func requestMainWindow(section: MainSection? = nil) {
        perform(.mainWindow, section: section)
    }

    /// Bumped when a menu command picks a section, so an already-open window
    /// switches to it.
    private(set) var sectionRequests = 0

    func selectSection(_ section: MainSection) {
        pendingSection = section
        sectionRequests += 1
        if !DockPolicy.hasOrdinaryWindow { requestMainWindow(section: section) }
    }
}

/// Dock presence follows whether a window is open.
///
/// The app is a menu bar utility (`LSUIElement`), but a utility with a real
/// window should behave like a real app while that window is up: Dock icon,
/// menu bar, ⌘Tab. It steps back out of the way when the window closes.
@MainActor
enum DockPolicy {
    /// Promote to a regular app *before* the window is created. Changing the
    /// activation policy while a window is being shown makes AppKit tear that
    /// window straight back down.
    static func promote() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    static func reviewAfterWindowClose() {
        // Run after the close completes so the closing window is not counted.
        DispatchQueue.main.async {
            if !hasOrdinaryWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Whether a real app window is on screen. The menu bar popover is an
    /// `NSPanel` and must not count: treating it as a window makes the app
    /// think it is already showing something and quietly ignore a request to
    /// open the dashboard.
    static var hasOrdinaryWindow: Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain && !(window is NSPanel)
        }
    }
}

/// Public, and without `@main`: the entry point is `Sources/MyMac/main.swift`,
/// which calls the `main()` the `App` protocol already provides. That keeps
/// every line of the app inside a library a test target can link against.
public struct MyMacApp: App {
    public init() {}

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = MetricsStore()
    @State private var cleaner = CleanerModel()
    @State private var uninstaller = UninstallerModel()
    @State private var permissions = PermissionsModel()
    @State private var processActions = ProcessActionModel()
    @AppStorage(MenuBarPreference.showsCPU) private var showsCPU = true
    @AppStorage(MenuBarPreference.showsMemory) private var showsMemory = true

    public var body: some Scene {
        // MenuBarExtra is declared first so it is the app's primary scene: this
        // is a menu bar utility, and launching it must not put a window on
        // screen. `AppDelegate` closes anything SwiftUI opens anyway.
        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            // The label reads the store itself. Reading it here, in `App.body`,
            // would make every one-second sample invalidate the entire scene
            // graph — including the main window — instead of one small view.
            MenuBarLabel(showsCPU: showsCPU, showsMemory: showsMemory)
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        mainWindow
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { AppState.shared.selectSection(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // ⌘1…⌘8 jump straight to a section, the way every native app with a
            // sidebar behaves.
            CommandGroup(after: .sidebar) {
                Divider()
                // ⌘1…⌘9 then ⌘0, the way a browser numbers its tabs. Sections
                // past the tenth have no number left to give; Settings keeps ⌘,
                // and everything is reachable from the sidebar regardless.
                ForEach(Array(MainSection.allCases.prefix(10).enumerated()), id: \.element) { index, section in
                    Button(section.title) { AppState.shared.selectSection(section) }
                        .keyboardShortcut(KeyEquivalent(Character("\((index + 1) % 10)")), modifiers: .command)
                }
            }
        }
    }

    /// The dashboard window.
    ///
    /// SwiftUI's `defaultLaunchBehavior(.suppressed)` and
    /// `restorationBehavior(.disabled)` are what would say "do not put this on
    /// screen at launch" declaratively, and a comment in `AppDelegate` used to
    /// claim they were doing so. They were never applied, and they cannot be
    /// while the deployment target is macOS 14: both need macOS 15, and
    /// `SceneBuilder` has no `buildEither`, so there is no way to attach them
    /// behind an availability check. `AppDelegate` handles it for every version
    /// instead — one mechanism rather than two that have to agree.
    private var mainWindow: some Scene {
        Window("MyMac", id: MainWindow.identifier) {
            MainWindowView()
                .environment(store)
                .environment(cleaner)
                .environment(uninstaller)
                .environment(permissions)
                .environment(processActions)
                // Large enough that the dashboard and the CPU page always fit
                // without a scroll bar.
                .frame(minWidth: 880, minHeight: 620)
        }
    }
}

/// The menu bar label keeps a low-frequency sampling scope alive for as long as
/// the app is running — this is the one thing that is always on screen.
private struct MenuBarLabel: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let showsCPU: Bool
    let showsMemory: Bool

    private var appState: AppState { AppState.shared }
    private var isActive: Bool { showsCPU || showsMemory }

    var body: some View {
        readout
            .onAppear { store.setMenuBarActive(isActive) }
            .onChange(of: isActive) { _, active in store.setMenuBarActive(active) }
            .onChange(of: appState.requestCount) { handleRequest() }
    }

    /// Rendered as one image rather than composed from `Text` and `Image`:
    /// symbol interpolation inside a `MenuBarExtra` label does not paint.
    private var readout: some View {
        Image(nsImage: MenuBarIcon.render(segments))
            .accessibilityLabel(accessibilityLabel)
    }

    private var segments: [MenuBarIcon.Segment] {
        var result: [MenuBarIcon.Segment] = []
        if showsCPU { result.append(.init(symbol: "cpu", text: store.menuBarCPUText)) }
        if showsMemory { result.append(.init(symbol: "memorychip", text: store.menuBarMemoryText)) }
        if result.isEmpty {
            result.append(.init(symbol: "gauge.with.dots.needle.33percent", text: ""))
        }
        return result
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if showsCPU { parts.append("CPU \(store.menuBarCPUText.trimmingCharacters(in: .whitespaces))") }
        if showsMemory { parts.append("Memory \(store.menuBarMemoryText.trimmingCharacters(in: .whitespaces))") }
        return parts.isEmpty ? "System status" : parts.joined(separator: ", ")
    }

    private func handleRequest() {
        // Promote before the window exists: changing the activation policy
        // while a window is appearing makes AppKit tear it straight down.
        DockPolicy.promote()
        openWindow(id: MainWindow.identifier)
        DockPolicy.activate()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Re-opening the app (Dock icon, `open -a`, Launchpad) shows the
    /// dashboard, which is what a user asking for an already-running utility
    /// expects to happen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // `hasVisibleWindows` counts the menu bar popover, so it is not the
        // right question — ask whether a real window is up.
        if !DockPolicy.hasOrdinaryWindow {
            AppState.shared.requestMainWindow()
        }
        return true
    }

    /// A menu bar utility must not put a window on screen when it launches, and
    /// must not have one restored onto it at login either.
    ///
    /// This used to be gated to macOS 14 on the belief that `MyMacApp` applied
    /// `defaultLaunchBehavior(.suppressed)` on newer systems. It never did —
    /// the name appeared only in this comment — so on macOS 15 and later
    /// nothing was enforcing it at all, and the app was relying on SwiftUI
    /// happening to leave the window closed because `MenuBarExtra` is declared
    /// first. The gate is gone: this now runs everywhere, which is also the
    /// only option while the deployment target is macOS 14 (see `mainWindow`).
    ///
    /// Run one turn of the run loop later, so anything SwiftUI opened — or
    /// macOS restored — already exists to be closed.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("MyMac launched")
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                Log.app.info("closing a window opened at launch; this app starts in the menu bar")
                window.close()
            }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Closing the last window returns the app to the menu bar rather than
    /// quitting it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MainWindowView: View {
    @Environment(MetricsStore.self) private var store
    @Environment(CleanerModel.self) private var cleaner
    @State private var section: MainSection = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(MainSection.Group.allCases) { group in
                    Section(group.title) {
                        ForEach(group.sections) { item in
                            Label(item.title, systemImage: item.symbol).tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch section {
            case .dashboard: DashboardView()
            case .cpu: CPUDetailView()
            case .memory: MemoryDetailView()
            case .storage: StorageDetailView()
            case .network: NetworkDetailView()
            case .battery: BatteryDetailView()
            case .processes: ProcessListView()
            case .cleaner: CleanerView()
            case .uninstaller: UninstallerView()
            case .settings: SettingsView()
            }
        }
        .onAppear { applyPendingSection() }
        .onChange(of: AppState.shared.sectionRequests) { applyPendingSection() }
        .onDisappear { DockPolicy.reviewAfterWindowClose() }
    }

    private func applyPendingSection() {
        guard let pending = AppState.shared.pendingSection else { return }
        section = pending
        AppState.shared.pendingSection = nil
    }
}

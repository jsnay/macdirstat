import AppKit
import SwiftUI

// =============================================================================
// FILE: Sources/MacDirStat/MacDirStatApp.swift
// =============================================================================
//
// PURPOSE
//   The executable's entry point and scene graph: creates the single
//   AppState, pins the engine ABI before any UI exists, defines the menu
//   commands (Open, View menu with metric/zoom/re-scan), and switches the
//   one window between the welcome picker (1f) and the active surface (1b)
//   via RootView. Also works around the bare-SwiftPM-executable activation
//   quirk so `swift run` behaves like a bundled app.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - Model/AppState.swift: the app-wide @StateObject; every menu command
//     calls into it (startScan, rescan, goBack/goForward, sizeMetric).
//   - Engine/Engine.swift: Engine.verifyABI at init; SizeMetric menu tags.
//   - Views/WelcomeView.swift + Views/MainView.swift: the two phases
//     RootView switches between.
//   - SwiftUI (App/Scene/commands) and AppKit (NSApp activation,
//     NSOpenPanel for ⌘O).
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - None in code — this is the root. Every view below receives the
//     AppState injected here via .environmentObject.
//
// STRUCTURE
//   - AppDelegate: activation-policy fix for bare `swift run`
//   - MacDirStatApp: @main App — scene, menu commands, ⌘O open panel
//   - RootView: phase switch (welcome vs active) + the shared error alert
//
// BEHAVIOR & INVARIANTS
//   - Engine.verifyABI() runs in MacDirStatApp.init — before any scene
//     body — so a header/library mismatch dies loudly at launch, never
//     mid-scan (APP-FFI-6).
//   - There is exactly one AppState; @StateObject here is its only owner.
//   - lastError is the single error surface: RootView's alert binding
//     clears it on dismiss, so any component can post one error string.
// =============================================================================

// MARK: - AppDelegate (activation quirk)

/// When launched as a bare SwiftPM executable (`swift run`) there is no app
/// bundle, so macOS treats the process as a background tool: the menu bar
/// stays owned by the launching app and no menus mount. Claiming regular
/// activation explicitly fixes both (a bundled build is unaffected).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - App entry point

@main
struct MacDirStatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The one AppState instance for the whole app, injected into the
    /// environment below.
    @StateObject private var state = AppState()

    /// Fail fast on an engine header/library mismatch (APP-FFI-6): this
    /// precondition fires before any window exists.
    init() {
        Engine.verifyABI()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)  // design 1b ships dark; light pass is deferred
                .frame(minWidth: 980, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { openFolder() }
                    .keyboardShortcut("o")
            }
            CommandMenu("View") {
                Button("Type Table") { state.typeTablePresented.toggle() }
                    .keyboardShortcut("t")
                    .disabled(state.model == nil)
                Picker("Sizes", selection: $state.sizeMetric) {
                    Text("On Disk (Allocated)").tag(SizeMetric.physical)
                    Text("Apparent (Logical)").tag(SizeMetric.logical)
                }
                Divider()
                Button("Zoom Out") { state.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!state.canGoBack)
                Button("Zoom Back In") { state.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!state.canGoForward)
                Divider()
                Button("Re-scan Selection") {
                    if let selection = state.selection { state.rescan(selection) }
                }
                .keyboardShortcut("r")
                .disabled(state.selection == nil || state.isScanning || state.isRefreshing)
                Button("Re-scan All") { state.rescanAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(state.model == nil || state.isScanning)
            }
        }
    }

    /// ⌘O: standard folder picker; a chosen folder starts a scan directly
    /// (volume figures are looked up from the containing volume).
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            state.startScan(path: url.path, volume: nil)
        }
    }
}

// MARK: - Root phase switch

/// Switches the window between the picker (1f) and the active two-pane
/// surface (1b/1d) and hosts the app-wide error alert. The alert binding
/// derives presentation from `lastError != nil` and clears the error when
/// dismissed — any component that sets `state.lastError` gets an alert
/// with no additional wiring.
struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            switch state.phase {
            case .welcome:
                WelcomeView()
            case .active:
                MainView()
            }
        }
        .alert(
            "MacDirStat",
            isPresented: Binding(
                get: { state.lastError != nil },
                set: { if !$0 { state.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.lastError ?? "")
        }
    }
}

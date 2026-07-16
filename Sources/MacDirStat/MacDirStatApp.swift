import AppKit
import SwiftUI

@main
struct MacDirStatApp: App {
    @StateObject private var state = AppState()

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

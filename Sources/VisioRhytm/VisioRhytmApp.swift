import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state?.prepareToQuit() == false ? .terminateCancel : .terminateNow
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first { state?.openURL(URL(fileURLWithPath: first)) }
        sender.reply(toOpenOrPrint: .success)
    }
}

@main
struct VisioRhytmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()
    var body: some Scene {
        Window("VisioRhytm", id: "main") {
            MainWindow(state: state)
                .onAppear { delegate.state = state }
                .onDisappear { state.metronome.stop() }
                .onOpenURL { state.openURL($0) }
        }
        .defaultSize(width: 1440, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новый проект") { state.newProject() }.keyboardShortcut("n")
                Button("Открыть…") { state.openProject() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Сохранить") { state.save() }.keyboardShortcut("s")
                Button("Сохранить как…") { state.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Воспроизведение") {
                Button(state.metronome.isPlaying ? "Stop" : "Play") { state.togglePlayback() }.keyboardShortcut(.space, modifiers: [.command])
                Button("Вернуться к началу") { state.returnToStart() }.keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }
}

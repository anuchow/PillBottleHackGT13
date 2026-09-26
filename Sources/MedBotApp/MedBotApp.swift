import AppKit
import SwiftUI

@main
struct MedBotApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup("MedBot") {
            ContentView()
        }
    }
}

/// Launched with `swift run` there is no app bundle, so macOS treats us as a background process.
/// Make it a normal app with a Dock icon and bring its window to the front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

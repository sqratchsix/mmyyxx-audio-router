import AppKit
import SwiftUI

@main
struct MmyyxxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("mmyyxx", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
                .preferredColorScheme(.dark)
                // Three things are needed for the glass, and it is opaque
                // without any one of them: a material for the window's own
                // background, a toolbar that does not paint its own opaque bar
                // over it, and the `NSWindow` transparency set in `ContentView`.
                .containerBackground(.ultraThinMaterial, for: .window)
                // The title bar is glass. What keeps it legible over scrolling
                // content is the scrim `ContentView` draws underneath it, not
                // an opaque bar.
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.onTerminate() }
    }
}

import SwiftUI

@main
struct WhisperFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scene — AppDelegate manages the menu bar status item
        // and the entire app lifecycle. Returning an empty Settings scene
        // would create a phantom "Preferences" menu item with no window.
        // Just return an empty body.
        Settings {
            EmptyView()
        }
        .commandsRemoved()  // Hide any default menu items
    }
}

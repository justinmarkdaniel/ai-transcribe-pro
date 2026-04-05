import SwiftUI
import AppKit

@main
struct AITranscribeProApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory: no dock icon, lives as a floating utility.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

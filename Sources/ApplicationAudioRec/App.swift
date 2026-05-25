import AppKit

// Menu-bar agent: no Dock icon, no main window. `.accessory` keeps it out of
// the Dock and app switcher; the same intent is declared via LSUIElement in
// Info.plist so it behaves identically when launched from Finder.
//
// The entry point is main-actor isolated so it can construct the @MainActor
// AppDelegate directly.
@main
struct ApplicationAudioRecApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

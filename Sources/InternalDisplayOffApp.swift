import Cocoa

@main
@MainActor
struct InternalDisplayOffEntry {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

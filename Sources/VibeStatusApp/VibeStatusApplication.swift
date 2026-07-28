import AppKit

@main
enum VibeStatusApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate(client: LiveDashboardClient())
        application.delegate = delegate
        application.run()
    }
}

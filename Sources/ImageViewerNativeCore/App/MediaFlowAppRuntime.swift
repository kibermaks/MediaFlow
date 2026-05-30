import AppKit

@MainActor public enum MediaFlowAppRuntime {
    private static let delegate = AppDelegate()

    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

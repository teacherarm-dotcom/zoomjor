import Cocoa

enum ZoomJorApp {
    @MainActor static var delegate: AppDelegate?

    @MainActor static func run() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d                    // NSApplication.delegate เป็น weak จึงต้องถือไว้เอง
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

MainActor.assumeIsolated { ZoomJorApp.run() }

import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.mainMenu = MainMenu.make()
    withExtendedLifetime(delegate) {
        app.run()
    }
}

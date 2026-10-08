import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = MainWindowController()
        self.window = window
        // Switch 进入「从 DBIbackend 安装游戏」时把窗口拿到前面
        Installer.shared.onConnect = { [weak window] in
            window?.showWindow(nil)
            NSApp.requestUserAttention(.informationalRequest)
        }
        Installer.shared.start()
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 拖到 Dock 图标上的文件
    func application(_ sender: NSApplication, open urls: [URL]) {
        Installer.shared.add(urls)
        window?.showWindow(nil)
    }

    /// 正在安装时退出前确认：Switch 那边的安装会中断
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Installer.shared.isSending else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "正在给 Switch 安装游戏。")
        alert.informativeText = String(localized: "现在退出，Switch 上的安装会中断。")
        alert.addButton(withTitle: String(localized: "退出"))
        alert.addButton(withTitle: String(localized: "取消"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Installer.shared.stop()
    }

    @objc func addFiles(_ sender: Any?) {
        window?.showWindow(nil)
        window?.addFiles(sender)
    }
}

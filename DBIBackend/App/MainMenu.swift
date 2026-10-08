import AppKit

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        return item
    }

    private static func appMenu() -> NSMenu {
        let name = "DBI Backend"
        let m = NSMenu(title: name)
        m.addItem(item(String(localized: "关于 \(name)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        let update = item(String(localized: "检查更新…"), #selector(AppUpdater.checkForUpdates(_:)))
        update.target = AppUpdater.shared
        m.addItem(update)
        m.addItem(.separator())
        m.addItem(item(String(localized: "隐藏 \(name)"), #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item(String(localized: "隐藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item(String(localized: "全部显示"), #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item(String(localized: "退出 \(name)"), #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu() -> NSMenu {
        let m = NSMenu(title: String(localized: "文件"))
        m.addItem(item(String(localized: "添加…"), #selector(AppDelegate.addFiles(_:)), "o"))
        m.addItem(.separator())
        m.addItem(item(String(localized: "关闭窗口"), #selector(NSWindow.performClose(_:)), "w"))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: String(localized: "编辑"))
        m.addItem(item(String(localized: "剪切"), #selector(NSText.cut(_:)), "x"))
        m.addItem(item(String(localized: "拷贝"), #selector(NSText.copy(_:)), "c"))
        m.addItem(item(String(localized: "粘贴"), #selector(NSText.paste(_:)), "v"))
        m.addItem(item(String(localized: "全选"), #selector(NSText.selectAll(_:)), "a"))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: String(localized: "窗口"))
        m.addItem(item(String(localized: "最小化"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item(String(localized: "缩放"), #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item(String(localized: "前置全部窗口"), #selector(NSApplication.arrangeInFront(_:))))
        return m
    }
}

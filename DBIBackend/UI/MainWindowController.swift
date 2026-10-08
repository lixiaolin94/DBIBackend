import AppKit
import UniformTypeIdentifiers

/// 唯一的窗口：上面是连接状态，中间是游戏列表，下面是按钮。文件可以直接拖进来。
@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let installer = Installer.shared

    private let statusIcon = NSImageView()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: String(localized: "重试"), target: nil, action: nil)
    private let table = FileTableView()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "把 NSP、NSZ、XCI、XCZ 文件或文件夹拖到这里"))
    private let removeButton = NSButton(title: String(localized: "移除"), target: nil, action: nil)
    private let clearButton = NSButton(title: String(localized: "清除已传完"), target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DBI Backend"
        window.minSize = NSSize(width: 480, height: 300)
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        super.init(window: window)
        buildContent()
        NotificationCenter.default.addObserver(self, selector: #selector(installerDidChange(_:)), name: Installer.didChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 布局

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        statusIcon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusTitle.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.font = .systemFont(ofSize: NSFont.systemFontSize)
        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        retryButton.bezelStyle = .rounded
        let texts = NSStackView(views: [statusTitle, statusDetail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let header = NSStackView(views: [statusIcon, texts, retryButton])
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        for (id, title, width) in [("name", String(localized: "名称"), 300.0), ("size", String(localized: "大小"), 80.0), ("status", String(localized: "状态"), 200.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = id == "size" ? 60 : 120
            table.addTableColumn(column)
        }
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 24
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.onDelete = { [weak self] in self?.removeSelected(nil) }
        table.menu = contextMenu()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 1)

        let addButton = NSButton(title: String(localized: "添加…"), target: self, action: #selector(addFiles(_:)))
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        clearButton.target = self
        clearButton.action = #selector(clearFinished(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [addButton, removeButton, spacer, clearButton])
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 14, right: 20)

        let separator = NSBox()
        separator.boxType = .separator

        for v in [header, separator, scroll, emptyLabel, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "在 Finder 中显示"), action: #selector(revealInFinder(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "移除"), action: #selector(removeSelected(_:)), keyEquivalent: "").target = self
        return menu
    }

    // MARK: 状态

    @objc private func installerDidChange(_ note: Notification) { refresh() }

    private func refresh() {
        let symbol: String
        let tint: NSColor
        switch installer.connection {
        case .waiting:
            symbol = "cable.connector"
            tint = .secondaryLabelColor
            statusTitle.stringValue = String(localized: "等待 Switch")
            statusDetail.stringValue = String(localized: "在 Switch 上打开 DBI，选择「从 DBIbackend 安装游戏」。")
        case .connected:
            symbol = installer.isSending ? "arrow.down.circle" : "checkmark.circle"
            tint = .systemGreen
            statusTitle.stringValue = installer.isSending ? String(localized: "正在安装") : String(localized: "已连接 Switch")
            statusDetail.stringValue = installer.items.isEmpty
                ? String(localized: "把游戏文件拖进来，然后在 Switch 上选择要安装的游戏。")
                : String(localized: "在 Switch 上选择要安装的游戏。新加的文件要在 Switch 上重新打开列表才会出现。")
        case let .failed(message):
            symbol = "exclamationmark.triangle"
            tint = .systemOrange
            statusTitle.stringValue = String(localized: "无法连接 Switch")
            statusDetail.stringValue = message
        }
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusIcon.contentTintColor = tint
        retryButton.isHidden = { if case .failed = installer.connection { return false } else { return true } }()

        let selected = Set(table.selectedRowIndexes.compactMap { installer.items.indices.contains($0) ? installer.items[$0].id : nil })
        table.reloadData()
        let rows = IndexSet(installer.items.enumerated().filter { selected.contains($0.element.id) }.map(\.offset))
        table.selectRowIndexes(rows, byExtendingSelection: false)
        emptyLabel.isHidden = !installer.items.isEmpty
        updateButtons()
    }

    private func updateButtons() {
        removeButton.isEnabled = selectedItems.contains { $0.state != .sending }
        clearButton.isEnabled = installer.items.contains { $0.state == .sent }
    }

    private var selectedItems: [Installer.Item] {
        table.selectedRowIndexes.compactMap { installer.items.indices.contains($0) ? installer.items[$0] : nil }
    }

    // MARK: 操作

    @objc func addFiles(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = Installer.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.prompt = String(localized: "添加")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { _ = self?.installer.add(urls) }
        }
    }

    @objc func removeSelected(_ sender: Any?) {
        installer.remove(Set(selectedItems.map(\.id)))
    }

    @objc private func clearFinished(_ sender: Any?) {
        installer.removeFinished()
    }

    @objc private func retry(_ sender: Any?) {
        installer.retry()
    }

    @objc private func revealInFinder(_ sender: Any?) {
        let rows = table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow)
            ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        let urls = rows.compactMap { installer.items.indices.contains($0) ? installer.items[$0].url : nil }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { installer.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue, installer.items.indices.contains(row) else { return nil }
        let item = installer.items[row]
        switch column {
        case "name":
            let cell = tableView.makeView(withIdentifier: .init("name"), owner: nil) as? NameCell ?? NameCell()
            cell.identifier = .init("name")
            cell.configure(item)
            return cell
        case "size":
            let cell = tableView.makeView(withIdentifier: .init("size"), owner: nil) as? NSTextField ?? Self.sizeLabel()
            cell.stringValue = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
            return cell
        default:
            let cell = tableView.makeView(withIdentifier: .init("status"), owner: nil) as? StatusCell ?? StatusCell()
            cell.identifier = .init("status")
            cell.configure(item)
            return cell
        }
    }

    private static func sizeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.identifier = .init("size")
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !Installer.installableFiles(in: Self.fileURLs(info)).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)   // 整个表格高亮，而不是插到某一行
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        installer.add(Self.fileURLs(info)) > 0
    }

    private static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

/// 支持删除键移除选中项
private final class FileTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?() } else { super.keyDown(with: event) }
    }
}

private final class NameCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingMiddle
        imageView = icon
        textField = label
        for v in [icon, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: Installer.Item) {
        icon.image = NSWorkspace.shared.icon(forFile: item.url.path)
        label.stringValue = item.name
        toolTip = item.url.path
    }
}

private final class StatusCell: NSTableCellView {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [bar, label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: Installer.Item) {
        let bytes = { (n: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        switch item.state {
        case .ready:
            bar.isHidden = true
            label.stringValue = String(localized: "等待在 Switch 上选择")
            label.textColor = .secondaryLabelColor
        case .sending:
            bar.isHidden = false
            bar.doubleValue = item.size > 0 ? Double(item.covered) / Double(item.size) : 0
            var text = "\(bytes(item.covered)) / \(bytes(item.size))"
            if let speed = item.bytesPerSecond { text += " · \(bytes(UInt64(speed)))/s" }
            label.stringValue = text
            label.textColor = .labelColor
        case .sent:
            bar.isHidden = true
            label.stringValue = String(localized: "已传完")
            label.textColor = .systemGreen
        case .interrupted:
            bar.isHidden = true
            label.stringValue = String(localized: "已中断（传到 \(bytes(item.covered))）")
            label.textColor = .systemOrange
        }
    }
}

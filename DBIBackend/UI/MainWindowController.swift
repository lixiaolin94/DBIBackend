import AppKit
import UniformTypeIdentifiers

/// 唯一的窗口：上面是连接状态，中间是游戏列表，下面是按钮。文件可以直接拖进来。
@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let installer = Installer.shared

    private let statusIcon = NSImageView()
    private let statusTitle = NSTextField(labelWithString: "")
    /// 固定一行：可换行的标签在窗口改宽度时会在一行、两行之间来回算，带着整个顶部区域的高度跳动
    private let statusDetail = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: String(localized: "重试"), target: nil, action: nil)
    private let table = FileTableView()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "把 NSP、NSZ、XCI、XCZ 文件或文件夹拖到这里"))
    /// 列表下方经典的「+ / −」按钮条
    private let addRemove = NSSegmentedControl()
    private let clearButton = NSButton(title: String(localized: "清除已传完"), target: nil, action: nil)
    /// 发送时每秒刷新一次速度列：Switch 停下来不要数据时不会有新事件，速度也要跟着降
    private var speedTimer: Timer?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DBI Backend"
        window.minSize = NSSize(width: 580, height: 300)
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
        statusDetail.lineBreakMode = .byTruncatingTail
        statusDetail.maximumNumberOfLines = 1
        // 放不下时截断，而不是把窗口撑宽
        statusDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

        let columns: [(id: String, title: String, width: CGFloat, minWidth: CGFloat, alignment: NSTextAlignment)] = [
            ("name", String(localized: "名称"), 220, 120, .left),
            ("size", String(localized: "大小"), 80, 60, .right),
            ("progress", String(localized: "进度"), 140, 80, .left),
            ("speed", String(localized: "速度"), 90, 70, .right),
        ]
        for c in columns {
            let column = NSTableColumn(identifier: .init(c.id))
            column.title = c.title
            column.width = c.width
            column.minWidth = c.minWidth
            column.headerCell.alignment = c.alignment
            table.addTableColumn(column)
        }
        table.style = .fullWidth
        table.gridStyleMask = []
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
        // 记住列宽和列顺序（在加完列之后设置，才会恢复上次保存的宽度）
        table.autosaveName = "GameTable"
        table.autosaveTableColumns = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 1)

        addRemove.segmentStyle = .smallSquare
        addRemove.trackingMode = .momentary
        addRemove.segmentCount = 2
        addRemove.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        addRemove.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        addRemove.setToolTip(String(localized: "添加游戏文件…"), forSegment: 0)
        addRemove.setToolTip(String(localized: "移除选中的文件"), forSegment: 1)
        for i in 0..<2 { addRemove.setWidth(26, forSegment: i) }
        addRemove.target = self
        addRemove.action = #selector(addRemoveClicked(_:))
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearFinished(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [addRemove, spacer, clearButton])
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 12)
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator

        let separator = NSBox()
        separator.boxType = .separator

        for v in [header, separator, scroll, emptyLabel, footerSeparator, footer] as [NSView] {
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
            footerSeparator.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: footerSeparator.bottomAnchor),
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
        statusDetail.toolTip = statusDetail.stringValue   // 截断时悬停能看到全文
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusIcon.contentTintColor = tint
        retryButton.isHidden = { if case .failed = installer.connection { return false } else { return true } }()

        let selected = Set(table.selectedRowIndexes.compactMap { installer.items.indices.contains($0) ? installer.items[$0].id : nil })
        table.reloadData()
        let rows = IndexSet(installer.items.enumerated().filter { selected.contains($0.element.id) }.map(\.offset))
        table.selectRowIndexes(rows, byExtendingSelection: false)
        emptyLabel.isHidden = !installer.items.isEmpty
        updateButtons()
        updateSpeedTimer()
    }

    private func updateSpeedTimer() {
        if installer.isSending, speedTimer == nil {
            speedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadSpeedColumn() }
            }
        } else if !installer.isSending {
            speedTimer?.invalidate()
            speedTimer = nil
        }
    }

    private func reloadSpeedColumn() {
        let column = table.column(withIdentifier: .init("speed"))
        guard column >= 0, table.numberOfRows > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: column))
    }

    private func updateButtons() {
        addRemove.setEnabled(selectedItems.contains { $0.state != .sending }, forSegment: 1)
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

    @objc private func addRemoveClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { addFiles(sender) } else { removeSelected(sender) }
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
            let cell = tableView.makeView(withIdentifier: .init("size"), owner: nil) as? TextCell ?? TextCell(identifier: "size")
            cell.label.stringValue = Self.bytes(item.size)
            return cell
        case "progress":
            let cell = tableView.makeView(withIdentifier: .init("progress"), owner: nil) as? ProgressCell ?? ProgressCell()
            cell.identifier = .init("progress")
            cell.configure(item)
            return cell
        default:
            let cell = tableView.makeView(withIdentifier: .init("speed"), owner: nil) as? TextCell ?? TextCell(identifier: "speed")
            cell.label.stringValue = item.bytesPerSecond().map { "\(Self.bytes(UInt64($0)))/s" } ?? ""
            return cell
        }
    }

    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
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

/// 右对齐的等宽数字（大小、速度）
private final class TextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(identifier: String) {
        super.init(frame: .zero)
        self.identifier = .init(identifier)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.lineBreakMode = .byClipping
        textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 发送中只显示进度条（百分比在悬停提示里）；其他状态显示一个短词
private final class ProgressCell: NSTableCellView {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        label.lineBreakMode = .byTruncatingTail
        for v in [bar, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: Installer.Item) {
        let fraction = item.size > 0 ? min(Double(item.covered) / Double(item.size), 1) : 0
        bar.isHidden = item.state != .sending
        label.isHidden = item.state == .sending
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        bar.doubleValue = fraction
        toolTip = item.state == .sending ? percent : nil
        switch item.state {
        case .ready:
            label.stringValue = String(localized: "等待选择")
            label.textColor = .secondaryLabelColor
        case .sending:
            break
        case .sent:
            label.stringValue = String(localized: "已传完")
            label.textColor = .systemGreen
        case .interrupted:
            label.stringValue = String(localized: "已中断（\(percent)）")
            label.textColor = .systemOrange
        }
    }
}

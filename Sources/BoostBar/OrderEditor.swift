import AppKit

/// Settings ▸ General ▸ Menu Bar Layout: a list of BoostBar's pieces, top = leftmost in the
/// menu bar. Drag rows, or select one and use the arrow buttons.
final class OrderEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var order: () -> [StatusGraphView.Segment]
    var isShown: (StatusGraphView.Segment) -> Bool
    var onChange: ([StatusGraphView.Segment]) -> Void

    private let table = NSTableView()
    private let upButton = NSButton()
    private let downButton = NSButton()
    private var items: [StatusGraphView.Segment] = []
    private static let rowType = NSPasteboard.PasteboardType("com.macsboost.boostbar.segment")

    init(order: @escaping () -> [StatusGraphView.Segment], isShown: @escaping (StatusGraphView.Segment) -> Bool,
         onChange: @escaping ([StatusGraphView.Segment]) -> Void) {
        self.order = order
        self.isShown = isShown
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 132))

        let col = NSTableColumn(identifier: .init("seg"))
        col.width = 300
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.rowType])
        table.draggingDestinationFeedbackStyle = .gap
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 132))
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.borderType = .bezelBorder
        addSubview(scroll)

        for (b, sym, tip, sel) in [(upButton, "arrow.left", "Move left (up the list)", #selector(moveItemLeft)),
                                   (downButton, "arrow.right", "Move right (down the list)", #selector(moveItemRight))] {
            b.bezelStyle = .rounded
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
            b.title = sym == "arrow.left" ? " Left" : " Right"
            b.imagePosition = .imageLeading
            b.toolTip = tip
            b.target = self
            b.action = sel
            addSubview(b)
        }
        upButton.frame = NSRect(x: 332, y: 100, width: 90, height: 28)
        downButton.frame = NSRect(x: 332, y: 68, width: 90, height: 28)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        let sel = table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow] : nil
        items = order()
        table.reloadData()
        if let sel, let i = items.firstIndex(of: sel) { table.selectRowIndexes([i], byExtendingSelection: false) }
        updateButtons()
    }

    private func commit(_ new: [StatusGraphView.Segment], select: StatusGraphView.Segment) {
        items = new
        onChange(new)
        table.reloadData()
        if let i = new.firstIndex(of: select) { table.selectRowIndexes([i], byExtendingSelection: false) }
        updateButtons()
    }

    @objc private func moveItemLeft() { move(by: -1) }
    @objc private func moveItemRight() { move(by: 1) }
    private func move(by d: Int) {
        let i = table.selectedRow
        guard i >= 0, i + d >= 0, i + d < items.count else { return }
        var n = items
        n.swapAt(i, i + d)
        commit(n, select: items[i])
    }

    private func updateButtons() {
        let i = table.selectedRow
        upButton.isEnabled = i > 0
        downButton.isEnabled = i >= 0 && i < items.count - 1
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let seg = items[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: Self.symbol(seg), accessibilityDescription: nil) ?? NSImage())
        icon.frame = NSRect(x: 6, y: 4, width: 18, height: 18)
        let shown = isShown(seg)
        let text = NSTextField(labelWithString: "\(row + 1).  \(Self.title(seg))" + (shown ? "" : "   (hidden)"))
        text.textColor = shown ? .labelColor : .secondaryLabelColor
        text.frame = NSRect(x: 30, y: 4, width: 240, height: 18)
        let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to reorder") ?? NSImage())
        grip.contentTintColor = .tertiaryLabelColor
        grip.frame = NSRect(x: 270, y: 4, width: 18, height: 18)
        cell.addSubview(icon); cell.addSubview(text); cell.addSubview(grip)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
              let from = Int(s), from < items.count else { return false }
        var n = items
        let seg = n.remove(at: from)
        n.insert(seg, at: from < row ? row - 1 : row)
        commit(n, select: seg)
        return true
    }

    static func title(_ s: StatusGraphView.Segment) -> String {
        switch s {
        case .eyes: return "Googly eyes"
        case .network: return "Network graph"
        case .battery: return "Battery watts"
        case .disks: return "Disk lights"
        case .cpu: return "CPU meter"
        case .gpu: return "GPU meter"
        }
    }

    static func symbol(_ s: StatusGraphView.Segment) -> String {
        switch s {
        case .eyes: return "eyes"
        case .network: return "chart.xyaxis.line"
        case .battery: return "bolt.fill"
        case .disks: return "internaldrive"
        case .cpu: return "gauge.with.needle"
        case .gpu: return "memorychip"
        }
    }
}

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ResultActions {
    let inspect: () -> Void
    let reveal: () -> Void
    let zip: () -> Void
    let trashAllOriginals: () -> Void
    let undoTrash: () -> Void
    let close: () -> Void
    let revealURL: (URL) -> Void
    let select: (UUID, NSEvent.ModifierFlags) -> Void
    let prepareImageDrag: (UUID, NSEvent.ModifierFlags) -> [ImageDragItem]
    let applyMarqueeSelection: (Set<UUID>) -> Void
    let dragActivity: (Bool) -> Void
    let hoverActivity: (Bool) -> Void
    let menuActivity: (Bool) -> Void
    let removeImageRecord: (UUID) -> Void
    let removeZipRecord: (UUID) -> Void
}

final class LitheResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ResultPanelController {
    let panel: LitheResultPanel
    private let hostingView: NSHostingView<ResultView>
    private var sessionVisibleFrame: NSRect?
    var visibleFrame: NSRect? { resolvedVisibleFrame() }

    init(model: SessionModel, actions: ResultActions) {
        panel = LitheResultPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView = NSHostingView(rootView: ResultView(model: model, actions: actions))
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        resize(itemCount: 1, hasBanner: false)
    }

    func show(itemCount: Int, hasBanner: Bool) {
        _ = resolvedVisibleFrame()
        resize(itemCount: itemCount, hasBanner: hasBanner)
        positionNearCopied()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    func refreshScreenForNewInvocation() {
        sessionVisibleFrame = (
            NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
        )?.visibleFrame
    }

    func resize(itemCount: Int, hasBanner: Bool) {
        let rows = max(1, Int(ceil(Double(max(1, itemCount)) / 3.0)))
        let gridHeight = min(CGFloat(rows) * 126, 344)
        let desiredHeight = 48 + gridHeight + 54 + (hasBanner ? 36 : 0) + 20
        let availableHeight = sessionVisibleFrame.map { visible -> CGFloat in
            let gap: CGFloat = 16
            let copiedWidth: CGFloat = 360
            let copiedReservedHeight: CGFloat = 360
            let copiedLeft = visible.midX - copiedWidth / 2
            let copiedRight = visible.midX + copiedWidth / 2
            let fitsBeside = copiedRight + gap + 360 <= visible.maxX
                || copiedLeft - gap - 360 >= visible.minX
            if fitsBeside { return max(180, visible.height - 24) }
            return max(180, visible.height - copiedReservedHeight - gap - 24)
        } ?? desiredHeight
        let height = min(desiredHeight, availableHeight)
        let oldTop = panel.frame.maxY
        panel.setContentSize(NSSize(width: 360, height: height))
        if oldTop > 0 {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: oldTop - height))
        }
    }

    private func positionNearCopied() {
        guard let visible = resolvedVisibleFrame() else { return }
        let size = panel.frame.size
        let copiedWidth: CGFloat = 360
        let copiedReservedHeight: CGFloat = 360
        let gap: CGFloat = 16
        let topMargin: CGFloat = 12
        let copiedLeft = visible.midX - copiedWidth / 2
        let copiedRight = visible.midX + copiedWidth / 2
        let rightX = copiedRight + gap
        let leftX = copiedLeft - gap - size.width
        let y = visible.maxY - topMargin - size.height
        let origin: NSPoint
        if rightX + size.width <= visible.maxX {
            origin = NSPoint(x: rightX, y: y)
        } else if leftX >= visible.minX {
            origin = NSPoint(x: leftX, y: y)
        } else {
            let belowY = visible.maxY - topMargin - copiedReservedHeight - gap - size.height
            origin = NSPoint(
                x: min(max(visible.midX - size.width / 2, visible.minX), visible.maxX - size.width),
                y: max(visible.minY, belowY)
            )
        }
        panel.setFrameOrigin(NSPoint(
            x: min(max(origin.x, visible.minX), visible.maxX - size.width),
            y: min(max(origin.y, visible.minY), visible.maxY - size.height)
        ))
    }

    private func resolvedVisibleFrame() -> NSRect? {
        if sessionVisibleFrame == nil {
            sessionVisibleFrame = (
                NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                    ?? NSScreen.main
            )?.visibleFrame
        }
        return sessionVisibleFrame
    }
}

struct ResultView: View {
    let model: SessionModel
    let actions: ResultActions
    @State private var cardFrames: [UUID: CGRect] = [:]
    private static let cardCornerRadius: CGFloat = 32

    private var columns: [GridItem] {
        let count = min(3, max(1, model.items.count + model.zipItems.count))
        return Array(repeating: GridItem(.fixed(96), spacing: 8), count: count)
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            ScrollView {
                LazyVGrid(columns: columns, alignment: .center, spacing: 10) {
                    ForEach(model.items) { item in
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            ResultImageCard(
                                item: item,
                                isSelected: model.selectedItemIDs.contains(item.id),
                                onSelect: { actions.select(item.id, $0) },
                                onPrepareDrag: { actions.prepareImageDrag(item.id, $0) },
                                onDragActivity: actions.dragActivity,
                                onRemove: { actions.removeImageRecord(item.id) }
                            )
                            .reportResultCardFrame(id: item.id)
                        }
                    }
                    ForEach(model.zipItems) { zipItem in
                        ZipResultCard(
                            item: zipItem,
                            onDragActivity: actions.dragActivity,
                            onReveal: { actions.revealURL(zipItem.artifact.publishedURL) },
                            onRemove: { actions.removeZipRecord(zipItem.id) }
                        )
                    }
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .center)
                .coordinateSpace(name: ResultGridCoordinateSpace.name)
                .background {
                    ResultMarqueeSelectionSurface(
                        cardFrames: cardFrames,
                        currentSelection: model.selectedItemIDs,
                        onSelectionChanged: actions.applyMarqueeSelection
                    )
                }
                .onPreferenceChange(ResultCardFramePreferenceKey.self) { cardFrames = $0 }
            }
            .scrollIndicators(.automatic)
            if let banner = model.bannerMessage {
                HStack(spacing: 6) {
                    Text(banner)
                        .lineLimit(1)
                        .font(.system(size: 11))
                    if !model.trashRecords.isEmpty {
                        Button("撤销", action: actions.undoTrash)
                            .buttonStyle(.link)
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            toolbar
        }
        .padding(16)
        .frame(width: 360)
        .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
        .resultPanelSurface(cornerRadius: Self.cardCornerRadius)
        .overlay {
            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                .stroke(.primary.opacity(0.15), lineWidth: 0.8)
        }
        .onHover(perform: actions.hoverActivity)
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            actions.menuActivity(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            actions.menuActivity(false)
        }
    }

    private var header: some View {
        HStack {
            Text(model.summaryText)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            iconButton(
                symbol: "xmark",
                help: "关闭",
                action: actions.close
            )
        }
        .frame(height: 28)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Spacer()
            iconButton(
                symbol: "rectangle.split.2x1",
                help: "检查压缩前后",
                prominent: true,
                disabled: model.inspectableItems.isEmpty || model.activities.contains(.processing),
                action: actions.inspect
            )
            iconButton(
                symbol: "folder",
                help: "在 Finder 中显示",
                disabled: model.selectedOrAllPublishedURLs().isEmpty,
                action: actions.reveal
            )
            iconButton(
                symbol: "archivebox",
                help: "打包为 ZIP",
                disabled: model.selectedOrAllEffectiveItems().isEmpty,
                action: actions.zip
            )
            iconButton(
                symbol: "trash",
                help: "将全部成功项的原图移到废纸篓",
                disabled: !model.items.contains(where: { $0.status == .ready && $0.trashedURL == nil }),
                role: .destructive,
                action: actions.trashAllOriginals
            )
            Spacer()
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private func iconButton(
        symbol: String,
        help: String,
        prominent: Bool = false,
        disabled: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(prominent ? Color.accentColor.opacity(0.18) : .primary.opacity(0.06))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

}

private struct ResultImageCard: View {
    let item: SessionItem
    let isSelected: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onPrepareDrag: (NSEvent.ModifierFlags) -> [ImageDragItem]
    let onDragActivity: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                thumbnail
                specialStatus
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : .primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.7)
            }
            .overlay(alignment: .bottomTrailing) {
                reductionBadge
                    .padding(5)
            }
            .overlay {
                ImageCardDragSource(
                    canRemove: item.canRemoveRecord,
                    previewImage: item.thumbnail,
                    onSelect: onSelect,
                    onPrepareDrag: onPrepareDrag,
                    onDragActivity: onDragActivity,
                    onRemove: onRemove
                )
            }

            Text(item.publishedURL?.lastPathComponent ?? item.sourceURL.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 96)
                .help(item.publishedURL?.lastPathComponent ?? item.sourceURL.lastPathComponent)
        }
        .frame(width: 96)
    }

    @ViewBuilder
    private var reductionBadge: some View {
        if let percent = item.reductionPercent,
           item.status == .ready || item.status == .noBenefit {
            let displayedPercent = max(0, percent)
            Text(displayedPercent > 0 ? "−\(displayedPercent)%" : "0%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.78), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.28), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .accessibilityLabel("压缩后减少 \(displayedPercent)%")
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = item.thumbnail {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay { Image(systemName: "photo") }
        }
    }

    @ViewBuilder
    private var specialStatus: some View {
        switch item.status {
        case .snapshotting, .queued, .processing:
            statusPill(symbol: nil, text: "处理中", progress: true)
        case .noBenefit:
            if item.generationFailureMessage != nil {
                statusPill(symbol: "exclamationmark.triangle", text: "生成失败")
            } else {
                statusPill(symbol: "checkmark", text: "无需压缩")
            }
        case .failed:
            statusPill(symbol: "exclamationmark.triangle", text: "失败")
        case .ready:
            if item.generationFailureMessage != nil {
                statusPill(symbol: "exclamationmark.triangle", text: "生成失败")
            } else if item.isRecompressing {
                statusPill(symbol: nil, text: "处理中", progress: true)
            } else if !item.publishedOutputExists {
                statusPill(symbol: "arrow.down.doc", text: "输出已移除")
            } else if item.reviewRecommended {
                statusPill(symbol: "viewfinder", text: "建议检查")
            }
        }
    }

    private func statusPill(symbol: String?, text: String, progress: Bool = false) -> some View {
        HStack(spacing: 4) {
            if progress { ProgressView().controlSize(.small) }
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.black.opacity(0.68), in: Capsule())
    }
}

private enum ResultGridCoordinateSpace {
    static let name = "LitheResultGrid"
}

private struct ResultCardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func reportResultCardFrame(id: UUID) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ResultCardFramePreferenceKey.self,
                    value: [id: proxy.frame(in: .named(ResultGridCoordinateSpace.name))]
                )
            }
        }
    }
}

private struct ResultMarqueeSelectionSurface: NSViewRepresentable {
    let cardFrames: [UUID: CGRect]
    let currentSelection: Set<UUID>
    let onSelectionChanged: (Set<UUID>) -> Void

    func makeNSView(context: Context) -> ResultMarqueeSelectionView {
        ResultMarqueeSelectionView()
    }

    func updateNSView(_ view: ResultMarqueeSelectionView, context: Context) {
        view.cardFrames = cardFrames
        view.currentSelection = currentSelection
        view.onSelectionChanged = onSelectionChanged
    }
}

private final class ResultMarqueeSelectionView: NSView {
    var cardFrames: [UUID: CGRect] = [:]
    var currentSelection: Set<UUID> = []
    var onSelectionChanged: ((Set<UUID>) -> Void)?
    private var startPoint: NSPoint?
    private var selectionRect: NSRect?
    private var baseSelection: Set<UUID> = []
    private var commandAtStart = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = constrained(convert(event.locationInWindow, from: nil))
        startPoint = point
        selectionRect = NSRect(origin: point, size: .zero)
        commandAtStart = event.modifierFlags.contains(.command)
        baseSelection = commandAtStart ? currentSelection : []
        if !commandAtStart { onSelectionChanged?([]) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = constrained(convert(event.locationInWindow, from: nil))
        let rectangle = NSRect(
            x: min(startPoint.x, point.x),
            y: min(startPoint.y, point.y),
            width: abs(point.x - startPoint.x),
            height: abs(point.y - startPoint.y)
        )
        selectionRect = rectangle
        onSelectionChanged?(MarqueeSelectionPolicy.selection(
            cardFrames: cardFrames,
            selectionRect: rectangle,
            baseSelection: baseSelection,
            command: commandAtStart
        ))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        startPoint = nil
        selectionRect = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let selectionRect, selectionRect.width > 0 || selectionRect.height > 0 else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        selectionRect.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    private func constrained(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

private struct ImageCardDragSource: NSViewRepresentable {
    let canRemove: Bool
    let previewImage: NSImage?
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onPrepareDrag: (NSEvent.ModifierFlags) -> [ImageDragItem]
    let onDragActivity: (Bool) -> Void
    let onRemove: () -> Void

    func makeNSView(context: Context) -> ImageCardDragSourceView {
        ImageCardDragSourceView()
    }

    func updateNSView(_ view: ImageCardDragSourceView, context: Context) {
        view.canRemove = canRemove
        view.previewImage = previewImage
        view.onSelect = onSelect
        view.onPrepareDrag = onPrepareDrag
        view.onDragActivity = onDragActivity
        view.onRemove = onRemove
    }
}

private final class ImageCardDragSourceView: NSView, NSDraggingSource {
    var canRemove = false
    var previewImage: NSImage?
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var onPrepareDrag: ((NSEvent.ModifierFlags) -> [ImageDragItem])?
    var onDragActivity: ((Bool) -> Void)?
    var onRemove: (() -> Void)?
    private var mouseDownPoint: NSPoint?
    private var mouseDownModifiers: NSEvent.ModifierFlags = []
    private var didBeginDrag = false
    private var activeOperation: ImageFileDragOperation?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownModifiers = event.modifierFlags
        didBeginDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeOperation == nil || activeOperation?.isFinished == true,
              !didBeginDrag,
              let mouseDownPoint,
              hypot(
                convert(event.locationInWindow, from: nil).x - mouseDownPoint.x,
                convert(event.locationInWindow, from: nil).y - mouseDownPoint.y
              ) >= 3,
              let entries = onPrepareDrag?(mouseDownModifiers),
              !entries.isEmpty else {
            return
        }
        didBeginDrag = true
        beginDrag(entries: entries, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !didBeginDrag { onSelect?(mouseDownModifiers) }
        mouseDownPoint = nil
        didBeginDrag = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard canRemove else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "从结果中移除",
            action: #selector(removeRecord),
            keyEquivalent: ""
        )
        item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func removeRecord() {
        onRemove?()
    }

    private func beginDrag(entries: [ImageDragItem], event: NSEvent) {
        let preparedEntries = entries.map { entry in
            let persistentURL = entry.persistentURL.flatMap { url in
                FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            return (entry: entry, persistentURL: persistentURL)
        }
        let promisedCount = preparedEntries.reduce(into: 0) { count, prepared in
            if prepared.persistentURL == nil { count += 1 }
        }
        let operation = ImageFileDragOperation(
            promisedCount: promisedCount,
            onActivityChanged: onDragActivity ?? { _ in }
        )
        activeOperation = operation
        operation.begin()

        var draggingItems: [NSDraggingItem] = []
        for (index, prepared) in preparedEntries.enumerated() {
            let entry = prepared.entry
            let writer: NSPasteboardWriting
            if let persistentURL = prepared.persistentURL {
                writer = persistentURL as NSURL
            } else {
                let delegate = ImageFilePromiseDelegate(
                    sourceURL: entry.fallbackURL,
                    displayName: entry.displayName,
                    onCompletion: { [weak operation] id in
                        operation?.promiseCompleted(id: id)
                    }
                )
                operation.retain(delegate)
                let type = UTType(
                    filenameExtension: URL(fileURLWithPath: entry.displayName).pathExtension
                ) ?? .data
                writer = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let offset = CGFloat(min(index, 4)) * 3
            draggingItem.setDraggingFrame(
                bounds.offsetBy(dx: offset, dy: -offset),
                contents: previewImage ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            )
            draggingItems.append(draggingItem)
        }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        activeOperation?.sessionEnded(accepted: !operation.isEmpty)
        if activeOperation?.isFinished == true { activeOperation = nil }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

@MainActor
private final class ImageFileDragOperation {
    private let onActivityChanged: (Bool) -> Void
    private var retainedDelegates: [UUID: ImageFilePromiseDelegate] = [:]
    private var promisesRemaining: Int
    private var sessionHasEnded = false
    private var accepted = false
    private var timeout: Timer?
    private(set) var isFinished = false

    init(promisedCount: Int, onActivityChanged: @escaping (Bool) -> Void) {
        promisesRemaining = promisedCount
        self.onActivityChanged = onActivityChanged
    }

    func begin() {
        onActivityChanged(true)
        timeout = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    func retain(_ delegate: ImageFilePromiseDelegate) {
        retainedDelegates[delegate.id] = delegate
    }

    nonisolated func promiseCompleted(id: UUID) {
        Task { @MainActor in
            guard !self.isFinished else { return }
            self.retainedDelegates.removeValue(forKey: id)
            self.promisesRemaining = max(0, self.promisesRemaining - 1)
            self.finishIfReady()
        }
    }

    func sessionEnded(accepted: Bool) {
        sessionHasEnded = true
        self.accepted = accepted
        if !accepted {
            promisesRemaining = 0
            retainedDelegates.removeAll()
        }
        finishIfReady()
    }

    private func finishIfReady() {
        guard sessionHasEnded, !accepted || promisesRemaining == 0 else { return }
        finish()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        timeout?.invalidate()
        timeout = nil
        retainedDelegates.removeAll()
        onActivityChanged(false)
    }
}

extension View {
    /// Mirrors Copied's card surface: native Liquid Glass on macOS 26+, material otherwise.
    @ViewBuilder
    fileprivate func resultPanelSurface(cornerRadius: CGFloat) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
#else
        self.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        }
#endif
    }
}

private struct ZipResultCard: View {
    let item: SessionZipItem
    let onDragActivity: (Bool) -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                .onTapGesture(count: 2, perform: onReveal)
                .contextMenu {
                    Button("在 Finder 中显示", systemImage: "folder", action: onReveal)
                    Divider()
                    Button("从结果中移除", systemImage: "xmark.circle", action: onRemove)
                }
                .onDrag {
                    DragActivityMonitor.shared.begin(onActivityChanged: onDragActivity)
                    return FileDragProvider.make(
                        persistentURL: FileManager.default.fileExists(
                            atPath: item.artifact.publishedURL.path
                        ) ? item.artifact.publishedURL : nil,
                        fallbackURL: item.artifact.sessionURL
                    ) ?? NSItemProvider()
                }
            Text(item.artifact.publishedURL.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 96)
        }
        .frame(width: 96)
    }
}

private enum FileDragProvider {
    static func make(persistentURL: URL?, fallbackURL: URL) -> NSItemProvider? {
        if let persistentURL,
           FileManager.default.fileExists(atPath: persistentURL.path) {
            return NSItemProvider(contentsOf: persistentURL)
        }
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return nil }

        let provider = NSItemProvider()
        provider.suggestedName = fallbackURL.lastPathComponent
        let type = UTType(filenameExtension: fallbackURL.pathExtension) ?? .data
        // With no .openInPlace option, Foundation copies this representation
        // before handing it to the receiver. Session cleanup therefore cannot
        // invalidate a large Finder drop that is still being materialized.
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(fallbackURL, false, nil)
            return nil
        }
        return provider
    }
}

@MainActor
private final class DragActivityMonitor {
    static let shared = DragActivityMonitor()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var fallback: Timer?
    private var callback: ((Bool) -> Void)?

    func begin(onActivityChanged: @escaping (Bool) -> Void) {
        finish()
        callback = onActivityChanged
        onActivityChanged(true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.finish()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
        fallback = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    private func finish() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        fallback?.invalidate()
        fallback = nil
        callback?(false)
        callback = nil
    }
}

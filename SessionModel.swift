import AppKit
import Foundation
import Observation

enum LitheDefaults {
    static let autoCopyResults = "autoCopyResults"
    static let autoTrashOriginals = "autoTrashOriginals"
    static let autoTrashConfirmationSeen = "autoTrashConfirmationSeen"
    static let autoCloseInterval = "autoCloseInterval"
    static let fixedOutputDirectory = "fixedOutputDirectory"

    static func register() {
        UserDefaults.standard.register(defaults: [
            autoCopyResults: true,
            autoTrashOriginals: false,
            autoCloseInterval: 10.0,
        ])
    }
}

enum SessionActivity: Hashable {
    case processing
    case recompressing
    case zipping
    case dragging
    case inspector
    case systemPanel
    case menu
    case trashing
    case undoing
    case hovering
}

enum SelectionPolicy {
    static func updatedSelection(
        current: Set<UUID>,
        clickedID: UUID,
        orderedIDs: [UUID],
        anchorID: UUID?,
        command: Bool,
        shift: Bool
    ) -> (selection: Set<UUID>, anchor: UUID?) {
        if shift,
           let anchorID,
           let anchorIndex = orderedIDs.firstIndex(of: anchorID),
           let clickedIndex = orderedIDs.firstIndex(of: clickedID) {
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            return (Set(range.map { orderedIDs[$0] }), anchorID)
        }
        if command {
            var result = current
            if result.contains(clickedID) {
                result.remove(clickedID)
            } else {
                result.insert(clickedID)
            }
            return (result, clickedID)
        }
        return ([clickedID], clickedID)
    }
}

struct ImageDragItem: Equatable {
    let itemID: UUID
    let persistentURL: URL?
    let fallbackURL: URL
    let displayName: String
}

enum MarqueeSelectionPolicy {
    static func selection(
        cardFrames: [UUID: CGRect],
        selectionRect: CGRect,
        baseSelection: Set<UUID>,
        command: Bool
    ) -> Set<UUID> {
        let rectangle = selectionRect.standardized
        let intersecting = Set(cardFrames.compactMap { id, frame in
            rectangle.intersects(frame.standardized) ? id : nil
        })
        return command ? baseSelection.union(intersecting) : intersecting
    }
}

final class ImageFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let id = UUID()
    private let sourceURL: URL
    private let displayName: String
    private let onCompletion: (UUID) -> Void
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(
        sourceURL: URL,
        displayName: String,
        onCompletion: @escaping (UUID) -> Void
    ) {
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.onCompletion = onCompletion
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        displayName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let result: Error?
        do {
            try FileManager.default.copyItem(at: sourceURL, to: url)
            result = nil
        } catch {
            result = error
        }
        completionHandler(result)
        onCompletion(id)
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}

@Observable
@MainActor
final class SessionItem: Identifiable {
    let id: UUID
    let requestID: UUID
    var sourceURL: URL
    let automaticTrashEnabled: Bool
    var status: SessionItemStatus = .snapshotting
    var generation = 0
    var snapshotURL: URL?
    var inputFormat: LitheImageFormat?
    var hasTransparency = false
    var originalByteCount: Int64 = 0
    var pngCandidate: CompressionCandidate?
    var jpegCandidate: CompressionCandidate?
    var selectedFormat: LitheImageFormat?
    var publishedURL: URL?
    var publishedFingerprint: PublishedFingerprint?
    var reviewRecommended = false
    var preservedOldOutput = false
    var isRecompressing = false
    var generationFailureMessage: String?
    var trashedURL: URL?
    var thumbnail: NSImage?

    init(
        id: UUID = UUID(),
        requestID: UUID,
        sourceURL: URL,
        automaticTrashEnabled: Bool
    ) {
        self.id = id
        self.requestID = requestID
        self.sourceURL = sourceURL
        self.automaticTrashEnabled = automaticTrashEnabled
        thumbnail = NSImage(contentsOf: sourceURL)
    }

    var selectedCandidate: CompressionCandidate? {
        switch selectedFormat {
        case .png: pngCandidate
        case .jpeg: jpegCandidate
        case nil: nil
        }
    }

    var effectiveResultURL: URL? {
        switch status {
        case .ready:
            selectedCandidate?.url
        case .noBenefit:
            snapshotURL
        default:
            nil
        }
    }

    var resultByteCount: Int64? {
        switch status {
        case .ready: selectedCandidate?.byteCount
        case .noBenefit: originalByteCount
        default: nil
        }
    }

    var reductionPercent: Int? {
        guard originalByteCount > 0, let resultByteCount else { return nil }
        return Int(((Double(originalByteCount - resultByteCount) / Double(originalByteCount)) * 100).rounded())
    }

    var publishedOutputExists: Bool {
        guard let publishedURL else { return false }
        return FileManager.default.fileExists(atPath: publishedURL.path)
    }

    var canInspect: Bool {
        snapshotURL != nil && (pngCandidate != nil || jpegCandidate != nil)
    }

    var canRemoveRecord: Bool {
        switch status {
        case .ready, .noBenefit, .failed: true
        case .snapshotting, .queued, .processing: false
        }
    }

    func beginGeneration() -> Int {
        generation += 1
        return generation
    }

    @discardableResult
    func applyIfCurrent(generation expected: Int, _ update: () -> Void) -> Bool {
        guard generation == expected else { return false }
        update()
        return true
    }
}

@Observable
@MainActor
final class SessionZipItem: Identifiable {
    nonisolated let id: UUID
    let artifact: ZipArtifact
    init(artifact: ZipArtifact) {
        id = artifact.id
        self.artifact = artifact
    }
}

@Observable
@MainActor
final class SessionModel {
    var items: [SessionItem] = []
    var zipItems: [SessionZipItem] = []
    var selectedItemIDs: Set<UUID> = []
    var selectionAnchorID: UUID?
    var trashRecords: [TrashRecord] = []
    var activities: Set<SessionActivity> = []
    var bannerMessage: String?
    var inspectorItemID: UUID?
    var isClosing = false

    var activeImageItems: [SessionItem] { items }

    var summaryText: String {
        let count = items.count
        let failed = items.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        let original = items.reduce(Int64(0)) { $0 + $1.originalByteCount }
        let result = items.reduce(Int64(0)) { $0 + ($1.resultByteCount ?? $1.originalByteCount) }
        let percent = original > 0
            ? max(0, Int((Double(original - result) / Double(original) * 100).rounded()))
            : 0
        var text = "\(count) 张图片 · 共减少 \(percent)%"
        if failed > 0 { text += " · \(failed) 个失败" }
        return text
    }

    var isBusy: Bool {
        !activities.isDisjoint(with: [
            .processing, .recompressing, .zipping, .trashing, .undoing, .dragging,
        ])
    }

    var shouldPauseAutoClose: Bool { !activities.isEmpty }

    var allowsResultPanelPresentation: Bool {
        !isClosing && !activities.contains(.inspector)
    }

    var inspectableItems: [SessionItem] { items.filter(\.canInspect) }

    func append(_ newItems: [SessionItem]) {
        items.append(contentsOf: newItems)
    }

    func removeImageRecord(id: UUID) {
        items.removeAll { $0.id == id && $0.canRemoveRecord }
        selectedItemIDs.remove(id)
        if selectionAnchorID == id { selectionAnchorID = nil }
        if inspectorItemID == id { inspectorItemID = nil }
    }

    func removeZipRecord(id: UUID) {
        zipItems.removeAll { $0.id == id }
    }

    func item(id: UUID) -> SessionItem? { items.first { $0.id == id } }

    func select(id: UUID, modifiers: NSEvent.ModifierFlags) {
        let result = SelectionPolicy.updatedSelection(
            current: selectedItemIDs,
            clickedID: id,
            orderedIDs: items.map(\.id),
            anchorID: selectionAnchorID,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift)
        )
        selectedItemIDs = result.selection
        selectionAnchorID = result.anchor
    }

    func prepareImageDrag(id: UUID, modifiers: NSEvent.ModifierFlags) -> [ImageDragItem] {
        if !selectedItemIDs.contains(id) {
            select(id: id, modifiers: modifiers)
        }
        return items.compactMap { item in
            guard selectedItemIDs.contains(item.id),
                  let fallbackURL = item.effectiveResultURL,
                  FileManager.default.fileExists(atPath: fallbackURL.path) else {
                return nil
            }
            let persistentURL: URL?
            switch item.status {
            case .ready:
                persistentURL = item.publishedOutputExists ? item.publishedURL : nil
            case .noBenefit:
                persistentURL = FileManager.default.fileExists(atPath: item.sourceURL.path)
                    ? item.sourceURL : nil
            default:
                persistentURL = nil
            }
            return ImageDragItem(
                itemID: item.id,
                persistentURL: persistentURL,
                fallbackURL: fallbackURL,
                displayName: item.publishedURL?.lastPathComponent
                    ?? item.sourceURL.lastPathComponent
            )
        }
    }

    func applyMarqueeSelection(_ selection: Set<UUID>) {
        selectedItemIDs = selection
        selectionAnchorID = items.last(where: { selection.contains($0.id) })?.id
    }

    func selectedOrAllEffectiveItems() -> [SessionItem] {
        let selected = items.filter { selectedItemIDs.contains($0.id) && $0.effectiveResultURL != nil }
        return selectedItemIDs.isEmpty ? items.filter { $0.effectiveResultURL != nil } : selected
    }

    func selectedOrAllPublishedURLs() -> [URL] {
        let selected = items.compactMap { item -> URL? in
            guard selectedItemIDs.contains(item.id), item.publishedOutputExists else { return nil }
            return item.publishedURL
        }
        if !selectedItemIDs.isEmpty { return selected }
        return items.compactMap { $0.publishedOutputExists ? $0.publishedURL : nil }
    }
}

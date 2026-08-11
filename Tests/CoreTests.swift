import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func expectThrows(_ message: String, _ operation: () throws -> Void) {
    do {
        try operation()
        expect(false, message)
    } catch { }
}

private final class CapturedError: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    func store(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func load() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

@main
struct CoreTests {
    @MainActor
    static func main() throws {
        compressionSelectionIsConservative()
        advancedQualityMappingAndPoliciesAreExact()
        outputNamingNeverOverwrites()
        selectionAndGenerationAreDeterministic()
        try resultDragPlanAndMarqueeSelectionAreDeterministic()
        resultPercentageUsesSelectedCandidateBytes()
        inspectorBackgroundChoicesAreUnified()
        inspectorViewportClampsOverscroll()
        try inspectorViewportUsesOneCanonicalCenter()
        try inspectorJPEGKeepsTwoCanvasColumnsAfterNavigation()
        try sessionModelRecordRemovalPreservesFiles()
        batchClipboardAndCommitGateAreSafe()
        try fileLifecyclePreservesChangedOutputs()
        try abandonedSessionCleanupRequiresLitheManifest()
        try pasteboardContractUsesSharedTypes()
        try imagePipelineProducesValidatedCandidates()
        try imageDecoderDistinguishesAlphaChannelFromTransparency()
        qualityMetricDetectsColorAndAlphaChanges()
        try imageDecoderNormalizesEXIFOrientation()
        try imagePipelineRejectsCorruptionAndPreservesJPEGRenderingMetadata()
        try jpegInputUsesLosslessJPEGTranBackend()
        try failingOptionalPNGToolFallsBack()
        try compressionCancellationStopsFallbackPipeline()
        try toolRunnerDrainsLargeOutput()
        try toolRunnerCancellationReapsChild()
        toolRunnerTimesOutAndReaps()
        try zipServiceCreatesArchive()
        print("CoreTests: PASS")
    }

    private static func compressionSelectionIsConservative() {
        let original: Int64 = 2_000_000
        expect(
            CompressionPolicy.choose(
                inputFormat: .png,
                hasTransparency: true,
                originalBytes: original,
                preset: .balanced,
                png: CandidateFacts(format: .png, byteCount: 1_000_000, ssim: 1),
                jpeg: CandidateFacts(format: .jpeg, byteCount: 100_000, ssim: 1)
            ) == .candidate(format: .png, reviewRecommended: false),
            "transparent PNG never selects JPEG"
        )
        expect(
            CompressionPolicy.choose(
                inputFormat: .png,
                hasTransparency: false,
                originalBytes: original,
                preset: .balanced,
                png: CandidateFacts(format: .png, byteCount: 1_000_000, ssim: 1),
                jpeg: CandidateFacts(format: .jpeg, byteCount: 700_000, ssim: 0.96)
            ) == .candidate(format: .jpeg, reviewRecommended: false),
            "high-quality JPEG wins only with at least twenty percent additional saving"
        )
        expect(
            CompressionPolicy.choose(
                inputFormat: .png,
                hasTransparency: false,
                originalBytes: original,
                preset: .balanced,
                png: CandidateFacts(format: .png, byteCount: 1_950_000, ssim: 1),
                jpeg: CandidateFacts(format: .jpeg, byteCount: 1_000_000, ssim: 0.96)
            ) == .candidate(format: .jpeg, reviewRecommended: false),
            "a quality-valid PNG baseline may prove JPEG dominance without meeting the PNG savings threshold"
        )
        expect(
            CompressionPolicy.choose(
                inputFormat: .png,
                hasTransparency: false,
                originalBytes: original,
                preset: .balanced,
                png: CandidateFacts(format: .png, byteCount: 1_000_000, ssim: 1),
                jpeg: CandidateFacts(format: .jpeg, byteCount: 880_000, ssim: 0.92)
            ) == .candidate(format: .png, reviewRecommended: true),
            "ambiguous JPEG keeps PNG and recommends review"
        )
        expect(
            CompressionPolicy.choose(
                inputFormat: .png,
                hasTransparency: false,
                originalBytes: original,
                preset: .balanced,
                png: nil,
                jpeg: CandidateFacts(format: .jpeg, byteCount: 500_000, ssim: 0.94)
            ) == .noBenefit,
            "a missing conservative PNG candidate blocks automatic JPEG publication"
        )
        expect(
            !CompressionPolicy.hasEffectiveSaving(originalBytes: 100_000, resultBytes: 95_000),
            "small absolute savings are ignored"
        )
    }

    @MainActor
    private static func advancedQualityMappingAndPoliciesAreExact() {
        let expected = [
            QualityEncodingParameters(jpegQualityPercent: 68, pngQualityRange: 55 ... 70, referenceSSIM: 0.78),
            QualityEncodingParameters(jpegQualityPercent: 76, pngQualityRange: 65 ... 78, referenceSSIM: 0.80),
            QualityEncodingParameters(jpegQualityPercent: 80, pngQualityRange: 72 ... 84, referenceSSIM: 0.83),
            QualityEncodingParameters(jpegQualityPercent: 84, pngQualityRange: 80 ... 90, referenceSSIM: 0.85),
            QualityEncodingParameters(jpegQualityPercent: 87, pngQualityRange: 80 ... 92, referenceSSIM: 0.88),
            QualityEncodingParameters(jpegQualityPercent: 90, pngQualityRange: 80 ... 95, referenceSSIM: 0.90),
            QualityEncodingParameters(jpegQualityPercent: 92, pngQualityRange: 85 ... 97, referenceSSIM: 0.93),
            QualityEncodingParameters(jpegQualityPercent: 94, pngQualityRange: 90 ... 100, referenceSSIM: 0.95),
            QualityEncodingParameters(jpegQualityPercent: 95, pngQualityRange: 93 ... 100, referenceSSIM: 0.97),
            QualityEncodingParameters(jpegQualityPercent: 96, pngQualityRange: 96 ... 100, referenceSSIM: 0.98),
        ]
        expect(
            QualityLevel.allCases.map(\.parameters) == expected,
            "all ten advanced levels use the exact production encoding map"
        )
        expect(
            QualityPreset.smaller.qualityLevel == .four
                && QualityPreset.balanced.qualityLevel == .six
                && QualityPreset.clearer.qualityLevel == .eight,
            "the three quick presets anchor levels four, six, and eight"
        )
        expect(
            CompressionQuality.default == .preset(.balanced)
                && CompressionQuality.default.level == .six,
            "initial compression defaults to balanced level six"
        )
        expect(
            CompressionQuality.advanced(.three).displayName == "高级 · 3/10",
            "a custom level keeps its advanced identity when the control collapses"
        )

        let item = SessionItem(
            requestID: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/quality.png"),
            automaticTrashEnabled: false
        )
        item.pngCandidate = CompressionCandidate(
            format: .png,
            url: URL(fileURLWithPath: "/tmp/quality-png.png"),
            byteCount: 80_000,
            ssim: 0.79,
            quality: .advanced(.two)
        )
        item.jpegCandidate = CompressionCandidate(
            format: .jpeg,
            url: URL(fileURLWithPath: "/tmp/quality-jpeg.jpg"),
            byteCount: 60_000,
            ssim: 0.96,
            quality: .advanced(.nine)
        )
        item.selectedFormat = .png
        expect(item.selectedCandidate?.quality == .advanced(.two), "PNG retains its own custom level")
        item.selectedFormat = .jpeg
        expect(item.selectedCandidate?.quality == .advanced(.nine), "JPEG retains its own custom level")

        expect(
            !AdvancedQualityInteractionPolicy.shouldSubmit(
                level: .one,
                isEditing: true,
                currentQuality: .advanced(.ten)
            ),
            "moving the advanced slider does not submit while editing"
        )
        expect(
            AdvancedQualityInteractionPolicy.shouldSubmit(
                level: .one,
                isEditing: false,
                currentQuality: .advanced(.ten)
            ),
            "a settled discrete level submits once"
        )
        expect(
            !AdvancedQualityInteractionPolicy.shouldSubmit(
                level: .one,
                isEditing: false,
                currentQuality: .advanced(.one)
            ),
            "the current advanced level does not trigger duplicate recompression"
        )
        expect(
            !AdvancedQualityInteractionPolicy.shouldScheduleSettledChange(
                level: .four,
                isEditing: false,
                displayedQuality: .preset(.smaller)
            ),
            "programmatic synchronization to another candidate does not schedule recompression"
        )
        expect(
            AdvancedQualityInteractionPolicy.shouldScheduleSettledChange(
                level: .five,
                isEditing: false,
                displayedQuality: .preset(.smaller)
            ),
            "a settled keyboard or step change schedules the newly selected level"
        )

        expect(
            ExplicitRecompressionPolicy.accepts(originalBytes: 100_000, resultBytes: 99_999),
            "explicit Inspector recompression accepts any non-empty result smaller than the original"
        )
        expect(
            !CompressionPolicy.hasEffectiveSaving(originalBytes: 100_000, resultBytes: 99_999),
            "automatic compression keeps the original savings floor"
        )
        expect(
            CompressionPolicy.choose(
                inputFormat: .jpeg,
                hasTransparency: false,
                originalBytes: 100_000,
                preset: .balanced,
                png: nil,
                jpeg: CandidateFacts(format: .jpeg, byteCount: 99_999, ssim: 1)
            ) == .noBenefit,
            "automatic selection does not inherit the relaxed explicit-recompression rule"
        )
    }

    private static func outputNamingNeverOverwrites() {
        let source = URL(fileURLWithPath: "/tmp/photo.png")
        let directory = URL(fileURLWithPath: "/tmp")
        let first = OutputNaming.compressedURL(
            sourceURL: source,
            format: .jpeg,
            destinationDirectory: directory,
            fileExists: { _ in false }
        )
        expect(first.lastPathComponent == "photo-Lithed.jpg", "output uses the Lithed suffix")

        let existing: Set<String> = ["photo-Lithed.jpg", "photo-Lithed-2.jpg"]
        let result = OutputNaming.compressedURL(
            sourceURL: source,
            format: .jpeg,
            destinationDirectory: directory,
            fileExists: { existing.contains($0.lastPathComponent) }
        )
        expect(result.lastPathComponent == "photo-Lithed-3.jpg", "output suffix increments safely")

        var used = Set(["same.png"])
        expect(
            OutputNaming.uniqueName("same.png", usedNames: &used) == "same-2.png",
            "ZIP duplicate names retain the extension"
        )
    }

    @MainActor
    private static func selectionAndGenerationAreDeterministic() {
        let ids = [UUID(), UUID(), UUID()]
        let first = SelectionPolicy.updatedSelection(
            current: [],
            clickedID: ids[0],
            orderedIDs: ids,
            anchorID: nil,
            command: false,
            shift: false
        )
        let third = SelectionPolicy.updatedSelection(
            current: first.selection,
            clickedID: ids[2],
            orderedIDs: ids,
            anchorID: first.anchor,
            command: false,
            shift: true
        )
        expect(third.selection == Set(ids), "shift selection fills the ordered range")

        let item = SessionItem(
            requestID: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/a.png"),
            automaticTrashEnabled: false
        )
        let old = item.beginGeneration()
        _ = item.beginGeneration()
        var applied = false
        expect(!item.applyIfCurrent(generation: old) { applied = true }, "stale generations are rejected")
        expect(!applied, "stale updates cannot mutate session state")
    }

    @MainActor
    private static func resultDragPlanAndMarqueeSelectionAreDeterministic() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheResultDrag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        let firstSource = base.appendingPathComponent("First.png")
        let secondSource = base.appendingPathComponent("Second.png")
        let thirdSource = base.appendingPathComponent("Third.png")
        let firstFallback = base.appendingPathComponent("candidate-1-lossy.jpg")
        let secondFallback = base.appendingPathComponent("candidate-2-lossy.jpg")
        let thirdSnapshot = base.appendingPathComponent("source.png")
        let firstPublished = base.appendingPathComponent("First-Lithed.jpg")
        let missingPublished = base.appendingPathComponent("Second-Lithed.jpg")
        for url in [
            firstSource, secondSource, thirdSource, firstFallback, secondFallback,
            thirdSnapshot, firstPublished,
        ] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }

        func readyItem(source: URL, fallback: URL, published: URL) -> SessionItem {
            let item = SessionItem(
                requestID: UUID(),
                sourceURL: source,
                automaticTrashEnabled: false
            )
            item.jpegCandidate = CompressionCandidate(
                format: .jpeg,
                url: fallback,
                byteCount: 10,
                ssim: 1,
                preset: .balanced
            )
            item.selectedFormat = .jpeg
            item.publishedURL = published
            item.status = .ready
            return item
        }

        let first = readyItem(
            source: firstSource,
            fallback: firstFallback,
            published: firstPublished
        )
        let second = readyItem(
            source: secondSource,
            fallback: secondFallback,
            published: missingPublished
        )
        let third = SessionItem(
            requestID: UUID(),
            sourceURL: thirdSource,
            automaticTrashEnabled: false
        )
        third.snapshotURL = thirdSnapshot
        third.status = .noBenefit

        let model = SessionModel()
        model.append([first, second, third])
        model.selectedItemIDs = [first.id, second.id]
        let selectedDrag = model.prepareImageDrag(id: first.id, modifiers: [])
        expect(
            selectedDrag.map(\.itemID) == [first.id, second.id],
            "dragging a selected card emits every valid selected image in model order"
        )
        expect(
            selectedDrag[0].persistentURL == firstPublished,
            "an existing published result is dragged as its real file URL"
        )
        expect(
            selectedDrag[1].persistentURL == nil
                && selectedDrag[1].fallbackURL == secondFallback
                && selectedDrag[1].displayName == "Second-Lithed.jpg",
            "a removed published result promises the session file under its published name"
        )
        expect(
            selectedDrag[1].displayName != secondFallback.lastPathComponent,
            "a file promise never exposes an internal candidate name"
        )
        expect(
            selectedDrag[1].displayName == missingPublished.lastPathComponent,
            "a file promise preserves the exact published display name for Finder conflict handling"
        )

        let singleDrag = model.prepareImageDrag(id: third.id, modifiers: [])
        expect(
            model.selectedItemIDs == [third.id] && singleDrag.map(\.itemID) == [third.id],
            "dragging an unselected card without modifiers selects and drags only that card"
        )
        expect(
            singleDrag[0].persistentURL == thirdSource
                && singleDrag[0].displayName == "Third.png",
            "a no-benefit item uses the existing original URL and filename"
        )

        model.selectedItemIDs = [first.id]
        let commandDrag = model.prepareImageDrag(id: second.id, modifiers: [.command])
        expect(
            commandDrag.map(\.itemID) == [first.id, second.id],
            "command-dragging an unselected card merges it before creating the drag plan"
        )

        let frames = [
            first.id: CGRect(x: 0, y: 0, width: 96, height: 112),
            second.id: CGRect(x: 104, y: 0, width: 96, height: 112),
            third.id: CGRect(x: 0, y: 122, width: 96, height: 112),
        ]
        let rectangle = CGRect(x: 90, y: 10, width: 40, height: 160)
        let replacement = MarqueeSelectionPolicy.selection(
            cardFrames: frames,
            selectionRect: rectangle,
            baseSelection: [third.id],
            command: false
        )
        expect(
            replacement == [first.id, second.id, third.id],
            "marquee selection includes every intersecting image card"
        )
        let additive = MarqueeSelectionPolicy.selection(
            cardFrames: frames,
            selectionRect: CGRect(x: 110, y: 10, width: 20, height: 20),
            baseSelection: [third.id],
            command: true
        )
        expect(
            additive == [second.id, third.id],
            "command-marquee preserves the selection captured at drag start"
        )

        let dropDirectory = base.appendingPathComponent("FinderDrop", isDirectory: true)
        try FileManager.default.createDirectory(at: dropDirectory, withIntermediateDirectories: false)
        let coordinatedFinalURL = dropDirectory.appendingPathComponent("Second-Lithed copy.jpg")
        var promiseError: Error?
        var completedPromiseID: UUID?
        let delegate = ImageFilePromiseDelegate(
            sourceURL: secondFallback,
            displayName: "Second-Lithed.jpg",
            onCompletion: { completedPromiseID = $0 }
        )
        let provider = NSFilePromiseProvider(fileType: UTType.jpeg.identifier, delegate: delegate)
        expect(
            delegate.filePromiseProvider(provider, fileNameForType: UTType.jpeg.identifier)
                == "Second-Lithed.jpg",
            "the promise advertises its exact display name without pre-uniquing it"
        )
        delegate.filePromiseProvider(
            provider,
            writePromiseTo: coordinatedFinalURL,
            completionHandler: { promiseError = $0 }
        )
        expect(promiseError == nil, "the promise writes successfully to Finder's supplied URL")
        let promisedData = try Data(contentsOf: coordinatedFinalURL)
        expect(
            promisedData == Data(secondFallback.lastPathComponent.utf8),
            "the promise writes only to the receiver-coordinated final URL"
        )
        expect(
            !FileManager.default.fileExists(
                atPath: coordinatedFinalURL.appendingPathComponent("Second-Lithed.jpg").path
            ),
            "the promise does not append its display name to the supplied final URL"
        )
        expect(completedPromiseID == delegate.id, "the promise reports materialization completion")
    }

    @MainActor
    private static func resultPercentageUsesSelectedCandidateBytes() {
        let item = SessionItem(
            requestID: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/PixPin.png"),
            automaticTrashEnabled: false
        )
        item.originalByteCount = 69_748
        item.pngCandidate = CompressionCandidate(
            format: .png,
            url: URL(fileURLWithPath: "/tmp/PixPin-Lithed.png"),
            byteCount: 16_388,
            ssim: 0.995,
            preset: .balanced,
            backend: .pngquant
        )
        item.selectedFormat = .png
        item.status = .ready
        expect(item.resultByteCount == 16_388, "ready item exposes selected candidate bytes")
        expect(item.reductionPercent == 77, "small PNG reduction rounds to the card percentage")

        item.selectedFormat = nil
        item.status = .noBenefit
        expect(item.resultByteCount == item.originalByteCount, "no-benefit item uses original bytes")
        expect(item.reductionPercent == 0, "no-benefit card exposes a zero-percent result")

        let model = SessionModel()
        expect(model.allowsResultPanelPresentation, "result panel is initially allowed")
        model.activities.insert(.inspector)
        expect(
            !model.allowsResultPanelPresentation,
            "result panel stays hidden while the inspector is open"
        )
        model.activities.remove(.inspector)
        model.isClosing = true
        expect(!model.allowsResultPanelPresentation, "closing suppresses result panel presentation")
    }

    private static func inspectorViewportClampsOverscroll() {
        let clipView = InspectorCenteringClipView()
        clipView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 800))

        let beforeStart = clipView.constrainBoundsRect(
            NSRect(x: -80, y: -60, width: 400, height: 300)
        )
        expect(beforeStart.origin == .zero, "zoomed image cannot expose blank space before its edges")

        let afterEnd = clipView.constrainBoundsRect(
            NSRect(x: 900, y: 700, width: 400, height: 300)
        )
        expect(
            afterEnd.origin == NSPoint(x: 600, y: 500),
            "zoomed image cannot expose blank space after its edges"
        )

        clipView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        let fullyVisible = clipView.constrainBoundsRect(
            NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        expect(
            fullyVisible.origin == NSPoint(x: -150, y: -110),
            "a fully visible small image is centered and may have surrounding space"
        )
    }

    private static func inspectorBackgroundChoicesAreUnified() {
        expect(
            InspectorBackground.allCases == [.transparent, .black, .white],
            "inspector exposes only transparent, black, and white canvas backgrounds"
        )
    }

    @MainActor
    private static func inspectorViewportUsesOneCanonicalCenter() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheInspectorViewport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let imageURL = base.appendingPathComponent("viewport.png")
        try makeTestPNG(at: imageURL, transparent: false, frameCount: 1)

        let group = SynchronizedViewportGroup()
        let first = InspectorCanvasView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        let second = InspectorCanvasView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        for canvas in [first, second] {
            canvas.viewportGroup = group
            canvas.update(
                url: imageURL,
                background: .transparent,
                isSelected: false,
                onSelect: { }
            )
            canvas.layoutSubtreeIfNeeded()
            group.register(canvas)
        }

        group.resetToActualSize()
        group.setViewport(
            ViewportState(magnification: 1, centerX: 0.75, centerY: 0.7),
            from: first
        )
        let firstState = first.viewportState
        let secondState = second.viewportState
        expect(abs(firstState.centerX - 0.75) < 0.001, "same-scale updates still move the viewport center")
        expect(abs(firstState.centerY - 0.7) < 0.001, "same-scale updates still move the vertical center")
        expect(
            abs(firstState.centerX - secondState.centerX) < 0.001
                && abs(firstState.centerY - secondState.centerY) < 0.001,
            "all inspector columns share one normalized image-space center"
        )
    }

    @MainActor
    private static func inspectorJPEGKeepsTwoCanvasColumnsAfterNavigation() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheInspectorJPEG-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        let jpegSource = base.appendingPathComponent("source.jpg")
        let jpegCandidateURL = base.appendingPathComponent("candidate.jpg")
        let pngSource = base.appendingPathComponent("source.png")
        let pngCandidateURL = base.appendingPathComponent("candidate.png")
        try makeTestJPEG(at: jpegSource, dpi: 144)
        try makeTestJPEG(at: jpegCandidateURL, dpi: 144, quality: 0.8)
        try makeTestPNG(at: pngSource, transparent: true, frameCount: 1)
        try makeTestPNG(at: pngCandidateURL, transparent: true, frameCount: 1)

        let jpegItem = SessionItem(
            requestID: UUID(),
            sourceURL: jpegSource,
            automaticTrashEnabled: false
        )
        jpegItem.snapshotURL = jpegSource
        jpegItem.originalByteCount = 100_000
        jpegItem.jpegCandidate = CompressionCandidate(
            format: .jpeg,
            url: jpegCandidateURL,
            byteCount: 70_000,
            ssim: 0.98,
            preset: .balanced,
            backend: .cjpegli
        )
        jpegItem.selectedFormat = .jpeg
        jpegItem.status = .ready

        let pngItem = SessionItem(
            requestID: UUID(),
            sourceURL: pngSource,
            automaticTrashEnabled: false
        )
        pngItem.snapshotURL = pngSource
        pngItem.originalByteCount = 100_000
        pngItem.pngCandidate = CompressionCandidate(
            format: .png,
            url: pngCandidateURL,
            byteCount: 70_000,
            ssim: 0.98,
            preset: .balanced,
            backend: .pngquant
        )
        pngItem.jpegCandidate = CompressionCandidate(
            format: .jpeg,
            url: jpegCandidateURL,
            byteCount: 60_000,
            ssim: 0.96,
            preset: .balanced,
            backend: .cjpegli
        )
        pngItem.selectedFormat = .png
        pngItem.hasTransparency = true
        pngItem.status = .ready

        let model = SessionModel()
        model.append([jpegItem, pngItem])
        model.inspectorItemID = pngItem.id
        let actions = InspectorActions(
            close: { },
            previous: { },
            next: { },
            selectCandidate: { _ in },
            recompress: { _ in }
        )
        let hostingView = NSHostingView(rootView: InspectorView(model: model, actions: actions))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 690)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        model.inspectorItemID = jpegItem.id
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        func canvases(in view: NSView) -> [InspectorCanvasView] {
            let current = (view as? InspectorCanvasView).map { [$0] } ?? []
            return current + view.subviews.flatMap(canvases)
        }
        let jpegCanvases = canvases(in: hostingView)
        expect(jpegCanvases.count == 2, "JPEG inspector keeps original and candidate canvases")
        expect(
            jpegCanvases.allSatisfy { $0.frame.width > 500 && $0.frame.height > 500 },
            "JPEG inspector keeps both canvas columns visibly laid out"
        )
        expect(
            jpegCanvases.allSatisfy { canvas in
                canvas.clipsToBounds
                    && canvas.subviews.first?.frame.size == canvas.bounds.size
            },
            "native inspector scroll views stay clipped and constrained to their columns"
        )
    }

    @MainActor
    private static func sessionModelRecordRemovalPreservesFiles() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheRecordRemoval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("source.png")
        let snapshot = base.appendingPathComponent("snapshot.png")
        let candidateURL = base.appendingPathComponent("candidate.png")
        let published = base.appendingPathComponent("published.png")
        let zipSession = base.appendingPathComponent("session.zip")
        let zipPublished = base.appendingPathComponent("published.zip")
        for url in [source, snapshot, candidateURL, published, zipSession, zipPublished] {
            try Data("preserve \(url.lastPathComponent)".utf8).write(to: url)
        }

        let item = SessionItem(
            requestID: UUID(),
            sourceURL: source,
            automaticTrashEnabled: false
        )
        item.status = .ready
        item.snapshotURL = snapshot
        item.pngCandidate = CompressionCandidate(
            format: .png,
            url: candidateURL,
            byteCount: 1,
            ssim: 1,
            preset: .balanced
        )
        item.selectedFormat = .png
        item.publishedURL = published

        let model = SessionModel()
        model.append([item])
        model.selectedItemIDs = [item.id]
        model.selectionAnchorID = item.id
        model.inspectorItemID = item.id

        let zipItem = SessionZipItem(artifact: ZipArtifact(
            sessionURL: zipSession,
            publishedURL: zipPublished,
            includedItemIDs: [item.id]
        ))
        model.zipItems.append(zipItem)

        model.removeImageRecord(id: item.id)
        expect(model.items.isEmpty, "removing an image record removes only its model entry")
        expect(!model.selectedItemIDs.contains(item.id), "image record removal clears selection")
        expect(model.selectionAnchorID == nil, "image record removal clears the selection anchor")
        expect(model.inspectorItemID == nil, "image record removal clears the inspector reference")

        model.removeZipRecord(id: zipItem.id)
        expect(model.zipItems.isEmpty, "removing a ZIP record removes only its model entry")
        for url in [source, snapshot, candidateURL, published, zipSession, zipPublished] {
            expect(
                FileManager.default.fileExists(atPath: url.path),
                "record removal preserves \(url.lastPathComponent) on disk"
            )
        }
    }

    private static func batchClipboardAndCommitGateAreSafe() {
        let original = URL(fileURLWithPath: "/tmp/original.png")
        let compressed = URL(fileURLWithPath: "/tmp/compressed.jpg")
        expect(
            ClipboardBatchPolicy.URLs(for: [.noBenefit(original)]).isEmpty,
            "single no-benefit result leaves the clipboard untouched"
        )
        expect(
            ClipboardBatchPolicy.URLs(for: [.ready(compressed), .noBenefit(original), .failed])
                == [compressed, original],
            "batch clipboard preserves ready and no-benefit positions"
        )

        let gate = GenerationCommitGate()
        let itemID = UUID()
        let stale = gate.begin(itemID: itemID)
        let current = gate.begin(itemID: itemID)
        var staleCommitted = false
        let staleResult: Int? = gate.commitIfCurrent(itemID: itemID, generation: stale) {
            staleCommitted = true
            return 1
        }
        expect(staleResult == nil && !staleCommitted, "stale generation cannot enter the commit body")
        let currentResult = gate.commitIfCurrent(itemID: itemID, generation: current) { 2 }
        expect(currentResult == 2, "current generation commits exactly once")
        gate.cancelAll()
        let afterCancel = gate.begin(itemID: itemID)
        let cancelledResult: Int? = gate.commitIfCurrent(itemID: itemID, generation: afterCancel) { 3 }
        expect(cancelledResult == nil, "session cancellation closes the publication gate")

        let cancellation = SessionCancellationState()
        expect(!cancellation.isCancelled, "session begins active")
        cancellation.cancel()
        expect(cancellation.isCancelled, "session cancellation is visible to queued work")

        let duplicate = URL(fileURLWithPath: "/tmp/../tmp/original.png")
        expect(
            TrashDeduplication.uniqueStandardizedURLs([original, duplicate]) == [original],
            "Trash source URLs are standardized and deduplicated"
        )
    }

    private static func fileLifecyclePreservesChangedOutputs() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try SessionFileStore(baseDirectory: base)
        defer { store.cleanup() }
        let source = base.appendingPathComponent("source.png")
        try Data(repeating: 7, count: 64_000).write(to: source)
        let itemID = UUID()
        let snapshot = try store.createSnapshot(sourceURL: source, itemID: itemID)
        let snapshotData = try Data(contentsOf: snapshot)
        let sourceData = try Data(contentsOf: source)
        expect(snapshotData == sourceData, "snapshot preserves source bytes")
        expect(store.contentsMatch(source, snapshot), "unchanged original still matches its snapshot")
        try Data(repeating: 8, count: 64_000).write(to: source)
        expect(!store.contentsMatch(source, snapshot), "a replaced original is ineligible for trash")
        try sourceData.write(to: source)

        let candidate = base.appendingPathComponent("candidate.jpg")
        try Data(repeating: 3, count: 32_000).write(to: candidate)
        let publication = try store.publishInitial(
            candidateURL: candidate,
            sourceURL: source,
            format: .jpeg,
            fixedDestinationDirectory: base
        )
        try Data("user edit".utf8).write(to: publication.0)
        let replacement = base.appendingPathComponent("replacement.jpg")
        try Data(repeating: 4, count: 24_000).write(to: replacement)
        let republished = try store.republish(
            candidateURL: replacement,
            sourceURL: source,
            format: .jpeg,
            currentPublishedURL: publication.0,
            currentFingerprint: publication.1,
            fixedDestinationDirectory: base
        )
        expect(republished.preservedOldOutput, "externally changed output is preserved")
        expect(FileManager.default.fileExists(atPath: publication.0.path), "changed output remains on disk")
        expect(republished.0 != publication.0, "replacement receives a new safe URL")

        let stableReplacement = base.appendingPathComponent("stable-replacement.jpg")
        try Data(repeating: 5, count: 20_000).write(to: stableReplacement)
        let stable = try store.republish(
            candidateURL: stableReplacement,
            sourceURL: source,
            format: .jpeg,
            currentPublishedURL: republished.0,
            currentFingerprint: republished.1,
            fixedDestinationDirectory: base
        )
        expect(stable.0 == republished.0, "an untouched same-format output updates at the same URL")
        expect(!stable.preservedOldOutput, "untouched output does not create a visible preserved copy")
        let stableData = try Data(contentsOf: stable.0)
        expect(stableData == Data(repeating: 5, count: 20_000), "same-URL update publishes new bytes")
        let leftoverBackups = try FileManager.default.contentsOfDirectory(atPath: base.path)
            .filter { $0.hasPrefix(".lithe-backup-") }
        expect(leftoverBackups.isEmpty, "same-URL update removes its verified backup")
    }

    private static func abandonedSessionCleanupRequiresLitheManifest() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = try SessionFileStore(baseDirectory: base)
        let ownedSession = store.rootURL
        let decoy = base.appendingPathComponent("session-decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: false)
        try Data("not a Lithe manifest".utf8).write(
            to: decoy.appendingPathComponent(".lithe-session")
        )

        SessionFileStore.cleanAbandonedSessions(baseDirectory: base)
        expect(
            !FileManager.default.fileExists(atPath: ownedSession.path),
            "startup removes an abandoned directory with Lithe's exact manifest"
        )
        expect(
            FileManager.default.fileExists(atPath: decoy.path),
            "startup preserves lookalike directories without Lithe's exact manifest"
        )
    }

    private static func pasteboardContractUsesSharedTypes() throws {
        expect(LithePasteboard.generatedFilesType.rawValue == "com.lithe.generated-files", "marker contract")
        expect(LithePasteboard.requestIDType.rawValue == "com.lithe.request-id", "request ID contract")
        let board = NSPasteboard(name: NSPasteboard.Name("LitheTests-\(UUID().uuidString)"))
        let file = URL(fileURLWithPath: "/tmp/result.png")
        let requestID = UUID()
        LithePasteboard.write(fileURLs: [file], requestID: requestID, to: board)
        expect(board.types?.contains(LithePasteboard.generatedFilesType) == true, "marker is present")
        expect(board.string(forType: LithePasteboard.requestIDType) == requestID.uuidString, "request UUID is UTF-8 text")
        let urls = board.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        expect(urls == [file], "file URLs share the same pasteboard content")
    }

    private static func imagePipelineProducesValidatedCandidates() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheImages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("opaque.png")
        try makeTestPNG(at: source, transparent: false, frameCount: 1)
        let decoded = try ImageDecoder.decode(source)
        expect(decoded.format == .png && !decoded.hasTransparency, "opaque PNG analysis")
        expect(!decoded.hasEmbeddedICCProfile, "ordinary sRGB PNG has no embedded ICC profile")
        expect(StructuralSimilarity.score(reference: decoded.image, candidate: decoded.image) > 0.9999, "identical SSIM")

        let store = try SessionFileStore(baseDirectory: base)
        defer { store.cleanup() }
        let itemID = UUID()
        let snapshot = try store.createSnapshot(sourceURL: source, itemID: itemID)
        let vendoredRunner = ToolRunner(
            toolsDirectory: URL(fileURLWithPath: "Vendor/bin", isDirectory: true)
        )
        let result = try CompressionEngine(toolRunner: vendoredRunner).compress(
            snapshotURL: snapshot,
            itemID: itemID,
            generation: 1,
            preset: .balanced,
            fileStore: store
        )
        expect(result.pngCandidate != nil, "PNG candidate exists")
        expect(result.jpegCandidate != nil, "opaque PNG receives JPEG candidate")
        expect(
            result.pngCandidate?.quality == .preset(.balanced)
                && result.jpegCandidate?.quality == .preset(.balanced)
                && result.pngCandidate?.quality.level == .six,
            "automatic initial candidates are encoded at balanced level six"
        )
        expect(result.jpegCandidate?.backend == .cjpegli, "opaque PNG uses bundled Jpegli")
        expect(result.pngCandidate?.ssim ?? 0 > 0.99, "lossless fallback remains faithful")

        let paletteURL = base.appendingPathComponent("palette-friendly.png")
        try makeTestPNG(
            at: paletteURL,
            transparent: false,
            frameCount: 1,
            image: makePaletteFriendlyImage()
        )
        let paletteID = UUID()
        let paletteSnapshot = try store.createSnapshot(sourceURL: paletteURL, itemID: paletteID)
        let paletteResult = try CompressionEngine(toolRunner: vendoredRunner).compress(
            snapshotURL: paletteSnapshot,
            itemID: paletteID,
            generation: 1,
            preset: .balanced,
            fileStore: store
        )
        expect(
            paletteResult.pngCandidate?.backend == .pngquant,
            "palette-friendly PNG is actually encoded by bundled pngquant "
                + "(backend=\(String(describing: paletteResult.pngCandidate?.backend)), "
                + "failures=\(paletteResult.candidateFailureMessage ?? "none"))"
        )

        let displayP3URL = base.appendingPathComponent("display-p3.png")
        guard let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) else {
            expect(false, "Display P3 color space is available")
            return
        }
        try makeTestPNG(
            at: displayP3URL,
            transparent: false,
            frameCount: 1,
            colorSpace: displayP3,
            dpi: 144
        )
        let decodedDisplayP3 = try ImageDecoder.decode(displayP3URL)
        expect(decodedDisplayP3.hasEmbeddedICCProfile, "Display P3 PNG retains its embedded iCCP profile")
        let displayP3ID = UUID()
        let displayP3Snapshot = try store.createSnapshot(
            sourceURL: displayP3URL,
            itemID: displayP3ID
        )
        let displayP3Result = try CompressionEngine(toolRunner: vendoredRunner).compress(
            snapshotURL: displayP3Snapshot,
            itemID: displayP3ID,
            generation: 1,
            preset: .balanced,
            fileStore: store
        )
        expect(
            displayP3Result.jpegCandidate?.backend == .cjpegli,
            "Display P3 is encoded by Jpegli instead of silently falling back"
        )
        expect(
            displayP3Result.jpegCandidate?.ssim ?? 0 >= QualityPreset.balanced.minimumSSIM,
            "Display P3 Jpegli output passes color-managed quality validation"
        )
        if let jpegURL = displayP3Result.jpegCandidate?.url {
            let displayP3JPEG = try ImageDecoder.decode(jpegURL)
            expect(
                displayP3JPEG.iccProfile != nil,
                "Display P3 Jpegli output retains an embedded color profile"
            )
        }

        let transparentURL = base.appendingPathComponent("transparent.png")
        try makeTestPNG(at: transparentURL, transparent: true, frameCount: 1)
        let transparentID = UUID()
        let transparentSnapshot = try store.createSnapshot(sourceURL: transparentURL, itemID: transparentID)
        let transparentResult = try CompressionEngine(toolRunner: vendoredRunner).compress(
            snapshotURL: transparentSnapshot,
            itemID: transparentID,
            generation: 1,
            preset: .balanced,
            fileStore: store
        )
        expect(transparentResult.hasTransparency, "transparent pixels are detected")
        expect(transparentResult.jpegCandidate == nil, "transparent PNG never generates JPEG")

        let animated = base.appendingPathComponent("animated.png")
        try makeTestPNG(at: animated, transparent: false, frameCount: 2)
        expectThrows("animated PNG is rejected") { _ = try ImageDecoder.decode(animated) }

        let singleFrameAPNG = base.appendingPathComponent("single-frame-apng.png")
        var synthetic = Data([137, 80, 78, 71, 13, 10, 26, 10])
        synthetic.append(contentsOf: [0, 0, 0, 8, 97, 99, 84, 76])
        synthetic.append(Data(repeating: 0, count: 12))
        try synthetic.write(to: singleFrameAPNG)
        expect(PNGAnimationDetector.containsAnimationControl(at: singleFrameAPNG), "single-frame acTL is detected")
        expectThrows("single-frame APNG is rejected before decode") {
            _ = try ImageDecoder.decode(singleFrameAPNG)
        }
    }

    private static func imageDecoderDistinguishesAlphaChannelFromTransparency() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheAlphaPixels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        let opaqueImage = makeTinyRGBAImage(hasTransparentPixel: false)
        let transparentImage = makeTinyRGBAImage(hasTransparentPixel: true)
        expect(imageDeclaresAlphaChannel(opaqueImage), "opaque RGBA fixture declares an alpha channel")
        expect(imageDeclaresAlphaChannel(transparentImage), "transparent fixture declares an alpha channel")

        let opaqueURL = base.appendingPathComponent("small-opaque-rgba.png")
        let transparentURL = base.appendingPathComponent("small-transparent-rgba.png")
        try makeTestPNG(
            at: opaqueURL,
            transparent: false,
            frameCount: 1,
            image: opaqueImage
        )
        try makeTestPNG(
            at: transparentURL,
            transparent: true,
            frameCount: 1,
            image: transparentImage
        )

        guard let opaqueSource = CGImageSourceCreateWithURL(opaqueURL as CFURL, nil),
              let rawOpaque = CGImageSourceCreateImageAtIndex(opaqueSource, 0, nil),
              let transparentSource = CGImageSourceCreateWithURL(transparentURL as CFURL, nil),
              let rawTransparent = CGImageSourceCreateImageAtIndex(transparentSource, 0, nil) else {
            expect(false, "RGBA PNG fixtures remain decodable through ImageIO")
            return
        }
        expect(imageDeclaresAlphaChannel(rawOpaque), "encoded opaque PNG keeps its alpha channel")
        expect(imageDeclaresAlphaChannel(rawTransparent), "encoded transparent PNG keeps its alpha channel")

        let opaqueDecoded = try ImageDecoder.decode(opaqueURL)
        let transparentDecoded = try ImageDecoder.decode(transparentURL)
        expect(!opaqueDecoded.hasTransparency, "alpha=255 pixels are treated as fully opaque")
        expect(transparentDecoded.hasTransparency, "an alpha<255 pixel is treated as transparent")

        let store = try SessionFileStore(baseDirectory: base)
        defer { store.cleanup() }
        let runner = ToolRunner(toolsDirectory: base.appendingPathComponent("NoTools"))
        let engine = CompressionEngine(toolRunner: runner)

        let opaqueID = UUID()
        let opaqueSnapshot = try store.createSnapshot(sourceURL: opaqueURL, itemID: opaqueID)
        let opaqueResult = try engine.compress(
            snapshotURL: opaqueSnapshot,
            itemID: opaqueID,
            generation: 1,
            preset: .balanced,
            fileStore: store
        )
        expect(opaqueResult.originalByteCount < CompressionPolicy.minimumAbsoluteSaving, "fixture is a small PNG")
        expect(opaqueResult.pngCandidate != nil, "small opaque RGBA generates a PNG candidate")
        expect(opaqueResult.jpegCandidate != nil, "small opaque RGBA generates a JPEG candidate")
        expect(opaqueResult.selectedFormat == nil, "small candidates below the savings floor are not published")

        let transparentID = UUID()
        let transparentSnapshot = try store.createSnapshot(
            sourceURL: transparentURL,
            itemID: transparentID
        )
        let transparentResult = try engine.compress(
            snapshotURL: transparentSnapshot,
            itemID: transparentID,
            generation: 1,
            preset: .balanced,
            fileStore: store
        )
        expect(transparentResult.pngCandidate != nil, "small transparent PNG generates a PNG candidate")
        expect(transparentResult.jpegCandidate == nil, "actual transparency blocks JPEG generation")
    }

    private static func qualityMetricDetectsColorAndAlphaChanges() {
        let red = makeSolidImage(red: 255, green: 0, blue: 0, alpha: 255)
        let equalLumaGreen = makeSolidImage(red: 0, green: 130, blue: 0, alpha: 255)
        expect(
            StructuralSimilarity.score(reference: red, candidate: equalLumaGreen) < 0.5,
            "quality metric rejects a strong color shift even when luma is nearly unchanged"
        )
        let translucentRed = makeSolidImage(red: 128, green: 0, blue: 0, alpha: 128)
        expect(
            StructuralSimilarity.score(reference: red, candidate: translucentRed) < 0.95,
            "quality metric detects changed transparency"
        )
    }

    private static func imageDecoderNormalizesEXIFOrientation() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheOrientation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("orientation-6.jpg")
        try makeTestJPEG(at: source, dpi: 72, orientation: 6, quality: 0.9)
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            expect(false, "oriented JPEG remains decodable before normalization")
            return
        }
        let decoded = try ImageDecoder.decode(source)
        expect(decoded.sourceOrientation == 6, "EXIF orientation is read from JPEG metadata")
        expect(raw.width == 512 && raw.height == 384, "fixture stores non-square raw JPEG pixels")
        expect(
            decoded.image.width == raw.height && decoded.image.height == raw.width,
            "orientation 6 swaps dimensions while normalizing JPEG pixels"
        )
    }

    private static func imagePipelineRejectsCorruptionAndPreservesJPEGRenderingMetadata() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheJPEG-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        let corrupt = base.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: corrupt)
        expectThrows("corrupt JPEG is rejected") { _ = try ImageDecoder.decode(corrupt) }

        let source = base.appendingPathComponent("相片 ' sample.jpg")
        try makeTestJPEG(at: source, dpi: 144)
        let decoded = try ImageDecoder.decode(source)
        expect(decoded.format == .jpeg, "JPEG input is detected")
        expect(abs((decoded.dpiWidth ?? 0) - 144) < 0.5, "JPEG input DPI is detected")

        let sanitized = base.appendingPathComponent("sanitized.jpg")
        try FileManager.default.copyItem(at: source, to: sanitized)
        try JPEGMetadataSanitizer.sanitize(sanitized, dpiWidth: 144, dpiHeight: 144)
        let sanitizedDecoded = try ImageDecoder.decode(sanitized)
        expect(abs((sanitizedDecoded.dpiWidth ?? 0) - 144) < 0.5, "sanitizer preserves JFIF density")
        guard let sanitizedRef = CGImageSourceCreateWithURL(sanitized as CFURL, nil),
              let sanitizedProperties = CGImageSourceCopyPropertiesAtIndex(
                sanitizedRef,
                0,
                nil
              ) as? [CFString: Any] else {
            expect(false, "sanitized JPEG properties are readable")
            return
        }
        expect(sanitizedProperties[kCGImagePropertyGPSDictionary] == nil, "sanitizer removes GPS markers")

        let store = try SessionFileStore(baseDirectory: base)
        defer { store.cleanup() }
        let itemID = UUID()
        let snapshot = try store.createSnapshot(sourceURL: source, itemID: itemID)
        let runner = ToolRunner(toolsDirectory: base.appendingPathComponent("NoTools", isDirectory: true))
        let result = try CompressionEngine(toolRunner: runner).compress(
            snapshotURL: snapshot,
            itemID: itemID,
            generation: 1,
            preset: .balanced,
            fileStore: store
        )
        guard let candidate = result.jpegCandidate else {
            expect(false, "JPEG candidate exists")
            return
        }
        let candidateDecoded = try ImageDecoder.decode(candidate.url)
        expect(abs((candidateDecoded.dpiWidth ?? 0) - 144) < 0.5, "JPEG output preserves DPI")
        guard let sourceRef = CGImageSourceCreateWithURL(candidate.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [CFString: Any] else {
            expect(false, "JPEG output properties are readable")
            return
        }
        expect(properties[kCGImagePropertyGPSDictionary] == nil, "JPEG output strips GPS metadata")
        expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1, "orientation is normalized")
    }

    private static func jpegInputUsesLosslessJPEGTranBackend() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheJPEGTran-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        let vendoredJPEGTran = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/bin/jpegtran")
        expect(
            FileManager.default.isExecutableFile(atPath: vendoredJPEGTran.path),
            "vendored jpegtran is executable for the lossless-backend regression"
        )
        let tools = base.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: tools.appendingPathComponent("jpegtran"),
            withDestinationURL: vendoredJPEGTran
        )

        let source = base.appendingPathComponent("already-lossy.jpg")
        try makeTestJPEG(at: source, dpi: 144, quality: 0.2)
        let store = try SessionFileStore(baseDirectory: base)
        defer { store.cleanup() }
        let itemID = UUID()
        let snapshot = try store.createSnapshot(sourceURL: source, itemID: itemID)
        let result = try CompressionEngine(
            toolRunner: ToolRunner(toolsDirectory: tools)
        ).compress(
            snapshotURL: snapshot,
            itemID: itemID,
            generation: 1,
            preset: .clearer,
            fileStore: store
        )
        expect(
            result.jpegCandidate?.backend == .jpegtran,
            "an already-lossy JPEG selects the real lossless jpegtran candidate "
                + "(backend=\(String(describing: result.jpegCandidate?.backend)), "
                + "failures=\(result.candidateFailureMessage ?? "none"))"
        )
    }

    private static func failingOptionalPNGToolFallsBack() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let tools = base.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
        let failingPNGQuant = tools.appendingPathComponent("pngquant")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: failingPNGQuant)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingPNGQuant.path)

        let source = base.appendingPathComponent("图 片 ' \" $.png")
        try makeTestPNG(at: source, transparent: false, frameCount: 1)
        let store = try SessionFileStore(baseDirectory: base)
        defer { store.cleanup() }
        let itemID = UUID()
        let snapshot = try store.createSnapshot(sourceURL: source, itemID: itemID)
        let result = try CompressionEngine(toolRunner: ToolRunner(toolsDirectory: tools)).compress(
            snapshotURL: snapshot,
            itemID: itemID,
            generation: 1,
            preset: .balanced,
            fileStore: store
        )
        expect(result.pngCandidate != nil, "a failing optional pngquant falls back to ImageIO")
    }

    private static func compressionCancellationStopsFallbackPipeline() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheCompressionCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let tools = base.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
        let pngquantStarted = base.appendingPathComponent("pngquant-started")
        let oxipngStarted = base.appendingPathComponent("oxipng-started")
        let cjpegliStarted = base.appendingPathComponent("cjpegli-started")
        try writeExecutableScript(
            """
            #!/bin/sh
            echo "$$" > '\(pngquantStarted.path)'
            exec /bin/sleep 10
            """,
            to: tools.appendingPathComponent("pngquant")
        )
        try writeExecutableScript(
            "#!/bin/sh\necho invoked > '\(oxipngStarted.path)'\nexit 1\n",
            to: tools.appendingPathComponent("oxipng")
        )
        try writeExecutableScript(
            "#!/bin/sh\necho invoked > '\(cjpegliStarted.path)'\nexit 1\n",
            to: tools.appendingPathComponent("cjpegli")
        )

        let source = base.appendingPathComponent("opaque.png")
        try makeTestPNG(at: source, transparent: false, frameCount: 1)
        let store = try SessionFileStore(baseDirectory: base)
        defer { store.cleanup() }
        let itemID = UUID()
        let snapshot = try store.createSnapshot(sourceURL: source, itemID: itemID)
        let lossyOutput = try store.candidateURL(
            itemID: itemID,
            format: .png,
            generation: 1,
            variant: "lossy"
        )
        let engine = CompressionEngine(toolRunner: ToolRunner(toolsDirectory: tools))
        let completion = DispatchSemaphore(value: 0)
        let capturedError = CapturedError()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completion.signal() }
            do {
                _ = try engine.compress(
                    snapshotURL: snapshot,
                    itemID: itemID,
                    generation: 1,
                    preset: .balanced,
                    fileStore: store
                )
            } catch {
                capturedError.store(error)
            }
        }

        let started = waitForFile(at: pngquantStarted, timeout: 2)
        engine.cancel()
        let completed = completion.wait(timeout: .now() + 3) == .success
        expect(started, "compression cancellation fixture reaches the first bundled tool")
        expect(completed, "compression cancellation returns promptly")
        expect(isCancellation(capturedError.load()), "compression reports cancellation")
        expect(
            !FileManager.default.fileExists(atPath: lossyOutput.path),
            "cancelled bundled encoding does not fall back to ImageIO"
        )
        expect(
            !FileManager.default.fileExists(atPath: oxipngStarted.path),
            "cancelled pngquant does not start oxipng"
        )
        expect(
            !FileManager.default.fileExists(atPath: cjpegliStarted.path),
            "cancelled PNG compression does not start the JPEG candidate"
        )
    }

    private static func toolRunnerDrainsLargeOutput() throws {
        let result = try ToolRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/jot"),
            arguments: ["50000", "1", "50000"]
        )
        expect(result.standardOutput.count > 100_000, "large stdout is drained without a pipe deadlock")
    }

    private static func toolRunnerCancellationReapsChild() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheToolCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let pidURL = base.appendingPathComponent("pid")
        let runner = ToolRunner()
        let completion = DispatchSemaphore(value: 0)
        let capturedError = CapturedError()
        let startedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completion.signal() }
            do {
                _ = try runner.run(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "echo \"$$\" > \"$1\"; exec /bin/sleep 10",
                        "lithe-cancel-test",
                        pidURL.path,
                    ]
                )
            } catch {
                capturedError.store(error)
            }
        }

        let started = waitForFile(at: pidURL, timeout: 2)
        runner.cancel()
        let completed = completion.wait(timeout: .now() + 3) == .success
        expect(started, "explicit-cancellation child process starts")
        expect(completed, "explicit ToolRunner cancellation returns promptly")
        expect(Date().timeIntervalSince(startedAt) < 4, "cancellation does not wait for child sleep")
        expect(isCancellation(capturedError.load()), "ToolRunner reports an explicit cancellation")

        guard let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            expect(false, "cancellation fixture records its child PID")
            return
        }
        errno = 0
        let probe = Darwin.kill(pid, 0)
        expect(probe == -1 && errno == ESRCH, "cancelled child is reaped instead of orphaned")
    }

    private static func toolRunnerTimesOutAndReaps() {
        expectThrows("timed-out helper is stopped and reaped") {
            _ = try ToolRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.02
            )
        }
    }

    private static func zipServiceCreatesArchive() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LitheZip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try SessionFileStore(baseDirectory: base)
        defer { store.cleanup() }
        let source = base.appendingPathComponent("one.txt")
        try Data("one".utf8).write(to: source)
        let unicodeSource = base.appendingPathComponent("设置截图 文字.txt")
        try Data("unicode".utf8).write(to: unicodeSource)
        let archive = store.rootURL.appendingPathComponent("test.zip")
        try ZipService.createZip(
            entries: [
                (source, "one.txt"),
                (source, "one.txt"),
                (unicodeSource, unicodeSource.lastPathComponent)
            ],
            sessionURL: archive,
            fileStore: store,
            toolRunner: ToolRunner()
        )
        expect(FileManager.default.fileExists(atPath: archive.path), "ZIP is produced")
        let archiveSize = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        expect(archiveSize > 0, "ZIP is nonempty")
        let listing = try ToolRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", archive.path]
        )
        let names = String(decoding: listing.standardOutput, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        expect(names.contains("one.txt"), "ZIP keeps the first file at archive root")
        expect(names.contains("one-2.txt"), "ZIP safely renames duplicate files at archive root")

        let extracted = base.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        _ = try ToolRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, extracted.path]
        )
        expect(
            FileManager.default.fileExists(
                atPath: extracted.appendingPathComponent(unicodeSource.lastPathComponent).path
            ),
            "ZIP round-trips Unicode names with the system archive tool"
        )
        expect(
            !FileManager.default.fileExists(atPath: extracted.appendingPathComponent("__MACOSX").path),
            "ZIP omits resource-fork metadata directories"
        )
    }

    private static func makeTestPNG(
        at url: URL,
        transparent: Bool,
        frameCount: Int,
        colorSpace: CGColorSpace? = nil,
        dpi: Double? = nil,
        image suppliedImage: CGImage? = nil
    ) throws {
        let image = suppliedImage
            ?? makePatternImage(transparent: transparent, colorSpace: colorSpace)
        guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                frameCount,
                nil
              ) else {
            throw CompressionEngineError.encodeFailed(.png)
        }
        var properties: [CFString: Any] = [:]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        for _ in 0..<frameCount {
            CGImageDestinationAddImage(
                destination,
                image,
                properties.isEmpty ? nil : properties as CFDictionary
            )
        }
        guard CGImageDestinationFinalize(destination) else {
            throw CompressionEngineError.encodeFailed(.png)
        }
    }

    private static func makeTestJPEG(
        at url: URL,
        dpi: Double,
        orientation: Int = 1,
        quality: Double = 1
    ) throws {
        let image = makePatternImage(transparent: false)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CompressionEngineError.encodeFailed(.jpeg)
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.2,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 121.5,
                kCGImagePropertyGPSLongitudeRef: "E",
            ] as CFDictionary,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CompressionEngineError.encodeFailed(.jpeg)
        }
    }

    private static func writeExecutableScript(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func waitForFile(at url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func isCancellation(_ error: Error?) -> Bool {
        if let engineError = error as? CompressionEngineError,
           case .cancelled = engineError {
            return true
        }
        if let toolError = error as? ToolRunnerError,
           case .cancelled = toolError {
            return true
        }
        return false
    }

    private static func makePatternImage(
        transparent: Bool,
        colorSpace: CGColorSpace? = nil
    ) -> CGImage {
        let width = 512
        let height = 384
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let alpha = transparent && x < width / 4 ? UInt8((x * 255) / (width / 4)) : 255
                pixels[index] = UInt8((x * Int(alpha)) / width)
                pixels[index + 1] = UInt8((y * Int(alpha)) / height)
                pixels[index + 2] = UInt8(((x ^ y) & 0xff) * Int(alpha) / 255)
                pixels[index + 3] = alpha
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            fatalError("unable to construct deterministic test image")
        }
        return image
    }

    private static func makeSolidImage(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> CGImage {
        let width = 64
        let height = 64
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            pixels.append(contentsOf: [red, green, blue, alpha])
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            fatalError("unable to construct solid test image")
        }
        return image
    }

    private static func makeTinyRGBAImage(hasTransparentPixel: Bool) -> CGImage {
        let width = 4
        let height = 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 24
            pixels[index + 1] = 80
            pixels[index + 2] = 160
            pixels[index + 3] = 255
        }
        if hasTransparentPixel {
            pixels[0] = 0
            pixels[1] = 0
            pixels[2] = 0
            pixels[3] = 0
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            fatalError("unable to construct tiny RGBA test image")
        }
        return image
    }

    private static func imageDeclaresAlphaChannel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private static func makePaletteFriendlyImage() -> CGImage {
        let width = 512
        let height = 384
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var generator: UInt32 = 0xC0FFEE
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                generator = generator &* 1_664_525 &+ 1_013_904_223
                let paletteIndex = UInt8(truncatingIfNeeded: generator >> 24)
                pixels[index] = paletteIndex
                pixels[index + 1] = paletteIndex &* 73
                pixels[index + 2] = paletteIndex &* 151
                pixels[index + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            fatalError("unable to construct palette-friendly test image")
        }
        return image
    }
}

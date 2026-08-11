import AppKit
import Foundation

private struct InitialCompressionJob: Sendable {
    let itemID: UUID
    let requestID: UUID
    let sourceURL: URL
    let automaticTrashEnabled: Bool
    let destinationDirectory: URL?
}

private struct TrashCandidate: Sendable {
    let itemID: UUID
    let sourceURL: URL
    let snapshotURL: URL
    let publishedURL: URL
    let publishedFingerprint: PublishedFingerprint
}

private struct AuditedTrashMove: Sendable {
    let itemIDs: [UUID]
    let recordItemID: UUID
    let originalURL: URL
    let trashedURL: URL
}

private struct TrashRecycleAudit: Sendable {
    let accepted: [AuditedTrashMove]
    let unresolved: [AuditedTrashMove]
    let restoredChangedFiles: Int
}

@MainActor
final class SessionCoordinator: @unchecked Sendable {
    let model = SessionModel()
    nonisolated let fileStore: SessionFileStore
    nonisolated let compressionEngine: CompressionEngine
    nonisolated let worker = DispatchQueue(label: "com.lithe.worker", qos: .userInitiated)
    nonisolated let generationGate = GenerationCommitGate()
    nonisolated let cancellationState = SessionCancellationState()

    private lazy var panelController = ResultPanelController(
        model: model,
        actions: makeResultActions()
    )
    private var inspectorController: InspectorWindowController?
    private var autoCloseTimer: Timer?
    private var pendingBatchCount = 0
    private var activeRecompressionCount = 0
    private var activeTrashCount = 0
    private var trashInFlightSourceURLs: Set<URL> = []

    var hasActiveSession: Bool {
        (!model.items.isEmpty || !model.zipItems.isEmpty || !model.trashRecords.isEmpty)
            && !model.isClosing
    }

    init(
        fileStore: SessionFileStore? = nil,
        compressionEngine: CompressionEngine = CompressionEngine()
    ) throws {
        self.fileStore = try fileStore ?? SessionFileStore()
        self.compressionEngine = compressionEngine
    }

    func receive(urls: [URL]) {
        guard !model.isClosing else { return }
        panelController.refreshScreenForNewInvocation()
        var seen: Set<URL> = []
        let supported = urls.compactMap { url -> URL? in
            let standardized = url.standardizedFileURL
            guard Self.isSupportedRegularImage(standardized),
                  seen.insert(standardized).inserted else { return nil }
            return standardized
        }
        guard !supported.isEmpty else {
            model.bannerMessage = "仅支持本地 JPG、JPEG 和静态 PNG 文件"
            showPanel()
            resetAutoCloseTimer()
            return
        }
        do {
            try fileStore.ensureTemporaryCapacity(for: supported)
        } catch {
            model.bannerMessage = error.localizedDescription
            showPanel()
            resetAutoCloseTimer()
            return
        }

        let requestID = UUID()
        let automaticTrash = UserDefaults.standard.bool(forKey: LitheDefaults.autoTrashOriginals)
        let destinationDirectory = fixedDestinationDirectory()
        let newItems = supported.map {
            SessionItem(
                requestID: requestID,
                sourceURL: $0,
                automaticTrashEnabled: automaticTrash
            )
        }
        model.append(newItems)
        model.bannerMessage = nil
        pendingBatchCount += 1
        model.activities.insert(.processing)
        showPanel()
        autoCloseTimer?.invalidate()

        let jobs = newItems.map {
            InitialCompressionJob(
                itemID: $0.id,
                requestID: requestID,
                sourceURL: $0.sourceURL,
                automaticTrashEnabled: $0.automaticTrashEnabled,
                destinationDirectory: destinationDirectory
            )
        }
        worker.async { [weak self] in
            self?.processBatch(jobs, requestID: requestID)
        }
    }

    func prepareForTermination() {
        autoCloseTimer?.invalidate()
        cancellationState.cancel()
        generationGate.cancelAll()
        compressionEngine.cancel()
        fileStore.cleanup()
    }

    private nonisolated func processBatch(_ jobs: [InitialCompressionJob], requestID: UUID) {
        var clipboardResults: [ClipboardBatchResult] = []
        for job in jobs {
            guard !cancellationState.isCancelled else { break }
            let generation: Int = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let item = self.model.item(id: job.itemID) else { return -1 }
                    item.status = .processing
                    let generation = self.generationGate.begin(itemID: job.itemID)
                    item.generation = generation
                    return generation
                }
            }
            guard generation >= 0 else { continue }
            do {
                let snapshot = try fileStore.createSnapshot(
                    sourceURL: job.sourceURL,
                    itemID: job.itemID
                )
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        guard let item = self.model.item(id: job.itemID),
                              item.generation == generation else { return }
                        item.snapshotURL = snapshot
                    }
                }
                let result = try compressionEngine.compress(
                    snapshotURL: snapshot,
                    itemID: job.itemID,
                    generation: generation,
                    preset: .balanced,
                    fileStore: fileStore
                )
                if let selected = result.selectedCandidate {
                    guard !cancellationState.isCancelled,
                          let publication = try generationGate.commitIfCurrent(
                            itemID: job.itemID,
                            generation: generation,
                            {
                                try fileStore.publishInitial(
                                    candidateURL: selected.url,
                                    sourceURL: job.sourceURL,
                                    format: selected.format,
                                    fixedDestinationDirectory: job.destinationDirectory
                                )
                            }
                          ) else { break }
                    clipboardResults.append(.ready(publication.0))
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            self.applyInitialResult(
                                itemID: job.itemID,
                                generation: generation,
                                snapshot: snapshot,
                                result: result,
                                publishedURL: publication.0,
                                fingerprint: publication.1
                            )
                        }
                    }
                    if job.automaticTrashEnabled {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self.trashOriginals(itemIDs: [job.itemID], automatic: true)
                            }
                        }
                    }
                } else {
                    clipboardResults.append(.noBenefit(job.sourceURL))
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            self.applyNoBenefit(
                                itemID: job.itemID,
                                generation: generation,
                                snapshot: snapshot,
                                result: result
                            )
                        }
                    }
                }
            } catch {
                clipboardResults.append(.failed)
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        guard let item = self.model.item(id: job.itemID),
                              item.generation == generation else { return }
                        item.status = .failed(error.localizedDescription)
                    }
                }
            }
        }
        let finalClipboardResults = clipboardResults
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.finishBatch(
                    requestID: requestID,
                    clipboardURLs: ClipboardBatchPolicy.URLs(for: finalClipboardResults)
                )
            }
        }
    }

    private func applyInitialResult(
        itemID: UUID,
        generation: Int,
        snapshot: URL,
        result: CompressionResult,
        publishedURL: URL,
        fingerprint: PublishedFingerprint
    ) {
        guard let item = model.item(id: itemID) else { return }
        item.applyIfCurrent(generation: generation) {
            item.snapshotURL = snapshot
            item.inputFormat = result.inputFormat
            item.hasTransparency = result.hasTransparency
            item.originalByteCount = result.originalByteCount
            item.pngCandidate = result.pngCandidate
            item.jpegCandidate = result.jpegCandidate
            item.selectedFormat = result.selectedFormat
            item.reviewRecommended = result.reviewRecommended
            item.generationFailureMessage = result.candidateFailureMessage
            item.publishedURL = publishedURL
            item.publishedFingerprint = fingerprint
            item.status = .ready
            item.thumbnail = result.selectedCandidate.flatMap { NSImage(contentsOf: $0.url) }
                ?? NSImage(contentsOf: snapshot)
        }
        showPanel()
    }

    private func applyNoBenefit(
        itemID: UUID,
        generation: Int,
        snapshot: URL,
        result: CompressionResult
    ) {
        guard let item = model.item(id: itemID) else { return }
        item.applyIfCurrent(generation: generation) {
            item.snapshotURL = snapshot
            item.inputFormat = result.inputFormat
            item.hasTransparency = result.hasTransparency
            item.originalByteCount = result.originalByteCount
            item.pngCandidate = result.pngCandidate
            item.jpegCandidate = result.jpegCandidate
            item.selectedFormat = nil
            item.generationFailureMessage = result.candidateFailureMessage
            item.status = .noBenefit
        }
        showPanel()
    }

    private func finishBatch(requestID: UUID, clipboardURLs: [URL]) {
        pendingBatchCount = max(0, pendingBatchCount - 1)
        if pendingBatchCount == 0 { model.activities.remove(.processing) }
        if !model.isClosing,
           UserDefaults.standard.bool(forKey: LitheDefaults.autoCopyResults),
           !clipboardURLs.isEmpty {
            LithePasteboard.write(fileURLs: clipboardURLs, requestID: requestID)
        }
        showPanel()
        resetAutoCloseTimer()
    }

    private func makeResultActions() -> ResultActions {
        ResultActions(
            inspect: { [weak self] in self?.openInspector() },
            reveal: { [weak self] in
                guard let self else { return }
                SystemActions.reveal(self.model.selectedOrAllPublishedURLs())
                self.resetAutoCloseTimer()
            },
            zip: { [weak self] in self?.createZip() },
            trashAllOriginals: { [weak self] in self?.trashAllEligibleOriginals() },
            undoTrash: { [weak self] in self?.undoTrash() },
            close: { [weak self] in self?.requestClose() },
            revealURL: { [weak self] url in
                SystemActions.reveal([url])
                self?.resetAutoCloseTimer()
            },
            select: { [weak self] id, modifiers in
                self?.model.select(id: id, modifiers: modifiers)
                self?.resetAutoCloseTimer()
            },
            prepareImageDrag: { [weak self] id, modifiers in
                guard let self else { return [] }
                let items = self.model.prepareImageDrag(id: id, modifiers: modifiers)
                self.resetAutoCloseTimer()
                return items
            },
            applyMarqueeSelection: { [weak self] selection in
                self?.model.applyMarqueeSelection(selection)
                self?.resetAutoCloseTimer()
            },
            dragActivity: { [weak self] active in self?.setActivity(.dragging, active: active) },
            hoverActivity: { [weak self] active in self?.setActivity(.hovering, active: active) },
            menuActivity: { [weak self] active in self?.setActivity(.menu, active: active) },
            removeImageRecord: { [weak self] id in self?.removeImageRecord(id) },
            removeZipRecord: { [weak self] id in self?.removeZipRecord(id) }
        )
    }

    private func removeImageRecord(_ id: UUID) {
        model.removeImageRecord(id: id)
        showPanel()
        resetAutoCloseTimer()
    }

    private func removeZipRecord(_ id: UUID) {
        model.removeZipRecord(id: id)
        showPanel()
        resetAutoCloseTimer()
    }

    private func makeInspectorActions() -> InspectorActions {
        InspectorActions(
            close: { [weak self] in self?.inspectorController?.close() },
            previous: { [weak self] in self?.moveInspector(by: -1) },
            next: { [weak self] in self?.moveInspector(by: 1) },
            selectCandidate: { [weak self] format in self?.publishExistingCandidate(format: format) },
            recompress: { [weak self] quality in self?.recompressCurrentItem(quality: quality) }
        )
    }

    private func openInspector() {
        let selected = model.inspectableItems.first { model.selectedItemIDs.contains($0.id) }
        guard let item = selected ?? model.inspectableItems.first else { return }
        model.inspectorItemID = item.id
        model.activities.remove(.hovering)
        model.activities.insert(.inspector)
        autoCloseTimer?.invalidate()
        panelController.hide()
        let controller = InspectorWindowController(
            model: model,
            actions: makeInspectorActions(),
            visibleFrame: panelController.visibleFrame,
            onClose: { [weak self] in self?.inspectorDidClose() }
        )
        inspectorController = controller
        controller.show()
    }

    private func inspectorDidClose() {
        inspectorController = nil
        model.inspectorItemID = nil
        model.activities.remove(.inspector)
        guard !model.isClosing else { return }
        showPanel()
        resetAutoCloseTimer()
    }

    private func moveInspector(by delta: Int) {
        let values = model.inspectableItems
        guard !values.isEmpty,
              let current = model.inspectorItemID,
              let index = values.firstIndex(where: { $0.id == current }) else { return }
        let next = (index + delta + values.count) % values.count
        model.inspectorItemID = values[next].id
    }

    private func recompressCurrentItem(quality: CompressionQuality) {
        guard let id = model.inspectorItemID,
              let item = model.item(id: id),
              let snapshot = item.snapshotURL,
              let format = item.selectedFormat ?? item.pngCandidate?.format ?? item.jpegCandidate?.format else {
            return
        }
        compressionEngine.cancel(itemID: id)
        let generation = generationGate.begin(itemID: id)
        guard generation >= 0 else { return }
        item.generation = generation
        item.isRecompressing = true
        item.generationFailureMessage = nil
        activeRecompressionCount += 1
        model.activities.insert(.recompressing)
        autoCloseTimer?.invalidate()
        let sourceURL = item.sourceURL
        let currentURL = item.publishedURL
        let currentFingerprint = item.publishedFingerprint
        let destination = fixedDestinationDirectory()

        worker.async { [weak self] in
            guard let self else { return }
            guard !self.cancellationState.isCancelled,
                  self.generationGate.isCurrent(itemID: id, generation: generation) else {
                self.finishStaleRecompression(itemID: id, generation: generation)
                return
            }
            do {
                let candidate = try self.compressionEngine.recompress(
                    snapshotURL: snapshot,
                    itemID: id,
                    generation: generation,
                    format: format,
                    quality: quality,
                    fileStore: self.fileStore
                )
                guard !self.cancellationState.isCancelled else {
                    self.finishStaleRecompression(itemID: id, generation: generation)
                    return
                }
                try self.validateRecompressedCandidate(candidate, originalBytes: DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self.model.item(id: id)?.originalByteCount ?? 0 }
                })
                guard let publication = try self.generationGate.commitIfCurrent(
                    itemID: id,
                    generation: generation,
                    {
                        try self.fileStore.republish(
                            candidateURL: candidate.url,
                            sourceURL: sourceURL,
                            format: format,
                            currentPublishedURL: currentURL,
                            currentFingerprint: currentFingerprint,
                            fixedDestinationDirectory: destination
                        )
                    }
                ) else {
                    self.finishStaleRecompression(itemID: id, generation: generation)
                    return
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.finishRecompression(
                            itemID: id,
                            generation: generation,
                            candidate: candidate,
                            publication: publication,
                            error: nil
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.finishRecompression(
                            itemID: id,
                            generation: generation,
                            candidate: nil,
                            publication: nil,
                            error: error
                        )
                    }
                }
            }
        }
    }

    private func publishExistingCandidate(format: LitheImageFormat) {
        guard let id = model.inspectorItemID,
              let item = model.item(id: id),
              item.selectedFormat != format,
              let candidate = format == .png ? item.pngCandidate : item.jpegCandidate else { return }
        compressionEngine.cancel(itemID: id)
        let generation = generationGate.begin(itemID: id)
        guard generation >= 0 else { return }
        item.generation = generation
        item.isRecompressing = true
        item.generationFailureMessage = nil
        activeRecompressionCount += 1
        model.activities.insert(.recompressing)
        let sourceURL = item.sourceURL
        let currentURL = item.publishedURL
        let currentFingerprint = item.publishedFingerprint
        let originalBytes = item.originalByteCount
        let destination = fixedDestinationDirectory()

        worker.async { [weak self] in
            guard let self else { return }
            guard !self.cancellationState.isCancelled,
                  self.generationGate.isCurrent(itemID: id, generation: generation) else {
                self.finishStaleRecompression(itemID: id, generation: generation)
                return
            }
            do {
                try self.validateManuallySelectedCandidate(candidate, originalBytes: originalBytes)
                guard let publication = try self.generationGate.commitIfCurrent(
                    itemID: id,
                    generation: generation,
                    {
                        try self.fileStore.republish(
                            candidateURL: candidate.url,
                            sourceURL: sourceURL,
                            format: format,
                            currentPublishedURL: currentURL,
                            currentFingerprint: currentFingerprint,
                            fixedDestinationDirectory: destination
                        )
                    }
                ) else {
                    self.finishStaleRecompression(itemID: id, generation: generation)
                    return
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.finishRecompression(
                            itemID: id,
                            generation: generation,
                            candidate: candidate,
                            publication: publication,
                            error: nil
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.finishRecompression(
                            itemID: id,
                            generation: generation,
                            candidate: nil,
                            publication: nil,
                            error: error
                        )
                    }
                }
            }
        }
    }

    private nonisolated func validateRecompressedCandidate(
        _ candidate: CompressionCandidate,
        originalBytes: Int64
    ) throws {
        guard ExplicitRecompressionPolicy.accepts(
            originalBytes: originalBytes,
            resultBytes: candidate.byteCount
        ) else {
            throw CompressionEngineError.validationFailed("重新压缩结果并未小于原图")
        }
    }

    private nonisolated func validateManuallySelectedCandidate(
        _ candidate: CompressionCandidate,
        originalBytes: Int64
    ) throws {
        guard ExplicitRecompressionPolicy.accepts(
            originalBytes: originalBytes,
            resultBytes: candidate.byteCount
        ) else {
            throw CompressionEngineError.validationFailed("所选结果并未小于原图")
        }
    }

    private nonisolated func finishStaleRecompression(itemID: UUID, generation: Int) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.finishRecompression(
                    itemID: itemID,
                    generation: generation,
                    candidate: nil,
                    publication: nil,
                    error: nil
                )
            }
        }
    }

    private func finishRecompression(
        itemID: UUID,
        generation: Int,
        candidate: CompressionCandidate?,
        publication: (URL, PublishedFingerprint, preservedOldOutput: Bool)?,
        error: Error?
    ) {
        defer {
            activeRecompressionCount = max(0, activeRecompressionCount - 1)
            if activeRecompressionCount == 0 { model.activities.remove(.recompressing) }
            resetAutoCloseTimer()
        }
        guard let item = model.item(id: itemID), item.generation == generation else { return }
        item.isRecompressing = false
        if let error {
            item.generationFailureMessage = error.localizedDescription
            model.bannerMessage = error.localizedDescription
            return
        }
        guard let candidate, let publication else { return }
        if candidate.format == .png {
            item.pngCandidate = candidate
        } else {
            item.jpegCandidate = candidate
        }
        item.selectedFormat = candidate.format
        item.publishedURL = publication.0
        item.publishedFingerprint = publication.1
        item.preservedOldOutput = publication.preservedOldOutput
        item.generationFailureMessage = nil
        item.reviewRecommended = false
        item.thumbnail = NSImage(contentsOf: candidate.url)
        item.status = .ready
        if publication.preservedOldOutput {
            model.bannerMessage = "旧输出已被修改，因此已保留"
        }
        refreshClipboardAfterInspectorChange()
        showPanel()
    }

    private func refreshClipboardAfterInspectorChange() {
        guard UserDefaults.standard.bool(forKey: LitheDefaults.autoCopyResults) else { return }
        let urls = model.items.compactMap { item -> URL? in
            if item.status == .ready,
               let url = item.publishedURL,
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            if item.status == .noBenefit,
               FileManager.default.fileExists(atPath: item.sourceURL.path) {
                return item.sourceURL
            }
            return nil
        }
        LithePasteboard.write(fileURLs: urls, requestID: UUID())
    }

    private func createZip() {
        let values = model.selectedOrAllEffectiveItems()
        guard !values.isEmpty else { return }
        let entries = values.compactMap { item -> (URL, String)? in
            guard let url = item.effectiveResultURL else { return nil }
            let name = item.publishedURL?.lastPathComponent ?? item.sourceURL.lastPathComponent
            return (url, name)
        }
        guard !entries.isEmpty else { return }

        let directories = Set(values.map {
            ($0.publishedURL ?? $0.sourceURL).deletingLastPathComponent().standardizedFileURL
        })
        let baseName = Self.zipBaseName()
        let requestedURL: URL
        if directories.count == 1, let directory = directories.first {
            requestedURL = directory.appendingPathComponent(baseName).appendingPathExtension("zip")
        } else {
            model.activities.insert(.systemPanel)
            autoCloseTimer?.invalidate()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(baseName).zip"
            panel.allowedContentTypes = [.zip]
            let response = panel.runModal()
            model.activities.remove(.systemPanel)
            guard response == .OK, let url = panel.url else {
                resetAutoCloseTimer()
                return
            }
            requestedURL = url
        }

        model.activities.insert(.zipping)
        autoCloseTimer?.invalidate()
        let includedIDs = values.map(\.id)
        let zipCommitID = UUID()
        let zipGeneration = generationGate.begin(itemID: zipCommitID)
        guard zipGeneration >= 0 else { return }
        let sessionURL = fileStore.rootURL
            .appendingPathComponent("archive-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        worker.async { [weak self] in
            guard let self else { return }
            guard !self.cancellationState.isCancelled else { return }
            do {
                try ZipService.createZip(
                    entries: entries.map { (sourceURL: $0.0, archiveName: $0.1) },
                    sessionURL: sessionURL,
                    fileStore: self.fileStore,
                    toolRunner: self.compressionEngine.toolRunner
                )
                guard !self.cancellationState.isCancelled,
                      let published = try self.generationGate.commitIfCurrent(
                        itemID: zipCommitID,
                        generation: zipGeneration,
                        {
                            try self.fileStore.publishArtifact(
                                sourceURL: sessionURL,
                                requestedURL: requestedURL
                            )
                        }
                      ) else { return }
                let artifact = ZipArtifact(
                    sessionURL: sessionURL,
                    publishedURL: published,
                    includedItemIDs: includedIDs
                )
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.model.zipItems.append(SessionZipItem(artifact: artifact))
                        self.model.activities.remove(.zipping)
                        if UserDefaults.standard.bool(forKey: LitheDefaults.autoCopyResults) {
                            LithePasteboard.write(fileURLs: [published], requestID: UUID())
                        }
                        self.showPanel()
                        self.resetAutoCloseTimer()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.model.activities.remove(.zipping)
                        self.model.bannerMessage = "ZIP 失败：\(error.localizedDescription)"
                        self.showPanel()
                        self.resetAutoCloseTimer()
                    }
                }
            }
        }
    }

    private func trashAllEligibleOriginals() {
        let ids = model.items.filter { $0.status == .ready }.map(\.id)
        trashOriginals(itemIDs: ids, automatic: false)
    }

    private func trashOriginals(itemIDs: [UUID], automatic: Bool) {
        let candidates = itemIDs.compactMap { id -> TrashCandidate? in
            guard let item = model.item(id: id),
                  item.status == .ready,
                  item.trashedURL == nil,
                  let snapshotURL = item.snapshotURL,
                  let output = item.publishedURL,
                  let fingerprint = item.publishedFingerprint,
                  FileManager.default.fileExists(atPath: item.sourceURL.path),
                  !trashInFlightSourceURLs.contains(item.sourceURL.standardizedFileURL) else { return nil }
            return TrashCandidate(
                itemID: id,
                sourceURL: item.sourceURL,
                snapshotURL: snapshotURL,
                publishedURL: output,
                publishedFingerprint: fingerprint
            )
        }
        guard !candidates.isEmpty else {
            if !automatic { model.bannerMessage = "没有可移到废纸篓的原图" }
            return
        }
        trashInFlightSourceURLs.formUnion(candidates.map { $0.sourceURL.standardizedFileURL })
        activeTrashCount += 1
        model.activities.insert(.trashing)
        autoCloseTimer?.invalidate()
        worker.async { [weak self] in
            guard let self else { return }
            let valid = candidates.filter {
                self.fileStore.matchesPublishedFile(
                    url: $0.publishedURL,
                    fingerprint: $0.publishedFingerprint
                ) && self.fileStore.contentsMatch($0.sourceURL, $0.snapshotURL)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.cancellationState.isCancelled else { return }
                    guard !valid.isEmpty else {
                        self.completeTrashOperation(
                            count: 0,
                            skipped: candidates.count,
                            automatic: automatic,
                            completedSources: candidates.map(\.sourceURL)
                        )
                        return
                    }
                    let uniqueSources = TrashDeduplication.uniqueStandardizedURLs(valid.map(\.sourceURL))
                    SystemActions.recycle(uniqueSources) { mappings, error in
                        self.worker.async {
                            let audit = self.auditRecycledFiles(
                                mappings: mappings,
                                allCandidates: candidates,
                                initiallyValidCandidates: valid
                            )
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    self.finishAuditedTrashOperation(
                                        audit,
                                        requestedSourceCount: uniqueSources.count,
                                        recycleError: error,
                                        automatic: automatic,
                                        completedSources: candidates.map(\.sourceURL)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private nonisolated func auditRecycledFiles(
        mappings: [URL: URL],
        allCandidates: [TrashCandidate],
        initiallyValidCandidates: [TrashCandidate]
    ) -> TrashRecycleAudit {
        let allBySource = Dictionary(grouping: allCandidates) {
            $0.sourceURL.standardizedFileURL
        }
        let validBySource = Dictionary(grouping: initiallyValidCandidates) {
            $0.sourceURL.standardizedFileURL
        }
        var accepted: [AuditedTrashMove] = []
        var unresolved: [AuditedTrashMove] = []
        var restoredChangedFiles = 0

        for (source, trashed) in mappings {
            let standardizedSource = source.standardizedFileURL
            guard let allForSource = allBySource[standardizedSource],
                  let canonical = allForSource.first,
                  let validForSource = validBySource[standardizedSource] else { continue }
            let move = AuditedTrashMove(
                itemIDs: allForSource.map(\.itemID),
                recordItemID: canonical.itemID,
                originalURL: source,
                trashedURL: trashed
            )
            let movedOriginal = validForSource.contains {
                fileStore.contentsMatch(trashed, $0.snapshotURL)
            }
            let outputStillValid = validForSource.contains {
                fileStore.matchesPublishedFile(
                    url: $0.publishedURL,
                    fingerprint: $0.publishedFingerprint
                )
            }
            if movedOriginal, outputStillValid {
                accepted.append(move)
                continue
            }

            let restoreURL = FileManager.default.fileExists(atPath: source.path)
                ? OutputNaming.restoredURL(originalURL: source)
                : source
            do {
                try FileManager.default.moveItem(at: trashed, to: restoreURL)
                restoredChangedFiles += 1
            } catch {
                unresolved.append(move)
            }
        }
        return TrashRecycleAudit(
            accepted: accepted,
            unresolved: unresolved,
            restoredChangedFiles: restoredChangedFiles
        )
    }

    private func finishAuditedTrashOperation(
        _ audit: TrashRecycleAudit,
        requestedSourceCount: Int,
        recycleError: Error?,
        automatic: Bool,
        completedSources: [URL]
    ) {
        for move in audit.accepted + audit.unresolved {
            for itemID in move.itemIDs {
                model.item(id: itemID)?.trashedURL = move.trashedURL
            }
            if !model.trashRecords.contains(where: { $0.trashedURL == move.trashedURL }) {
                model.trashRecords.append(TrashRecord(
                    itemID: move.recordItemID,
                    originalURL: move.originalURL,
                    trashedURL: move.trashedURL
                ))
            }
        }

        let acceptedCount = audit.accepted.count
        let skipped = max(0, requestedSourceCount - acceptedCount)
        let message: String?
        if !audit.unresolved.isEmpty {
            message = "检测到文件变化；\(audit.unresolved.count) 个恢复失败，可点击撤销"
        } else if audit.restoredChangedFiles > 0 {
            message = "检测到文件变化，已安全恢复 \(audit.restoredChangedFiles) 个文件"
        } else if let recycleError, acceptedCount == 0 {
            message = "移到废纸篓失败：\(recycleError.localizedDescription)"
        } else {
            message = nil
        }
        completeTrashOperation(
            count: acceptedCount,
            skipped: skipped,
            automatic: automatic,
            completedSources: completedSources,
            message: message
        )
    }

    private func completeTrashOperation(
        count: Int,
        skipped: Int,
        automatic: Bool,
        completedSources: [URL],
        message: String? = nil
    ) {
        trashInFlightSourceURLs.subtract(completedSources.map { $0.standardizedFileURL })
        activeTrashCount = max(0, activeTrashCount - 1)
        if activeTrashCount == 0 { model.activities.remove(.trashing) }
        if let message {
            model.bannerMessage = message
        } else if count > 0 {
            model.bannerMessage = skipped > 0
                ? "已将 \(count) 个原文件移到废纸篓，跳过 \(skipped) 个"
                : "已将 \(count) 个原文件移到废纸篓"
        } else if !automatic, model.bannerMessage == nil {
            model.bannerMessage = "原图或输出已变化，未执行操作"
        }
        showPanel()
        resetAutoCloseTimer()
    }

    private func undoTrash() {
        guard !model.trashRecords.isEmpty else { return }
        var planned: [(TrashRecord, URL)] = []
        for record in model.trashRecords {
            if FileManager.default.fileExists(atPath: record.originalURL.path) {
                model.activities.insert(.systemPanel)
                let alert = NSAlert()
                alert.messageText = "原位置已有同名文件"
                alert.informativeText = "是否将 \(record.originalURL.lastPathComponent) 恢复为新名称？"
                alert.addButton(withTitle: "恢复为新名称")
                alert.addButton(withTitle: "取消")
                let response = alert.runModal()
                model.activities.remove(.systemPanel)
                guard response == .alertFirstButtonReturn else { continue }
                planned.append((record, OutputNaming.restoredURL(originalURL: record.originalURL)))
            } else {
                planned.append((record, record.originalURL))
            }
        }
        guard !planned.isEmpty else {
            resetAutoCloseTimer()
            return
        }
        model.activities.insert(.undoing)
        autoCloseTimer?.invalidate()
        let workPlan = planned
        worker.async { [weak self] in
            guard let self else { return }
            var restoredDestinations: [UUID: URL] = [:]
            var failureCount = 0
            for (record, destination) in workPlan {
                guard !self.cancellationState.isCancelled else {
                    failureCount += 1
                    continue
                }
                do {
                    try FileManager.default.moveItem(at: record.trashedURL, to: destination)
                    restoredDestinations[record.id] = destination
                } catch {
                    failureCount += 1
                }
            }
            let finalRestoredDestinations = restoredDestinations
            let finalFailureCount = failureCount
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let succeededSet = Set(finalRestoredDestinations.keys)
                    let restoredRecords = self.model.trashRecords.filter { succeededSet.contains($0.id) }
                    for record in restoredRecords {
                        guard let destination = finalRestoredDestinations[record.id] else { continue }
                        for item in self.model.items where item.trashedURL == record.trashedURL {
                            item.sourceURL = destination
                            item.trashedURL = nil
                        }
                    }
                    self.model.trashRecords.removeAll { succeededSet.contains($0.id) }
                    self.model.activities.remove(.undoing)
                    self.model.bannerMessage = finalFailureCount == 0
                        ? "已恢复 \(finalRestoredDestinations.count) 个原文件"
                        : "已恢复 \(finalRestoredDestinations.count) 个，\(finalFailureCount) 个失败"
                    self.showPanel()
                    self.resetAutoCloseTimer()
                }
            }
        }
    }

    private func requestClose() {
        if model.activities.contains(.trashing) || model.activities.contains(.undoing) {
            let alert = NSAlert()
            alert.messageText = "文件操作正在进行"
            alert.informativeText = "请等待废纸篓或恢复操作完成后再关闭。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            resetAutoCloseTimer()
            return
        }
        if model.isBusy {
            model.activities.insert(.systemPanel)
            let alert = NSAlert()
            alert.messageText = "停止任务并关闭？"
            alert.informativeText = "尚未完成的压缩或文件操作会停止。已发布的文件不会删除。"
            alert.addButton(withTitle: "停止并关闭")
            alert.addButton(withTitle: "继续等待")
            let response = alert.runModal()
            model.activities.remove(.systemPanel)
            guard response == .alertFirstButtonReturn else {
                resetAutoCloseTimer()
                return
            }
        }
        closeSession()
    }

    private func closeSession() {
        guard !model.isClosing else { return }
        model.isClosing = true
        autoCloseTimer?.invalidate()
        cancellationState.cancel()
        generationGate.cancelAll()
        compressionEngine.cancel()
        inspectorController?.close()
        panelController.hide()
        worker.async { [weak self] in
            guard let self else { return }
            self.fileStore.cleanup()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func setActivity(_ activity: SessionActivity, active: Bool) {
        if active {
            model.activities.insert(activity)
            autoCloseTimer?.invalidate()
        } else {
            model.activities.remove(activity)
            resetAutoCloseTimer()
        }
    }

    private func resetAutoCloseTimer() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        guard !model.shouldPauseAutoClose, !model.isClosing else { return }
        let interval = UserDefaults.standard.double(forKey: LitheDefaults.autoCloseInterval)
        guard interval > 0 else { return }
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.closeSession() }
        }
    }

    private func showPanel() {
        guard model.allowsResultPanelPresentation else { return }
        panelController.show(
            itemCount: model.items.count + model.zipItems.count,
            hasBanner: model.bannerMessage != nil
        )
    }

    private func fixedDestinationDirectory() -> URL? {
        let path = UserDefaults.standard.string(forKey: LitheDefaults.fixedOutputDirectory) ?? ""
        guard !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func isSupportedRegularImage(_ url: URL) -> Bool {
        guard ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return true
    }

    private static func zipBaseName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Lithe-\(formatter.string(from: Date()))"
    }
}

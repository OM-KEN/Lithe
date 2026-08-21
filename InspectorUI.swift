import AppKit
import ImageIO
import SwiftUI

enum InspectorBackground: String, CaseIterable {
    case transparent
    case black
    case white

    var symbol: String {
        switch self {
        case .transparent: "square.dashed"
        case .black: "moon.fill"
        case .white: "sun.max.fill"
        }
    }

    var displayName: String {
        switch self {
        case .transparent: "透明"
        case .black: "黑色"
        case .white: "白色"
        }
    }
}

private enum InspectorColumnRole: Hashable {
    case source
    case png
    case jpeg
}

struct InspectorActions {
    let close: () -> Void
    let previous: () -> Void
    let next: () -> Void
    let selectCandidate: (LitheImageFormat) -> Void
    let recompress: (CompressionQuality) -> Void
    let preparePNGPaletteCandidates: () -> Void
    let selectPNGCandidate: (UUID) -> Void
}

@MainActor
final class InspectorWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let onClose: () -> Void

    init(
        model: SessionModel,
        actions: InspectorActions,
        visibleFrame: NSRect?,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        let visible = visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 720)
        let size = NSSize(
            width: min(1200, max(1, visible.width - 48)),
            height: min(720, max(1, visible.height - 48))
        )
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.delegate = self
        window.title = "检查压缩结果"
        window.minSize = NSSize(width: min(760, size.width), height: min(520, size.height))
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.appearance = NSAppearance(named: .darkAqua)
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        let hostingView = NSHostingView(
            rootView: InspectorView(model: model, actions: actions)
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        window.contentView = effectView
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.safeAreaLayoutGuide.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        let frameSize = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: min(max(visible.midX - frameSize.width / 2, visible.minX), visible.maxX - frameSize.width),
            y: min(max(visible.midY - frameSize.height / 2, visible.minY), visible.maxY - frameSize.height)
        ))
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

struct InspectorView: View {
    let model: SessionModel
    let actions: InspectorActions
    @State private var quality: CompressionQuality = .default
    @State private var advancedLevel = Double(QualityLevel.six.rawValue)
    @State private var isAdvancedExpanded = false
    @State private var isEditingAdvanced = false
    @State private var advancedDebounceTask: Task<Void, Never>?
    @State private var pngCandidatePosition = 0.0
    @State private var isEditingPNGCandidate = false
    @State private var pngCandidateDebounceTask: Task<Void, Never>?
    @State private var background: InspectorBackground = .transparent
    @State private var pendingFormat: LitheImageFormat?
    @StateObject private var viewportGroup = SynchronizedViewportGroup()

    var body: some View {
        Group {
            if let item = currentItem {
                VStack(spacing: 0) {
                    header(item)
                        .background(Color.black.opacity(0.16))
                    Divider()
                    comparison(item)
                        .id(item.id)
                    Divider()
                    controls(item)
                        .background(Color.black.opacity(0.16))
                }
                .onChange(of: item.id) { _, _ in
                    synchronizeQuality(from: item)
                    synchronizePNGCandidate(from: item)
                    pendingFormat = nil
                    viewportGroup.resetToActualSize()
                }
                .onChange(of: item.selectedCandidate?.id) { _, _ in
                    synchronizeQuality(from: item)
                    synchronizePNGCandidate(from: item)
                }
                .onChange(of: item.pngPreparationState) { _, state in
                    if state == .ready { synchronizePNGCandidate(from: item) }
                }
                .onChange(of: item.isRecompressing) { _, isRecompressing in
                    if !isRecompressing { pendingFormat = nil }
                }
                .onChange(of: item.generationFailureMessage) { _, message in
                    guard message != nil, !item.isRecompressing else { return }
                    synchronizeQuality(from: item)
                }
                .onAppear {
                    synchronizeQuality(from: item)
                    synchronizePNGCandidate(from: item)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        viewportGroup.resetToActualSize()
                    }
                }
                .onDisappear {
                    advancedDebounceTask?.cancel()
                    pngCandidateDebounceTask?.cancel()
                }
            } else {
                ContentUnavailableView("没有可检查的图片", systemImage: "photo.badge.exclamationmark")
            }
        }
    }

    private var currentItem: SessionItem? {
        guard let id = model.inspectorItemID else { return nil }
        return model.item(id: id)
    }

    private func header(_ item: SessionItem) -> some View {
        HStack(spacing: 12) {
            Button(action: actions.previous) { Image(systemName: "chevron.left") }
                .help("上一张")
                .accessibilityLabel("上一张")
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button(action: actions.next) { Image(systemName: "chevron.right") }
                .help("下一张")
                .accessibilityLabel("下一张")
                .keyboardShortcut(.rightArrow, modifiers: [])
            Text(item.sourceURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(positionText(item))
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private func comparison(_ item: SessionItem) -> some View {
        let loadingFormat = pendingFormat ?? activeFormat(item)
        return HStack(spacing: 1) {
            if let snapshot = item.snapshotURL {
                comparisonColumn(
                    role: .source,
                    title: "原图",
                    detail: byteString(item.originalByteCount),
                    url: snapshot,
                    format: nil,
                    isSelected: false,
                    isLoading: false,
                    qualityWarning: nil,
                    background: background
                )
            }
            if let png = displayedPNGCandidate(item) {
                comparisonColumn(
                    role: .png,
                    title: "PNG",
                    detail: candidateDetail(png, original: item.originalByteCount),
                    url: png.url,
                    format: .png,
                    isSelected: item.selectedFormat == .png,
                    isLoading: item.isRecompressing && loadingFormat == .png,
                    qualityWarning: qualityWarning(png),
                    background: background
                )
            }
            if let jpeg = item.jpegCandidate {
                comparisonColumn(
                    role: .jpeg,
                    title: "JPEG",
                    detail: candidateDetail(jpeg, original: item.originalByteCount),
                    url: jpeg.url,
                    format: .jpeg,
                    isSelected: item.selectedFormat == .jpeg,
                    isLoading: item.isRecompressing && loadingFormat == .jpeg,
                    qualityWarning: qualityWarning(jpeg),
                    background: background
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func comparisonColumn(
        role: InspectorColumnRole,
        title: String,
        detail: String,
        url: URL,
        format: LitheImageFormat?,
        isSelected: Bool,
        isLoading: Bool,
        qualityWarning: String?,
        background: InspectorBackground
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold)
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                if let qualityWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help(qualityWarning)
                        .accessibilityLabel(qualityWarning)
                }
                Text(detail).foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.black.opacity(0.14))
            SynchronizedImageCanvas(
                url: url,
                background: background,
                isSelected: isSelected,
                group: viewportGroup,
                onSelect: {
                    if let format, !isSelected {
                        pendingFormat = format
                        actions.selectCandidate(format)
                    }
                }
            )
            .id(role)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay {
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.24)
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.regular)
                            Text("正在重新压缩…")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                Rectangle()
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func controls(_ item: SessionItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if activeFormat(item) == .png {
                    pngControls(item)
                } else {
                    jpegControls(item)
                }

                Picker("背景", selection: $background) {
                    ForEach(InspectorBackground.allCases, id: \.self) { value in
                        Image(systemName: value.symbol)
                            .accessibilityLabel(value.displayName)
                            .tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
                .help("画布背景")

                if !item.isRecompressing, let message = item.generationFailureMessage {
                    Label("重新压缩失败", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(message)
                }

                Spacer()
                Button {
                    viewportGroup.fit()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .help("适应窗口")
                .accessibilityLabel("适应窗口")
                Button("100%") { viewportGroup.resetToActualSize() }
                    .help("按实际像素显示")
                Button(action: actions.close) {
                    Image(systemName: "xmark")
                }
                .help("关闭检查")
                .accessibilityLabel("关闭检查")
            }
            .padding(.horizontal, 16)
            .frame(height: activeFormat(item) == .png ? 64 : 54)

            if activeFormat(item) == .jpeg, isAdvancedExpanded {
                Divider()
                advancedControls(item)
            }
        }
    }

    @ViewBuilder
    private func jpegControls(_ item: SessionItem) -> some View {
        Picker("质量", selection: quickPresetBinding(item)) {
            ForEach(QualityPreset.allCases, id: \.self) { value in
                Text(value.displayName).tag(Optional(value))
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 260)

        Button {
            advancedDebounceTask?.cancel()
            isAdvancedExpanded.toggle()
            if isAdvancedExpanded {
                advancedLevel = Double(quality.level.rawValue)
            }
        } label: {
            HStack(spacing: 4) {
                Text(quality.preset == nil ? quality.displayName : "高级")
                Image(systemName: isAdvancedExpanded ? "chevron.down" : "chevron.right")
            }
        }
        .buttonStyle(.bordered)
        .tint(quality.preset == nil ? .accentColor : .secondary)
        .help(quality.preset == nil ? quality.displayName : "展开高级质量")
    }

    @ViewBuilder
    private func pngControls(_ item: SessionItem) -> some View {
        switch item.pngPreparationState {
        case .idle:
            if let candidate = displayedPNGCandidate(item) {
                Text(pngCandidateSummary(candidate))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Button("进一步减小…", action: actions.preparePNGPaletteCandidates)
                .buttonStyle(.borderedProminent)
        case .preparing:
            ProgressView()
                .controlSize(.small)
            Text("正在准备更小的 PNG 结果…")
                .font(.system(size: 12, weight: .medium))
        case .ready:
            if item.pngCandidates.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("更小")
                        Slider(
                            value: $pngCandidatePosition,
                            in: 0 ... Double(max(0, item.pngCandidates.count - 1)),
                            step: 1,
                            onEditingChanged: { editing in
                                isEditingPNGCandidate = editing
                                pngCandidateDebounceTask?.cancel()
                                if !editing { submitPNGCandidate(item: item) }
                            }
                        )
                        .frame(width: 260)
                        .onChange(of: pngCandidatePosition) { _, _ in
                            guard !isEditingPNGCandidate else { return }
                            schedulePNGCandidateSubmission(itemID: item.id)
                        }
                        Text("更清晰")
                    }
                    if let candidate = displayedPNGCandidate(item) {
                        Text(pngCandidateSummary(candidate))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    if let candidate = displayedPNGCandidate(item) {
                        Text(pngCandidateSummary(candidate))
                            .font(.system(size: 12))
                    }
                    Text("此图片没有更小且有效的调色板结果。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        case let .failed(message):
            if let candidate = displayedPNGCandidate(item) {
                Text(pngCandidateSummary(candidate))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Label("准备失败：\(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(message)
            Button("重试", action: actions.preparePNGPaletteCandidates)
        }
    }

    private func advancedControls(_ item: SessionItem) -> some View {
        let level = QualityLevel(rawValue: Int(advancedLevel.rounded())) ?? .six
        return HStack(spacing: 12) {
            Text("高级")
                .font(.system(size: 12, weight: .semibold))
            Slider(
                value: $advancedLevel,
                in: 1 ... 10,
                step: 1,
                onEditingChanged: { editing in
                    isEditingAdvanced = editing
                    advancedDebounceTask?.cancel()
                    if !editing { submitAdvanced(level: currentAdvancedLevel, item: item) }
                }
            )
            .help("调整压缩质量")
            .frame(width: 300)
            .onChange(of: advancedLevel) { _, _ in
                guard AdvancedQualityInteractionPolicy.shouldScheduleSettledChange(
                    level: currentAdvancedLevel,
                    isEditing: isEditingAdvanced,
                    displayedQuality: quality
                ) else { return }
                scheduleAdvancedSubmission(itemID: item.id)
            }
            Text("\(level.rawValue)/10")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
            Text(parameterSummary(level: level, format: activeFormat(item)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private func positionText(_ item: SessionItem) -> String {
        let values = model.inspectableItems
        guard let index = values.firstIndex(where: { $0.id == item.id }) else { return "" }
        return "\(index + 1) / \(values.count)"
    }

    private func activeFormat(_ item: SessionItem) -> LitheImageFormat? {
        item.selectedFormat ?? item.pngCandidate?.format ?? item.jpegCandidate?.format ?? item.inputFormat
    }

    private func displayedPNGCandidate(_ item: SessionItem) -> CompressionCandidate? {
        guard activeFormat(item) == .png,
              item.pngPreparationState == .ready,
              !item.pngCandidates.isEmpty else { return item.pngCandidate }
        let index = min(
            max(0, Int(pngCandidatePosition.rounded())),
            item.pngCandidates.count - 1
        )
        return item.pngCandidates[index]
    }

    private var currentAdvancedLevel: QualityLevel {
        QualityLevel(rawValue: Int(advancedLevel.rounded())) ?? .six
    }

    private func quickPresetBinding(_ item: SessionItem) -> Binding<QualityPreset?> {
        Binding(
            get: { quality.preset },
            set: { newValue in
                guard let newValue else { return }
                isAdvancedExpanded = false
                submitQuality(.preset(newValue), item: item)
            }
        )
    }

    private func synchronizeQuality(from item: SessionItem) {
        advancedDebounceTask?.cancel()
        let selectedQuality = item.selectedCandidate?.quality ?? .default
        quality = selectedQuality
        advancedLevel = Double(selectedQuality.level.rawValue)
    }

    private func synchronizePNGCandidate(from item: SessionItem) {
        pngCandidateDebounceTask?.cancel()
        guard !item.pngCandidates.isEmpty else {
            pngCandidatePosition = 0
            return
        }
        let selectedIndex = item.selectedPNGCandidateID.flatMap { selectedID in
            item.pngCandidates.firstIndex { $0.id == selectedID }
        } ?? (item.pngCandidates.count - 1)
        pngCandidatePosition = Double(selectedIndex)
    }

    private func submitAdvanced(level: QualityLevel, item: SessionItem) {
        guard AdvancedQualityInteractionPolicy.shouldSubmit(
            level: level,
            isEditing: isEditingAdvanced,
            currentQuality: item.selectedCandidate?.quality
        ) else {
            quality = .advanced(level)
            return
        }
        submitQuality(.advanced(level), item: item)
    }

    private func submitQuality(_ requested: CompressionQuality, item: SessionItem) {
        advancedDebounceTask?.cancel()
        if quality == requested, item.isRecompressing { return }
        quality = requested
        guard item.selectedCandidate?.quality != requested else { return }
        pendingFormat = activeFormat(item)
        actions.recompress(requested)
    }

    private func scheduleAdvancedSubmission(itemID: UUID) {
        let level = currentAdvancedLevel
        advancedDebounceTask?.cancel()
        advancedDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: AdvancedQualityInteractionPolicy.debounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let item = currentItem,
                  item.id == itemID else { return }
            submitAdvanced(level: level, item: item)
        }
    }

    private func submitPNGCandidate(item: SessionItem) {
        pngCandidateDebounceTask?.cancel()
        guard !item.pngCandidates.isEmpty else { return }
        let index = min(
            max(0, Int(pngCandidatePosition.rounded())),
            item.pngCandidates.count - 1
        )
        let candidate = item.pngCandidates[index]
        guard item.selectedFormat != .png || item.selectedPNGCandidateID != candidate.id else { return }
        pendingFormat = .png
        actions.selectPNGCandidate(candidate.id)
    }

    private func schedulePNGCandidateSubmission(itemID: UUID) {
        pngCandidateDebounceTask?.cancel()
        pngCandidateDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: AdvancedQualityInteractionPolicy.debounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let item = currentItem,
                  item.id == itemID else { return }
            submitPNGCandidate(item: item)
        }
    }

    private func qualityWarning(_ candidate: CompressionCandidate) -> String? {
        guard candidate.isBelowReferenceQuality else { return nil }
        if candidate.format == .png {
            return "此 PNG 结果低于质量参考，建议以 100% 大小检查文字、边缘和渐变。"
        }
        return "此结果低于当前档位的质量参考，建议以 100% 大小检查文字、边缘和渐变。"
    }

    private func parameterSummary(
        level: QualityLevel,
        format: LitheImageFormat?
    ) -> String {
        let parameters = level.parameters
        let reference = Int((parameters.referenceSSIM * 100).rounded())
        switch format {
        case .jpeg:
            return "JPEG · Jpegli Q\(parameters.jpegQualityPercent) · SSIM 参考 \(reference)"
        case .png:
            return "PNG · 调色板压缩 · 质量参考 \(reference)/100"
        case nil:
            return "SSIM 参考 \(reference)"
        }
    }

    private func candidateDetail(_ candidate: CompressionCandidate, original: Int64) -> String {
        let reduction = original > 0
            ? Int((Double(original - candidate.byteCount) / Double(original) * 100).rounded())
            : 0
        if candidate.format == .png {
            return "\(byteString(candidate.byteCount)) · −\(max(0, reduction))% · 相似度 \(similarityString(candidate))"
        }
        return "\(byteString(candidate.byteCount)) · −\(max(0, reduction))% · \(candidate.quality.displayName)"
    }

    private func pngCandidateSummary(_ candidate: CompressionCandidate) -> String {
        "\(byteString(candidate.byteCount)) · 视觉相似度 \(similarityString(candidate))"
    }

    private func similarityString(_ candidate: CompressionCandidate) -> String {
        String(format: "%.1f", candidate.ssim * 100)
    }

    private func byteString(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

@MainActor
final class SynchronizedViewportGroup: ObservableObject {
    private var canvases: [WeakCanvas] = []
    private var isSynchronizing = false
    private var currentState = ViewportState(magnification: 1, centerX: 0.5, centerY: 0.5)

    func register(_ canvas: InspectorCanvasView) {
        canvases.removeAll { $0.value == nil }
        if !canvases.contains(where: { $0.value === canvas }) {
            canvases.append(WeakCanvas(value: canvas))
            apply(currentState, to: canvas)
        }
    }

    func unregister(_ canvas: InspectorCanvasView) {
        canvases.removeAll { $0.value == nil || $0.value === canvas }
    }

    func setViewport(_ proposedState: ViewportState, from source: InspectorCanvasView) {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        source.apply(proposedState)
        let canonicalState = source.viewportState
        currentState = canonicalState
        for canvas in canvases.compactMap(\.value) where canvas !== source {
            canvas.apply(canonicalState)
        }
    }

    func didScroll(_ source: InspectorCanvasView) {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        let state = source.viewportState
        currentState = state
        for canvas in canvases.compactMap(\.value) where canvas !== source {
            canvas.apply(state)
        }
    }

    func reapply(to canvas: InspectorCanvasView) {
        guard !isSynchronizing,
              canvases.contains(where: { $0.value === canvas }) else { return }
        apply(currentState, to: canvas)
    }

    func fit() {
        guard let first = canvases.compactMap(\.value).first else { return }
        let magnification = first.fitMagnification
        applyToAll(ViewportState(magnification: magnification, centerX: 0.5, centerY: 0.5))
    }

    func setMagnification(_ value: CGFloat) {
        let center = canvases.compactMap(\.value).first?.viewportState ?? currentState
        applyToAll(ViewportState(
            magnification: min(8, max(0.25, value)),
            centerX: center.centerX,
            centerY: center.centerY
        ))
    }

    func resetToActualSize() {
        applyToAll(ViewportState(magnification: 1, centerX: 0.5, centerY: 0.5))
    }

    private func applyToAll(_ state: ViewportState) {
        guard let first = canvases.compactMap(\.value).first else {
            currentState = state
            return
        }
        isSynchronizing = true
        defer { isSynchronizing = false }
        first.apply(state)
        let canonicalState = first.viewportState
        currentState = canonicalState
        for canvas in canvases.compactMap(\.value) where canvas !== first {
            canvas.apply(canonicalState)
        }
    }

    private func apply(_ state: ViewportState, to canvas: InspectorCanvasView) {
        isSynchronizing = true
        defer { isSynchronizing = false }
        canvas.apply(state)
    }
}

private struct WeakCanvas {
    weak var value: InspectorCanvasView?
}

struct ViewportState {
    let magnification: CGFloat
    let centerX: CGFloat
    let centerY: CGFloat
}

struct SynchronizedImageCanvas: NSViewRepresentable {
    let url: URL
    let background: InspectorBackground
    let isSelected: Bool
    let group: SynchronizedViewportGroup
    let onSelect: () -> Void

    func makeNSView(context: Context) -> InspectorCanvasView {
        let view = InspectorCanvasView()
        view.viewportGroup = group
        view.update(url: url, background: background, isSelected: isSelected, onSelect: onSelect)
        group.register(view)
        return view
    }

    func updateNSView(_ nsView: InspectorCanvasView, context: Context) {
        nsView.viewportGroup = group
        nsView.update(url: url, background: background, isSelected: isSelected, onSelect: onSelect)
    }

    static func dismantleNSView(_ nsView: InspectorCanvasView, coordinator: ()) {
        nsView.viewportGroup?.unregister(nsView)
    }
}

final class InspectorCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        guard let documentView else { return super.constrainBoundsRect(proposedBounds) }
        let document = documentView.frame
        var constrained = proposedBounds

        if document.width <= proposedBounds.width {
            constrained.origin.x = document.midX - proposedBounds.width / 2
        } else {
            constrained.origin.x = min(
                max(proposedBounds.origin.x, document.minX),
                document.maxX - proposedBounds.width
            )
        }
        if document.height <= proposedBounds.height {
            constrained.origin.y = document.midY - proposedBounds.height / 2
        } else {
            constrained.origin.y = min(
                max(proposedBounds.origin.y, document.minY),
                document.maxY - proposedBounds.height
            )
        }
        return constrained
    }
}

final class InspectorZoomScrollView: NSScrollView {
    var onScrollZoom: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScrollZoom?(event)
    }
}

final class InspectorCanvasView: NSView {
    private let scrollView = InspectorZoomScrollView()
    private let clipView = InspectorCenteringClipView()
    private let imageView = InspectorImageDocumentView()
    private var observedURL: URL?
    private var backgroundMode: InspectorBackground = .transparent {
        didSet { needsDisplay = true }
    }
    private var panStartWindowPoint: NSPoint?
    private var panStartViewportState: ViewportState?
    private var lastViewportSize = NSSize.zero
    private var suppressViewportReporting = false
    weak var viewportGroup: SynchronizedViewportGroup?
    private var boundsObserver: NSObjectProtocol?
    private var magnifyObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        layer?.masksToBounds = true
        scrollView.clipsToBounds = true
        clipView.clipsToBounds = true
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 8
        scrollView.documentView = imageView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onScrollZoom = { [weak self] event in
            self?.zoom(with: event)
        }
        imageView.onPanBegan = { [weak self] event in
            self?.beginPanning(with: event)
        }
        imageView.onPanChanged = { [weak self] event in
            self?.continuePanning(with: event)
        }
        imageView.onPanEnded = { [weak self] in
            self?.endPanning()
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Keep these callbacks synchronous: applying a peer viewport emits more
        // bounds notifications while the group's recursion guard is active.
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.suppressViewportReporting else { return }
                self.viewportGroup?.didScroll(self)
            }
        }
        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.suppressViewportReporting else { return }
                self.viewportGroup?.didScroll(self)
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let magnifyObserver { NotificationCenter.default.removeObserver(magnifyObserver) }
    }

    override func layout() {
        suppressViewportReporting = true
        super.layout()
        suppressViewportReporting = false
        guard lastViewportSize != bounds.size else { return }
        lastViewportSize = bounds.size
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let viewportGroup = self.viewportGroup {
                viewportGroup.reapply(to: self)
            } else {
                self.constrainViewport()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBackground(dirtyRect)
    }

    func update(
        url: URL,
        background: InspectorBackground,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) {
        backgroundMode = background
        imageView.isSelectedCandidate = isSelected
        imageView.onSelect = onSelect
        guard observedURL != url else {
            needsDisplay = true
            imageView.needsDisplay = true
            return
        }
        observedURL = url
        suppressViewportReporting = true
        imageView.image = Self.pixelSizedImage(url)
        imageView.frame = NSRect(origin: .zero, size: imageView.image?.size ?? .zero)
        suppressViewportReporting = false
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportGroup?.reapply(to: self)
        }
    }

    var viewportState: ViewportState {
        let documentBounds = imageView.bounds
        let visible = clipView.bounds
        return ViewportState(
            magnification: scrollView.magnification,
            centerX: documentBounds.width > 0
                ? min(1, max(0, visible.midX / documentBounds.width)) : 0.5,
            centerY: documentBounds.height > 0
                ? min(1, max(0, visible.midY / documentBounds.height)) : 0.5
        )
    }

    var fitMagnification: CGFloat {
        guard imageView.bounds.width > 0, imageView.bounds.height > 0 else { return 1 }
        let content = scrollView.contentSize
        return min(
            1,
            max(0.25, min(content.width / imageView.bounds.width, content.height / imageView.bounds.height))
        )
    }

    func apply(_ state: ViewportState) {
        guard imageView.bounds.width > 0, imageView.bounds.height > 0 else { return }
        suppressViewportReporting = true
        defer { suppressViewportReporting = false }
        let magnification = min(
            scrollView.maxMagnification,
            max(scrollView.minMagnification, state.magnification)
        )
        if abs(scrollView.magnification - magnification) > 0.0001 {
            scrollView.setMagnification(magnification, centeredAt: NSPoint(
                x: imageView.bounds.midX,
                y: imageView.bounds.midY
            ))
        }
        scrollView.layoutSubtreeIfNeeded()
        var proposed = clipView.bounds
        proposed.origin = NSPoint(
            x: imageView.bounds.width * min(1, max(0, state.centerX)) - proposed.width / 2,
            y: imageView.bounds.height * min(1, max(0, state.centerY)) - proposed.height / 2
        )
        let constrained = clipView.constrainBoundsRect(proposed)
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func zoom(with event: NSEvent) {
        guard imageView.image != nil,
              event.momentumPhase.isEmpty,
              event.scrollingDeltaY != 0 else { return }
        let boundedDelta = min(20, max(-20, event.scrollingDeltaY))
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.018 : 0.12
        let target = min(
            scrollView.maxMagnification,
            max(
                scrollView.minMagnification,
                scrollView.magnification * exp(boundedDelta * sensitivity)
            )
        )
        guard abs(target - scrollView.magnification) > 0.0001 else { return }
        let visible = clipView.bounds
        let cursor = imageView.convert(event.locationInWindow, from: nil)
        let cursorIsInsideImage = imageView.bounds.contains(cursor)
        let anchor = cursorIsInsideImage
            ? cursor
            : NSPoint(x: visible.midX, y: visible.midY)
        let fractionX = cursorIsInsideImage && visible.width > 0
            ? min(1, max(0, (anchor.x - visible.minX) / visible.width))
            : 0.5
        let fractionY = cursorIsInsideImage && visible.height > 0
            ? min(1, max(0, (anchor.y - visible.minY) / visible.height))
            : 0.5
        let scale = scrollView.magnification / target
        let newVisibleSize = NSSize(
            width: visible.width * scale,
            height: visible.height * scale
        )
        let proposed = ViewportState(
            magnification: target,
            centerX: (anchor.x + (0.5 - fractionX) * newVisibleSize.width) / imageView.bounds.width,
            centerY: (anchor.y + (0.5 - fractionY) * newVisibleSize.height) / imageView.bounds.height
        )
        if let viewportGroup {
            viewportGroup.setViewport(proposed, from: self)
        } else {
            apply(proposed)
        }
    }

    private func beginPanning(with event: NSEvent) {
        panStartWindowPoint = event.locationInWindow
        panStartViewportState = viewportState
        NSCursor.closedHand.set()
    }

    private func continuePanning(with event: NSEvent) {
        guard let start = panStartWindowPoint,
              let startState = panStartViewportState,
              imageView.bounds.width > 0,
              imageView.bounds.height > 0 else { return }
        let scale = max(startState.magnification, 0.0001)
        let deltaX = (event.locationInWindow.x - start.x) / scale
        let deltaY = (event.locationInWindow.y - start.y) / scale
        let proposed = ViewportState(
            magnification: startState.magnification,
            centerX: startState.centerX - deltaX / imageView.bounds.width,
            centerY: startState.centerY + deltaY / imageView.bounds.height
        )
        if let viewportGroup {
            viewportGroup.setViewport(proposed, from: self)
        } else {
            apply(proposed)
        }
    }

    private func endPanning() {
        panStartWindowPoint = nil
        panStartViewportState = nil
        NSCursor.openHand.set()
    }

    private func constrainViewport() {
        let constrained = clipView.constrainBoundsRect(clipView.bounds)
        guard constrained.origin != clipView.bounds.origin else { return }
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func drawBackground(_ rect: NSRect) {
        switch backgroundMode {
        case .transparent:
            NSGraphicsContext.current?.cgContext.clear(rect)
        case .black:
            NSColor.black.setFill()
            rect.fill()
        case .white:
            NSColor.white.setFill()
            rect.fill()
        }
    }

    private static func pixelSizedImage(_ url: URL) -> NSImage? {
        guard let cgImage = try? ImageDecoder.decode(url).image else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

final class InspectorImageDocumentView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var isSelectedCandidate = false
    var onSelect: (() -> Void)?
    var onPanBegan: ((NSEvent) -> Void)?
    var onPanChanged: ((NSEvent) -> Void)?
    var onPanEnded: (() -> Void)?
    private var mouseDownWindowPoint: NSPoint?
    private var didDrag = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        image?.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownWindowPoint = event.locationInWindow
        didDrag = false
        onPanBegan?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = mouseDownWindowPoint {
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            if hypot(dx, dy) >= 3 { didDrag = true }
        }
        guard didDrag else { return }
        onPanChanged?(event)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onSelect?() }
        onPanEnded?()
        mouseDownWindowPoint = nil
        didDrag = false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}

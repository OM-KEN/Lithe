import Foundation

final class GenerationCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [UUID: Int] = [:]
    private var isCancelled = false

    func begin(itemID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return -1 }
        let next = (generations[itemID] ?? 0) + 1
        generations[itemID] = next
        return next
    }

    func isCurrent(itemID: UUID, generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[itemID] == generation
    }

    /// The commit body runs while new generations for this gate are excluded.
    /// A stale generation never enters the body and therefore cannot publish files.
    func commitIfCurrent<T>(
        itemID: UUID,
        generation: Int,
        _ body: () throws -> T
    ) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, generations[itemID] == generation else { return nil }
        return try body()
    }

    func cancelAll() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }
}

final class SessionCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum ClipboardBatchResult: Equatable {
    case ready(URL)
    case noBenefit(URL)
    case failed
}

enum ClipboardBatchPolicy {
    static func URLs(for results: [ClipboardBatchResult]) -> [URL] {
        results.compactMap { result in
            switch result {
            case let .ready(url): url
            case let .noBenefit(url): results.count > 1 ? url : nil
            case .failed: nil
            }
        }
    }
}

enum TrashDeduplication {
    static func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.compactMap {
            let standardized = $0.standardizedFileURL
            return seen.insert(standardized).inserted ? standardized : nil
        }
    }
}

enum LitheImageFormat: String, Codable, CaseIterable, Sendable {
    case jpeg
    case png

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        }
    }

    var displayName: String { rawValue.uppercased() }
}

struct QualityEncodingParameters: Equatable, Sendable {
    let jpegQualityPercent: Int
    let referenceSSIM: Double

    var jpegQuality: Double { Double(jpegQualityPercent) / 100 }
}

enum QualityLevel: Int, Codable, CaseIterable, Sendable {
    case one = 1
    case two
    case three
    case four
    case five
    case six
    case seven
    case eight
    case nine
    case ten

    var parameters: QualityEncodingParameters {
        switch self {
        case .one: .init(jpegQualityPercent: 68, referenceSSIM: 0.78)
        case .two: .init(jpegQualityPercent: 76, referenceSSIM: 0.80)
        case .three: .init(jpegQualityPercent: 80, referenceSSIM: 0.83)
        case .four: .init(jpegQualityPercent: 84, referenceSSIM: 0.85)
        case .five: .init(jpegQualityPercent: 87, referenceSSIM: 0.88)
        case .six: .init(jpegQualityPercent: 90, referenceSSIM: 0.90)
        case .seven: .init(jpegQualityPercent: 92, referenceSSIM: 0.93)
        case .eight: .init(jpegQualityPercent: 94, referenceSSIM: 0.95)
        case .nine: .init(jpegQualityPercent: 95, referenceSSIM: 0.97)
        case .ten: .init(jpegQualityPercent: 96, referenceSSIM: 0.98)
        }
    }
}

enum QualityPreset: String, Codable, CaseIterable, Sendable {
    case smaller
    case balanced
    case clearer

    var displayName: String {
        switch self {
        case .smaller: "更小"
        case .balanced: "平衡"
        case .clearer: "更清晰"
        }
    }

    var jpegQuality: Double {
        qualityLevel.parameters.jpegQuality
    }

    var minimumSSIM: Double {
        qualityLevel.parameters.referenceSSIM
    }

    var qualityLevel: QualityLevel {
        switch self {
        case .smaller: .four
        case .balanced: .six
        case .clearer: .eight
        }
    }
}

enum CompressionQuality: Equatable, Sendable {
    case preset(QualityPreset)
    case advanced(QualityLevel)

    static let `default`: CompressionQuality = .preset(.balanced)

    var level: QualityLevel {
        switch self {
        case let .preset(preset): preset.qualityLevel
        case let .advanced(level): level
        }
    }

    var preset: QualityPreset? {
        guard case let .preset(preset) = self else { return nil }
        return preset
    }

    var displayName: String {
        switch self {
        case let .preset(preset): preset.displayName
        case let .advanced(level): "高级 · \(level.rawValue)/10"
        }
    }
}

enum AdvancedQualityInteractionPolicy {
    static let debounceNanoseconds: UInt64 = 250_000_000

    static func shouldScheduleSettledChange(
        level: QualityLevel,
        isEditing: Bool,
        displayedQuality: CompressionQuality
    ) -> Bool {
        !isEditing && displayedQuality.level != level
    }

    static func shouldSubmit(
        level: QualityLevel,
        isEditing: Bool,
        currentQuality: CompressionQuality?
    ) -> Bool {
        !isEditing && currentQuality != .advanced(level)
    }
}

struct CompressionCandidate: Identifiable, Sendable {
    let id: UUID
    let format: LitheImageFormat
    let url: URL
    let byteCount: Int64
    let ssim: Double
    let quality: CompressionQuality
    let backend: CompressionBackend
    let pngPaletteMaximumColors: Int?

    var isBelowReferenceQuality: Bool {
        ssim < (format == .png
            ? PNGPaletteCandidatePolicy.referenceSSIM
            : quality.level.parameters.referenceSSIM)
    }

    init(
        id: UUID = UUID(),
        format: LitheImageFormat,
        url: URL,
        byteCount: Int64,
        ssim: Double,
        quality: CompressionQuality,
        backend: CompressionBackend = .imageIO,
        pngPaletteMaximumColors: Int? = nil
    ) {
        self.id = id
        self.format = format
        self.url = url
        self.byteCount = byteCount
        self.ssim = ssim
        self.quality = quality
        self.backend = backend
        self.pngPaletteMaximumColors = pngPaletteMaximumColors
    }

    init(
        id: UUID = UUID(),
        format: LitheImageFormat,
        url: URL,
        byteCount: Int64,
        ssim: Double,
        preset: QualityPreset,
        backend: CompressionBackend = .imageIO,
        pngPaletteMaximumColors: Int? = nil
    ) {
        self.init(
            id: id,
            format: format,
            url: url,
            byteCount: byteCount,
            ssim: ssim,
            quality: .preset(preset),
            backend: backend,
            pngPaletteMaximumColors: pngPaletteMaximumColors
        )
    }
}

enum CompressionBackend: String, Sendable {
    case imageIO
    case pngquant
    case cjpegli
    case jpegtran
}

struct CandidateFacts: Equatable, Sendable {
    let format: LitheImageFormat
    let byteCount: Int64
    let ssim: Double
}

enum CompressionSelection: Equatable, Sendable {
    case candidate(format: LitheImageFormat, reviewRecommended: Bool)
    case noBenefit
}

enum CompressionPolicy {
    static let minimumAbsoluteSaving: Int64 = 8 * 1_024
    static let largeAbsoluteSaving: Int64 = 1_024 * 1_024
    static let minimumRelativeSaving = 0.05

    static func hasEffectiveSaving(originalBytes: Int64, resultBytes: Int64) -> Bool {
        guard originalBytes > 0, resultBytes > 0, resultBytes < originalBytes else {
            return false
        }
        let saving = originalBytes - resultBytes
        let relative = Double(saving) / Double(originalBytes)
        return saving >= minimumAbsoluteSaving
            && (relative >= minimumRelativeSaving || saving >= largeAbsoluteSaving)
    }

    static func choose(
        inputFormat: LitheImageFormat,
        hasTransparency: Bool,
        originalBytes: Int64,
        preset: QualityPreset,
        png: CandidateFacts?,
        jpeg: CandidateFacts?
    ) -> CompressionSelection {
        let acceptablePNG = png.flatMap {
            $0.ssim >= preset.minimumSSIM
                && hasEffectiveSaving(originalBytes: originalBytes, resultBytes: $0.byteCount)
                ? $0 : nil
        }
        let comparablePNG = png.flatMap {
            $0.ssim >= preset.minimumSSIM ? $0 : nil
        }
        let acceptableJPEG = jpeg.flatMap {
            $0.ssim >= preset.minimumSSIM
                && hasEffectiveSaving(originalBytes: originalBytes, resultBytes: $0.byteCount)
                ? $0 : nil
        }

        if inputFormat == .jpeg {
            guard let acceptableJPEG else { return .noBenefit }
            return .candidate(format: acceptableJPEG.format, reviewRecommended: false)
        }

        if hasTransparency {
            guard let acceptablePNG else { return .noBenefit }
            return .candidate(format: acceptablePNG.format, reviewRecommended: false)
        }

        // The PNG candidate is also the conservative visual/size baseline. It
        // need not itself clear the publication-saving threshold for a clearly
        // superior JPEG to win, but it must exist and pass the quality gate.
        guard let comparablePNG else { return .noBenefit }
        if let jpeg = acceptableJPEG {
            let jpegRatio = Double(jpeg.byteCount) / Double(max(1, comparablePNG.byteCount))
            if jpeg.ssim >= 0.95, jpegRatio <= 0.80 {
                return .candidate(format: .jpeg, reviewRecommended: false)
            }
            if acceptablePNG != nil, jpeg.ssim >= 0.90, jpegRatio <= 0.90 {
                return .candidate(format: .png, reviewRecommended: true)
            }
        }
        if let acceptablePNG {
            return .candidate(format: acceptablePNG.format, reviewRecommended: false)
        }
        return .noBenefit
    }
}

enum PNGPaletteCandidatePolicy {
    static let maximumColors = [64, 128, 192, 256]
    static let additionalPreparationOrder = [192, 128, 64]
    static let initialMaximumColors = 256
    static let referenceSSIM = 0.98

    static func effectiveCandidates(
        _ candidates: [CompressionCandidate],
        originalByteCount: Int64,
        preserving preservedCandidateID: UUID?
    ) -> [CompressionCandidate] {
        func isEligible(_ candidate: CompressionCandidate) -> Bool {
            candidate.format == .png
                && candidate.byteCount > 0
                && (candidate.byteCount < originalByteCount || candidate.id == preservedCandidateID)
        }

        var paletteByMaximumColors: [Int: CompressionCandidate] = [:]
        for candidate in candidates where isEligible(candidate) {
            guard let maximumColors = candidate.pngPaletteMaximumColors,
                  Self.maximumColors.contains(maximumColors) else { continue }
            if let existing = paletteByMaximumColors[maximumColors] {
                if existing.id == preservedCandidateID { continue }
                if candidate.id == preservedCandidateID || candidate.byteCount < existing.byteCount {
                    paletteByMaximumColors[maximumColors] = candidate
                }
            } else {
                paletteByMaximumColors[maximumColors] = candidate
            }
        }

        var ordered = paletteByMaximumColors.values.sorted {
            ($0.pngPaletteMaximumColors ?? 0) < ($1.pngPaletteMaximumColors ?? 0)
        }
        if let preservedCandidateID,
           let preserved = candidates.first(where: { $0.id == preservedCandidateID }),
           isEligible(preserved),
           preserved.pngPaletteMaximumColors == nil {
            ordered.append(preserved)
        }
        guard let clearest = ordered.last else { return [] }

        var retainedFromRight = [clearest]
        var previousRetained = clearest
        for candidate in ordered.dropLast().reversed() {
            if candidate.id == preservedCandidateID
                || CompressionPolicy.hasEffectiveSaving(
                    originalBytes: previousRetained.byteCount,
                    resultBytes: candidate.byteCount
                ) {
                retainedFromRight.append(candidate)
                previousRetained = candidate
            }
        }
        return retainedFromRight.reversed()
    }
}

enum ExplicitRecompressionPolicy {
    static func accepts(originalBytes: Int64, resultBytes: Int64) -> Bool {
        originalBytes > 0 && resultBytes > 0 && resultBytes < originalBytes
    }
}

struct CompressionResult: Sendable {
    let inputFormat: LitheImageFormat
    let hasTransparency: Bool
    let originalByteCount: Int64
    let pngCandidates: [CompressionCandidate]
    let selectedPNGCandidateID: UUID?
    let jpegCandidate: CompressionCandidate?
    let selectedFormat: LitheImageFormat?
    let reviewRecommended: Bool
    let candidateFailureMessage: String?

    var pngCandidate: CompressionCandidate? {
        guard let selectedPNGCandidateID else { return pngCandidates.last }
        return pngCandidates.first { $0.id == selectedPNGCandidateID } ?? pngCandidates.last
    }

    var selectedCandidate: CompressionCandidate? {
        switch selectedFormat {
        case .png: pngCandidate
        case .jpeg: jpegCandidate
        case nil: nil
        }
    }
}

enum PNGCandidatePreparationState: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case failed(String)
}

enum SessionItemStatus: Equatable, Sendable {
    case snapshotting
    case queued
    case processing
    case ready
    case noBenefit
    case failed(String)
}

struct PublishedFingerprint: Equatable, Codable, Sendable {
    let byteCount: Int64
    let modificationTime: TimeInterval
    let sha256: String
}

struct TrashRecord: Identifiable, Sendable {
    let id: UUID
    let itemID: UUID
    let originalURL: URL
    let trashedURL: URL

    init(id: UUID = UUID(), itemID: UUID, originalURL: URL, trashedURL: URL) {
        self.id = id
        self.itemID = itemID
        self.originalURL = originalURL
        self.trashedURL = trashedURL
    }
}

struct ZipArtifact: Identifiable, Sendable {
    let id: UUID
    let sessionURL: URL
    let publishedURL: URL
    let includedItemIDs: [UUID]

    init(
        id: UUID = UUID(),
        sessionURL: URL,
        publishedURL: URL,
        includedItemIDs: [UUID]
    ) {
        self.id = id
        self.sessionURL = sessionURL
        self.publishedURL = publishedURL
        self.includedItemIDs = includedItemIDs
    }
}

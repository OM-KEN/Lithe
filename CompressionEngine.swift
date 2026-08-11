import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CompressionEngineError: LocalizedError {
    case unsupportedFormat
    case animatedPNG
    case decodeFailed
    case encodeFailed(LitheImageFormat)
    case validationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "仅支持静态 JPG、JPEG 和 PNG"
        case .animatedPNG: "暂不支持动态 PNG"
        case .decodeFailed: "图片无法解码"
        case let .encodeFailed(format): "无法生成 \(format.displayName)"
        case let .validationFailed(reason): "图片验证失败：\(reason)"
        case .cancelled: "压缩已取消"
        }
    }
}

struct DecodedImage {
    let image: CGImage
    let format: LitheImageFormat
    let hasTransparency: Bool
    let sourceOrientation: Int32
    let dpiWidth: Double?
    let dpiHeight: Double?
    let iccProfile: Data?
    let hasEmbeddedICCProfile: Bool
}

enum EmbeddedICCProfileDetector {
    static func containsProfile(at url: URL, format: LitheImageFormat) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        switch format {
        case .png:
            return pngContainsProfile(data)
        case .jpeg:
            return jpegContainsProfile(data)
        }
    }

    private static func pngContainsProfile(_ data: Data) -> Bool {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count >= signature.count,
              Array(data.prefix(signature.count)) == signature else { return false }

        var offset = signature.count
        while offset + 12 <= data.count {
            let length = data[offset ..< offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            let chunkEnd = offset + 12 + length
            guard length >= 0, chunkEnd <= data.count else { return false }
            if data[offset + 4] == 0x69,
               data[offset + 5] == 0x43,
               data[offset + 6] == 0x43,
               data[offset + 7] == 0x50 {
                return true
            }
            offset = chunkEnd
        }
        return false
    }

    private static func jpegContainsProfile(_ data: Data) -> Bool {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return false }
        let signature = Data("ICC_PROFILE\0".utf8)
        var offset = 2
        while offset + 4 <= data.count {
            while offset < data.count, data[offset] == 0xFF { offset += 1 }
            guard offset < data.count else { return false }
            let marker = data[offset]
            offset += 1
            if marker == 0xD9 || marker == 0xDA { return false }
            if marker == 0x01 || (0xD0 ... 0xD7).contains(marker) { continue }
            guard offset + 2 <= data.count else { return false }
            let length = (Int(data[offset]) << 8) | Int(data[offset + 1])
            guard length >= 2, offset + length <= data.count else { return false }
            let payloadStart = offset + 2
            if marker == 0xE2,
               payloadStart + signature.count <= offset + length,
               data[payloadStart ..< payloadStart + signature.count].elementsEqual(signature) {
                return true
            }
            offset += length
        }
        return false
    }
}

enum ImageDecoder {
    static func decode(_ url: URL) throws -> DecodedImage {
        if PNGAnimationDetector.containsAnimationControl(at: url) {
            throw CompressionEngineError.animatedPNG
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw CompressionEngineError.decodeFailed
        }
        let type = CGImageSourceGetType(source) as String?
        let format: LitheImageFormat
        if type == UTType.png.identifier {
            guard CGImageSourceGetCount(source) == 1 else {
                throw CompressionEngineError.animatedPNG
            }
            format = .png
        } else if type == UTType.jpeg.identifier {
            format = .jpeg
        } else {
            throw CompressionEngineError.unsupportedFormat
        }

        guard let rawImage = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary) else {
            throw CompressionEngineError.decodeFailed
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationValue = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let normalized = normalize(rawImage, exifOrientation: orientationValue)
        let dpiWidth = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        let dpiHeight = (properties?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
        return DecodedImage(
            image: normalized,
            format: format,
            hasTransparency: format == .png && containsTransparentPixel(normalized),
            sourceOrientation: orientationValue,
            dpiWidth: dpiWidth,
            dpiHeight: dpiHeight,
            iccProfile: normalized.colorSpace?.copyICCData() as Data?,
            hasEmbeddedICCProfile: EmbeddedICCProfileDetector.containsProfile(at: url, format: format)
        )
    }

    private static func normalize(_ image: CGImage, exifOrientation: Int32) -> CGImage {
        guard exifOrientation != 1,
              let orientation = CGImagePropertyOrientation(rawValue: UInt32(exifOrientation)) else {
            return image
        }
        let ciImage = CIImage(cgImage: image).oriented(orientation)
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(ciImage, from: ciImage.extent) ?? image
    }

    private static func containsTransparentPixel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }
        let stripHeight = 256
        for originY in stride(from: 0, to: height, by: stripHeight) {
            let currentHeight = min(stripHeight, height - originY)
            guard let strip = image.cropping(to: CGRect(
                x: 0,
                y: originY,
                width: width,
                height: currentHeight
            )) else { return true }
            var pixels = [UInt8](repeating: 0, count: width * currentHeight * 4)
            guard let context = CGContext(
                data: &pixels,
                width: width,
                height: currentHeight,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return true }
            context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: currentHeight))
            var offset = 3
            while offset < pixels.count {
                if pixels[offset] < 255 { return true }
                offset += 4
            }
        }
        return false
    }
}

enum PNGAnimationDetector {
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let animationChunk: [UInt8] = [97, 99, 84, 76] // acTL

    static func containsAnimationControl(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 20,
              Array(data.prefix(8)) == signature else { return false }
        var offset = 8
        while offset <= data.count - 12 {
            let length = data[offset..<(offset + 4)].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            let typeStart = offset + 4
            let typeEnd = typeStart + 4
            if Array(data[typeStart..<typeEnd]) == animationChunk { return true }
            let chunkSize = Int64(length) + 12
            guard chunkSize <= Int64(data.count - offset) else { return false }
            offset += Int(chunkSize)
        }
        return false
    }
}

enum ImageEncoder {
    static func encode(
        _ decoded: DecodedImage,
        format: LitheImageFormat,
        quality: Double,
        to outputURL: URL
    ) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let type: UTType = format == .png ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw CompressionEngineError.encodeFailed(format)
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
        ]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
            properties[kCGImagePropertyJFIFDictionary] = [
                kCGImagePropertyJFIFIsProgressive: true,
            ] as CFDictionary
        }
        if let dpi = decoded.dpiWidth { properties[kCGImagePropertyDPIWidth] = dpi }
        if let dpi = decoded.dpiHeight { properties[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(destination, decoded.image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CompressionEngineError.encodeFailed(format)
        }
    }
}

enum StructuralSimilarity {
    /// Standard block SSIM applied to color-managed RGB channels. Alpha is
    /// included when either rendered image contains transparency so a color
    /// shift or changed transparency cannot hide behind an identical luma.
    static func score(reference: CGImage, candidate: CGImage) -> Double {
        guard reference.width == candidate.width,
              reference.height == candidate.height,
              reference.width > 0,
              reference.height > 0 else { return 0 }

        let target = comparisonSize(width: reference.width, height: reference.height)
        guard let left = rgba(reference, width: target.width, height: target.height),
              let right = rgba(candidate, width: target.width, height: target.height) else {
            return 0
        }

        var channels = [0, 1, 2]
        if left.hasTransparency || right.hasTransparency { channels.append(3) }
        let scores = channels.map {
            channelScore(
                left.bytes,
                right.bytes,
                channel: $0,
                width: target.width,
                height: target.height
            )
        }
        return scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
    }

    private static func channelScore(
        _ left: [UInt8],
        _ right: [UInt8],
        channel: Int,
        width: Int,
        height: Int
    ) -> Double {
        let c1: Double = pow(0.01 * 255.0, 2.0)
        let c2: Double = pow(0.03 * 255.0, 2.0)
        let blockSize = 8
        var total = 0.0
        var blockCount = 0
        for y in stride(from: 0, to: height, by: blockSize) {
            for x in stride(from: 0, to: width, by: blockSize) {
                let maxX = min(x + blockSize, width)
                let maxY = min(y + blockSize, height)
                let count = Double((maxX - x) * (maxY - y))
                guard count > 1 else { continue }
                var meanL = 0.0
                var meanR = 0.0
                for row in y..<maxY {
                    for column in x..<maxX {
                        let index = (row * width + column) * 4 + channel
                        meanL += Double(left[index])
                        meanR += Double(right[index])
                    }
                }
                meanL /= count
                meanR /= count
                var varianceL = 0.0
                var varianceR = 0.0
                var covariance = 0.0
                for row in y..<maxY {
                    for column in x..<maxX {
                        let index = (row * width + column) * 4 + channel
                        let deltaL = Double(left[index]) - meanL
                        let deltaR = Double(right[index]) - meanR
                        varianceL += deltaL * deltaL
                        varianceR += deltaR * deltaR
                        covariance += deltaL * deltaR
                    }
                }
                varianceL /= count - 1
                varianceR /= count - 1
                covariance /= count - 1
                let numerator = (2 * meanL * meanR + c1) * (2 * covariance + c2)
                let denominator = (meanL * meanL + meanR * meanR + c1)
                    * (varianceL + varianceR + c2)
                total += denominator == 0 ? 1 : numerator / denominator
                blockCount += 1
            }
        }
        return blockCount == 0 ? 0 : max(0, min(1, total / Double(blockCount)))
    }

    private static func comparisonSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let largest = max(width, height)
        guard largest > 1_024 else { return (width, height) }
        let scale = 1_024.0 / Double(largest)
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }

    private static func rgba(
        _ image: CGImage,
        width: Int,
        height: Int
    ) -> (bytes: [UInt8], hasTransparency: Bool)? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let alpha = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(alpha).rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hasTransparency = false
        var offset = 3
        while offset < bytes.count {
            if bytes[offset] < 255 {
                hasTransparency = true
                break
            }
            offset += 4
        }
        return (bytes, hasTransparency)
    }
}

final class CompressionEngine: @unchecked Sendable {
    private struct OperationKey: Hashable {
        let itemID: UUID
        let generation: Int
    }

    let toolRunner: ToolRunner
    private let activeOperationLock = NSLock()
    private var activeOperation: OperationKey?
    private var cancelledOperations: Set<OperationKey> = []
    private var allOperationsCancelled = false

    init(toolRunner: ToolRunner = ToolRunner()) {
        self.toolRunner = toolRunner
    }

    func compress(
        snapshotURL: URL,
        itemID: UUID,
        generation: Int,
        preset: QualityPreset,
        fileStore: SessionFileStore
    ) throws -> CompressionResult {
        let operation = OperationKey(itemID: itemID, generation: generation)
        beginOperation(operation)
        defer { endOperation(operation) }
        try throwIfCancelled(operation)
        let decoded = try ImageDecoder.decode(snapshotURL)
        let originalBytes = try fileSize(snapshotURL)
        let quality = CompressionQuality.preset(preset)
        var pngCandidate: CompressionCandidate?
        var jpegCandidate: CompressionCandidate?
        var candidateFailures: [String] = []

        switch decoded.format {
        case .jpeg:
            var candidates: [CompressionCandidate] = []
            do {
                candidates.append(try makeCandidate(
                    decoded: decoded,
                    sourceURL: snapshotURL,
                    itemID: itemID,
                    generation: generation,
                    format: .jpeg,
                    quality: quality,
                    variant: "lossy",
                    fileStore: fileStore
                ))
            } catch {
                try propagateCancellation(error)
                candidateFailures.append("JPEG：\(error.localizedDescription)")
            }
            try throwIfCancelled(operation)
            if candidates.first.map({
                !isAcceptable($0, originalBytes: originalBytes, preset: preset)
            }) ?? true {
                do {
                    if let lossless = try makeLosslessJPEGCandidate(
                        decoded: decoded,
                        sourceURL: snapshotURL,
                        itemID: itemID,
                        generation: generation,
                        quality: quality,
                        fileStore: fileStore
                    ) {
                        candidates.append(lossless)
                    }
                } catch {
                    try propagateCancellation(error)
                    candidateFailures.append("JPEG 无损优化：\(error.localizedDescription)")
                }
            }
            guard !candidates.isEmpty else {
                throw CompressionEngineError.validationFailed(
                    candidateFailures.joined(separator: "；")
                )
            }
            jpegCandidate = preferredCandidate(candidates, preset: preset)
        case .png:
            var pngCandidates: [CompressionCandidate] = []
            do {
                pngCandidates.append(try makeCandidate(
                    decoded: decoded,
                    sourceURL: snapshotURL,
                    itemID: itemID,
                    generation: generation,
                    format: .png,
                    quality: quality,
                    variant: "lossy",
                    fileStore: fileStore
                ))
            } catch {
                try propagateCancellation(error)
                candidateFailures.append("PNG：\(error.localizedDescription)")
            }
            try throwIfCancelled(operation)
            if pngCandidates.first.map({
                !isAcceptable($0, originalBytes: originalBytes, preset: preset)
            }) ?? true {
                do {
                    pngCandidates.append(try makeLosslessPNGCandidate(
                        decoded: decoded,
                        itemID: itemID,
                        generation: generation,
                        quality: quality,
                        fileStore: fileStore
                    ))
                } catch {
                    try propagateCancellation(error)
                    candidateFailures.append("PNG 无损优化：\(error.localizedDescription)")
                }
            }
            pngCandidate = preferredCandidate(pngCandidates, preset: preset)
            if !decoded.hasTransparency {
                do {
                    jpegCandidate = try makeCandidate(
                        decoded: decoded,
                        sourceURL: snapshotURL,
                        itemID: itemID,
                        generation: generation,
                        format: .jpeg,
                        quality: quality,
                        variant: "lossy",
                        fileStore: fileStore
                    )
                } catch {
                    try propagateCancellation(error)
                    candidateFailures.append("JPEG：\(error.localizedDescription)")
                }
            }
            if pngCandidate == nil, decoded.hasTransparency || jpegCandidate == nil {
                throw CompressionEngineError.validationFailed(
                    candidateFailures.joined(separator: "；")
                )
            }
        }

        let decision = CompressionPolicy.choose(
            inputFormat: decoded.format,
            hasTransparency: decoded.hasTransparency,
            originalBytes: originalBytes,
            preset: preset,
            png: pngCandidate.map { CandidateFacts(format: .png, byteCount: $0.byteCount, ssim: $0.ssim) },
            jpeg: jpegCandidate.map { CandidateFacts(format: .jpeg, byteCount: $0.byteCount, ssim: $0.ssim) }
        )
        let selectedFormat: LitheImageFormat?
        let review: Bool
        switch decision {
        case let .candidate(format, reviewRecommended):
            selectedFormat = format
            review = reviewRecommended
        case .noBenefit:
            selectedFormat = nil
            review = false
        }
        return CompressionResult(
            inputFormat: decoded.format,
            hasTransparency: decoded.hasTransparency,
            originalByteCount: originalBytes,
            pngCandidate: pngCandidate,
            jpegCandidate: jpegCandidate,
            selectedFormat: selectedFormat,
            reviewRecommended: review,
            candidateFailureMessage: candidateFailures.isEmpty
                ? nil
                : candidateFailures.joined(separator: "；")
        )
    }

    func recompress(
        snapshotURL: URL,
        itemID: UUID,
        generation: Int,
        format: LitheImageFormat,
        quality: CompressionQuality,
        fileStore: SessionFileStore
    ) throws -> CompressionCandidate {
        let operation = OperationKey(itemID: itemID, generation: generation)
        beginOperation(operation)
        defer { endOperation(operation) }
        try throwIfCancelled(operation)
        let decoded = try ImageDecoder.decode(snapshotURL)
        if format == .jpeg, decoded.hasTransparency {
            throw CompressionEngineError.validationFailed("透明图片不能转为 JPEG")
        }
        return try makeCandidate(
            decoded: decoded,
            sourceURL: snapshotURL,
            itemID: itemID,
            generation: generation,
            format: format,
            quality: quality,
            fileStore: fileStore
        )
    }

    func cancel() {
        activeOperationLock.lock()
        allOperationsCancelled = true
        if let activeOperation { cancelledOperations.insert(activeOperation) }
        activeOperationLock.unlock()
        toolRunner.cancel()
    }

    func cancel(itemID: UUID) {
        activeOperationLock.lock()
        let operation = activeOperation
        let shouldCancel = operation?.itemID == itemID
        if shouldCancel, let operation { cancelledOperations.insert(operation) }
        activeOperationLock.unlock()
        if shouldCancel { toolRunner.cancel() }
    }

    private func beginOperation(_ operation: OperationKey) {
        activeOperationLock.lock()
        activeOperation = operation
        activeOperationLock.unlock()
    }

    private func endOperation(_ operation: OperationKey) {
        activeOperationLock.lock()
        if activeOperation == operation { activeOperation = nil }
        cancelledOperations.remove(operation)
        activeOperationLock.unlock()
    }

    private func throwIfCancelled(_ operation: OperationKey) throws {
        activeOperationLock.lock()
        let cancelled = allOperationsCancelled || cancelledOperations.contains(operation)
        activeOperationLock.unlock()
        if cancelled { throw CompressionEngineError.cancelled }
    }

    private func propagateCancellation(_ error: Error) throws {
        if case CompressionEngineError.cancelled = error { throw error }
        if let toolError = error as? ToolRunnerError,
           case .cancelled = toolError {
            throw error
        }
    }

    private func makeCandidate(
        decoded: DecodedImage,
        sourceURL: URL,
        itemID: UUID,
        generation: Int,
        format: LitheImageFormat,
        quality: CompressionQuality,
        variant: String? = nil,
        fileStore: SessionFileStore
    ) throws -> CompressionCandidate {
        let operation = OperationKey(itemID: itemID, generation: generation)
        try throwIfCancelled(operation)
        let outputURL = try fileStore.candidateURL(
            itemID: itemID,
            format: format,
            generation: generation,
            variant: variant
        )
        var usedBundledTool = false
        if (format == .png && toolRunner.bundledTool(named: "pngquant") != nil)
            || (format == .jpeg && toolRunner.bundledTool(named: "cjpegli") != nil) {
            do {
                let normalizedInput = try normalizedToolInput(
                    decoded: decoded,
                    itemID: itemID,
                    generation: generation,
                    fileStore: fileStore
                )
                switch format {
                case .png:
                    usedBundledTool = try encodePNGWithBundledToolsIfAvailable(
                        sourceURL: normalizedInput,
                        outputURL: outputURL,
                        quality: quality
                    )
                case .jpeg:
                    usedBundledTool = try encodeJPEGWithBundledToolIfAvailable(
                        sourceURL: normalizedInput,
                        outputURL: outputURL,
                        quality: quality
                    )
                }
            } catch {
                try propagateCancellation(error)
                usedBundledTool = false
            }
        }
        if usedBundledTool, format == .jpeg {
            do {
                try JPEGMetadataSanitizer.sanitize(
                    outputURL,
                    dpiWidth: decoded.dpiWidth,
                    dpiHeight: decoded.dpiHeight
                )
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                usedBundledTool = false
            }
        }
        if !usedBundledTool {
            try throwIfCancelled(operation)
            try encodeImageIOFallback(
                decoded: decoded,
                format: format,
                quality: quality,
                outputURL: outputURL
            )
        }
        try throwIfCancelled(operation)

        do {
            return try validatedCandidate(
                decoded: decoded,
                outputURL: outputURL,
                format: format,
                quality: quality,
                backend: usedBundledTool
                    ? (format == .png ? .pngquant : .cjpegli)
                    : .imageIO
            )
        } catch {
            guard usedBundledTool else { throw error }
            try encodeImageIOFallback(
                decoded: decoded,
                format: format,
                quality: quality,
                outputURL: outputURL
            )
            return try validatedCandidate(
                decoded: decoded,
                outputURL: outputURL,
                format: format,
                quality: quality,
                backend: .imageIO
            )
        }
    }

    private func validatedCandidate(
        decoded: DecodedImage,
        outputURL: URL,
        format: LitheImageFormat,
        quality: CompressionQuality,
        backend: CompressionBackend
    ) throws -> CompressionCandidate {
        let candidateDecoded = try ImageDecoder.decode(outputURL)
        guard candidateDecoded.format == format else {
            throw CompressionEngineError.validationFailed("格式与扩展名不一致")
        }
        guard candidateDecoded.image.width == decoded.image.width,
              candidateDecoded.image.height == decoded.image.height else {
            throw CompressionEngineError.validationFailed("像素尺寸发生变化")
        }
        if decoded.hasTransparency, !candidateDecoded.hasTransparency {
            throw CompressionEngineError.validationFailed("透明区域丢失")
        }
        guard candidateDecoded.sourceOrientation == 1 else {
            throw CompressionEngineError.validationFailed("输出方向未规范化")
        }
        if decoded.hasEmbeddedICCProfile,
           !candidateDecoded.hasEmbeddedICCProfile || candidateDecoded.iccProfile == nil {
            throw CompressionEngineError.validationFailed("ICC 色彩配置丢失")
        }
        if let sourceDPI = decoded.dpiWidth,
           candidateDecoded.dpiWidth.map({ abs(sourceDPI - $0) > 0.5 }) != false {
            throw CompressionEngineError.validationFailed("水平像素密度发生变化")
        }
        if let sourceDPI = decoded.dpiHeight,
           candidateDecoded.dpiHeight.map({ abs(sourceDPI - $0) > 0.5 }) != false {
            throw CompressionEngineError.validationFailed("垂直像素密度发生变化")
        }
        let score = StructuralSimilarity.score(
            reference: decoded.image,
            candidate: candidateDecoded.image
        )
        return CompressionCandidate(
            format: format,
            url: outputURL,
            byteCount: try fileSize(outputURL),
            ssim: score,
            quality: quality,
            backend: backend
        )
    }

    private func normalizedToolInput(
        decoded: DecodedImage,
        itemID: UUID,
        generation: Int,
        fileStore: SessionFileStore
    ) throws -> URL {
        let inputURL = try fileStore.candidateURL(
            itemID: itemID,
            format: .png,
            generation: generation,
            variant: "normalized"
        )
        try ImageEncoder.encode(
            decoded,
            format: .png,
            quality: 1,
            to: inputURL
        )
        return inputURL
    }

    private func encodeImageIOFallback(
        decoded: DecodedImage,
        format: LitheImageFormat,
        quality: CompressionQuality,
        outputURL: URL
    ) throws {
        try ImageEncoder.encode(
            decoded,
            format: format,
            quality: quality.level.parameters.jpegQuality,
            to: outputURL
        )
        guard format == .png,
              let oxipng = toolRunner.bundledTool(named: "oxipng") else { return }
        do {
            _ = try toolRunner.run(executableURL: oxipng, arguments: [
                "-o", "2", "--strip", "safe", outputURL.path,
            ])
        } catch let error as ToolRunnerError {
            if case .cancelled = error { throw error }
            try ImageEncoder.encode(
                decoded,
                format: .png,
                quality: 1,
                to: outputURL
            )
        } catch {
            try ImageEncoder.encode(
                decoded,
                format: .png,
                quality: 1,
                to: outputURL
            )
        }
    }

    private func makeLosslessPNGCandidate(
        decoded: DecodedImage,
        itemID: UUID,
        generation: Int,
        quality: CompressionQuality,
        fileStore: SessionFileStore
    ) throws -> CompressionCandidate {
        let outputURL = try fileStore.candidateURL(
            itemID: itemID,
            format: .png,
            generation: generation,
            variant: "lossless"
        )
        try encodeImageIOFallback(
            decoded: decoded,
            format: .png,
            quality: quality,
            outputURL: outputURL
        )
        return try validatedCandidate(
            decoded: decoded,
            outputURL: outputURL,
            format: .png,
            quality: quality,
            backend: .imageIO
        )
    }

    private func makeLosslessJPEGCandidate(
        decoded: DecodedImage,
        sourceURL: URL,
        itemID: UUID,
        generation: Int,
        quality: CompressionQuality,
        fileStore: SessionFileStore
    ) throws -> CompressionCandidate? {
        guard let jpegtran = toolRunner.bundledTool(named: "jpegtran") else { return nil }
        let outputURL = try fileStore.candidateURL(
            itemID: itemID,
            format: .jpeg,
            generation: generation,
            variant: "lossless"
        )
        try? FileManager.default.removeItem(at: outputURL)
        var arguments = ["-copy", "all", "-optimize", "-progressive"]
        let transformArguments = jpegtranTransformArguments(for: decoded.sourceOrientation)
        if !transformArguments.isEmpty { arguments.append("-perfect") }
        arguments.append(contentsOf: transformArguments)
        arguments.append(contentsOf: ["-outfile", outputURL.path, sourceURL.path])
        _ = try toolRunner.run(executableURL: jpegtran, arguments: arguments)
        try JPEGMetadataSanitizer.sanitize(
            outputURL,
            dpiWidth: decoded.dpiWidth,
            dpiHeight: decoded.dpiHeight
        )
        return try validatedCandidate(
            decoded: decoded,
            outputURL: outputURL,
            format: .jpeg,
            quality: quality,
            backend: .jpegtran
        )
    }

    private func jpegtranTransformArguments(for orientation: Int32) -> [String] {
        switch orientation {
        case 2: ["-flip", "horizontal"]
        case 3: ["-rotate", "180"]
        case 4: ["-flip", "vertical"]
        case 5: ["-transpose"]
        case 6: ["-rotate", "90"]
        case 7: ["-transverse"]
        case 8: ["-rotate", "270"]
        default: []
        }
    }

    private func isAcceptable(
        _ candidate: CompressionCandidate,
        originalBytes: Int64,
        preset: QualityPreset
    ) -> Bool {
        candidate.ssim >= preset.minimumSSIM
            && CompressionPolicy.hasEffectiveSaving(
                originalBytes: originalBytes,
                resultBytes: candidate.byteCount
            )
    }

    private func preferredCandidate(
        _ candidates: [CompressionCandidate],
        preset: QualityPreset
    ) -> CompressionCandidate? {
        let qualityPassing = candidates.filter { $0.ssim >= preset.minimumSSIM }
        if !qualityPassing.isEmpty {
            return qualityPassing.min { $0.byteCount < $1.byteCount }
        }
        return candidates.max { $0.ssim < $1.ssim }
    }

    private func encodePNGWithBundledToolsIfAvailable(
        sourceURL: URL,
        outputURL: URL,
        quality: CompressionQuality
    ) throws -> Bool {
        guard let pngquant = toolRunner.bundledTool(named: "pngquant") else { return false }
        let range = quality.level.parameters.pngQualityRange
        do {
            _ = try toolRunner.run(executableURL: pngquant, arguments: [
                "--force",
                "--quality", "\(range.lowerBound)-\(range.upperBound)",
                "--output", outputURL.path,
                sourceURL.path,
            ])
            if let oxipng = toolRunner.bundledTool(named: "oxipng") {
                _ = try toolRunner.run(executableURL: oxipng, arguments: [
                    "-o", "2", "--strip", "safe", outputURL.path,
                ])
            }
            return true
        } catch let error as ToolRunnerError {
            if case .cancelled = error { throw error }
            try? FileManager.default.removeItem(at: outputURL)
            return false
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
    }

    private func encodeJPEGWithBundledToolIfAvailable(
        sourceURL: URL,
        outputURL: URL,
        quality: CompressionQuality
    ) throws -> Bool {
        guard let cjpegli = toolRunner.bundledTool(named: "cjpegli") else { return false }
        do {
            try? FileManager.default.removeItem(at: outputURL)
            let qualityValue = quality.level.parameters.jpegQualityPercent
            _ = try toolRunner.run(executableURL: cjpegli, arguments: [
                sourceURL.path, outputURL.path, "--quality=\(qualityValue)",
            ])
            return true
        } catch let error as ToolRunnerError {
            if case .cancelled = error { throw error }
            try? FileManager.default.removeItem(at: outputURL)
            return false
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else { throw FileLifecycleError.invalidFile(url) }
        return Int64(size)
    }
}

enum JPEGMetadataSanitizer {
    static func sanitize(
        _ url: URL,
        dpiWidth: Double? = nil,
        dpiHeight: Double? = nil
    ) throws {
        let bytes = [UInt8](try Data(contentsOf: url, options: [.mappedIfSafe]))
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw CompressionEngineError.validationFailed("JPEG 标记无效")
        }

        let replacementJFIF = makeJFIF(dpiWidth: dpiWidth, dpiHeight: dpiHeight)
        var output = Array(bytes[0..<2])
        if let replacementJFIF { output.append(contentsOf: replacementJFIF) }
        var cursor = 2
        while cursor < bytes.count {
            let markerStart = cursor
            guard bytes[cursor] == 0xff else {
                throw CompressionEngineError.validationFailed("JPEG 标记边界无效")
            }
            while cursor < bytes.count, bytes[cursor] == 0xff { cursor += 1 }
            guard cursor < bytes.count else {
                throw CompressionEngineError.validationFailed("JPEG 标记不完整")
            }
            let marker = bytes[cursor]
            cursor += 1

            if marker == 0xd9 {
                output.append(contentsOf: bytes[markerStart..<bytes.count])
                cursor = bytes.count
                break
            }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) {
                output.append(contentsOf: bytes[markerStart..<cursor])
                continue
            }

            guard cursor + 1 < bytes.count else {
                throw CompressionEngineError.validationFailed("JPEG 段长度缺失")
            }
            let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            guard length >= 2, cursor + length <= bytes.count else {
                throw CompressionEngineError.validationFailed("JPEG 段长度无效")
            }
            let segmentEnd = cursor + length
            if marker == 0xda {
                output.append(contentsOf: bytes[markerStart..<bytes.count])
                cursor = bytes.count
                break
            }
            let isJFIF = marker == 0xe0
                && hasPrefix("JFIF\0", bytes: bytes, start: cursor + 2, end: segmentEnd)
            if !(isJFIF && replacementJFIF != nil),
               shouldKeep(marker: marker, bytes: bytes, payloadStart: cursor + 2, end: segmentEnd) {
                output.append(contentsOf: bytes[markerStart..<segmentEnd])
            }
            cursor = segmentEnd
        }

        guard cursor == bytes.count else {
            throw CompressionEngineError.validationFailed("JPEG 数据不完整")
        }
        try Data(output).write(to: url, options: .atomic)
    }

    private static func shouldKeep(
        marker: UInt8,
        bytes: [UInt8],
        payloadStart: Int,
        end: Int
    ) -> Bool {
        if marker == 0xfe { return false }
        guard (0xe0...0xef).contains(marker) else { return true }
        switch marker {
        case 0xe0:
            return hasPrefix("JFIF\0", bytes: bytes, start: payloadStart, end: end)
        case 0xe2:
            return hasPrefix("ICC_PROFILE\0", bytes: bytes, start: payloadStart, end: end)
        case 0xee:
            return hasPrefix("Adobe", bytes: bytes, start: payloadStart, end: end)
        default:
            return false
        }
    }

    private static func hasPrefix(
        _ value: String,
        bytes: [UInt8],
        start: Int,
        end: Int
    ) -> Bool {
        let prefix = Array(value.utf8)
        guard start >= 0, start + prefix.count <= end else { return false }
        return Array(bytes[start..<(start + prefix.count)]) == prefix
    }

    private static func makeJFIF(dpiWidth: Double?, dpiHeight: Double?) -> [UInt8]? {
        guard let dpiWidth, let dpiHeight,
              dpiWidth.isFinite, dpiHeight.isFinite,
              dpiWidth >= 1, dpiWidth <= Double(UInt16.max),
              dpiHeight >= 1, dpiHeight <= Double(UInt16.max) else { return nil }
        let x = UInt16(dpiWidth.rounded())
        let y = UInt16(dpiHeight.rounded())
        return [
            0xff, 0xe0, 0x00, 0x10,
            0x4a, 0x46, 0x49, 0x46, 0x00,
            0x01, 0x02,
            0x01,
            UInt8(x >> 8), UInt8(x & 0xff),
            UInt8(y >> 8), UInt8(y & 0xff),
            0x00, 0x00,
        ]
    }
}

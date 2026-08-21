import CryptoKit
import Darwin
import Foundation

enum FileLifecycleError: LocalizedError {
    case insufficientTemporarySpace(required: Int64, available: Int64)
    case sourceMissing(URL)
    case destinationChanged(URL)
    case invalidFile(URL)

    var errorDescription: String? {
        switch self {
        case let .insufficientTemporarySpace(required, available):
            "临时空间不足（需要 \(required) 字节，可用 \(available) 字节）"
        case let .sourceMissing(url):
            "找不到原文件：\(url.lastPathComponent)"
        case let .destinationChanged(url):
            "输出文件已被修改：\(url.lastPathComponent)"
        case let .invalidFile(url):
            "文件无效：\(url.lastPathComponent)"
        }
    }
}

enum OutputNaming {
    static func compressedURL(
        sourceURL: URL,
        format: LitheImageFormat,
        destinationDirectory: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let base = "\(stem)-Lithed"
        var index = 1
        while true {
            let suffix = index == 1 ? "" : "-\(index)"
            let candidate = destinationDirectory
                .appendingPathComponent(base + suffix)
                .appendingPathExtension(format.fileExtension)
            if !fileExists(candidate) { return candidate }
            index += 1
        }
    }

    static func restoredURL(
        originalURL: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        if !fileExists(originalURL) { return originalURL }
        let directory = originalURL.deletingLastPathComponent()
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        var index = 1
        while true {
            let suffix = index == 1 ? "-restored" : "-restored-\(index)"
            var candidate = directory.appendingPathComponent(stem + suffix)
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fileExists(candidate) { return candidate }
            index += 1
        }
    }

    static func preservedURL(
        outputURL: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let directory = outputURL.deletingLastPathComponent()
        let stem = outputURL.deletingPathExtension().lastPathComponent
        let ext = outputURL.pathExtension
        var index = 1
        while true {
            let suffix = index == 1 ? "-preserved" : "-preserved-\(index)"
            var candidate = directory.appendingPathComponent(stem + suffix)
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fileExists(candidate) { return candidate }
            index += 1
        }
    }

    static func uniqueName(
        _ proposedName: String,
        usedNames: inout Set<String>
    ) -> String {
        if usedNames.insert(proposedName).inserted { return proposedName }
        let url = URL(fileURLWithPath: proposedName)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            var name = "\(stem)-\(index)"
            if !ext.isEmpty { name += ".\(ext)" }
            if usedNames.insert(name).inserted { return name }
            index += 1
        }
    }
}

final class SessionFileStore: @unchecked Sendable {
    let rootURL: URL
    private let fileManager: FileManager
    private let manifestURL: URL

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) throws {
        self.fileManager = fileManager
        let base = baseDirectory ?? fileManager.temporaryDirectory
            .appendingPathComponent("com.lithe.app", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        rootURL = base.appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: false)
        manifestURL = rootURL.appendingPathComponent(".lithe-session")
        try Data("Lithe session v1".utf8).write(to: manifestURL, options: .atomic)
    }

    static func cleanAbandonedSessions(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        let base = baseDirectory ?? fileManager.temporaryDirectory
            .appendingPathComponent("com.lithe.app", isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for child in children where child.lastPathComponent.hasPrefix("session-") {
            let manifest = child.appendingPathComponent(".lithe-session")
            guard (try? Data(contentsOf: manifest)) == Data("Lithe session v1".utf8) else {
                continue
            }
            try? fileManager.removeItem(at: child)
        }
    }

    func ensureTemporaryCapacity(for sources: [URL], safetyMultiplier: Int64 = 3) throws {
        let required = sources.reduce(Int64(0)) { partial, url in
            partial + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
        }
        let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64.max
        let safetyRequirement = max(required * max(1, safetyMultiplier), 32 * 1_024 * 1_024)
        guard available >= safetyRequirement else {
            throw FileLifecycleError.insufficientTemporarySpace(
                required: safetyRequirement,
                available: available
            )
        }
    }

    func itemDirectory(for id: UUID) throws -> URL {
        let url = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw FileLifecycleError.invalidFile(url) }
            return url
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            var createdDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &createdDirectory),
                  createdDirectory.boolValue else { throw error }
        }
        return url
    }

    func createSnapshot(sourceURL: URL, itemID: UUID) throws -> URL {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw FileLifecycleError.sourceMissing(sourceURL)
        }
        let directory = try itemDirectory(for: itemID)
        let snapshot = directory.appendingPathComponent("source")
            .appendingPathExtension(sourceURL.pathExtension.lowercased())
        if clonefile(sourceURL.path, snapshot.path, 0) != 0 {
            try fileManager.copyItem(at: sourceURL, to: snapshot)
        }
        return snapshot
    }

    func candidateURL(
        itemID: UUID,
        format: LitheImageFormat,
        generation: Int,
        variant: String? = nil
    ) throws -> URL {
        let suffix = variant.map { "-\($0)" } ?? ""
        return try itemDirectory(for: itemID)
            .appendingPathComponent("candidate-\(generation)\(suffix)")
            .appendingPathExtension(format.fileExtension)
    }

    func normalizedInputURL(itemID: UUID) throws -> URL {
        try itemDirectory(for: itemID)
            .appendingPathComponent("normalized-input")
            .appendingPathExtension(LitheImageFormat.png.fileExtension)
    }

    func temporaryNormalizedInputURL(itemID: UUID) throws -> URL {
        try itemDirectory(for: itemID)
            .appendingPathComponent(".normalized-input-\(UUID().uuidString)")
            .appendingPathExtension(LitheImageFormat.png.fileExtension)
    }

    func publishInitial(
        candidateURL: URL,
        sourceURL: URL,
        format: LitheImageFormat,
        fixedDestinationDirectory: URL?
    ) throws -> (URL, PublishedFingerprint) {
        let destinationDirectory = fixedDestinationDirectory ?? sourceURL.deletingLastPathComponent()
        let finalURL = OutputNaming.compressedURL(
            sourceURL: sourceURL,
            format: format,
            destinationDirectory: destinationDirectory
        )
        try publishCopy(candidateURL: candidateURL, finalURL: finalURL)
        return (finalURL, try fingerprint(of: finalURL))
    }

    func republish(
        candidateURL: URL,
        sourceURL: URL,
        format: LitheImageFormat,
        currentPublishedURL: URL?,
        currentFingerprint: PublishedFingerprint?,
        fixedDestinationDirectory: URL?
    ) throws -> (URL, PublishedFingerprint, preservedOldOutput: Bool) {
        var oldIsUntouched = false
        if let currentPublishedURL, let currentFingerprint,
           fileManager.fileExists(atPath: currentPublishedURL.path) {
            oldIsUntouched = (try? fingerprint(of: currentPublishedURL)) == currentFingerprint
        }

        let destinationDirectory = fixedDestinationDirectory ?? sourceURL.deletingLastPathComponent()
        if let currentPublishedURL,
           oldIsUntouched,
           currentPublishedURL.pathExtension.lowercased() == format.fileExtension {
            let temporary = currentPublishedURL.deletingLastPathComponent()
                .appendingPathComponent(".lithe-\(UUID().uuidString).tmp")
            let backupName = ".lithe-backup-\(UUID().uuidString)"
            let backupURL = currentPublishedURL.deletingLastPathComponent()
                .appendingPathComponent(backupName)
            try fileManager.copyItem(at: candidateURL, to: temporary)
            guard (try? fingerprint(of: currentPublishedURL)) == currentFingerprint else {
                let preservedURL = OutputNaming.compressedURL(
                    sourceURL: sourceURL,
                    format: format,
                    destinationDirectory: destinationDirectory
                )
                do {
                    try fileManager.moveItem(at: temporary, to: preservedURL)
                    return (preservedURL, try fingerprint(of: preservedURL), true)
                } catch {
                    try? fileManager.removeItem(at: temporary)
                    throw error
                }
            }
            do {
                _ = try fileManager.replaceItemAt(
                    currentPublishedURL,
                    withItemAt: temporary,
                    backupItemName: backupName,
                    options: [.withoutDeletingBackupItem]
                )
            } catch {
                try? fileManager.removeItem(at: temporary)
                if fileManager.fileExists(atPath: backupURL.path),
                   !fileManager.fileExists(atPath: currentPublishedURL.path) {
                    try? fileManager.moveItem(at: backupURL, to: currentPublishedURL)
                }
                throw error
            }
            guard fileManager.fileExists(atPath: backupURL.path) else {
                throw FileLifecycleError.destinationChanged(currentPublishedURL)
            }
            let backupMatches = (try? fingerprint(of: backupURL)) == currentFingerprint
            if backupMatches {
                try? fileManager.removeItem(at: backupURL)
            } else {
                let preservedURL = OutputNaming.preservedURL(outputURL: currentPublishedURL)
                try? fileManager.moveItem(at: backupURL, to: preservedURL)
            }
            return (
                currentPublishedURL,
                try fingerprint(of: currentPublishedURL),
                !backupMatches
            )
        }

        let newURL = OutputNaming.compressedURL(
            sourceURL: sourceURL,
            format: format,
            destinationDirectory: destinationDirectory
        )
        try publishCopy(candidateURL: candidateURL, finalURL: newURL)

        var preservedOld = false
        if let currentPublishedURL,
           currentPublishedURL != newURL,
           fileManager.fileExists(atPath: currentPublishedURL.path) {
            if oldIsUntouched, let currentFingerprint {
                preservedOld = preserveOrRemovePublishedFile(
                    currentPublishedURL,
                    expectedFingerprint: currentFingerprint
                )
            } else {
                preservedOld = true
            }
        }
        return (newURL, try fingerprint(of: newURL), preservedOld)
    }

    func fingerprint(of url: URL) throws -> PublishedFingerprint {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw FileLifecycleError.invalidFile(url)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PublishedFingerprint(
            byteCount: size.int64Value,
            modificationTime: modified.timeIntervalSince1970,
            sha256: digest
        )
    }

    func matchesPublishedFile(url: URL?, fingerprint expected: PublishedFingerprint?) -> Bool {
        guard let url, let expected, fileManager.fileExists(atPath: url.path) else { return false }
        return (try? fingerprint(of: url)) == expected
    }

    func contentsMatch(_ firstURL: URL, _ secondURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: firstURL.path),
              fileManager.fileExists(atPath: secondURL.path),
              let first = try? fingerprint(of: firstURL),
              let second = try? fingerprint(of: secondURL) else { return false }
        return first.byteCount == second.byteCount && first.sha256 == second.sha256
    }

    func makeStagingDirectory() throws -> URL {
        let url = rootURL.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func publishArtifact(sourceURL: URL, requestedURL: URL) throws -> URL {
        var finalURL = requestedURL
        var index = 2
        while fileManager.fileExists(atPath: finalURL.path) {
            let directory = requestedURL.deletingLastPathComponent()
            let stem = requestedURL.deletingPathExtension().lastPathComponent
            let ext = requestedURL.pathExtension
            finalURL = directory.appendingPathComponent("\(stem)-\(index)")
            if !ext.isEmpty { finalURL.appendPathExtension(ext) }
            index += 1
        }
        try publishCopy(candidateURL: sourceURL, finalURL: finalURL)
        return finalURL
    }

    func cleanup() {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return }
        try? fileManager.removeItem(at: rootURL)
    }

    private func publishCopy(candidateURL: URL, finalURL: URL) throws {
        try fileManager.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".lithe-\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: candidateURL, to: temporary)
        do {
            try fileManager.moveItem(at: temporary, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func preserveOrRemovePublishedFile(
        _ url: URL,
        expectedFingerprint: PublishedFingerprint
    ) -> Bool {
        let quarantined = url.deletingLastPathComponent()
            .appendingPathComponent(".lithe-old-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: url, to: quarantined)
        } catch {
            return true
        }
        if (try? fingerprint(of: quarantined)) == expectedFingerprint {
            do {
                try fileManager.removeItem(at: quarantined)
                return false
            } catch {
                return true
            }
        }
        let destination = fileManager.fileExists(atPath: url.path)
            ? OutputNaming.preservedURL(outputURL: url)
            : url
        do {
            try fileManager.moveItem(at: quarantined, to: destination)
        } catch {
            return true
        }
        return true
    }
}

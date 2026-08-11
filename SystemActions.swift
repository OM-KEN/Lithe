import AppKit
import Foundation

enum LithePasteboard {
    static let generatedFilesType = NSPasteboard.PasteboardType("com.lithe.generated-files")
    static let requestIDType = NSPasteboard.PasteboardType("com.lithe.request-id")

    static func write(
        fileURLs: [URL],
        requestID: UUID,
        to pasteboard: NSPasteboard = .general
    ) {
        guard !fileURLs.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(fileURLs as [NSURL])
        pasteboard.setString("1", forType: generatedFilesType)
        pasteboard.setString(requestID.uuidString, forType: requestIDType)
    }
}

@MainActor
enum SystemActions {
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func recycle(
        _ urls: [URL],
        completion: @escaping @MainActor @Sendable ([URL: URL], Error?) -> Void
    ) {
        guard !urls.isEmpty else {
            completion([:], nil)
            return
        }
        NSWorkspace.shared.recycle(urls) { mappings, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(mappings, error) }
            }
        }
    }
}

enum ZipService {
    static func createZip(
        entries: [(sourceURL: URL, archiveName: String)],
        sessionURL: URL,
        fileStore: SessionFileStore,
        toolRunner: ToolRunner
    ) throws {
        let staging = try fileStore.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        var usedNames: Set<String> = []
        for entry in entries {
            let name = OutputNaming.uniqueName(entry.archiveName, usedNames: &usedNames)
            try FileManager.default.copyItem(
                at: entry.sourceURL,
                to: staging.appendingPathComponent(name)
            )
        }
        try? FileManager.default.removeItem(at: sessionURL)
        do {
            _ = try toolRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [
                    "-c", "-k",
                    "--norsrc", "--noextattr", "--noqtn", "--noacl",
                    staging.path, sessionURL.path
                ]
            )
            _ = try toolRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-t", sessionURL.path]
            )
            guard FileManager.default.fileExists(atPath: sessionURL.path),
                  (try sessionURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                throw FileLifecycleError.invalidFile(sessionURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: sessionURL)
            throw error
        }
    }
}

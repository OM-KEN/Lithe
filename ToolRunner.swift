import Darwin
import Foundation

struct ToolResult: Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

enum ToolRunnerError: LocalizedError {
    case unavailable(String)
    case failed(String, Int32, String)
    case timedOut(String)
    case cancelled(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(name): "未内嵌压缩工具：\(name)"
        case let .failed(name, code, stderr): "\(name) 失败（\(code)）：\(stderr)"
        case let .timedOut(name): "\(name) 执行超时"
        case let .cancelled(name): "\(name) 已取消"
        }
    }
}

final class ToolRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: Process?
    private var cancelledProcesses: Set<ObjectIdentifier> = []
    private let toolsDirectory: URL?

    init(toolsDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent(
        "Tools",
        isDirectory: true
    )) {
        self.toolsDirectory = toolsDirectory
    }

    func bundledTool(named name: String) -> URL? {
        toolsDirectory?
            .appendingPathComponent(name)
            .takeIfExecutable()
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 120
    ) throws -> ToolResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ToolRunnerError.unavailable(executableURL.lastPathComponent)
        }
        let process = Process()
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let stdoutURL = temporaryDirectory.appendingPathComponent("lithe-stdout-\(UUID().uuidString)")
        let stderrURL = temporaryDirectory.appendingPathComponent("lithe-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: stdoutURL)
        let error = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? output.close()
            try? error.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error

        lock.lock()
        activeProcess = process
        lock.unlock()
        defer {
            lock.lock()
            if activeProcess === process { activeProcess = nil }
            cancelledProcesses.remove(ObjectIdentifier(process))
            lock.unlock()
        }

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            if isCancelled(process) {
                stopAndReap(process)
                throw ToolRunnerError.cancelled(executableURL.lastPathComponent)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if isCancelled(process) {
            if process.isRunning { stopAndReap(process) }
            throw ToolRunnerError.cancelled(executableURL.lastPathComponent)
        }
        if process.isRunning {
            stopAndReap(process)
            throw ToolRunnerError.timedOut(executableURL.lastPathComponent)
        }
        try output.synchronize()
        try error.synchronize()
        let stdoutData = try Data(contentsOf: stdoutURL)
        let stderrData = try Data(contentsOf: stderrURL)
        guard process.terminationStatus == 0 else {
            throw ToolRunnerError.failed(
                executableURL.lastPathComponent,
                process.terminationStatus,
                String(decoding: stderrData, as: UTF8.self)
            )
        }
        return ToolResult(
            exitCode: process.terminationStatus,
            standardOutput: stdoutData,
            standardError: stderrData
        )
    }

    func cancel() {
        lock.lock()
        let process = activeProcess
        if let process { cancelledProcesses.insert(ObjectIdentifier(process)) }
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func isCancelled(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledProcesses.contains(ObjectIdentifier(process))
    }

    private func stopAndReap(_ process: Process) {
        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < gracefulDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private extension URL {
    func takeIfExecutable() -> URL? {
        FileManager.default.isExecutableFile(atPath: path) ? self : nil
    }
}

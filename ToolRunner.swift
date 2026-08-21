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
    private final class TrackedProcess: @unchecked Sendable {
        let process: Process
        let wake: DispatchSemaphore
        let terminated: DispatchSemaphore

        init(
            process: Process,
            wake: DispatchSemaphore,
            terminated: DispatchSemaphore
        ) {
            self.process = process
            self.wake = wake
            self.terminated = terminated
        }
    }

    private let lock = NSLock()
    private var activeProcesses: [ObjectIdentifier: TrackedProcess] = [:]
    private var cancelledProcesses: Set<ObjectIdentifier> = []
    private var cancellationGeneration: UInt64 = 0
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
        timeout: TimeInterval = 120,
        cancellationCheck: @escaping @Sendable () -> Bool = { false }
    ) throws -> ToolResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ToolRunnerError.unavailable(executableURL.lastPathComponent)
        }
        if cancellationCheck() {
            throw ToolRunnerError.cancelled(executableURL.lastPathComponent)
        }
        lock.lock()
        let startingCancellationGeneration = cancellationGeneration
        lock.unlock()

        let process = Process()
        let wake = DispatchSemaphore(value: 0)
        let terminated = DispatchSemaphore(value: 0)
        let tracked = TrackedProcess(process: process, wake: wake, terminated: terminated)
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
        process.terminationHandler = { _ in
            terminated.signal()
            wake.signal()
        }

        let identifier = ObjectIdentifier(process)
        let cancelledBeforeRegistration = cancellationCheck()
        lock.lock()
        activeProcesses[identifier] = tracked
        if cancelledBeforeRegistration
            || cancellationGeneration != startingCancellationGeneration {
            cancelledProcesses.insert(identifier)
        }
        lock.unlock()
        defer {
            process.terminationHandler = nil
            lock.lock()
            activeProcesses.removeValue(forKey: identifier)
            cancelledProcesses.remove(identifier)
            lock.unlock()
        }

        if isCancelled(process) || cancellationCheck() {
            throw ToolRunnerError.cancelled(executableURL.lastPathComponent)
        }
        do {
            try process.run()
        } catch {
            if isCancelled(process) {
                throw ToolRunnerError.cancelled(executableURL.lastPathComponent)
            }
            throw error
        }
        if isCancelled(process) {
            stopAndReap(tracked)
            throw ToolRunnerError.cancelled(executableURL.lastPathComponent)
        }

        let waitResult = wake.wait(timeout: .now() + timeout)
        if isCancelled(process) {
            stopAndReap(tracked)
            throw ToolRunnerError.cancelled(executableURL.lastPathComponent)
        }
        if waitResult == .timedOut {
            stopAndReap(tracked)
            if isCancelled(process) {
                throw ToolRunnerError.cancelled(executableURL.lastPathComponent)
            }
            throw ToolRunnerError.timedOut(executableURL.lastPathComponent)
        }
        process.waitUntilExit()
        if isCancelled(process) {
            throw ToolRunnerError.cancelled(executableURL.lastPathComponent)
        }
        try output.synchronize()
        try error.synchronize()
        let stdoutData = try Data(contentsOf: stdoutURL)
        let stderrData = try Data(contentsOf: stderrURL)
        if isCancelled(process) {
            throw ToolRunnerError.cancelled(executableURL.lastPathComponent)
        }
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
        cancellationGeneration &+= 1
        let trackedProcesses = Array(activeProcesses.values)
        for tracked in trackedProcesses {
            cancelledProcesses.insert(ObjectIdentifier(tracked.process))
        }
        lock.unlock()
        for tracked in trackedProcesses {
            tracked.wake.signal()
            if tracked.process.isRunning { tracked.process.terminate() }
        }
    }

    private func isCancelled(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledProcesses.contains(ObjectIdentifier(process))
    }

    private func stopAndReap(_ tracked: TrackedProcess) {
        let process = tracked.process
        if process.isRunning {
            process.terminate()
            if tracked.terminated.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
    }
}

private extension URL {
    func takeIfExecutable() -> URL? {
        FileManager.default.isExecutableFile(atPath: path) ? self : nil
    }
}

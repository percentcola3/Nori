import Darwin
import Foundation

/// Synchronous, bounded receipt queries and uninstall operations. Mutation
/// commands are composed separately, so discovery only submits read-only argv.
enum CLICommandRunner {
    private static let outputLimit = 64 * 1024

    static func run(_ executable: String, _ arguments: [String], searchPath: [String], home: String,
                    timeout: TimeInterval, environment overrides: [String: String] = [:]) -> (succeeded: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = CLICommandEnvironment.make(home: home, searchPath: searchPath,
            executable: executable, overrides: overrides)
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }

        // Own a separate nonblocking read descriptor. Cancellation closes it on
        // the reader's serial queue after outstanding callbacks finish, avoiding
        // a read/close race if the system reuses the descriptor for another file.
        let descriptor = dup(pipe.fileHandleForReading.fileDescriptor)
        guard descriptor >= 0 else { return (false, String(cString: strerror(errno))) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            return (false, message)
        }
        let collector = OutputCollector(limit: outputLimit)
        let reachedEOF = DispatchSemaphore(value: 0)
        let outputQueue = DispatchQueue(label: "com.nori.cli.output", qos: .utility)
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: outputQueue)
        reader.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 8192)
            // Bound each callback even if a child writes forever. Retained output
            // is capped, but the remaining bytes are drained to avoid backpressure.
            for _ in 0..<8 {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 { collector.append(buffer.prefix(count)); continue }
                if count == 0 { reachedEOF.signal() }
                if count < 0, errno == EINTR { continue }
                return
            }
        }
        reader.setCancelHandler { close(descriptor) }
        reader.resume()
        defer { reader.cancel() }

        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch { return (false, error.localizedDescription) }
        try? pipe.fileHandleForWriting.close()
        let deadline: DispatchTime = timeout.isFinite ? .now() + max(0.05, timeout) : .distantFuture
        let timedOut = completed.wait(timeout: deadline) == .timedOut
        if timedOut, process.isRunning {
            process.terminate()
            if completed.wait(timeout: .now() + 0.1) == .timedOut, process.isRunning {
                // Signal only the Process we launched. We cannot reliably bind
                // an inherited process group, so unrelated processes and child
                // processes are never selected by name or broad group signals.
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 0.1)
            }
        }
        // A descendant may inherit stdout after its parent exits. Do not wait
        // for it indefinitely; cancel the reader without signaling descendants.
        _ = reachedEOF.wait(timeout: .now() + 0.1)
        reader.cancel()
        outputQueue.sync {}
        let succeeded = !timedOut && !process.isRunning && process.terminationStatus == 0
        return (succeeded, collector.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func append(_ bytes: ArraySlice<UInt8>) {
            lock.lock()
            defer { lock.unlock() }
            data.append(contentsOf: bytes.prefix(max(0, limit - data.count)))
        }

        var output: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

import Foundation

/// Minimal wrapper for invoking system binaries with absolute paths.
///
/// Absolute paths only: the sampler runs from launchd where `PATH` is not the
/// user's, and a relative lookup would be both fragile and a hijack surface.
///
/// ## File descriptors are closed explicitly, and that is not optional
///
/// This runs several times per tick for the life of a long-running agent, so a
/// leak of even one descriptor per call is fatal over hours. An earlier version
/// relied on `Pipe` closing itself on deinit and leaked both ends: after roughly
/// ninety minutes the agent held 2 553 open PIPE descriptors, could no longer
/// spawn `netstat`, and every tick failed with empty output while the process
/// stayed alive and apparently healthy. Closing the parent's write end also
/// matters for correctness independently of the leak — while this process holds
/// it open the reader never sees EOF, so `readDataToEndOfFile` can block forever.
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        /// True when the child had to be killed for exceeding `timeout`.
        public let timedOut: Bool
    }

    @discardableResult
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/sbin:/usr/bin:/sbin:/bin"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Read ends are closed on every exit path, including a thrown launch.
        var readEndsClosed = false
        func closeReadEnds() {
            guard !readEndsClosed else { return }
            readEndsClosed = true
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }
        defer { closeReadEnds() }

        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            throw error
        }

        // The child holds its own copies; ours must go or EOF never arrives.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        // Drain both pipes concurrently. Reading them in sequence deadlocks as
        // soon as a child fills the pipe buffer we are not currently reading.
        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = data; lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = data; lock.unlock()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        // Bounded, so a reader stuck on an inherited descriptor cannot wedge the
        // sampler permanently. Closing the read ends below releases it.
        if group.wait(timeout: .now() + 5) == .timedOut {
            timedOut = true
            closeReadEnds()
            _ = group.wait(timeout: .now() + 2)
        }
        process.waitUntilExit()

        lock.lock()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()

        return Result(status: process.terminationStatus, stdout: out, stderr: err, timedOut: timedOut)
    }

    /// Number of descriptors this process currently holds open.
    ///
    /// Used by the test suite to pin the leak regression; cheap enough to call
    /// from diagnostics too.
    public static func openFileDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }
}

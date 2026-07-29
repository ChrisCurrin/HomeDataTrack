import Foundation

/// Minimal wrapper for invoking system binaries with absolute paths.
///
/// Absolute paths only: the sampler runs from launchd where `PATH` is not the
/// user's, and a relative lookup would be both fragile and a hijack surface.
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
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

        try process.run()

        // Drain both pipes concurrently. Reading them in sequence deadlocks as
        // soon as a child fills the pipe buffer we are not currently reading.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            // Give the child a moment to die before we stop waiting on its pipes.
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        group.wait()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

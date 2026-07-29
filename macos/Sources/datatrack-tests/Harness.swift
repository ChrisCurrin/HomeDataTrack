import Foundation

/// A deliberately tiny test harness.
///
/// swift-testing and XCTest are both unusable with only the Xcode Command Line
/// Tools installed: the SDK ships no `XCTest.framework`, and while
/// `Testing.framework` is present it is built against a `swift-6.2` toolchain
/// path and its helper exits 0 having run nothing. A harness that silently passes
/// zero tests is worse than no harness, so this runs the assertions itself and
/// returns a real exit code.
enum Harness {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var currentSuite = ""
    nonisolated(unsafe) static var currentTest = ""
    nonisolated(unsafe) static var suiteFailed = false

    static func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
        do {
            try body()
        } catch {
            record("suite threw: \(error)")
        }
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        suiteFailed = false
        let before = failures.count
        do {
            try body()
        } catch {
            record("threw: \(error)")
        }
        let ok = failures.count == before
        print("  \(ok ? "\u{001B}[32m✓\u{001B}[0m" : "\u{001B}[31m✗\u{001B}[0m") \(name)")
    }

    static func record(_ message: String) {
        failures.append("\(currentSuite) › \(currentTest): \(message)")
    }

    static func expect(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        if !condition { record("\(message) (line \(line))") }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "", line: Int = #line) {
        checks += 1
        if actual != expected {
            let prefix = label.isEmpty ? "" : "\(label): "
            record("\(prefix)expected \(expected), got \(actual) (line \(line))")
        }
    }

    static func notNil<T>(_ value: T?, _ label: String, line: Int = #line) -> T? {
        checks += 1
        if value == nil { record("\(label): expected non-nil (line \(line))") }
        return value
    }

    static func throwsError(_ label: String, _ body: () throws -> Void, line: Int = #line) {
        checks += 1
        do {
            try body()
            record("\(label): expected an error but none was thrown (line \(line))")
        } catch {
            // Expected.
        }
    }

    static func finish() -> Never {
        print("\n" + String(repeating: "─", count: 60))
        if failures.isEmpty {
            print("\u{001B}[32mAll checks passed\u{001B}[0m — \(checks) assertions")
            exit(0)
        }
        print("\u{001B}[31m\(failures.count) failure(s)\u{001B}[0m of \(checks) assertions\n")
        for failure in failures { print("  • \(failure)") }
        exit(1)
    }
}

import CoreGraphics
import Foundation

/// A tiny test kit: no macros, no XCTest. Each test target's main.swift is `runTests([...])`.
public struct TestCase {
    let name: String
    let body: @MainActor () throws -> Void
}

public struct Suite {
    let name: String
    let tests: [TestCase]
    public init(_ name: String, _ tests: [TestCase]) {
        self.name = name
        self.tests = tests
    }
}

public func test(_ name: String, _ body: @escaping @MainActor () throws -> Void) -> TestCase {
    TestCase(name: name, body: body)
}

@MainActor private var failures: [String] = []

@MainActor
public func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !condition { failures.append("\(file):\(line): expectation failed \(message())") }
}

@MainActor
public func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    if actual != expected { failures.append("\(file):\(line): \(actual) is not \(expected) \(message())") }
}

@MainActor
public func expectClose(_ actual: CGFloat, _ expected: CGFloat, within tolerance: CGFloat = 1e-6, file: StaticString = #fileID, line: UInt = #line) {
    if abs(actual - expected) > tolerance { failures.append("\(file):\(line): \(actual) is not within \(tolerance) of \(expected)") }
}

@MainActor
public func expectClose(_ actual: CGPoint, _ expected: CGPoint, within tolerance: CGFloat = 1e-6, file: StaticString = #fileID, line: UInt = #line) {
    if hypot(actual.x - expected.x, actual.y - expected.y) > tolerance {
        failures.append("\(file):\(line): \(actual) is not within \(tolerance) of \(expected)")
    }
}

@MainActor
public func expectThrows<E: Error & Equatable>(_ expected: E, file: StaticString = #fileID, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        failures.append("\(file):\(line): expected \(expected) to be thrown; nothing was")
    } catch let error as E {
        if error != expected { failures.append("\(file):\(line): threw \(error), expected \(expected)") }
    } catch {
        failures.append("\(file):\(line): threw \(error), expected \(expected)")
    }
}

public struct RequireFailed: Error { public init() {} }

// Async work in a synchronous test. Tasks on the main actor, and what they wait for (a URLSession's
// answer, a continuation resumed), land while the main run loop runs, so a test runs it.

/// Runs the main run loop, a turn at a time, until `done` holds; fails the test if it doesn't within
/// `timeout` seconds, and returns whether it did. Always runs at least one turn.
@MainActor @discardableResult
public func spinRunLoop(until done: () -> Bool, timeout: TimeInterval = 2, file: StaticString = #fileID, line: UInt = #line) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    repeat {
        guard Date() < deadline else {
            failures.append("\(file):\(line): timed out after \(timeout) s")
            return false
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
    } while !done()
    return true
}

/// Runs `body` to its end, turning the main run loop meanwhile, and returns what it returns, or
/// throws what it throws; fails the test (and stops it) if it takes longer than `timeout` seconds.
@MainActor
public func awaitResult<T>(timeout: TimeInterval = 5, file: StaticString = #fileID, line: UInt = #line,
                           _ body: @escaping @MainActor () async throws -> T) throws -> T {
    let outcome = Outcome<T>()
    let task = Task { @MainActor in
        do { outcome.result = .success(try await body()) } catch { outcome.result = .failure(error) }
    }
    guard spinRunLoop(until: { outcome.result != nil }, timeout: timeout, file: file, line: line), let result = outcome.result else {
        task.cancel()
        throw RequireFailed()
    }
    return try result.get()
}

@MainActor private final class Outcome<T> {
    var result: Result<T, any Error>?
}

/// How long `body` kept this thread running: what a test holding code to a time budget measures,
/// since wall time counts whatever else the machine runs (the other test executables, run at once).
public func threadCPUTime(_ body: () throws -> Void) rethrows -> Duration {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    try body()
    return .nanoseconds(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start)
}

/// Unwraps, or fails the test and stops it.
@MainActor
public func require<T>(_ value: T?, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else {
        failures.append("\(file):\(line): required value was nil \(message())")
        throw RequireFailed()
    }
    return value
}

/// Runs every test (TEST_FILTER=substring runs the matching ones; empty means all), prints failures
/// with file:line, ends with "N passed, M failed" (test.sh reads it), and exits 1 if any failed.
/// TEST_TIMES=1 writes each test's seconds to standard error ("0.123 Suite: test").
@MainActor
public func runTests(_ suites: [Suite]) -> Never {
    // Line-buffered even into a file (test.sh sends this to one), so a crash doesn't swallow what came before.
    setvbuf(stdout, nil, _IOLBF, 0)
    let environment = ProcessInfo.processInfo.environment
    let filter = environment["TEST_FILTER"].flatMap { $0.isEmpty ? nil : $0 }
    let timed = environment["TEST_TIMES"] == "1"
    var passed = 0, failed = 0
    for suite in suites {
        for test in suite.tests {
            let name = "\(suite.name): \(test.name)"
            if let filter, !name.localizedCaseInsensitiveContains(filter) { continue }
            failures = []
            let start = Date()
            do { try test.body() } catch is RequireFailed {} catch { failures.append("threw \(error)") }
            if timed { FileHandle.standardError.write(Data((String(format: "%.3f ", Date().timeIntervalSince(start)) + name + "\n").utf8)) }
            if failures.isEmpty {
                passed += 1
            } else {
                failed += 1
                print("FAIL \(name)")
                for failure in failures { print("     \(failure)") }
            }
        }
    }
    print("\(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

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
@MainActor
public func runTests(_ suites: [Suite]) -> Never {
    // Line-buffered even into a pipe (test.sh tees this), so a crash doesn't swallow what came before.
    setvbuf(stdout, nil, _IOLBF, 0)
    let filter = ProcessInfo.processInfo.environment["TEST_FILTER"].flatMap { $0.isEmpty ? nil : $0 }
    var passed = 0, failed = 0
    for suite in suites {
        for test in suite.tests {
            let name = "\(suite.name): \(test.name)"
            if let filter, !name.localizedCaseInsensitiveContains(filter) { continue }
            failures = []
            do { try test.body() } catch is RequireFailed {} catch { failures.append("threw \(error)") }
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

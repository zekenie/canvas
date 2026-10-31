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
/// It marks the suite running now as one that holds a time budget, in a process that holds them
/// (`runTests`' `holdsBudgets`), so test.sh runs it with little else running: the thread's own time
/// is about half again as long with every core busy (the clocks slow, the caches are shared).
public func threadCPUTime(_ body: () throws -> Void) rethrows -> Duration {
    if budgetsHeld { measuredForBudget = true }
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

@MainActor private var endings: [@MainActor () -> Void] = []

/// Runs `body` as the test running now ends, after `afterEach`, in its pool, in the order asked:
/// for what a helper made for that test alone (ShippedTesting's pasteboard, released). Asked
/// outside a test, it runs as the next test ends.
@MainActor
public func afterThisTest(_ body: @escaping @MainActor () -> Void) {
    endings.append(body)
}

/// Runs `body` as `runTests` runs a test, and returns its failures (file:line and what failed),
/// which aren't the calling test's: in an autorelease pool of its own, as the app handles each event
/// in one, so what it let go is gone when it returns. Without the pool nothing a test made with
/// AppKit went (no run loop here drains one): its windows, their views and what those had scheduled
/// (a panel handing the keyboard back a turn later) lived on into the tests after it. What `body`
/// asks to run as it ends (`afterThisTest`) runs as it returns, and the calling test's waits.
@MainActor
public func runAsTest(_ body: @MainActor () throws -> Void, afterEach: @MainActor () -> Void = {}) -> [String] {
    let outer = failures, outerEndings = endings
    failures = []
    endings = []
    defer { failures = outer; endings = outerEndings }
    autoreleasepool {
        do { try body() } catch is RequireFailed {} catch { failures.append("threw \(error)") }
        afterEach()
        while !endings.isEmpty { endings.removeFirst()() }
    }
    return failures
}

/// Runs every test (TEST_FILTER=substring runs the matching ones; empty means all), prints failures
/// with file:line, ends with "N passed, M failed" (test.sh reads it), and exits 1 if any failed.
/// TEST_TIMES=1 writes each test's seconds to standard error ("0.123 Suite: test"). `afterEach` runs
/// after each test, whatever it did, as part of it: what it expects there fails that test; then what
/// the test asked to run as it ends (`afterThisTest`). Each test runs as `runAsTest` runs one.
///
/// test.sh runs a long executable as several processes at once, each running a share of its
/// suites: TEST_SHARD=k/n runs the k-th of n (`shares`), then `closing`, which every share runs whole
/// after its own (a suite that judges what the suites before it in the process reported, as
/// BenchmarkTests' Scaling does). TEST_SUITE_TIMES=file writes each suite's seconds there as it ends
/// ("seconds<TAB>suite", and "<TAB>budget" after one that measured with `threadCPUTime` while
/// `holdsBudgets`), but for `closing`'s, which test.sh keeps for the next run's shares as TEST_WEIGHTS;
/// TEST_BUDGETS=skip runs only the suites it doesn't mark so, and TEST_BUDGETS=only only those it
/// does, before any share is dealt. A process whose measures are reports, not budgets (BenchmarkTests
/// in a debug build) says `holdsBudgets: false`.
@MainActor
public func runTests(_ suites: [Suite], closing: [Suite] = [], holdsBudgets: Bool = true, afterEach: @MainActor () -> Void = {}) -> Never {
    // Line-buffered even into a file (test.sh sends this to one), so a crash doesn't swallow what came before.
    setvbuf(stdout, nil, _IOLBF, 0)
    budgetsHeld = holdsBudgets
    let environment = ProcessInfo.processInfo.environment
    let filter = environment["TEST_FILTER"].flatMap { $0.isEmpty ? nil : $0 }
    let timed = environment["TEST_TIMES"] == "1"
    let weights = environment["TEST_WEIGHTS"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
    var suites = suites
    var keys = suiteKeys(suites), records = suiteRecords(weights, keys: suiteKeys(suites))
    func keep(_ positions: [Int]) {
        (suites, keys, records) = (positions.map { suites[$0] }, positions.map { keys[$0] }, positions.map { records[$0] })
    }
    if let budgets = environment["TEST_BUDGETS"], !budgets.isEmpty {
        guard budgets == "skip" || budgets == "only" else {
            print("TEST_BUDGETS is skip or only; not '\(budgets)'")
            exit(2)
        }
        keep(suites.indices.filter { (records[$0]?.holdsBudget ?? false) == (budgets == "only") })
    }
    if let shard = environment["TEST_SHARD"], !shard.isEmpty {
        let parts = shard.split(separator: "/", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 2, let k = parts[0], let n = parts[1], n >= 1, (1...n).contains(k) else {
            print("TEST_SHARD is k/n, the k-th of n shares (k from 1); not '\(shard)'")
            exit(2)
        }
        // Past one share a suite, the rest are empty, so a count of millions deals no more than that.
        let count = min(n, max(suites.count, 1))
        keep(k <= count ? shares(suites, of: count, records: records)[k - 1] : [])
    }
    let dealt = suites.count
    suites += closing
    let times = environment["TEST_SUITE_TIMES"].flatMap { path -> FileHandle? in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
    var passed = 0, failed = 0
    for (index, suite) in suites.enumerated() {
        let began = Date()
        var failedHere = false
        measuredForBudget = false
        defer {
            if index < dealt {
                // One that failed before it measured keeps the mark it had.
                let budget = measuredForBudget || failedHere && records[index]?.holdsBudget == true
                let line = String(format: "%.3f\t", Date().timeIntervalSince(began)) + keys[index] + (budget ? "\tbudget" : "")
                times?.write(Data((line + "\n").utf8))
            }
        }
        for test in suite.tests {
            let name = "\(suite.name): \(test.name)"
            if let filter, !name.localizedCaseInsensitiveContains(filter) { continue }
            let start = Date()
            let failures = runAsTest(test.body, afterEach: afterEach)
            if timed { FileHandle.standardError.write(Data((String(format: "%.3f ", Date().timeIntervalSince(start)) + name + "\n").utf8)) }
            if failures.isEmpty {
                passed += 1
            } else {
                failed += 1
                failedHere = true
                print("FAIL \(name)")
                for failure in failures { print("     \(failure)") }
            }
        }
    }
    print("\(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

/// Whether the suite running now measured a thread's time while its process holds budgets: the mark
/// `runTests` writes after it. Set wherever `threadCPUTime` is called (a test on another thread
/// writes it too, while the test thread waits for it) and read on the test thread as the suite ends.
nonisolated(unsafe) private var measuredForBudget = false
nonisolated(unsafe) private var budgetsHeld = true

/// What a run kept of a suite: its seconds, and whether it held a time budget.
struct SuiteRecord {
    let seconds: Double
    let holdsBudget: Bool
}

/// What each suite is called in what a run keeps: its name, and for one of a name that more than one
/// suite has, which of them it is in the order given ("Drawing #2"), since the shares' lines are
/// joined in no order of the suites'.
func suiteKeys(_ suites: [Suite]) -> [String] {
    var named: [String: Int] = [:], seen: [String: Int] = [:]
    for suite in suites { named[suite.name, default: 0] += 1 }
    return suites.map { suite in
        guard named[suite.name, default: 0] > 1 else { return suite.name }
        seen[suite.name, default: 0] += 1
        return "\(suite.name) #\(seen[suite.name]!)"
    }
}

/// Each suite's record in `weights` (lines of "seconds<TAB>suite", "<TAB>budget" after one that held
/// a time budget), by its key (`suiteKeys`), nil for one with none.
func suiteRecords(_ weights: String, keys: [String]) -> [SuiteRecord?] {
    var kept: [String: SuiteRecord] = [:]
    for line in weights.split(separator: "\n") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3, let value = Double(fields[0]) else { continue }
        kept[String(fields[1])] = SuiteRecord(seconds: value, holdsBudget: fields.count == 3 && fields[2] == "budget")
    }
    return keys.map { kept[$0] }
}

/// Deals `suites` out into `count` shares, as the positions of each share's suites in the order
/// given: heaviest first, each to the share with the least so far (the first such), so the shares
/// take about as long as each other and every process dealing them deals them the same. A suite
/// weighs its seconds in its record (`suiteRecords`), else its tests at the mean seconds a test took
/// in the suites that have one (one each when none has).
func shares(_ suites: [Suite], of count: Int, records: [SuiteRecord?]) -> [[Int]] {
    let known = records.map { $0?.seconds }
    let timed = zip(suites, known).filter { $0.1 != nil }
    let tests = timed.reduce(0) { $0 + $1.0.tests.count }
    let perTest = tests == 0 ? 1 : timed.reduce(0) { $0 + $1.1! } / Double(tests)
    let weight = zip(suites, known).map { $0.1 ?? Double($0.0.tests.count) * perTest }
    var dealt = Array(repeating: [Int](), count: count), load = Array(repeating: 0.0, count: count)
    for index in suites.indices.sorted(by: { weight[$0] > weight[$1] || weight[$0] == weight[$1] && $0 < $1 }) {
        let lightest = load.indices.min { load[$0] < load[$1] || load[$0] == load[$1] && $0 < $1 }!
        dealt[lightest].append(index)
        load[lightest] += weight[index]
    }
    return dealt.map { $0.sorted() }
}

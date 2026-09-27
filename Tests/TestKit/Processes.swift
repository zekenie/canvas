import Foundation

// For tests of the command line and the app's end of it: a socket path of their own, work on
// another thread while the main run loop turns (the app answers requests on the main actor), and
// the command line itself, run as it's built.

/// A path for a test's socket, short enough for one (a socket's path has at most 103 bytes), in
/// this user's temporary folder.
public func temporarySocketPath() -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)      // with its terminating zero
    let folder = length > 1 ? String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "/tmp/"
    return folder + "rpc-\(UUID().uuidString.prefix(8)).sock"
}

/// A value one thread sets and another reads.
public final class Handoff<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    public init() {}
    public var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Runs `body` on another thread, turning the main run loop until it's done (or `timeout` seconds
/// pass, and it's nil), and returns what it returned.
@MainActor
public func offMain<Value: Sendable>(timeout: TimeInterval = 10, _ body: @escaping @Sendable () -> Value) -> Value? {
    let result = Handoff<Value>()
    Thread { result.value = body() }.start()
    let deadline = Date(timeIntervalSinceNow: timeout)
    while result.value == nil, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
    return result.value
}

/// An executable build.sh built beside this test's: `build/<config>/<name>/<name>`.
public func builtExecutable(_ name: String) -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("\(name)/\(name)")
}

/// What a process did: its exit status, and what it wrote.
public struct ProcessOutput: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
}

/// Runs an executable to its end, turning the main run loop meanwhile (so an app's end of a socket,
/// on the main actor, can answer it). Its standard input is `input`, or nothing.
@MainActor
public func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:], input: String? = nil,
                timeout: TimeInterval = 20) throws -> ProcessOutput {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    // Files, not pipes: a pipe that fills stops the process until it's read.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let out = folder.appendingPathComponent("out"), err = folder.appendingPathComponent("err"), inp = folder.appendingPathComponent("in")
    FileManager.default.createFile(atPath: out.path, contents: nil)
    FileManager.default.createFile(atPath: err.path, contents: nil)
    FileManager.default.createFile(atPath: inp.path, contents: Data((input ?? "").utf8))
    process.standardOutput = try FileHandle(forWritingTo: out)
    process.standardError = try FileHandle(forWritingTo: err)
    process.standardInput = try FileHandle(forReadingFrom: inp)
    try process.run()
    let deadline = Date(timeIntervalSinceNow: timeout)
    while process.isRunning, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
    }
    return ProcessOutput(status: process.terminationStatus, output: try String(contentsOf: out, encoding: .utf8),
                         error: try String(contentsOf: err, encoding: .utf8))
}

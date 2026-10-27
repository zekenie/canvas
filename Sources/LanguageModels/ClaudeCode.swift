import Darwin
import Foundation
import os

/// Claude Code, the person's own `claude` program, as the app runs it: found once, then run with an
/// environment of the app's making and the app's own configuration folder (`configDirectory`), so
/// none of the person's own Claude Code setup is read or written: their settings, hooks, CLAUDE.md,
/// memory, plugins, history and sign-in stay as they are. The app never sees a token: `claude`
/// signs in through Anthropic's own page and keeps the app's sign-in in a Keychain entry it keys to
/// that folder, and the app only asks it whether it's signed in (`status()`), to sign in
/// (`signIn()`) or out (`signOut()`), and to answer (`ClaudeCodeModel`).
///
/// Every run has Claude Code's background updates off (`DISABLE_AUTOUPDATER`), so no run of the
/// app's updates the program, and every run writes only in the app's folder, so any run may be
/// stopped partway.
public struct ClaudeCode: Sendable {
    /// Where the program is, looked for again even if it wasn't found a moment ago when the
    /// argument says so; nil when it isn't installed.
    let locate: @Sendable (_ lookAgain: Bool) -> URL?
    /// The app's Claude Code configuration (`CLAUDE_CONFIG_DIR` for every run): its sign-in, its
    /// settings, what Claude Code caches. Never the person's own (`~/.claude`).
    public let configDirectory: URL

    /// The program at `executable`, configured in `configDirectory` (tests give a script and a
    /// temporary directory).
    public init(executable: URL, configDirectory: URL) {
        locate = { _ in FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil }
        self.configDirectory = configDirectory
    }

    /// The person's program, found as their login shell finds it, else where Claude Code's
    /// installers put it, and kept once found (`ClaudeCodeLocator`); configured in the app's folder.
    public static let standard = ClaudeCode(locator: ClaudeCodeLocator(), configDirectory: standardConfigDirectory)

    /// The app's: `~/Library/Application Support/InfiniteCanvas/claude-code`, beside the key.
    public static var standardConfigDirectory: URL {
        AnthropicKeyStore.standard.url.deletingLastPathComponent().appending(path: "claude-code", directoryHint: .isDirectory)
    }

    init(locator: ClaudeCodeLocator, configDirectory: URL) {
        locate = { locator.find(lookingAgain: $0) }
        self.configDirectory = configDirectory
    }

    /// The program; nil when it isn't installed, or wasn't a moment ago (a model's call on every
    /// edit doesn't look for it each time), or, with `lookingAgain`, looked for now. Looked for on a
    /// thread of GCD's, never one Swift's tasks run on: a login shell may take seconds.
    public func executable(lookingAgain: Bool = false) async -> URL? {
        let locate = locate
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: locate(lookingAgain)) }
        }
    }

    /// Whether `claude` said a moment ago that the app isn't signed in in this folder: a model's
    /// call fails at once then, rather than start a run that would say it again, until a status
    /// check or a sign-in says otherwise, or `ClaudeCodeSignedOut.wait` passes.
    var isKnownSignedOut: Bool { ClaudeCodeSignedOut.isKnown(configDirectory) }

    /// Keeps whether `claude` said the app is signed out in this folder.
    func remember(signedOut: Bool) { ClaudeCodeSignedOut.set(configDirectory, signedOut) }

    // MARK: Signing in

    /// How long `status()` waits for `claude auth status`.
    static let statusTimeout: TimeInterval = 15
    /// How long `signIn()` waits for the person to approve in their browser.
    static let signInTimeout: TimeInterval = 600
    /// How long `signOut()` waits for `claude auth logout`.
    static let signOutTimeout: TimeInterval = 30

    /// Whether Claude Code is installed and the app signed in to it, and as whom: `claude auth
    /// status`, which answers in JSON. It looks for the program again, so an install made a moment
    /// ago is found.
    public func status() async -> ClaudeCodeStatus {
        guard let executable = await executable(lookingAgain: true) else { return .notInstalled }
        guard let output = try? await run(executable, ["auth", "status"], timeout: Self.statusTimeout) else { return .signedOut }
        let status = Self.status(fromJSON: output.stdout)
        if case .signedIn = status { remember(signedOut: false) } else { remember(signedOut: true) }
        return status
    }

    /// What `claude auth status` says: signed in, with the account's email and plan where it gives
    /// them, or signed out (anything else, an answer that can't be read included).
    public static func status(fromJSON data: Data) -> ClaudeCodeStatus {
        struct Status: Decodable {
            let loggedIn: Bool?
            let email: String?
            let subscriptionType: String?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: data), status.loggedIn == true else { return .signedOut }
        return .signedIn(ClaudeCodeAccount(email: status.email.flatMap { $0.isEmpty ? nil : $0 },
                                           plan: status.subscriptionType.flatMap(ClaudeCodeAccount.planName)))
    }

    /// Signs the app in with the person's Claude account: `claude auth login --claudeai`, which
    /// opens Anthropic's page in their browser and ends once they've approved there; it needs no
    /// terminal. What it comes to is `status()` after, or `.signedOut` when the task asking was
    /// cancelled (Cancel), which stops it.
    public func signIn() async -> ClaudeCodeStatus {
        guard let executable = await executable(lookingAgain: true) else { return .notInstalled }
        do throws(ProcessFailure) {
            _ = try await run(executable, ["auth", "login", "--claudeai"], timeout: Self.signInTimeout)
        } catch {
            if error == .cancelled { return .signedOut }
        }
        return await status()
    }

    /// Signs the app out (`claude auth logout`, which also revokes the sign-in), then says where
    /// that leaves it.
    public func signOut() async -> ClaudeCodeStatus {
        guard let executable = await executable(lookingAgain: true) else { return .notInstalled }
        _ = try? await run(executable, ["auth", "logout"], timeout: Self.signOutTimeout)
        return await status()
    }

    // MARK: Running it

    /// Runs `executable` with `arguments` in an empty directory, with the app's folder and its
    /// environment (`environment(for:extra:)`), `input` on its standard input; stopped when the
    /// task asking is cancelled or `timeout` passes.
    func run(_ executable: URL, _ arguments: [String], input: Data = Data(), extra: [String: String] = [:],
             timeout: TimeInterval) async throws(ProcessFailure) -> ProcessOutput {
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return try await Subprocess.run(executable, arguments, input: input, environment: environment(for: executable, extra: extra),
                                        directory: Self.workingDirectory(), timeout: timeout)
    }

    /// The variables `claude` gets from the app's own environment: who and where the person is,
    /// their language, and any proxy. Nothing else: not an `ANTHROPIC_API_KEY` or another
    /// credential, which `claude -p` would use in place of the sign-in, nor the variables of a
    /// Claude Code session the app was started from, which would make this run that session's.
    public static let inheritedVariables: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy", "NODE_EXTRA_CA_CERTS",
    ]

    /// What every run of `claude` is given whatever the app's environment says: the app's folder as
    /// Claude Code's configuration, and its background updates off.
    public var fixedVariables: [String: String] {
        ["CLAUDE_CONFIG_DIR": configDirectory.path, "DISABLE_AUTOUPDATER": "1"]
    }

    /// Where a program is looked for besides the directory `claude` is in (an install that runs on
    /// Node needs `node` beside it).
    public static let standardPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// `claude`'s environment: `inheritedVariables` of `inherited`, `PATH` (the directory it was
    /// found in, the one it resolves to, then `standardPath`), `extra`, and `fixedVariables` over
    /// all of them.
    public func environment(for executable: URL, inherited: [String: String] = ProcessInfo.processInfo.environment,
                            extra: [String: String] = [:]) -> [String: String] {
        var environment = inherited.filter { Self.inheritedVariables.contains($0.key) }
        var path: [String] = []
        for directory in [executable.deletingLastPathComponent().path, executable.resolvingSymlinksInPath().deletingLastPathComponent().path]
            + Self.standardPath where !path.contains(directory) {
            path.append(directory)
        }
        environment["PATH"] = path.joined(separator: ":")
        environment.merge(extra) { $1 }
        environment.merge(fixedVariables) { $1 }
        return environment
    }

    /// An empty directory `claude` runs in, outside the person's home, so no project's
    /// instructions or settings are read there or in the directories above it.
    static func workingDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "InfiniteCanvas-ClaudeCode", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// The app's folders whose `claude` said the app isn't signed in there, and when (`ClaudeCode.isKnownSignedOut`).
enum ClaudeCodeSignedOut {
    private static let known = OSAllocatedUnfairLock<[URL: Date]>(initialState: [:])

    /// How long a run's word that the app is signed out stands without a status check.
    static let wait: TimeInterval = 300

    static func isKnown(_ folder: URL) -> Bool {
        known.withLock { known in known[folder].map { Date().timeIntervalSince($0) < wait } ?? false }
    }

    static func set(_ folder: URL, _ signedOut: Bool) {
        known.withLock { $0[folder] = signedOut ? Date() : nil }
    }
}

/// Whether Claude Code can answer for the app.
public enum ClaudeCodeStatus: Equatable, Sendable {
    /// No `claude` was found.
    case notInstalled
    case signedOut
    case signedIn(ClaudeCodeAccount)
}

/// Who the app is signed in to Claude Code as, as far as it says.
public struct ClaudeCodeAccount: Equatable, Sendable {
    public var email: String?
    /// The plan, as Anthropic names it ("Max"); nil when it isn't said.
    public var plan: String?

    public init(email: String? = nil, plan: String? = nil) {
        self.email = email
        self.plan = plan
    }

    /// A plan's name from `subscriptionType` ("max" is "Max"); nil for none.
    static func planName(_ type: String) -> String? {
        let type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty else { return nil }
        return type.prefix(1).uppercased() + type.dropFirst()
    }
}

/// Finds `claude` once and keeps where: first as the person's login shell finds it (their terminal's
/// `PATH`, which an app opened from the Finder doesn't have), its directory's links followed (a
/// version manager's per-shell directory is a shell's own), else where Claude Code's installers put it. A program that's
/// gone since is looked for again; one not found isn't looked for again for `notFoundWait`, so calls
/// made meanwhile (a type's sync on every edit) don't each start a shell. One looks at a time: calls
/// that come while it looks wait for its answer.
public final class ClaudeCodeLocator: Sendable {
    private struct Found {
        var url: URL?
        /// When nothing was found, if it wasn't.
        var missedAt: Date?
    }

    private let found = OSAllocatedUnfairLock<Found>(initialState: Found())
    private let looking = DispatchQueue(label: "InfiniteCanvas.ClaudeCodeLocator")

    /// How long a lookup that found nothing stands.
    static let notFoundWait: TimeInterval = 30

    /// How long the login shell may take to say where `claude` is.
    static let shellTimeout: TimeInterval = 10
    /// Where Claude Code's installers put it, in their order of preference.
    static let knownPaths = ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    /// What marks the shell's answer among what its start-up files print.
    public static let marker = "__infinite_canvas_claude__="

    func find(lookingAgain: Bool = false) -> URL? {
        looking.sync {
            let known = found.withLock { $0 }
            if let url = known.url, FileManager.default.isExecutableFile(atPath: url.path) { return url }
            if !lookingAgain, let missed = known.missedAt, Date().timeIntervalSince(missed) < Self.notFoundWait { return nil }
            let url = Self.fromLoginShell() ?? Self.fromKnownPaths()
            found.withLock { $0 = Found(url: url, missedAt: url == nil ? Date() : nil) }
            return url
        }
    }

    static func fromKnownPaths() -> URL? {
        knownPaths.lazy.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }.map(steady)
    }

    /// `url` with its directory's links followed but not its own: a version manager's per-shell
    /// directory becomes the version's, which stays, and `node` is beside it, for a Claude Code
    /// that runs on Node (`environment(for:)` puts both the program's directory and the one it
    /// resolves to on `PATH`).
    static func steady(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent, directoryHint: .notDirectory)
    }

    /// `command -v claude` in an interactive login shell, so its start-up files run as a terminal's
    /// do; waited for on this thread (it's asked off the main actor, from a model's call or a
    /// status).
    static func fromLoginShell() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '\\n\(marker)%s\\n' \"$(command -v claude)\""]
        process.environment = ProcessInfo.processInfo.environment.filter { ClaudeCode.inheritedVariables.contains($0.key) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Waited for by its handler: `waitUntilExit` off the main thread can miss the end.
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        let running = Unchecked(process)
        let deadline = DispatchWorkItem { running.value.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + shellTimeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = ended.wait(timeout: .now() + shellTimeout)
        deadline.cancel()
        return path(fromShellOutput: data)
    }

    /// The path after `marker`, if it names a program that runs, its directory's links followed
    /// (`steady`).
    public static func path(fromShellOutput data: Data) -> URL? {
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last { $0.hasPrefix(marker) }
        guard let path = line.map({ String($0.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces) }),
              path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return steady(URL(fileURLWithPath: path))
    }
}

/// What isn't `Sendable`, handed to the one thread that uses it at a time.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// How a program ended and what it wrote, set by the threads that learn it, and answered once.
private final class Collected: Sendable {
    private struct Parts {
        var status: Int32 = 0
        var stopped: ProcessFailure?
        var stdout = Data()
        var stderr = Data()
        var answered = false
    }

    private let parts = OSAllocatedUnfairLock(initialState: Parts())

    func ended(status: Int32, stopped: ProcessFailure?) {
        parts.withLock { $0.status = status; $0.stopped = stopped }
    }

    func add(_ chunk: Data, toErrors: Bool) {
        parts.withLock { if toErrors { $0.stderr.append(chunk) } else { $0.stdout.append(chunk) } }
    }

    /// The run's answer, the first time it's asked; nil after.
    func answer() -> Result<ProcessOutput, ProcessFailure>? {
        parts.withLock { parts in
            guard !parts.answered else { return nil }
            parts.answered = true
            return parts.stopped.map { .failure($0) } ?? .success(ProcessOutput(status: parts.status, stdout: parts.stdout, stderr: parts.stderr))
        }
    }
}

/// A program run to its end: what it wrote, and how it ended.
struct ProcessOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

/// Why a program run gave no output.
enum ProcessFailure: Error, Equatable {
    /// It couldn't be started, with the system's words.
    case notStarted(String)
    /// It ran past its time and was stopped.
    case timedOut
    /// The task waiting for it was cancelled, and it was stopped.
    case cancelled
}

enum Subprocess {
    /// How long a run waits for what a program wrote once it has ended: past it, what's read is its
    /// output.
    static let outputGrace: TimeInterval = 2
    /// Runs `executable` with `arguments` in `directory`, `input` on its standard input, and waits
    /// for it to end, at most `timeout` seconds; past that, or when the task waiting is cancelled,
    /// it's stopped (SIGTERM, as Control-C stops it in a terminal), waited for, and `.timedOut` or
    /// `.cancelled`.
    static func run(_ executable: URL, _ arguments: [String], input: Data = Data(), environment: [String: String],
                    directory: URL, timeout: TimeInterval) async throws(ProcessFailure) -> ProcessOutput {
        if Task.isCancelled { throw .cancelled }
        let run = Run()
        let result: Result<ProcessOutput, ProcessFailure> = await withTaskCancellationHandler {
            await run.start(executable, arguments, input: input, environment: environment, directory: directory, timeout: timeout)
        } onCancel: {
            run.stop(because: .cancelled)
        }
        return try result.get()
    }

    /// One program's run: started once, stopped at most once, for the first reason given, and
    /// answered once, when it ends.
    private final class Run: Sendable {
        private struct State {
            var process: Process?
            var stopped: ProcessFailure?
        }

        private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

        func start(_ executable: URL, _ arguments: [String], input: Data, environment: [String: String], directory: URL,
                   timeout: TimeInterval) async -> Result<ProcessOutput, ProcessFailure> {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            // A program that ends before it has read what it's given makes the write fail, never
            // stop the app with SIGPIPE.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            let alreadyStopped: ProcessFailure? = state.withLockUnchecked { state in
                if state.stopped == nil { state.process = process }
                return state.stopped
            }
            if let alreadyStopped { return .failure(alreadyStopped) }
            // Done when it has ended (its status, said by the handler, the one place it's sure to be
            // set) and all it wrote is read, or `outputGrace` after it ended, should something it
            // started hold its output open. Written, read and waited for on the system's threads,
            // not the tasks' own: a program that writes before it has read all it's given never
            // waits on the app, and a long answer holds no thread Swift's tasks run on.
            let collected = Collected()
            let group = DispatchGroup(), exited = DispatchGroup()
            group.enter()
            exited.enter()
            process.terminationHandler = { [weak self] ended in
                // Why it was stopped, if it was before it ended: a deadline that passes once it has
                // ended, while what it wrote is still being read, doesn't take its answer away.
                collected.ended(status: ended.terminationStatus, stopped: self?.state.withLockUnchecked { $0.stopped })
                exited.leave()
                group.leave()
            }
            do {
                try process.run()
            } catch {
                return .failure(.notStarted(error.localizedDescription))
            }
            // Stopped while it was starting: it's running now, so it can be.
            if state.withLockUnchecked({ $0.stopped }) != nil { process.terminate() }
            let deadline = DispatchWorkItem { [weak self] in self?.stop(because: .timedOut) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            let pipes = Unchecked((stdin, stdout, stderr))
            DispatchQueue.global().async(group: group) {
                try? pipes.value.0.fileHandleForWriting.write(contentsOf: input)
                try? pipes.value.0.fileHandleForWriting.close()
            }
            for (pipe, toErrors) in [(pipes.value.1, false), (pipes.value.2, true)] {
                let handle = Unchecked(pipe.fileHandleForReading)
                DispatchQueue.global().async(group: group) {
                    while case let chunk = handle.value.availableData, !chunk.isEmpty { collected.add(chunk, toErrors: toErrors) }
                }
            }
            return await withCheckedContinuation { continuation in
                let pending = Unchecked(deadline)
                let finish: @Sendable () -> Void = {
                    guard let answer = collected.answer() else { return }
                    pending.value.cancel()
                    continuation.resume(returning: answer)
                }
                group.notify(queue: .global(), execute: finish)
                exited.notify(queue: .global()) { DispatchQueue.global().asyncAfter(deadline: .now() + Subprocess.outputGrace, execute: finish) }
            }
        }

        /// Stops the program for `reason`, once (a later reason is ignored): SIGTERM, then its end
        /// is waited for as any end is.
        func stop(because reason: ProcessFailure) {
            let process: Process?? = state.withLockUnchecked { state in
                guard state.stopped == nil else { return .none }
                state.stopped = reason
                return .some(state.process)
            }
            guard case let .some(process) = process, let process, process.isRunning else { return }
            process.terminate()
        }
    }
}

/// How many `claude -p` the app runs at once, at most: a type's sync over many notes asks many
/// questions together, and each is a program of its own on the person's machine. A call waits its
/// turn here, and waiting is cancellable.
public actor ClaudeCodeTurns {
    public static let shared = ClaudeCodeTurns(limit: 4)

    public let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    public init(limit: Int) { self.limit = limit }

    /// Waits for a turn: true once it has one, false if the task asking was cancelled first.
    func take() async -> Bool {
        if Task.isCancelled { return false }
        if running < limit {
            running += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) } else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.giveUp(id) }
        }
    }

    /// Ends a turn taken, handing it to the next waiting.
    func done() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().continuation.resume(returning: true)
        }
    }

    private func giveUp(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}

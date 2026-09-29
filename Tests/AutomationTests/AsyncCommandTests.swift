import Automation
import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import TestKit

// Commands that answer later (`runAsync:`), as one that waits on a language model does, beside
// those that answer at once (`run:`), as `draw` and `kinds` do: run as the app's command server runs
// them, through `runAutomationCommand`.

/// What the test holds a command at: it waits there until the test lets it go, or its task is
/// cancelled.
@MainActor
final class Gate {
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false

    var isWaiting: Bool { waiting != nil }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting = $0 }
        } onCancel: {
            Task { @MainActor in
                self.wasCancelled = true
                self.open()
            }
        }
    }

    func open() {
        waiting?.resume()
        waiting = nil
    }
}

/// Where an output was written and let go of.
final class ThreadLog: Sendable {
    let encodedOnMain = Handoff<Bool>()
    let freedOnMain = Handoff<Bool>()
}

/// Something an output holds, which notes where it was let go of.
final class Probe: Sendable {
    let log: ThreadLog

    init(_ log: ThreadLog) {
        self.log = log
    }

    deinit { log.freedOnMain.value = Thread.isMainThread }
}

/// An output that notes where it was written.
struct Tracked: Encodable, Sendable {
    let probe: Probe

    private enum Keys: String, CodingKey { case name }

    func encode(to encoder: any Encoder) throws {
        probe.log.encodedOnMain.value = Thread.isMainThread
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode("tracked", forKey: .name)
    }
}

/// A value the main actor's other work sets, for a test to see whether it ran.
@MainActor
final class Flag {
    var isSet = false
}

/// Commands of each sort: `now` answers at once; `later` waits at the gate; `tracked` answers an
/// output that notes where it was written and freed; `raw` answers JSON of its own, with a number
/// that isn't finite, which writing it as JSON would refuse; `wrong` fails with where, and more.
@MainActor func asyncCommands(_ gate: Gate, _ log: ThreadLog) -> Contributor {
    Contributor(id: "waiting") { registrar in
        registrar.automationCommand("now", "Answer at once.", scope: .app, params: NoParams.self,
                                    run: { _, _ throws(AutomationError) -> [String: String] in ["answered": "now"] })
        registrar.automationCommand("later", "Answer once let go.", scope: .app, params: NoParams.self,
                                    runAsync: { _, _ throws(AutomationError) -> [String: String] in
            await gate.wait()
            if gate.wasCancelled { throw AutomationError("It was cancelled.", reason: "cancelled") }
            return ["answered": "later"]
        })
        registrar.automationCommand("tracked", "Answer something that notes where it goes.", scope: .app, params: NoParams.self,
                                    runAsync: { _, _ throws(AutomationError) in Tracked(probe: Probe(log)) })
        registrar.automationCommand("raw", "Answer JSON as it is.", scope: .app, params: NoParams.self,
                                    runAsync: { _, _ throws(AutomationError) in JSON.object(["ratio": .number(.nan), "rows": [["id": 1]]]) })
        registrar.automationCommand("wrong", "Fail, saying where.", scope: .app, params: NoParams.self, runAsync: { _, _ throws(AutomationError) -> JSON in
            let first = AutomationError(":mention isn't a pseudo-class.", reason: "unknown_word", hint: "Did you mean :mentions?", line: 1, column: 12,
                                        length: 8, statement: #"note:mention("API")"#, details: ["query": "note:mention"])
            // Its own members are its own whether it has them or not: no detail stands in for a hint or
            // a place it hasn't.
            let second = AutomationError("\"API\" isn't in the file.", reason: "unknown_title", line: 1, column: 21, length: 5,
                                         statement: #"note:mention("API")"#, details: ["hint": "not a hint", "errors": [], "near": "Apis"])
            throw AutomationError(first.message, reason: first.reason, hint: first.hint, line: 1, column: 12, length: 8, statement: first.statement,
                                  errors: [first, second],
                                  details: ["query": "note:mention", "reason": "not this", "column": 99, "hint": "nor this", "transient": false])
        })
        registrar.automationCommand("bare", "Fail, saying nowhere.", scope: .app, params: NoParams.self, runAsync: { _, _ throws(AutomationError) -> JSON in
            throw AutomationError("It didn't work.", reason: "no_luck",
                                  details: ["hint": "not a hint", "line": 3, "statement": "x", "errors": [["message": "no"]], "message": "no", "tried": 2])
        })
    }
}

@MainActor func asyncRegistry(_ gate: Gate = Gate(), _ log: ThreadLog = ThreadLog()) throws -> Registry {
    try Registry(plugins: [AutomationPlugin(), asyncCommands(gate, log)])
}

/// Runs a command as the app's server does, and says what came back.
@MainActor func answer(_ name: String, in registry: Registry) async -> Result<JSON, RPCError> {
    do throws(RPCError) {
        return .success(try await registry.runAutomationCommand(name, params: [:], editor: nil))
    } catch {
        return .failure(error)
    }
}

@MainActor final class Answer {
    var result: Result<JSON, RPCError>?
}

@MainActor let asyncCommandTests = Suite("Commands that answer later", [
    test("a command made with run: answers in the turn it's asked in; one made with runAsync: gives the main actor a turn") {
        let registry = try asyncRegistry()
        /// What a command answered, and whether other work on the main actor ran while it did.
        @MainActor func run(_ name: String) throws -> (Result<JSON, RPCError>, interleaved: Bool) {
            try awaitResult {
                let other = Flag()
                Task { @MainActor in other.isSet = true }
                let result = await answer(name, in: registry)
                return (result, other.isSet)
            }
        }
        let now = try run("now")
        expectEqual(try now.0.get(), ["answered": "now"])
        expect(!now.interleaved, "nothing else ran on the main actor meanwhile")
        let tracked = try run("tracked")
        expectEqual(try tracked.0.get(), ["name": "tracked"])
        expect(tracked.interleaved, "its output was written elsewhere, the main actor free meanwhile")
    },
    test("a command made with runAsync: answers once what it waits for comes") {
        let gate = Gate()
        let registry = try asyncRegistry(gate)
        let answered = Answer()
        Task { @MainActor in answered.result = await answer("later", in: registry) }
        spinRunLoop(until: { gate.isWaiting })
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        expect(answered.result == nil, "still waiting")
        gate.open()
        spinRunLoop(until: { answered.result != nil })
        expectEqual(try answered.result?.get(), ["answered": "later"])
    },
    test("its output is written off the main actor, and let go of there") {
        let log = ThreadLog()
        let registry = try asyncRegistry(Gate(), log)
        let json = try awaitResult { try await registry.runAutomationCommand("tracked", params: [:], editor: nil) }
        expectEqual(json, ["name": "tracked"])
        expectEqual(log.encodedOnMain.value, false)
        expectEqual(log.freedOnMain.value, false)
    },
    test("an output that's JSON already goes back as it is, never written and read again") {
        let registry = try asyncRegistry()
        let json = try awaitResult { try await registry.runAutomationCommand("raw", params: [:], editor: nil) }
        expect(json["ratio"]?.numberValue?.isNaN == true, "writing it would refuse a number that isn't finite: \(json)")
        expectEqual(json["rows"], [["id": 1]])
    },
    test("cancelling the request cancels the command's task") {
        let gate = Gate()
        let registry = try asyncRegistry(gate)
        let answered = Answer()
        let task = Task { @MainActor in answered.result = await answer("later", in: registry) }
        spinRunLoop(until: { gate.isWaiting })
        task.cancel()
        spinRunLoop(until: { answered.result != nil })
        expect(gate.wasCancelled)
        guard case .failure(let error) = answered.result else { return expect(false, "\(String(describing: answered.result))") }
        expectEqual(error.reason, "cancelled")
    },
    test("an error says where on its line, and more, in its data, never over its own members") {
        let registry = try asyncRegistry()
        guard case .failure(let error) = try awaitResult({ await answer("wrong", in: registry) }) else { return expect(false, "it fails") }
        expectEqual(error.message, ":mention isn't a pseudo-class.")
        expectEqual(error.data, [
            "reason": "unknown_word", "hint": "Did you mean :mentions?",
            "line": 1, "column": 12, "length": 8, "statement": #"note:mention("API")"#,
            "query": "note:mention", "transient": false,
            "errors": [
                ["reason": "unknown_word", "message": ":mention isn't a pseudo-class.", "hint": "Did you mean :mentions?",
                 "line": 1, "column": 12, "length": 8, "statement": #"note:mention("API")"#, "query": "note:mention"],
                ["reason": "unknown_title", "message": "\"API\" isn't in the file.", "line": 1, "column": 21, "length": 5,
                 "statement": #"note:mention("API")"#, "near": "Apis"],
            ],
        ])
        guard case .failure(let bare) = try awaitResult({ await answer("bare", in: registry) }) else { return expect(false, "it fails") }
        expectEqual(bare.data, ["reason": "no_luck", "tried": 2])
    },
])

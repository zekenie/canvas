import CanvasRPC
import Darwin
import Foundation
import TestKit

// Requests that take their time, as a command that waits on a language model does: the listener
// answers each when it's done, a connection's in order, and lets go of what a client that hung up
// asked.

/// Requests the test holds, by name: each waits until the test lets it go, or its task is cancelled.
@MainActor
final class Holds {
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    /// The methods answered, in the order their handlers finished.
    var answered: [String] = []
    private(set) var cancelled: [String] = []
    private(set) var finished: [String] = []

    func hold(_ name: String) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting[name] = $0 }
        } onCancel: {
            Task { @MainActor in self.cancel(name) }
        }
        finished.append(name)
    }

    func isWaiting(_ name: String) -> Bool { waiting[name] != nil }

    func release(_ name: String) { waiting.removeValue(forKey: name)?.resume() }

    private func cancel(_ name: String) {
        guard let continuation = waiting.removeValue(forKey: name) else { return }
        cancelled.append(name)
        continuation.resume()
    }
}

/// Answers `hold` once the test lets its `name` go, and anything else at once, each with its params.
@MainActor func holdingListener(at path: String, _ holds: Holds) -> RPCListener {
    RPCListener(path: path) { request in
        if request.method == "hold", let name = request.params?["name"]?.stringValue { await holds.hold(name) }
        holds.answered.append(request.method)
        return .success(request.params ?? .null)
    }
}

/// A request's line, or a notification's with no id.
func line(_ id: Int?, _ method: String, _ params: JSON) -> String {
    let data = (try? JSONEncoder().encode(RPCRequest(id: id.map(RequestID.number), method: method, params: params))) ?? Data()
    return String(decoding: data, as: UTF8.self) + "\n"
}

/// A connection by hand, which reads what comes back on a thread of its own into `lines`, a line
/// each, until the app or the test hangs up.
final class RawConnection: Sendable {
    let fd: Int32
    let lines = Handoff<[String]>()

    init?(_ path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = rawAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
        let lines = lines
        lines.value = []
        Thread {
            var received = Data()
            while true {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { return }
                received.append(contentsOf: chunk.prefix(count))
                lines.value = String(decoding: received, as: UTF8.self).split(separator: "\n").map(String.init)
            }
        }.start()
    }

    deinit {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    func send(_ text: String) {
        _ = text.withCString { write(fd, $0, strlen($0)) }
    }

    /// Stops sending and reading, as a client that exits does: the app reads the end of what it sent.
    func hangUp() {
        shutdown(fd, SHUT_RDWR)
    }

    /// The ids of the responses read so far, in order.
    var answeredIDs: [RequestID?] {
        (lines.value ?? []).compactMap { try? JSONDecoder().decode(RPCResponse.self, from: Data($0.utf8)).id }
    }
}

/// Turns the main run loop for a moment, for whatever's due to happen to happen.
@MainActor func settle() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}

@MainActor let asyncTests = Suite("Answering later", [
    test("a connection's answers go back in the order its requests came, though a later one finishes first") {
        let path = temporarySocketPath(), holds = Holds()
        let listener = holdingListener(at: path, holds)
        try listener.start()
        defer { listener.stop() }
        let connection = try require(RawConnection(path))
        connection.send(line(1, "hold", ["name": "first"]) + line(2, "echo", ["n": 2]))
        spinRunLoop(until: { holds.answered == ["echo"] && holds.isWaiting("first") })
        settle()
        expectEqual(connection.lines.value, [], "the second's answer waits for the first's")
        holds.release("first")
        spinRunLoop(until: { connection.answeredIDs.count == 2 })
        expectEqual(connection.answeredIDs, [.number(1), .number(2)])
        expectEqual(holds.answered, ["echo", "hold"])
    },
    test("a request that waits holds up neither the main actor nor another connection") {
        let path = temporarySocketPath(), holds = Holds()
        let listener = holdingListener(at: path, holds)
        try listener.start()
        defer { listener.stop() }
        let slow = try require(RawConnection(path))
        slow.send(line(1, "hold", ["name": "slow"]))
        spinRunLoop(until: { holds.isWaiting("slow") })
        expectEqual(request(path, "echo", params: "quick"), .success("quick"), "another client, answered meanwhile")
        expect(holds.isWaiting("slow"))
        expectEqual(slow.lines.value, [])
        holds.release("slow")
        spinRunLoop(until: { slow.answeredIDs == [.number(1)] })
    },
    test("a client that hangs up cancels its requests still running, but not a notification, which runs to its end") {
        let path = temporarySocketPath(), holds = Holds()
        let listener = holdingListener(at: path, holds)
        try listener.start()
        defer { listener.stop() }
        let connection = try require(RawConnection(path))
        connection.send(line(1, "hold", ["name": "asked"]) + line(nil, "hold", ["name": "told"]))
        spinRunLoop(until: { holds.isWaiting("asked") && holds.isWaiting("told") })
        connection.hangUp()
        spinRunLoop(until: { holds.cancelled == ["asked"] })
        settle()
        expectEqual(holds.cancelled, ["asked"])
        expect(holds.isWaiting("told"), "a notification isn't cancelled")
        holds.release("told")
        spinRunLoop(until: { holds.finished.contains("told") })
        expectEqual(holds.answered, ["hold", "hold"])
    },
    test("a request holds an activity from its line to its answer, so macOS doesn't nap the process while a client waits; one each, and each ends") {
        spinRunLoop(until: { RPCListener.activitiesHeld == 0 })
        let path = temporarySocketPath(), holds = Holds()
        let listener = holdingListener(at: path, holds)
        try listener.start()
        defer { listener.stop() }
        expectEqual(request(path, "echo", params: "quick"), .success("quick"))
        spinRunLoop(until: { RPCListener.activitiesHeld == 0 })
        // Two clients waiting at once, and an answer waiting to go back after the one before it.
        let first = try require(RawConnection(path)), second = try require(RawConnection(path))
        first.send(line(1, "hold", ["name": "first"]) + line(2, "echo", ["n": 2]))
        second.send(line(1, "hold", ["name": "second"]))
        spinRunLoop(until: { holds.isWaiting("first") && holds.isWaiting("second") && holds.answered == ["echo", "echo"] })
        expectEqual(RPCListener.activitiesHeld, 3, "one a request, the echo's until its answer is written")
        holds.release("first")
        spinRunLoop(until: { first.answeredIDs == [.number(1), .number(2)] })
        spinRunLoop(until: { RPCListener.activitiesHeld == 1 })
        // A client that hangs up (a timeout, ^C): its request is cancelled, and lets go.
        second.hangUp()
        spinRunLoop(until: { holds.cancelled == ["second"] })
        spinRunLoop(until: { RPCListener.activitiesHeld == 0 })
        // A notification holds one until it has run; a line that isn't a request, and a request with
        // no method, until their errors are written.
        let third = try require(RawConnection(path))
        third.send(line(nil, "hold", ["name": "told"]))
        spinRunLoop(until: { holds.isWaiting("told") })
        expectEqual(RPCListener.activitiesHeld, 1)
        holds.release("told")
        spinRunLoop(until: { holds.finished.contains("told") })
        spinRunLoop(until: { RPCListener.activitiesHeld == 0 })
        third.send("not json\n" + #"{"jsonrpc":"2.0","id":5}"# + "\n" + line(6, "echo", ["n": 6]))
        spinRunLoop(until: { third.lines.value?.count == 3 })
        spinRunLoop(until: { RPCListener.activitiesHeld == 0 })
    },
    test("a listener made with a synchronous handler answers as one that waits does") {
        let path = temporarySocketPath()
        let listener = RPCListener(path: path, synchronous: { request in .success(["method": .string(request.method)]) })
        try listener.start()
        defer { listener.stop() }
        expectEqual(request(path, "now"), .success(["method": "now"]))
    },
    test("a param's x-timeout is how long canvas waits for an answer when it's given, and help says so") {
        let spec = CommandSpec(name: "ask", summary: "Ask.", scope: .app, params: [
            "type": "object",
            "properties": [
                "question": ["type": "string", "description": "A question.", "x-stdin": true, "x-value-name": "question", "x-timeout": 60],
                "brief": ["type": "boolean", "x-timeout": 0.5],
                "limit": ["type": "integer"],
                "never": ["type": "integer", "x-timeout": 0],
                "wrong": ["type": "integer", "x-timeout": "60"],
            ],
        ])
        let waits = Dictionary(uniqueKeysWithValues: spec.arguments.map { ($0.name, $0.waits) })
        expectEqual(waits, ["question": 60, "brief": 0.5, "limit": nil, "never": nil, "wrong": nil], "only a number of seconds above 0")
        let help = spec.help()
        expect(help.contains("A question. Given as -, it's read from standard input. (waits up to 60 s)"), help)
        expect(help.contains("--brief") && help.contains("(waits up to 0.5 s)"), help)
        expectEqual(help.components(separatedBy: "(waits up to").count - 1, 2, help)
    },
])

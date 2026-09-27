import CanvasRPC
import Darwin
import Foundation
import TestKit

/// Answers `echo` with its params, and anything else with an error.
@MainActor func echoListener(at path: String) -> RPCListener {
    RPCListener(path: path) { request in
        expect(Thread.isMainThread, "requests are answered on the main actor")
        return request.method == "echo" ? .success(request.params ?? .null) : .failure(.failed("There's no \(request.method).", reason: "nope"))
    }
}

/// A request from a client of its own, on another thread, while the main run loop turns.
@MainActor func request(_ path: String, _ method: String, params: JSON? = nil, timeout: TimeInterval = 5) -> Result<JSON, ClientError> {
    offMain { Result { () throws(ClientError) in try RPCClient(path: path).call(method, params: params, timeout: timeout) } }
        ?? .failure(.timedOut(timeout))
}

// Sockets by hand, for what the client never does: a line that isn't a request, a listener that never answers.

func rawAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: Array(path.utf8))
        raw[path.utf8.count] = 0
    }
    return address
}

/// A socket bound at `path` and listening, which never accepts: a connection to it waits forever.
func rawListener(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = rawAddress(path)
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    listen(fd, 4)
    return fd
}

/// Writes `text` to the socket at `path`, then reads until `lines` lines come back or a second passes.
func rawExchange(_ path: String, _ text: String, lines: Int) -> [String] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = rawAddress(path)
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard connected == 0 else { return ["connect failed: \(errno)"] }
    _ = text.withCString { write(fd, $0, strlen($0)) }
    var received = Data()
    let deadline = Date(timeIntervalSinceNow: 1)
    while received.filter({ $0 == UInt8(ascii: "\n") }).count < lines, Date() < deadline {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 50) > 0 else { continue }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { break }
        received.append(contentsOf: chunk.prefix(count))
    }
    return String(decoding: received, as: UTF8.self).split(separator: "\n").map(String.init)
}

/// A socket at `path` that answers the first line it reads with `reply`, on a thread of its own.
func rawServer(_ path: String, reply: String) -> Int32 {
    let fd = rawListener(path)
    Thread {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var byte: UInt8 = 0
        while read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
        _ = reply.withCString { write(client, $0, strlen($0)) }
        close(client)
    }.start()
    return fd
}

@MainActor let socketTests = Suite("Sockets", [
    test("requests on one connection are answered in order, on the main actor, results and errors alike") {
        let path = temporarySocketPath()
        let listener = echoListener(at: path)
        try listener.start()
        defer { listener.stop() }
        let results = offMain { () -> [Result<JSON, ClientError>] in
            do throws(ClientError) {
                let client = try RPCClient(path: path)
                return (1...3).map { n in Result { () throws(ClientError) in try client.call(n == 2 ? "nope" : "echo", params: ["n": .number(Double(n))]) } }
            } catch {
                return [.failure(error)]
            }
        }
        let got = try require(results)
        expectEqual(got.count, 3)
        expectEqual(try? got[0].get(), ["n": 1])
        expectEqual(try? got[2].get(), ["n": 3])
        guard case .failure(.remote(let error)) = got[1] else { return expect(false, "\(got[1])") }
        expectEqual(error.reason, "nope")
        expectEqual(error.message, "There's no nope.")
    },
    test("a line that isn't a request gets an error with no id; a notification gets nothing; the rest are answered") {
        let path = temporarySocketPath()
        let listener = echoListener(at: path)
        try listener.start()
        defer { listener.stop() }
        let text = "not json\n{\"jsonrpc\":\"2.0\",\"method\":\"echo\"}\n\n{\"jsonrpc\":\"2.0\",\"id\":5}\n{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"echo\",\"params\":[1]}\n"
        let lines = try require(offMain { rawExchange(path, text, lines: 3) })
        expectEqual(lines.count, 3, "\(lines)")
        let responses = lines.compactMap { try? JSONDecoder().decode(RPCResponse.self, from: Data($0.utf8)) }
        expectEqual(responses.count, 3)
        guard responses.count == 3 else { return }
        expectEqual(responses[0].id, nil)
        expectEqual((try? responses[0].outcome.get()) == nil ? "failed" : "", "failed")
        if case .failure(let error) = responses[0].outcome { expectEqual(error.code, RPCError.parseError) }
        expectEqual(responses[1].id, .number(5), "a request with no method: invalid, but its id is known")
        if case .failure(let error) = responses[1].outcome { expectEqual(error.code, RPCError.invalidRequest) }
        expectEqual(responses[2].id, .number(6))
        expectEqual(try? responses[2].outcome.get(), [1])
    },
    test("with nothing listening, or a socket left by an app that crashed, the app isn't running; a listener takes the socket over") {
        let path = temporarySocketPath()
        expectEqual(request(path, "echo"), .failure(.notRunning(path: path)))
        close(rawListener(path))                       // a socket file with nothing behind it
        expect(FileManager.default.fileExists(atPath: path))
        expectEqual(request(path, "echo"), .failure(.notRunning(path: path)))
        let listener = echoListener(at: path)
        try listener.start()
        defer { listener.stop() }
        expectEqual(request(path, "echo", params: "up"), .success("up"))
    },
    test("a second listener where one is listening, or where a file that isn't a socket is, is refused, and leaves it be") {
        let path = temporarySocketPath()
        let first = echoListener(at: path)
        try first.start()
        defer { first.stop() }
        expectThrows(SocketError.inUse(path)) { try echoListener(at: path).start() }
        expectEqual(request(path, "echo", params: 1), .success(1), "the first still answers")
        let file = temporarySocketPath()
        FileManager.default.createFile(atPath: file, contents: Data("keep".utf8))
        defer { try? FileManager.default.removeItem(atPath: file) }
        expectThrows(SocketError.notASocket(file)) { try echoListener(at: file).start() }
        expectEqual(FileManager.default.contents(atPath: file), Data("keep".utf8))
        // One listening without the lock (an older app) is still found, and left be.
        let unlocked = temporarySocketPath()
        let fd = rawListener(unlocked)
        defer {
            close(fd)
            unlink(unlocked)
        }
        expectThrows(SocketError.inUse(unlocked)) { try echoListener(at: unlocked).start() }
        expect(FileManager.default.fileExists(atPath: unlocked))
    },
    test("an error the app couldn't tie to a request is the answer, not something to wait out") {
        let path = temporarySocketPath()
        let fd = rawServer(path, reply: #"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Not a request."}}"# + "\n")
        defer {
            close(fd)
            unlink(path)
        }
        let started = Date()
        guard case .failure(.remote(let error)) = request(path, "echo", timeout: 5) else { return expect(false, "it waited, or took it for a result") }
        expectEqual(error.message, "Not a request.")
        expect(Date().timeIntervalSince(started) < 2, "it didn't wait out the timeout")
    },
    test("stopping removes the socket; its folder, made if missing, and the socket are this user's alone") {
        let folder = temporarySocketPath().replacingOccurrences(of: ".sock", with: "")
        let path = folder + "/s.sock"
        let listener = echoListener(at: path)
        try listener.start()
        let folderMode = (try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? NSNumber)?.intValue
        let socketMode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        expectEqual(folderMode, 0o700)
        expectEqual(socketMode, 0o600)
        listener.stop()
        expect(!FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: folder)
    },
    test("a path too long for a socket says so") {
        let path = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        expectThrows(SocketError.pathTooLong(path)) { try echoListener(at: path).start() }
        guard case .failure(.unreachable) = request(path, "echo") else { return expect(false, "a client says it can't reach a path that long") }
    },
    test("an app that doesn't answer in time times out") {
        let path = temporarySocketPath()
        let fd = rawListener(path)
        defer {
            close(fd)
            unlink(path)
        }
        expectEqual(request(path, "echo", timeout: 0.2), .failure(.timedOut(0.2)))
    },
])

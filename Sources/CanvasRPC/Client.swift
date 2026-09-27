import Darwin
import Foundation

/// A connection to the app, for the command line: a request, then its response, as many times as
/// it takes. It blocks, since a command line has nothing else to do while it waits.
public final class RPCClient {
    public let path: String
    private let fd: Int32
    private var buffer = LineBuffer()
    private var nextID = 1

    /// Connects to the app listening at `path`.
    public init(path: String) throws(ClientError) {
        do {
            fd = try Sockets.connect(to: path)
        } catch .system(call: _, path: _, errno: let code) where code == ENOENT || code == ECONNREFUSED || code == ENOTDIR {
            throw .notRunning(path: path)
        } catch {
            throw .unreachable(path: path, reason: error.description)
        }
        self.path = path
    }

    deinit { close(fd) }

    /// Sends a request and waits up to `timeout` seconds for its response: the result, or the
    /// app's error as `ClientError.remote`.
    public func call(_ method: String, params: JSON? = nil, timeout: TimeInterval = 10) throws(ClientError) -> JSON {
        let id = RequestID.number(nextID)
        nextID += 1
        guard var data = try? JSON.encoder().encode(RPCRequest(id: id, method: method, params: params)) else {
            throw .malformedRequest
        }
        data.append(UInt8(ascii: "\n"))
        guard Sockets.write(data, to: fd) else { throw .connectionClosed }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            if let line = buffer.nextLine() {
                guard let response = try? JSONDecoder().decode(RPCResponse.self, from: line) else {
                    throw .malformedResponse(String(decoding: line.prefix(200), as: UTF8.self))
                }
                // One request at a time, so an error the app couldn't tie to a request (it couldn't
                // read ours) is ours too.
                guard response.id == id || (response.id == nil && (try? response.outcome.get()) == nil) else { continue }
                switch response.outcome {
                case .success(let result): return result
                case .failure(let error): throw .remote(error)
                }
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw .timedOut(timeout) }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
            guard ready >= 0 else {
                if errno == EINTR { continue }
                throw .connectionClosed
            }
            guard ready > 0 else { throw .timedOut(timeout) }
            var chunk = [UInt8](repeating: 0, count: 64 << 10)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else {
                if count < 0, errno == EINTR { continue }
                throw .connectionClosed
            }
            chunk.withUnsafeBytes { buffer.append(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
    }

    /// What `describe` says: the app, its protocol, and its commands.
    public func describe(timeout: TimeInterval = 10) throws(ClientError) -> AppDescription {
        let json = try call(RPC.describeMethod, timeout: timeout)
        guard let description = try? json.decode(AppDescription.self) else {
            throw .malformedResponse(String(json.compactText.prefix(200)))
        }
        return description
    }
}

/// Why a request got no answer from the app, or an error.
public enum ClientError: Error, Equatable, CustomStringConvertible {
    /// Nothing listens at the path: the app isn't running, or listens somewhere else.
    case notRunning(path: String)
    /// Something's there, and it couldn't be reached: its permissions, a sandbox.
    case unreachable(path: String, reason: String)
    case timedOut(TimeInterval)
    /// The app closed the connection before it answered.
    case connectionClosed
    case malformedRequest
    /// What came back isn't a JSON-RPC response.
    case malformedResponse(String)
    /// The app answered with an error.
    case remote(RPCError)

    public var description: String {
        switch self {
        case .notRunning(let path): "Infinite Canvas isn't running: nothing is listening at \(path)"
        case .unreachable(let path, let reason): "Infinite Canvas can't be reached at \(path): \(reason)"
        case .timedOut(let seconds): "Infinite Canvas didn't answer within \(seconds.formatted()) s"
        case .connectionClosed: "Infinite Canvas closed the connection before it answered"
        case .malformedRequest: "the request couldn't be written as JSON"
        case .malformedResponse(let text): "Infinite Canvas answered with something that isn't a response: \(text)"
        case .remote(let error): error.message
        }
    }
}

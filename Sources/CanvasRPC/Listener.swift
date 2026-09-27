import Darwin
import Dispatch
import Foundation

/// Listens on a Unix-domain socket for JSON-RPC requests, one a line, and answers each on the main
/// actor, in the order it came on its connection. Reading and writing happen off the main thread,
/// a queue per connection, so a client that's slow to read holds up only itself. The app's command
/// server is built on it.
///
/// Only processes of the user the app runs as are answered: the socket is readable by no one else,
/// its folder is made readable by no one else, and each connection's peer is checked.
public final class RPCListener: @unchecked Sendable {
    /// What a request does. It runs on the main actor; a request without an id (a notification)
    /// runs too, but gets no response.
    public typealias Handler = @MainActor @Sendable (RPCRequest) -> Result<JSON, RPCError>

    public let path: String
    private let handler: Handler
    /// Guards everything below.
    private let queue = DispatchQueue(label: "canvas.rpc.listener")
    private var source: DispatchSourceRead?
    /// The socket file's, so that stopping removes only the file this listener made.
    private var inode: ino_t?
    /// Held while it listens (`path.lock`): whoever holds it is the one listening at `path`.
    private var lock: Int32 = -1
    /// Not accepting for a moment: out of descriptors, a connection would wait, and the source fire
    /// again at once.
    private var isPaused = false
    private var connections: [ObjectIdentifier: Connection] = [:]

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// Starts listening. Makes the socket's folder, readable only by this user, if there's none,
    /// and replaces a socket that nothing listens on (one an app that crashed left). Throws if
    /// another process is listening there, or something that isn't a socket is in the way.
    public func start() throws(SocketError) {
        var failure: SocketError?
        queue.sync {
            do throws(SocketError) { try listen() } catch { failure = error }
        }
        if let failure { throw failure }
    }

    private func listen() throws(SocketError) {
        guard source == nil else { return }
        let folder = (path as NSString).deletingLastPathComponent
        if !folder.isEmpty, !FileManager.default.fileExists(atPath: folder) {
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw .system(call: "mkdir", path: folder, errno: Int32((error as NSError).code))
            }
        }
        // Whoever holds the lock listens: a second app gives up here, and the socket an app that
        // crashed left (its lock went with it) is taken over with no other app halfway through the same.
        let lockPath = path + ".lock"
        let lock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw .system(call: "open", path: lockPath, errno: errno) }
        var listening = false
        defer { if !listening { close(lock) } }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw .inUse(path) }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw .notASocket(path) }
            // An app that doesn't take the lock (an older one) may still be listening there.
            if let live = try? Sockets.connect(to: path) {
                close(live)
                throw .inUse(path)
            }
            unlink(path)
        }
        let fd = try Sockets.make(path: path)
        let bound = try Sockets.withAddress(path) { bind(fd, $0, $1) }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw code == EADDRINUSE ? .inUse(path) : .system(call: "bind", path: path, errno: code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw .system(call: "listen", path: path, errno: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        inode = stat(path, &info) == 0 ? info.st_ino : nil
        self.lock = lock
        listening = true
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(from: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// Stops listening, lets go of every connection, and removes the socket file.
    public func stop() {
        queue.sync { shutDown() }
    }

    // Nothing else holds the listener by now (its handlers hold it weakly), so there's no queue to wait for.
    deinit { shutDown() }

    private func shutDown() {
        guard let source else { return }
        source.cancel()
        // A source cancelled while it's suspended closes nothing until it's resumed.
        if isPaused {
            isPaused = false
            source.resume()
        }
        self.source = nil
        var info = stat()
        if let inode, stat(path, &info) == 0, info.st_ino == inode { unlink(path) }
        inode = nil
        // The lock file stays: removing it could let two apps each lock a file of that name.
        close(lock)
        lock = -1
        for connection in connections.values { connection.stopReading() }
        connections = [:]
    }

    private func acceptAll(from listening: Int32) {
        while true {
            let fd = accept(listening, nil, nil)
            guard fd >= 0 else {
                switch errno {
                case EINTR, ECONNABORTED: continue
                case EAGAIN: return                      // no one else waiting
                default:
                    // Out of descriptors (EMFILE, ENFILE): the connection waits in the backlog, and
                    // the source would fire again at once. Look again in a moment.
                    pauseAccepting()
                    return
                }
            }
            Sockets.prepare(fd)
            // Blocking, whatever it inherits: its queue waits on it, never the main thread. A write
            // gives up after a while, so a client that never reads doesn't hold its queue forever.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var uid = uid_t(), gid = gid_t()
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            let connection = Connection(fd: fd, handler: handler) { [weak self] finished in
                let id = ObjectIdentifier(finished)
                self?.queue.async { [weak self] in self?.connections[id] = nil }
            }
            connections[ObjectIdentifier(connection)] = connection
            connection.start()
        }
    }

    private func pauseAccepting() {
        guard !isPaused, let source else { return }
        isPaused = true
        source.suspend()
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, isPaused else { return }
            isPaused = false
            self.source?.resume()
        }
    }
}

/// One client's connection: it reads requests off it, hands each to the main actor, and writes
/// back the answers, in order, all on its own queue.
private final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let handler: RPCListener.Handler
    private let didFinish: @Sendable (Connection) -> Void
    /// Guards everything below.
    private let queue = DispatchQueue(label: "canvas.rpc.connection")
    private var source: DispatchSourceRead?
    private var buffer = LineBuffer()
    /// Requests the main actor has and hasn't answered yet.
    private var pending = 0
    /// Nothing more will be read: the client's done sending, or gone.
    private var doneReading = false
    private var closed = false

    init(fd: Int32, handler: @escaping RPCListener.Handler, didFinish: @escaping @Sendable (Connection) -> Void) {
        self.fd = fd
        self.handler = handler
        self.didFinish = didFinish
    }

    func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in read() }
            // The descriptor stays open until every answer is written (`closeIfDone`).
            source.setCancelHandler { [self] in
                doneReading = true
                closeIfDone()
            }
            source.resume()
            self.source = source
        }
    }

    func stopReading() {
        queue.async { [self] in source?.cancel() }
    }

    private func read() {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else {
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            source?.cancel()                     // the client's done sending, or gone
            return
        }
        chunk.withUnsafeBytes { buffer.append(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        while let line = buffer.nextLine() { handle(line) }
        if buffer.isOverLimit { source?.cancel() }
    }

    private func handle(_ line: Data) {
        let request: RPCRequest
        do {
            request = try JSONDecoder().decode(RPCRequest.self, from: line)
        } catch {
            // Answered with no id when there's none to read, as JSON-RPC says.
            let json = try? JSON(data: line)
            let id = json?["id"].flatMap { try? $0.decode(RequestID.self) }
            let failure = json == nil
                ? RPCError(RPCError.parseError, reason: "parse_error", "The request isn't JSON.")
                : RPCError(RPCError.invalidRequest, reason: "invalid_request", "The request isn't a JSON-RPC 2.0 request: \(error)")
            send(RPCResponse(id: id, outcome: .failure(failure)))
            return
        }
        pending += 1
        let handler = handler
        DispatchQueue.main.async { [self] in
            let outcome = MainActor.assumeIsolated { handler(request) }
            queue.async { [self] in
                pending -= 1
                if let id = request.id { send(RPCResponse(id: id, outcome: outcome)) }
                closeIfDone()
            }
        }
    }

    private func send(_ response: RPCResponse) {
        guard !closed else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data: Data
        do {
            data = try encoder.encode(response)
        } catch {
            // A result that isn't JSON (a number that isn't finite): say so rather than nothing.
            let failure = RPCError(RPCError.internalError, reason: "internal", "The app's answer couldn't be written as JSON: \(error)")
            data = (try? encoder.encode(RPCResponse(id: response.id, outcome: .failure(failure)))) ?? Data()
        }
        data.append(UInt8(ascii: "\n"))
        if !Sockets.write(data, to: fd) { source?.cancel() }
    }

    private func closeIfDone() {
        guard doneReading, pending == 0, !closed else { return }
        closed = true
        close(fd)
        didFinish(self)
    }
}

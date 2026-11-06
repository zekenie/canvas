import Darwin
import Foundation

/// Where the app listens: a Unix-domain socket, which only this user can reach (it's in a folder
/// only they can read, and the app answers only their processes).
public enum SocketPath {
    /// Set, both the app and the command line use this path instead: for tests, or a second app.
    public static let environmentKey = "CANVAS_SOCKET"

    /// `CANVAS_SOCKET` if it's set, else `~/Library/Application Support/InfiniteCanvas/canvas.sock`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment[environmentKey], !path.isEmpty { return path }
        return defaultPath(home: NSHomeDirectory())
    }

    public static func defaultPath(home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/InfiniteCanvas/canvas.sock")
    }

    /// The longest path a socket can have (`sockaddr_un.sun_path`, less its terminating zero).
    public static var maxLength: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1 }
}

/// Why a socket couldn't be listened on or reached.
public enum SocketError: Error, Equatable, CustomStringConvertible {
    /// Longer than a Unix-domain socket's path can be.
    case pathTooLong(String)
    /// Another process is listening there already: the app, open twice.
    case inUse(String)
    /// Something that isn't a socket is at the path; it's left alone.
    case notASocket(String)
    /// A system call failed.
    case system(call: String, path: String, errno: Int32)

    public var description: String {
        switch self {
        case .pathTooLong(let path):
            "the socket path is \(path.utf8.count) bytes long, longer than \(SocketPath.maxLength): \(path) (set \(SocketPath.environmentKey) to a shorter one)"
        case .inUse(let path): "another app is listening at \(path)"
        case .notASocket(let path): "\(path) isn't a socket, so it's left as it is"
        case .system(let call, let path, let code): "\(call) \(path): \(String(cString: strerror(code)))"
        }
    }
}

// MARK: System calls

enum Sockets {
    /// A new socket, closed on exec, that never raises SIGPIPE (a write to a closed peer fails with
    /// EPIPE instead of ending the process).
    static func make(path: String) throws(SocketError) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system(call: "socket", path: path, errno: errno) }
        prepare(fd)
        return fd
    }

    static func prepare(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// Runs `body` with the socket address of `path`.
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws(SocketError) -> T {
        let bytes = Array(path.utf8)
        guard bytes.count <= SocketPath.maxLength else { throw .pathTooLong(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// A socket connected to `path`, or the errno of why not.
    static func connect(to path: String) throws(SocketError) -> Int32 {
        let fd = try make(path: path)
        let result = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw .system(call: "connect", path: path, errno: code)
        }
        return fd
    }

    /// Writes all of `data`, whatever it takes. False if the peer's gone.
    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

/// Bytes read from a socket, cut into lines: one message a line.
struct LineBuffer {
    private var data = Data()
    /// How much of the buffer, from its start, is known to hold no newline: a long line that comes in many reads (a document of
    /// megabytes) is looked through once, not again from its start at each read.
    private var searched = 0
    /// Past this, with no line in sight, the peer isn't sending messages: 16 MB.
    static let limit = 16 << 20

    var isOverLimit: Bool { data.count > Self.limit }

    mutating func append(_ bytes: UnsafeRawBufferPointer) { data.append(contentsOf: bytes) }

    /// The next whole line, without its newline; blank lines are skipped. Nil until one has come.
    mutating func nextLine() -> Data? {
        while let newline = data[(data.startIndex + searched)...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = data[data.startIndex..<newline]
            data.removeSubrange(data.startIndex...newline)
            searched = 0
            if line.contains(where: { !Self.isSpace($0) }) { return Data(line) }
        }
        searched = data.count
        return nil
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0D }
}

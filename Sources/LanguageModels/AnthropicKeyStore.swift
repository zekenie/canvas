import Foundation

/// Where the Anthropic API key is kept: a file only its owner can read (mode 0600), by default
/// `~/Library/Application Support/InfiniteCanvas/anthropic-api-key`, holding the key and nothing
/// else. Not the Keychain: the app isn't signed, so every build would be a new app to it and ask
/// again. The quick evals (`scripts/`) read the same file. A missing file is no key.
///
/// Never print, log or show what `read()` returns.
public struct AnthropicKeyStore: Equatable, Sendable {
    /// The file.
    public let url: URL

    /// A store in any file (tests use a temporary directory).
    public init(url: URL) { self.url = url }

    /// The app's: `~/Library/Application Support/InfiniteCanvas/anthropic-api-key`.
    public static var standard: AnthropicKeyStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return AnthropicKeyStore(url: support.appending(path: "InfiniteCanvas/anthropic-api-key", directoryHint: .notDirectory))
    }

    /// The key, without the whitespace around it; nil if there's no file, or it can't be read, or
    /// holds nothing but whitespace.
    public func read() -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Whether a key is saved.
    public var hasKey: Bool { read() != nil }

    /// Saves `key`, without the whitespace around it, in place of any saved before; nothing but
    /// whitespace removes the file. Makes the directory if need be. The file is written whole
    /// under another name, readable only by its owner from the start, then renamed over the old,
    /// so no one else can ever read it and a failure leaves the old key as it was.
    public func write(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return try remove() }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent)-\(UUID().uuidString)", directoryHint: .notDirectory)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        var written = false
        defer { if !written { unlink(temporary.path) } }
        do {
            defer { close(descriptor) }
            guard fchmod(descriptor, 0o600) == 0 else { throw Self.posixError() }
            let bytes = Array(key.utf8)
            var offset = 0
            while offset < bytes.count {
                let count = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                guard count > 0 else { throw Self.posixError() }
                offset += count
            }
            guard fsync(descriptor) == 0 else { throw Self.posixError() }
        }
        guard rename(temporary.path, url.path) == 0 else { throw Self.posixError() }
        written = true
    }

    /// Removes the key. No key saved is fine.
    public func remove() throws {
        guard unlink(url.path) == 0 || errno == ENOENT else { throw Self.posixError() }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

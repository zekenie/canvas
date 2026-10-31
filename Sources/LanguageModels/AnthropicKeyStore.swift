import Foundation

/// A file that keeps a service's API key: only its owner can read it (mode 0600), and it holds the
/// key and nothing else. Not the Keychain: the app isn't signed, so every build would be a new app to
/// it and ask again. A missing file is no key. Each service's key has a store of its own, by its own
/// name (`AnthropicKeyStore`; DecisionModels' `TypeSafeKeyStore`); this is what they do with the file.
///
/// Never print, log or show what `read()` returns.
public protocol KeyFile: Sendable {
    /// The file.
    var url: URL { get }
}

extension KeyFile {
    /// `~/Library/Application Support/InfiniteCanvas/<name>`: where the app keeps a service's key.
    public static func applicationSupport(_ name: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: "InfiniteCanvas/\(name)", directoryHint: .notDirectory)
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
        guard descriptor >= 0 else { throw keyFileError() }
        var written = false
        defer { if !written { unlink(temporary.path) } }
        do {
            defer { close(descriptor) }
            guard fchmod(descriptor, 0o600) == 0 else { throw keyFileError() }
            let bytes = Array(key.utf8)
            var offset = 0
            while offset < bytes.count {
                let count = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                guard count > 0 else { throw keyFileError() }
                offset += count
            }
            guard fsync(descriptor) == 0 else { throw keyFileError() }
        }
        guard rename(temporary.path, url.path) == 0 else { throw keyFileError() }
        written = true
    }

    /// Removes the key. No key saved is fine.
    public func remove() throws {
        guard unlink(url.path) == 0 || errno == ENOENT else { throw keyFileError() }
    }
}

private func keyFileError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

/// Where the Anthropic API key is kept, by default
/// `~/Library/Application Support/InfiniteCanvas/anthropic-api-key`. The quick evals (`scripts/`)
/// read the same file.
public struct AnthropicKeyStore: KeyFile, Equatable {
    /// The file.
    public let url: URL

    /// A store in any file (tests use a temporary directory).
    public init(url: URL) { self.url = url }

    /// The app's: `~/Library/Application Support/InfiniteCanvas/anthropic-api-key`.
    public static var standard: AnthropicKeyStore { AnthropicKeyStore(url: applicationSupport("anthropic-api-key")) }
}

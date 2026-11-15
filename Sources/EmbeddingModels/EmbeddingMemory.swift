import CryptoKit
import Foundation
import os

/// The vectors embedding models gave, kept by the model and the text: a text asked of a model again, in
/// this process or another, after the app opens again too, is answered from here and asks nothing. A
/// vector of a given text by a given model never changes, so nothing is let go: no cap, no expiry (the
/// file grows by a vector a text, some 12 KB with the app's model).
///
/// In memory, and in a file in Application Support where the app keeps one
/// (`EmbeddingModelsPlugin()`); a test's is in memory only. Not main-actor: the file is read at the
/// first lookup and written after each chunk the model answered, and `Embeddings` has both done off the
/// main actor (`loadInBackground()`, `saveInBackground()`).
///
/// The file is shared by the app and every copy of it that runs, at once: a save never truncates the
/// file and never writes a record in pieces. It appends the records kept since the last save as one
/// `write` (`O_APPEND`) of the whole buffer; a file that isn't ours (the wrong magic) is replaced by one
/// written whole beside it and renamed into place. A torn record is where a load stops, keeping what it
/// read before; and a save that finds the file torn (a process killed mid-write, a full disk) heals it
/// first, the same way: the records before the tear and what's in memory, written whole beside it and
/// renamed into place, so nothing is ever appended after a tear, where no load would reach it.
///
/// The format: the magic `ICEMBV1\n`, then records, each a `UInt32` byte count of the key, the key's
/// UTF-8, a `UInt32` dimension `d` and `d` `Float32`s, every number little-endian, the floats as the
/// model sent them (never rounded), so a vector read back from the file equals the one it sent.
public final class EmbeddingMemory: Sendable {
    /// Where it's kept between launches; nil for memory only.
    public let url: URL?

    private struct Kept: Sendable {
        var key: String
        var vector: [Float]
    }

    private struct State: Sendable {
        var vectors: [String: [Float]] = [:]
        /// What's been kept since the last save, in order.
        var unsaved: [Kept] = []
        var loaded = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Held while the file is read or written, so one process reads and writes it one at a time.
    private let files = NSLock()
    #if DEBUG
    private let threads = OSAllocatedUnfairLock<[Bool]>(initialState: [])
    /// Debug builds only: for each time the file was read or written, whether the main thread did it.
    public var fileAccessesOnMainThread: [Bool] { threads.withLock { $0 } }
    #endif

    public nonisolated init(url: URL?) {
        self.url = url
    }

    /// The app's: `~/Library/Application Support/InfiniteCanvas/embedding-vectors.bin`.
    public nonisolated static func standard() -> EmbeddingMemory {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return EmbeddingMemory(url: support.appending(path: "InfiniteCanvas/embedding-vectors.bin", directoryHint: .notDirectory))
    }

    /// What a text of `model` is kept by: the model's name, a space and the SHA-256 of the text's UTF-8 in
    /// hex. The one key wherever a text is identified, so two texts that are canonically equal (a
    /// precomposed and a decomposed "é") are two.
    public static func key(of text: String, from model: String) -> String {
        model + " " + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The vector kept under `key` (`key(of:from:)`), if any. Reads the file first if it hasn't been.
    public func vector(forKey key: String) -> [Float]? {
        load()
        return state.withLock { $0.vectors[key] }
    }

    /// Keeps `vector` under `key`, to be written by the next `save()`. The same vector kept again is kept
    /// once. One the file's format can't hold (no numbers, or more than 65,536; a key of more than 1,024
    /// bytes) is not kept: a load would stop at its record and never reach the ones after it.
    public func keep(_ vector: [Float], forKey key: String) {
        guard Self.holds(vector, forKey: key) else { return }
        load()
        state.withLock { state in
            guard state.vectors[key] != vector else { return }
            state.vectors[key] = vector
            state.unsaved.append(Kept(key: key, vector: vector))
        }
    }

    /// Reads the file, once; later calls do nothing. Whatever was kept before it stays kept over what
    /// the file says. A missing, short or foreign file is empty; a corrupt one is read up to its last
    /// whole record.
    public func load() {
        if state.withLock({ $0.loaded }) { return }
        files.lock()
        defer { files.unlock() }
        if state.withLock({ $0.loaded }) { return }
        #if DEBUG
        if url != nil { threads.withLock { $0.append(Thread.isMainThread) } }
        #endif
        let read = url.flatMap { try? Data(contentsOf: $0) }.map(Self.records(in:)) ?? [:]
        state.withLock { state in
            state.vectors = read.merging(state.vectors) { _, kept in kept }
            state.loaded = true
        }
    }

    /// `load()`, off the main actor.
    @concurrent
    public func loadInBackground() async { load() }

    /// Writes what's been kept since the last save to the file, once, as one `write` appended to it. A
    /// failure keeps it, to try again with the next. With no file, nothing.
    public func save() {
        guard let url else { return }
        files.lock()
        defer { files.unlock() }
        let unsaved = state.withLock { state in
            defer { state.unsaved = [] }
            return state.unsaved
        }
        guard !unsaved.isEmpty else { return }
        #if DEBUG
        threads.withLock { $0.append(Thread.isMainThread) }
        #endif
        do {
            try append(unsaved, to: url)
        } catch {
            state.withLock { $0.unsaved = unsaved + $0.unsaved }
        }
    }

    /// `save()`, off the main actor.
    @concurrent
    public func saveInBackground() async { save() }

    // MARK: The file

    static let magic = Array("ICEMBV1\n".utf8)
    private static let longestKey = 1_024
    static let mostDimensions = 65_536

    /// Whether a record of `vector` under `key` is one a load reads back.
    static func holds(_ vector: [Float], forKey key: String) -> Bool {
        key.utf8.count <= longestKey && (1...mostDimensions).contains(vector.count)
    }

    private func append(_ unsaved: [Kept], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Mapped, and only the records' headers read: the file may be many megabytes.
        let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        if data.isEmpty {
            try Self.appendBuffer(Self.magic + Self.encode(unsaved), to: url)
        } else if data.starts(with: Self.magic), Self.intactEnd(of: data) == data.count {
            try Self.appendBuffer(Self.encode(unsaved), to: url)
        } else {
            // Not ours, or torn: replaced, never truncated in place, by the whole records before the tear
            // (none in a file that isn't ours) and what's in memory, which wins.
            let kept = state.withLock { $0.vectors }
            let whole = Self.records(in: data).merging(kept) { _, kept in kept }
            let all = whole.keys.sorted().map { Kept(key: $0, vector: whole[$0]!) }
            try Self.replace(url, with: Self.magic + Self.encode(all))
        }
    }

    /// One `write` of `buffer` at the file's end (made, readable by its owner alone, if need be).
    private static func appendBuffer(_ buffer: [UInt8], to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var offset = 0
        while offset < buffer.count {
            let count = buffer[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += count
        }
    }

    /// `buffer` in a new file beside `url`, readable by its owner alone from the start, renamed over it.
    private static func replace(_ url: URL, with buffer: [UInt8]) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent)-\(UUID().uuidString)", directoryHint: .notDirectory)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var renamed = false
        defer { if !renamed { unlink(temporary.path) } }
        do {
            defer { close(descriptor) }
            var offset = 0
            while offset < buffer.count {
                let count = buffer[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        renamed = true
    }

    private static func encode(_ records: [Kept]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(records.reduce(0) { $0 + 8 + $1.key.utf8.count + 4 * $1.vector.count })
        for record in records {
            let key = Array(record.key.utf8)
            put(UInt32(key.count), in: &out)
            out += key
            put(UInt32(record.vector.count), in: &out)
            for value in record.vector { put(value.bitPattern, in: &out) }
        }
        return out
    }

    private static func put(_ value: UInt32, in out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    /// The records in a file's bytes, the later of two with one key winning. Every record is checked (a
    /// key of at most 1,024 bytes, in UTF-8, a dimension from 1 to 65,536, all its bytes there) and the
    /// first to fail ends the reading. Without the magic, nothing. A second magic at a record's start
    /// (two copies each making a new file) is passed over.
    static func records(in data: Data) -> [String: [Float]] {
        guard data.starts(with: magic) else { return [:] }
        var vectors: [String: [Float]] = [:]
        data.withUnsafeBytes { bytes in
            _ = walk(bytes) { key, start, dimensions in
                var vector = [Float](repeating: 0, count: dimensions)
                for i in 0..<dimensions {
                    vector[i] = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 4 * i, as: UInt32.self)))
                }
                vectors[key] = vector
            }
        }
        return vectors
    }

    /// Where the whole records of a file's bytes (starting with the magic) end: the file's size when every
    /// byte is in one, short of it where a torn or corrupt record begins. Reads the records' headers only.
    static func intactEnd(of data: Data) -> Int {
        data.withUnsafeBytes { walk($0) { _, _, _ in } }
    }

    /// Walks the records of `bytes` (which start with the magic), calling `visit` with each one's key, where
    /// its numbers start and how many there are; returns the offset after the last whole record.
    private static func walk(_ bytes: UnsafeRawBufferPointer, visit: (String, Int, Int) -> Void) -> Int {
        func number(_ at: Int) -> Int? {
            guard at + 4 <= bytes.count else { return nil }
            return Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
        }
        func startsMagic(_ at: Int) -> Bool {
            at + magic.count <= bytes.count && magic.indices.allSatisfy { bytes[at + $0] == magic[$0] }
        }
        var at = magic.count
        while at < bytes.count {
            if startsMagic(at) {
                at += magic.count
                continue
            }
            guard let keyCount = number(at), keyCount <= longestKey, at + 4 + keyCount <= bytes.count,
                  let key = String(bytes: bytes[(at + 4)..<(at + 4 + keyCount)], encoding: .utf8),
                  let dimensions = number(at + 4 + keyCount), (1...mostDimensions).contains(dimensions) else { break }
            let start = at + 8 + keyCount
            guard start + 4 * dimensions <= bytes.count else { break }
            visit(key, start, dimensions)
            at = start + 4 * dimensions
        }
        return at
    }
}

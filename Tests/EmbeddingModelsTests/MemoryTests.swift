import EmbeddingModels
import Foundation
import TestKit

private let magic = Array("ICEMBV1\n".utf8)

/// A record as the file holds it: the key's byte count, the key, the dimension, the floats, all little-endian.
private func record(_ key: String, _ vector: [Float], keyCount: Int? = nil, dimensions: Int? = nil) -> [UInt8] {
    func word(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    let bytes = Array(key.utf8)
    return word(UInt32(keyCount ?? bytes.count)) + bytes + word(UInt32(dimensions ?? vector.count)) + vector.flatMap { word($0.bitPattern) }
}

private func bits(_ vector: [Float]?) -> [UInt32]? { vector?.map(\.bitPattern) }

private func fileBytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

private func inode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int) ?? -1
}

private let odd: [Float] = [0.1, -0.0, Float.leastNonzeroMagnitude, 3.4028235e38, -2.5e-7, .pi, 0, 1]
private let other: [Float] = [1, 2, 3]

@MainActor let memoryTests = Suite("Vectors kept", [
    test("the same text of the same model is answered from memory; another text, or another model, isn't") {
        let memory = EmbeddingMemory(url: nil)
        let key = EmbeddingMemory.key(of: "a text", from: "openai/text-embedding-3-large")
        memory.keep(odd, forKey: key)
        expectEqual(bits(memory.vector(forKey: key)), bits(odd))
        expectEqual(memory.vector(forKey: EmbeddingMemory.key(of: "another text", from: "openai/text-embedding-3-large")), nil)
        expectEqual(memory.vector(forKey: EmbeddingMemory.key(of: "a text", from: "scripted")), nil)
        expect(key.hasPrefix("openai/text-embedding-3-large "))
        expectEqual(key.count, "openai/text-embedding-3-large ".count + 64)
        // SHA-256 of "abc", a known one.
        expectEqual(EmbeddingMemory.key(of: "abc", from: "m"), "m ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    },
    test("canonically equal texts are two keys") {
        expect(EmbeddingMemory.key(of: "caf\u{E9}", from: "m") != EmbeddingMemory.key(of: "cafe\u{301}", from: "m"))
    },
    test("a file round trip is bit for bit, as the model sent the numbers") {
        try withVectorFile { url in
            let memory = EmbeddingMemory(url: url)
            memory.keep(odd, forKey: "m a")
            memory.keep(other, forKey: "m b")
            memory.save()
            let reopened = EmbeddingMemory(url: url)
            expectEqual(bits(reopened.vector(forKey: "m a")), bits(odd))
            expectEqual(bits(reopened.vector(forKey: "m b")), bits(other))
            expectEqual(reopened.vector(forKey: "m c"), nil)
            expectEqual(try fileBytes(url), magic + record("m a", odd) + record("m b", other), "the format, as the plan writes it")
        }
    },
    test("the file is readable by its owner alone") {
        try withVectorFile { url in
            let memory = EmbeddingMemory(url: url)
            memory.keep(other, forKey: "m a")
            memory.save()
            expectEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        }
    },
    test("a save appends: two saves are one file with both records, the first bytes and the file left as they were") {
        try withVectorFile { url in
            let memory = EmbeddingMemory(url: url)
            memory.keep(odd, forKey: "m a")
            memory.save()
            let first = try fileBytes(url)
            let file = try inode(url)
            memory.save()
            expectEqual(try fileBytes(url), first, "nothing kept since: nothing written")
            memory.keep(other, forKey: "m b")
            memory.save()
            let both = try fileBytes(url)
            expectEqual(Array(both.prefix(first.count)), first)
            expectEqual(both, magic + record("m a", odd) + record("m b", other))
            expectEqual(try inode(url), file, "the same file, never replaced")
        }
    },
    test("a vector kept again, as it was, is kept once") {
        try withVectorFile { url in
            let memory = EmbeddingMemory(url: url)
            memory.keep(other, forKey: "m a")
            memory.keep(other, forKey: "m a")
            memory.save()
            expectEqual(try fileBytes(url), magic + record("m a", other))
        }
    },
    test("two memories on one file each append, and a third reads both") {
        try withVectorFile { url in
            let one = EmbeddingMemory(url: url)
            let two = EmbeddingMemory(url: url)
            one.keep(odd, forKey: "m one")
            two.keep(other, forKey: "m two")
            one.save()
            two.save()
            one.keep([9], forKey: "m three")
            one.save()
            let third = EmbeddingMemory(url: url)
            expectEqual(bits(third.vector(forKey: "m one")), bits(odd))
            expectEqual(bits(third.vector(forKey: "m two")), bits(other))
            expectEqual(bits(third.vector(forKey: "m three")), bits([9]))
            expectEqual(try fileBytes(url), magic + record("m one", odd) + record("m two", other) + record("m three", [9]), "the magic once")
        }
    },
    test("two copies that each made the file new write the magic twice, which a load passes over") {
        try withVectorFile { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(magic + record("m a", odd) + magic + record("m b", other)).write(to: url)
            let memory = EmbeddingMemory(url: url)
            expectEqual(bits(memory.vector(forKey: "m a")), bits(odd))
            expectEqual(bits(memory.vector(forKey: "m b")), bits(other))
        }
    },
    test("of two records with one key the later wins") {
        try withVectorFile { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(magic + record("m a", odd) + record("m a", other)).write(to: url)
            expectEqual(bits(EmbeddingMemory(url: url).vector(forKey: "m a")), bits(other))
        }
    },
    test("a missing, short or foreign file is empty, and a torn or corrupt one is read to its last whole record") {
        let good = record("m a", odd)
        let cases: [(String, [UInt8], Bool)] = [
            ("short", Array(magic.prefix(5)), false),
            ("the magic only", magic, false),
            ("another magic", Array("ICEMBV2\n".utf8) + good, false),
            ("torn at its end", magic + good + Array(record("m b", other).dropLast(3)), true),
            ("its key's bytes cut", magic + good + Array(record("m b", other).prefix(6)), true),
            ("an oversized key", magic + good + record("m b", other, keyCount: 1_025), true),
            ("no dimensions", magic + good + record("m b", [], dimensions: 0), true),
            ("too many dimensions", magic + good + record("m b", other, dimensions: 65_537), true),
            ("a dimension past the bytes", magic + good + record("m b", other, dimensions: 4), true),
            ("a key that isn't UTF-8", magic + good + [2, 0, 0, 0, 0xFF, 0xFE, 1, 0, 0, 0, 0, 0, 0, 0], true),
            ("zeros after it", magic + good + [UInt8](repeating: 0, count: 64), true),
            ("a record after a bad one is never reached", magic + good + record("m b", other, dimensions: 0) + record("m c", other), true),
        ]
        for (name, bytes, keepsFirst) in cases {
            try withVectorFile { url in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(bytes).write(to: url)
                let memory = EmbeddingMemory(url: url)
                expectEqual(bits(memory.vector(forKey: "m a")), keepsFirst ? bits(odd) : nil, name)
                expectEqual(memory.vector(forKey: "m b"), nil, name)
                expectEqual(memory.vector(forKey: "m c"), nil, name)
            }
        }
        try withVectorFile { url in expectEqual(EmbeddingMemory(url: url).vector(forKey: "m a"), nil, "no file") }
    },
    test("a save that finds the file torn heals it first: what's before the tear and what's in memory, written whole, so the next load reaches the new records") {
        let good = record("m a", odd)
        let torn: [(String, [UInt8])] = [
            ("cut inside its numbers", Array(record("m x", other).dropLast(3))),
            ("cut inside its key", Array(record("m x", other).prefix(6))),
            ("cut inside its count", [9, 0]),
            ("a count, then another record's bytes as its key and numbers", record("m x", other, keyCount: 20)),
            ("zeros", [UInt8](repeating: 0, count: 64)),
        ]
        for (name, tail) in torn {
            try withVectorFile { url in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(magic + good + tail).write(to: url)
                let before = try inode(url)
                let memory = EmbeddingMemory(url: url)
                expectEqual(bits(memory.vector(forKey: "m a")), bits(odd), name)
                memory.keep(other, forKey: "m b")
                memory.save()
                expectEqual(try fileBytes(url), magic + good + record("m b", other), "\(name): the whole records, the new one after them")
                expect(try inode(url) != before, "\(name): written beside it and renamed over, never truncated in place")
                memory.keep([9], forKey: "m c")
                memory.save()
                let reopened = EmbeddingMemory(url: url)
                expectEqual(bits(reopened.vector(forKey: "m a")), bits(odd), name)
                expectEqual(bits(reopened.vector(forKey: "m b")), bits(other), name)
                expectEqual(bits(reopened.vector(forKey: "m c")), bits([9]), "\(name): appended after the healed file")
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["embedding-vectors.bin"], "\(name): no temporary file left")
            }
        }
    },
    test("healing keeps the records another copy wrote before the tear, and memory's vector wins over the file's of one key") {
        try withVectorFile { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let memory = EmbeddingMemory(url: url)
            memory.keep(odd, forKey: "m a")
            _ = memory.vector(forKey: "m a")
            // Another copy appended two records after this one loaded the file, and the second is torn.
            try Data(magic + record("m a", other) + record("m other", other) + Array(record("m torn", other).dropLast(2))).write(to: url)
            memory.save()
            let reopened = EmbeddingMemory(url: url)
            expectEqual(bits(reopened.vector(forKey: "m a")), bits(odd), "memory's own")
            expectEqual(bits(reopened.vector(forKey: "m other")), bits(other), "the other copy's whole record")
            expectEqual(reopened.vector(forKey: "m torn"), nil)
        }
    },
    test("a file torn by a failed write, then saved to, is read back whole: the record kept after the tear is not lost") {
        try withVectorFile { url in
            let memory = EmbeddingMemory(url: url)
            memory.keep(odd, forKey: "m a")
            memory.save()
            // A write that failed part way left half of a record, as a full disk does.
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(record("m lost", other).prefix(11)))
            try handle.close()
            memory.keep(other, forKey: "m b")
            memory.save()
            let reopened = EmbeddingMemory(url: url)
            expectEqual(bits(reopened.vector(forKey: "m a")), bits(odd))
            expectEqual(bits(reopened.vector(forKey: "m b")), bits(other), "read back, not swallowed by the torn record's lengths")
            expectEqual(try fileBytes(url), magic + record("m a", odd) + record("m b", other))
        }
    },
    test("a file with the wrong magic is replaced by a new file renamed into place, never truncated in place") {
        try withVectorFile { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let foreign = Array("not ours, whatever it is".utf8)
            try Data(foreign).write(to: url)
            let before = try inode(url)
            let opened = try FileHandle(forReadingFrom: url)
            defer { try? opened.close() }
            let memory = EmbeddingMemory(url: url)
            memory.keep(other, forKey: "m a")
            memory.save()
            expectEqual(try fileBytes(url), magic + record("m a", other))
            expect(try inode(url) != before, "a new file")
            expectEqual([UInt8](try opened.readToEnd() ?? Data()), foreign, "the old one, read through the handle held open, was left as it was")
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["embedding-vectors.bin"], "no temporary file left")
            expectEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        }
    },
    test("a memory with no file writes none") {
        let memory = EmbeddingMemory(url: nil)
        memory.keep(other, forKey: "m a")
        memory.save()
        expectEqual(memory.url, nil)
        expectEqual(bits(memory.vector(forKey: "m a")), bits(other))
    },
    test("a failed save keeps what it couldn't write, for the next") {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let blocked = directory.appending(path: "blocked", directoryHint: .notDirectory)
            try Data("a file where a directory should be".utf8).write(to: blocked)
            let url = blocked.appending(path: "embedding-vectors.bin", directoryHint: .notDirectory)
            let memory = EmbeddingMemory(url: url)
            memory.keep(other, forKey: "m a")
            memory.save()
            expectEqual(bits(memory.vector(forKey: "m a")), bits(other), "still in memory")
            try FileManager.default.removeItem(at: blocked)
            memory.save()
            expectEqual(try fileBytes(url), magic + record("m a", other))
        }
    },
    test("the app's is in Application Support, beside the keys") {
        expectEqual(EmbeddingMemory.standard().url?.path, "\(NSHomeDirectory())/Library/Application Support/InfiniteCanvas/embedding-vectors.bin")
    },
    test("reading and writing the file are done off the main thread, as Embeddings has them done") {
        try withVectorFile { url in
            let embeddings = Embeddings(model: ScriptedEmbeddingModel.hashing(), memory: EmbeddingMemory(url: url))
            _ = try outcome(of: embeddings, ["one", "two"])
            let threads = embeddings.memory.fileAccessesOnMainThread
            expectEqual(threads.count, 2, "a read and a write")
            expect(!threads.contains(true), "\(threads)")
            let direct = EmbeddingMemory(url: url)
            _ = direct.vector(forKey: "m a")
            expectEqual(direct.fileAccessesOnMainThread, [true], "a lookup made from the main thread reads there: the log sees it")
        }
    },
])

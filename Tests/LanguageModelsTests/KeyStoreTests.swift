import Foundation
import LanguageModels
import TestKit

@MainActor let keyStoreTests = Suite("The key store", [
    test("the app's is ~/Library/Application Support/InfiniteCanvas/anthropic-api-key") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        expectEqual(AnthropicKeyStore.standard.url.path, "\(home)/Library/Application Support/InfiniteCanvas/anthropic-api-key")
    },
    test("a missing file is no key") {
        try withTemporaryStore { keys in
            expectEqual(keys.read(), nil)
            expect(!keys.hasKey)
        }
    },
    test("saves a key and reads it back, making the directory") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            expectEqual(keys.read(), testKey)
            expect(keys.hasKey)
            expectEqual(try String(contentsOf: keys.url, encoding: .utf8), testKey, "the file holds the key and nothing else")
        }
    },
    test("only its owner can read the file (0600)") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            let attributes = try FileManager.default.attributesOfItem(atPath: keys.url.path)
            expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    },
    test("a key saved over a file anyone could read leaves it 0600") {
        try withTemporaryStore { keys in
            try FileManager.default.createDirectory(at: keys.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old".utf8).write(to: keys.url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keys.url.path)
            try keys.write(testKey)
            expectEqual(keys.read(), testKey)
            let attributes = try FileManager.default.attributesOfItem(atPath: keys.url.path)
            expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let left = try FileManager.default.contentsOfDirectory(atPath: keys.url.deletingLastPathComponent().path)
            expectEqual(left, ["anthropic-api-key"], "no temporary file is left behind")
        }
    },
    test("trims whitespace: pasted with a newline, it's saved without") {
        try withTemporaryStore { keys in
            try keys.write("  \(testKey)\n")
            expectEqual(try String(contentsOf: keys.url, encoding: .utf8), testKey)
            try Data("\n\(testKey)  \n\n".utf8).write(to: keys.url)
            expectEqual(keys.read(), testKey, "a file edited by hand reads trimmed")
        }
    },
    test("nothing but whitespace is no key: saving it removes the file, reading it reads none") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            try keys.write(" \n ")
            expect(!FileManager.default.fileExists(atPath: keys.url.path))
            try Data("  \n".utf8).write(to: keys.url)
            expectEqual(keys.read(), nil)
        }
    },
    test("removes the key; removing none is fine") {
        try withTemporaryStore { keys in
            try keys.remove()
            try keys.write(testKey)
            try keys.remove()
            expectEqual(keys.read(), nil)
            expect(!FileManager.default.fileExists(atPath: keys.url.path))
        }
    },
])

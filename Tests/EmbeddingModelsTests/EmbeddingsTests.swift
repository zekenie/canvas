import EmbeddingModels
import Foundation
import TestKit

private func bits(_ vector: [Float]) -> [UInt32] { vector.map(\.bitPattern) }

@MainActor let embeddingsTests = Suite("The vectors the registry lends", [
    test("only the missing texts are asked, once each, however often they come, and the answer is in the order asked") {
        let model = ScriptedEmbeddingModel.hashing()
        let embeddings = Embeddings(model: model, memory: EmbeddingMemory(url: nil))
        let answered = try require(try outcome(of: embeddings, ["b", "a", "b", "c", "a"]).successValue)
        expectEqual(model.requests, [["b", "a", "c"]], "first-seen order, duplicates once")
        expectEqual(answered.asked, 3)
        expectEqual(answered.model, "scripted")
        expectEqual(answered.vectors.count, 5)
        let hashing = ScriptedEmbeddingModel.hashing()
        let expected = try require(try outcome(of: hashing, ["b", "a", "b", "c", "a"]).successValue)
        expectEqual(answered.vectors.map(bits), expected.map(bits))
        expectEqual(bits(answered.vectors[0]), bits(answered.vectors[2]))
        expectEqual(bits(answered.vectors[1]), bits(answered.vectors[4]))
    },
    test("a second call asks nothing, and one with a text more asks only for it") {
        let model = ScriptedEmbeddingModel.hashing()
        let embeddings = Embeddings(model: model, memory: EmbeddingMemory(url: nil))
        _ = try outcome(of: embeddings, ["a", "b"])
        let again = try require(try outcome(of: embeddings, ["b", "a"]).successValue)
        expectEqual(again.asked, 0)
        expectEqual(model.requests.count, 1)
        let more = try require(try outcome(of: embeddings, ["a", "c"]).successValue)
        expectEqual(more.asked, 1)
        expectEqual(model.requests, [["a", "b"], ["c"]])
    },
    test("no texts ask nothing") {
        let model = ScriptedEmbeddingModel.hashing()
        let answered = try require(try outcome(of: Embeddings(model: model, memory: EmbeddingMemory(url: nil)), []).successValue)
        expectEqual(answered.vectors.count, 0)
        expectEqual(answered.asked, 0)
        expectEqual(model.requests.count, 0)
    },
    test("it asks in chunks of the model's texts a request, in the order the texts first come") {
        let model = ScriptedEmbeddingModel.hashing(textsPerRequest: 2)
        let embeddings = Embeddings(model: model, memory: EmbeddingMemory(url: nil))
        let answered = try require(try outcome(of: embeddings, ["a", "b", "a", "c", "d", "e", "b"]).successValue)
        expectEqual(model.requests, [["a", "b"], ["c", "d"], ["e"]])
        expectEqual(answered.asked, 5)
        expectEqual(answered.vectors.count, 7)
    },
    test("a failure at the second chunk keeps the first's vectors, in memory and in the file, throws, and the next call asks for the rest") {
        try withVectorFile { url in
            let model = ScriptedEmbeddingModel.hashing(textsPerRequest: 2)
            let memory = EmbeddingMemory(url: url)
            let embeddings = Embeddings(model: model, memory: memory)
            model.vectors[Array("c".utf8)] = [1, 2]
            model.fallback = nil
            model.set([0], for: "a")
            model.set([0.5], for: "b")
            // The second chunk is "c" and "d": "d" has no vector, so the call fails there.
            let failed = try require(try outcome(of: embeddings, ["a", "b", "c", "d"]).failureValue)
            expectEqual(failed.failure, .server(status: 0, message: "ScriptedEmbeddingModel has no vector for “d”"))
            expectEqual(model.requests, [["a", "b"], ["c", "d"]])
            let name = model.name
            expectEqual(memory.vector(forKey: EmbeddingMemory.key(of: "a", from: name)), [0])
            expectEqual(memory.vector(forKey: EmbeddingMemory.key(of: "b", from: name)), [0.5])
            expectEqual(memory.vector(forKey: EmbeddingMemory.key(of: "c", from: name)), nil, "a chunk that failed keeps none")
            let reopened = EmbeddingMemory(url: url)
            expectEqual(reopened.vector(forKey: EmbeddingMemory.key(of: "b", from: name)), [0.5], "in the file too")
            model.set([3], for: "d")
            let rest = try require(try outcome(of: embeddings, ["a", "b", "c", "d"]).successValue)
            expectEqual(rest.asked, 2)
            expectEqual(model.requests.last, ["c", "d"])
            expectEqual(rest.vectors, [[0], [0.5], [1, 2], [3]])
        }
    },
    test("a model that answers the wrong number of vectors is an unusable answer, and nothing from it is kept") {
        let model = ScriptedEmbeddingModel.hashing()
        let embeddings = Embeddings(model: model, memory: EmbeddingMemory(url: nil))
        let short = CountingModel(answers: 1)
        let wrong = Embeddings(model: short, memory: EmbeddingMemory(url: nil))
        let error = try require(try outcome(of: wrong, ["a", "b"]).failureValue)
        expectEqual(error.failure, .malformedResponse)
        expectEqual(error.message, "Unusable answer")
        expectEqual(wrong.memory.vector(forKey: EmbeddingMemory.key(of: "a", from: short.name)), nil)
        _ = embeddings
    },
    test("canonically equal texts are two texts: asked twice, kept twice") {
        let model = ScriptedEmbeddingModel.hashing()
        let embeddings = Embeddings(model: model, memory: EmbeddingMemory(url: nil))
        let answered = try require(try outcome(of: embeddings, ["caf\u{E9}", "cafe\u{301}"]).successValue)
        expectEqual(answered.asked, 2)
        expectEqual(model.requests.count, 1)
        expectEqual(model.requests[0].count, 2)
        expect(bits(answered.vectors[0]) != bits(answered.vectors[1]), "two vectors, as the hashing model hashes the bytes")
    },
    test("the file is written after each chunk the model answered") {
        try withVectorFile { url in
            let model = ScriptedEmbeddingModel.hashing(textsPerRequest: 1)
            model.holdsAnswers = true
            let embeddings = Embeddings(model: model, memory: EmbeddingMemory(url: url))
            var done = false
            let call = Task { _ = try? await embeddings.vectors(of: ["a", "b", "c"]); done = true }
            for expected in 1...3 {
                spinRunLoop(until: { model.waiting == 1 })
                let kept = (try? Data(contentsOf: url)).map { EmbeddingMemory.records(count: $0) } ?? 0
                expectEqual(kept, expected - 1, "before the chunk \(expected) is answered, the file has the ones before it")
                model.release()
                spinRunLoop(until: { model.answered == expected })
            }
            spinRunLoop(until: { done })
            _ = call
            expectEqual(EmbeddingMemory.records(count: try Data(contentsOf: url)), 3)
        }
    },
    test("cancelling the asking task between chunks throws cancelled, keeping the chunks that came") {
        try withVectorFile { url in
            let model = ScriptedEmbeddingModel.hashing(textsPerRequest: 1)
            model.holdsAnswers = true
            let embeddings = Embeddings(model: model, memory: EmbeddingMemory(url: url))
            var result: Result<EmbeddedTexts, EmbeddingModelError>?
            let call = Task {
                do throws(EmbeddingModelError) { result = .success(try await embeddings.vectors(of: ["a", "b"])) } catch { result = .failure(error) }
            }
            spinRunLoop(until: { model.waiting == 1 })
            model.release()
            spinRunLoop(until: { model.answered == 1 })
            // The second chunk is held: the first was kept, and saved, before it was asked.
            spinRunLoop(until: { model.waiting == 1 })
            expectEqual(result == nil, true)
            call.cancel()
            spinRunLoop(until: { result != nil })
            expectEqual(result?.failureValue?.failure, .cancelled)
            expectEqual(model.requests, [["a"], ["b"]])
            expectEqual(EmbeddingMemory.records(count: try Data(contentsOf: url)), 1, "the file holds the first chunk")
            let reopened = EmbeddingMemory(url: url)
            expect(reopened.vector(forKey: EmbeddingMemory.key(of: "a", from: model.name)) != nil, "the first text's vector is kept")
            expectEqual(reopened.vector(forKey: EmbeddingMemory.key(of: "b", from: model.name)), nil, "the second's isn't")
            expect(embeddings.memory.vector(forKey: EmbeddingMemory.key(of: "a", from: model.name)) != nil, "and in memory")
        }
    },
    test("a vector the file cannot hold is an unusable answer, kept nowhere: none, or past 65,536 numbers") {
        for dimensions in [0, 65_537] {
            try withVectorFile { url in
                let embeddings = Embeddings(model: FixedModel(dimensions: dimensions), memory: EmbeddingMemory(url: url))
                expectEqual(try outcome(of: embeddings, ["one"]).failureValue?.failure, .malformedResponse, "\(dimensions) numbers")
                expect(!FileManager.default.fileExists(atPath: url.path), "nothing written")
                expectEqual(embeddings.memory.vector(forKey: EmbeddingMemory.key(of: "one", from: embeddings.model.name)), nil)
            }
        }
        // And the memory itself refuses one, so the records after it stay readable.
        try withVectorFile { url in
            let memory = EmbeddingMemory(url: url)
            memory.keep([], forKey: "m empty")
            memory.keep([Float](repeating: 1, count: 65_537), forKey: "m long")
            memory.keep([1], forKey: "m " + String(repeating: "k", count: 1_024))
            memory.keep([2], forKey: "m fine")
            memory.save()
            let reopened = EmbeddingMemory(url: url)
            expectEqual(reopened.vector(forKey: "m fine"), [2])
            expectEqual(EmbeddingMemory.records(count: try Data(contentsOf: url)), 1)
        }
    },
])

/// A model that answers every text with a vector of `dimensions` ones.
private struct FixedModel: EmbeddingModel {
    var dimensions: Int
    var name: String { "fixed" }
    var textsPerRequest: Int { 10 }
    func embed(_ texts: [String]) async throws(EmbeddingModelError) -> [[Float]] {
        texts.map { _ in [Float](repeating: 1, count: dimensions) }
    }
}

/// A model that answers fewer vectors than texts.
private struct CountingModel: EmbeddingModel {
    var answers: Int
    var name: String { "counting" }
    var textsPerRequest: Int { 10 }
    func embed(_ texts: [String]) async throws(EmbeddingModelError) -> [[Float]] {
        Array(repeating: [1, 2], count: answers)
    }
}

private extension EmbeddingMemory {
    /// How many records a file's bytes hold, by the format.
    static func records(count data: Data) -> Int {
        let bytes = [UInt8](data)
        var at = 8, count = 0
        func word(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        while at + 4 <= bytes.count {
            let keyEnd = at + 4 + word(at)
            guard keyEnd + 4 <= bytes.count else { break }
            at = keyEnd + 4 + 4 * word(keyEnd)
            count += 1
        }
        return count
    }
}

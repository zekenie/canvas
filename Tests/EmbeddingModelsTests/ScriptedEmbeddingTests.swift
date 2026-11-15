import EmbeddingModels
import Foundation
import TestKit

@MainActor let scriptedEmbeddingTests = Suite("The scripted embedding model", [
    test("answers each text from its vector, then its fallback, then fails, keeping every request") {
        let model = ScriptedEmbeddingModel()
        model.set([1, 2], for: "a")
        expectEqual(try require(try outcome(of: model, ["a"]).successValue), [[1, 2]])
        let failed = try require(try outcome(of: model, ["a", "b"]).failureValue)
        expectEqual(failed.failure, .server(status: 0, message: "ScriptedEmbeddingModel has no vector for “b”"))
        model.fallback = { text in [Float(text.utf8.count)] }
        expectEqual(try require(try outcome(of: model, ["a", "bcd"]).successValue), [[1, 2], [3]], "its own vector first")
        expectEqual(model.requests, [["a"], ["a", "b"], ["a", "bcd"]])
        expectEqual(model.answered, 3)
        expectEqual(model.name, "scripted")
        expectEqual(ScriptedEmbeddingModel.name, "scripted")
        expectEqual(model.textsPerRequest, .max)
        expectEqual(ScriptedEmbeddingModel(textsPerRequest: 4).textsPerRequest, 4)
    },
    test("its vectors are kept by the text's UTF-8: two texts canonically equal are two") {
        let model = ScriptedEmbeddingModel()
        model.set([1], for: "caf\u{E9}")
        model.set([2], for: "cafe\u{301}")
        expectEqual(try require(try outcome(of: model, ["cafe\u{301}", "caf\u{E9}"]).successValue), [[2], [1]])
    },
    test("a queued failure is the next call's, and only its") {
        let model = ScriptedEmbeddingModel.hashing()
        model.queue(.rateLimited)
        model.queue(EmbeddingModelError(.noKey, provider: "Other"))
        expectEqual(try require(try outcome(of: model, ["a"]).failureValue).message, "Rate limited")
        expectEqual(try require(try outcome(of: model, ["a"]).failureValue).message, "No Other key")
        expect(try outcome(of: model, ["a"]).successValue != nil)
    },
    test("hashing is deterministic, equal for equal text, and its numbers are bytes of the text's SHA-256 from -0.5 to 0.5") {
        let model = ScriptedEmbeddingModel.hashing(dimensions: 4)
        let first = try require(try outcome(of: model, ["abc", "abc", "abd"]).successValue)
        expectEqual(first[0], first[1])
        expect(first[0] != first[2])
        expectEqual(first[0].count, 4)
        // SHA-256("abc") starts ba 78 16 bf.
        expectEqual(first[0], [Float(0xBA) / 255 - 0.5, Float(0x78) / 255 - 0.5, Float(0x16) / 255 - 0.5, Float(0xBF) / 255 - 0.5])
        expectEqual(try require(try outcome(of: ScriptedEmbeddingModel.hashing(dimensions: 4), ["abc"]).successValue)[0], first[0], "another model, the same")
        expectEqual(try require(try outcome(of: ScriptedEmbeddingModel.hashing(), ["abc"]).successValue)[0].count, 8, "eight dimensions by default")
    },
    test("holds each call while it says, until released, and a held call cancelled ends cancelled") {
        let model = ScriptedEmbeddingModel.hashing()
        model.holdsAnswers = true
        var result: Result<[[Float]], EmbeddingModelError>?
        let call = Task {
            do throws(EmbeddingModelError) { result = .success(try await model.embed(["a"])) } catch { result = .failure(error) }
        }
        spinRunLoop(until: { model.waiting == 1 })
        expect(result == nil, "held")
        model.release()
        spinRunLoop(until: { result != nil })
        expectEqual(result?.successValue?.count, 1)
        _ = call
        var cancelled: Result<[[Float]], EmbeddingModelError>?
        let held = Task {
            do throws(EmbeddingModelError) { cancelled = .success(try await model.embed(["a"])) } catch { cancelled = .failure(error) }
        }
        spinRunLoop(until: { model.waiting == 1 })
        held.cancel()
        spinRunLoop(until: { cancelled != nil })
        expectEqual(cancelled?.failureValue?.failure, .cancelled)
        expectEqual(model.waiting, 0)
    },
    test("its errors are said as a person reads them") {
        let cases: [(EmbeddingModelError.Failure, String, transient: Bool, needsKey: Bool)] = [
            (.noKey, "No P key", false, true), (.unauthorized, "P key rejected", false, true), (.rateLimited, "Rate limited", true, false),
            (.overloaded, "P overloaded", true, false), (.server(status: 500, message: "Boom. Sorry."), "P error 500", true, false),
            (.server(status: 400, message: "Bad input. See the docs."), "Bad input", false, false), (.server(status: 404, message: nil), "P error 404", false, false),
            (.network("offline"), "Can’t reach P", true, false), (.timedOut, "Timed out", true, false),
            (.malformedResponse, "Unusable answer", false, false), (.cancelled, "Cancelled", false, false),
        ]
        for (failure, message, transient, needsKey) in cases {
            let error = EmbeddingModelError(failure, provider: "P")
            expectEqual(error.message, message)
            expectEqual(error.isTransient, transient, message)
            expectEqual(error.needsKey, needsKey, message)
            expectEqual(error.errorDescription, message)
        }
    },
])

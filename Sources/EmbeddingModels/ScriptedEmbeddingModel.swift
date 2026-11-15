import CryptoKit
import Foundation

/// An embedding model for tests: it keeps every request it's asked and answers each text from the
/// vectors it was given (by the text's UTF-8, never a `String`, which would merge two texts that are
/// canonically equal), else from `fallback`, else the call fails with `.server(status: 0, …)`. A failure
/// can be queued for the next call; while `holdsAnswers` every call waits, once its request is kept,
/// until the test calls `release()`. Never reaches the network.
///
/// Calls land on the main actor: a test that makes one runs the main run loop until it's done
/// (TestKit's `spinRunLoop(until:)`).
@MainActor
public final class ScriptedEmbeddingModel: EmbeddingModel {
    /// What the model's vectors say it is.
    public nonisolated static let name = "scripted"
    /// What its errors call it.
    public static let provider = "Scripted"

    /// Every call's texts, in order, answered or not.
    public private(set) var requests: [[String]] = []
    /// The vector of each text, by the text's UTF-8.
    public var vectors: [[UInt8]: [Float]] = [:]
    /// Answers a text with no vector of its own.
    public var fallback: (@MainActor (String) -> [Float])?
    /// The failures the next calls throw, one each, in order.
    public private(set) var queued: [EmbeddingModelError] = []
    /// While true, each call waits, once its request is kept, until `release()`.
    public var holdsAnswers = false
    /// How many calls have been answered (with vectors or an error, cancelled ones included).
    public private(set) var answered = 0
    /// Read from any thread, as every model's are.
    public nonisolated let textsPerRequest: Int
    public nonisolated var name: String { Self.name }

    private var held: [(id: Int, resume: CheckedContinuation<Void, Never>)] = []
    private var nextID = 0

    public init(textsPerRequest: Int = .max) {
        self.textsPerRequest = textsPerRequest
    }

    /// A model that answers any text with the first `dimensions` bytes of its SHA-256, each as
    /// `Float(byte) / 255 - 0.5`: the same for the same text, and otherwise unlike.
    public static func hashing(dimensions: Int = 8, textsPerRequest: Int = .max) -> ScriptedEmbeddingModel {
        let model = ScriptedEmbeddingModel(textsPerRequest: textsPerRequest)
        model.fallback = { text in
            SHA256.hash(data: Data(text.utf8)).prefix(dimensions).map { Float($0) / 255 - 0.5 }
        }
        return model
    }

    /// Gives `text` its vector.
    public func set(_ vector: [Float], for text: String) { vectors[Array(text.utf8)] = vector }

    /// How many calls are waiting for `release()`.
    public var waiting: Int { held.count }

    /// Queues a failure: the next call throws it.
    public func queue(_ error: EmbeddingModelError) { queued.append(error) }

    /// Queues a failure of the scripted provider's.
    public func queue(_ failure: EmbeddingModelError.Failure) { queue(EmbeddingModelError(failure, provider: Self.provider)) }

    /// Lets every waiting call go on, in the order they came (after this returns, once the main run loop
    /// turns). Calls made later still wait while `holdsAnswers`.
    public func release() {
        let waiting = held
        held.removeAll()
        for call in waiting { call.resume.resume() }
    }

    public func embed(_ texts: [String]) async throws(EmbeddingModelError) -> [[Float]] {
        requests.append(texts)
        defer { answered += 1 }
        if holdsAnswers {
            let id = nextID
            nextID += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { held.append((id, $0)) }
            } onCancel: {
                Task { @MainActor in self.releaseCancelled(id) }
            }
        }
        if Task.isCancelled { throw EmbeddingModelError(.cancelled, provider: Self.provider) }
        if !queued.isEmpty { throw queued.removeFirst() }
        var answers: [[Float]] = []
        for text in texts {
            if let vector = vectors[Array(text.utf8)] {
                answers.append(vector)
            } else if let fallback {
                answers.append(fallback(text))
            } else {
                throw EmbeddingModelError(.server(status: 0, message: "ScriptedEmbeddingModel has no vector for “\(text)”"), provider: Self.provider)
            }
        }
        return answers
    }

    private func releaseCancelled(_ id: Int) {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        held.remove(at: index).resume.resume()
    }
}

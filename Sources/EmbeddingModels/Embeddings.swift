import Canvas
import Foundation

/// What `Embeddings.vectors(of:)` answers.
public struct EmbeddedTexts: Sendable {
    /// The model that gave the vectors (`EmbeddingModel.name`).
    public var model: String
    /// A vector for each text asked, in the order asked.
    public var vectors: [[Float]]
    /// How many distinct texts the model was asked for (0: memory held them all).
    public var asked: Int
}

/// The embedding model the registry lends, and the vectors it gave, kept (`EmbeddingMemory`): what a
/// plugin asks through, never the model itself. One for the registry, so one memory for every editor and
/// every command (`canvas measure` runs with no editor when no board is open, and a vector once kept is
/// never asked for again): the deviation from DecisionModels, whose `Decisions` is a service of each
/// editor. Two calls at once may each ask for a text neither has had answered yet, and so a text twice:
/// nothing tracks what is in flight (a measure is one-shot, so it costs a duplicate request at worst).
@MainActor
public final class Embeddings {
    /// The model asked.
    public let model: any EmbeddingModel
    /// What it answered.
    public let memory: EmbeddingMemory

    public nonisolated init(model: any EmbeddingModel, memory: EmbeddingMemory) {
        self.model = model
        self.memory = memory
    }

    /// The vector of each of `texts`, in their order: kept ones from memory, the rest from the model,
    /// asked in chunks of its `textsPerRequest` in the order the texts first come, each chunk kept (in
    /// memory and in the file) as it lands, so a failure part way keeps what came, throws, and the next
    /// call asks only for the rest. A text is asked once however often it comes in a call, and not again
    /// once kept; a call that overlaps another may ask for a text the other is still waiting on. Texts
    /// are told apart by their UTF-8 (`EmbeddingMemory.key(of:from:)`), never by `String`'s equality,
    /// which takes a precomposed and a decomposed "é" for one. A vector with no numbers or more than the
    /// file can hold (65,536) is an unusable answer, kept nowhere. Cancelling the asking task throws `.cancelled`.
    public func vectors(of texts: [String]) async throws(EmbeddingModelError) -> EmbeddedTexts {
        let name = model.name
        let keys = texts.map { EmbeddingMemory.key(of: $0, from: name) }
        var firstText: [String: String] = [:]
        var distinct: [String] = []
        for (key, text) in zip(keys, texts) where firstText[key] == nil {
            firstText[key] = text
            distinct.append(key)
        }
        let memory = memory
        await memory.loadInBackground()
        let missing = distinct.filter { memory.vector(forKey: $0) == nil }
        let chunk = max(1, model.textsPerRequest)
        var start = 0
        while start < missing.count {
            if Task.isCancelled { throw failure(.cancelled) }
            let asking = Array(missing[start..<min(start + chunk, missing.count)])
            let answered = try await model.embed(asking.map { firstText[$0]! })
            // A vector the memory's file can't hold would cut off every record after it, on every load.
            guard answered.count == asking.count, answered.allSatisfy({ (1...EmbeddingMemory.mostDimensions).contains($0.count) }) else {
                throw failure(.malformedResponse)
            }
            for (key, vector) in zip(asking, answered) { memory.keep(vector, forKey: key) }
            await memory.saveInBackground()
            start += chunk
        }
        let vectors = keys.map { memory.vector(forKey: $0) ?? [] }
        return EmbeddedTexts(model: name, vectors: vectors, asked: missing.count)
    }

    private func failure(_ failure: EmbeddingModelError.Failure) -> EmbeddingModelError {
        EmbeddingModelError(failure, provider: "Embedding model")
    }
}

// MARK: The point

/// Who lends the registry its embeddings: `EmbeddingModelsPlugin`, once.
public enum EmbeddingEngines {}

private struct EmbeddingEnginesKey: Hashable, CustomStringConvertible {
    var description: String { "embedding engine" }
}

extension EmbeddingEngines: KeyedExtensionPoint {
    public typealias Contribution = Embeddings
    public static var owner: PluginID { .embeddingModels }
    public static func uniqueKeys(of _: Embeddings, for _: ShapeTarget) -> [AnyHashable] { [EmbeddingEnginesKey()] }
    public static func summary(of _: Embeddings, for _: ShapeTarget) -> String { "embeddings" }
}

extension Registry {
    /// The embedding model, with the vectors it gave: nil without `EmbeddingModelsPlugin`.
    @MainActor
    public var embeddings: Embeddings? { contributions(to: EmbeddingEngines.self).first?.value }
}

extension CanvasEditor {
    /// The registry's `Embeddings`: nil without `EmbeddingModelsPlugin`.
    public var embeddings: Embeddings? { registry.embeddings }

    /// The model plugins have texts embedded by: OpenAI's in the app, a scripted one in tests. Nil without
    /// `EmbeddingModelsPlugin`.
    public var embeddingModel: (any EmbeddingModel)? { embeddings?.model }
}

@_spi(Host) import Canvas
import EmbeddingModels
import TestKit

// A helper of its own, so that the digest tests need not import EmbeddingModels for one cast.

/// The shipped list's embedding model in a test, scripted, is asked next as one with no OpenAI key is: the request is refused, and `canvas measure
/// --tightness` answers `unavailable` with the reason `no_key`.
@MainActor func queueNoEmbeddingKey(on editor: CanvasEditor) throws {
    try require(editor.embeddingModel as? ScriptedEmbeddingModel, "the shipped list's embedding model, scripted").queue(.noKey)
}

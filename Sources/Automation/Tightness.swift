import Canvas
import Draw
import EmbeddingModels
import Foundation

// `canvas measure --tightness`: how alike the two notes of each link are. Each note is embedded by its title and words
// (`EmbeddingText`) by the registry's embedding model, its vectors kept by text, so a second measure asks nothing; the
// vectors of each board are centred on the board's mean, and a pair's tightness is the cosine of its two.

/// The tightness of each pair of `links`, or why it can't be said: no embedding model, no key, or a failed request. One
/// failed request makes the whole answer unavailable, nothing partial. Suspends while the model answers.
@MainActor
func documentTightness(_ links: DocumentLinks, registry: Registry) async -> DocumentTightness {
    guard let embeddings = registry.embeddings else { return .unavailable("No embedding model", reason: "no_model") }
    let model = embeddings.model.name
    if links.pairs.isEmpty { return .measured(model: model, texts: 0, asked: 0, pairs: []) }
    let texts = links.nodes.map { EmbeddingText.of(title: $0.title, words: $0.words) }
    let embedded: EmbeddedTexts
    do throws(EmbeddingModelError) {
        embedded = try await embeddings.vectors(of: texts)
    } catch {
        return .unavailable(error.message, reason: error.needsKey ? "no_key" : "failed")
    }
    let pairs = tightness(of: links, vectors: embedded.vectors)
    // Told apart by their UTF-8, as the memory keeps them.
    return .measured(model: model, texts: Set(texts.map { Array($0.utf8) }).count, asked: embedded.asked, pairs: pairs)
}

/// Each pair's tightness over `vectors`, the vector of each of `links.nodes` in order. Per board, in the order of the keys:
/// each vector less the board's mean (the mean over every note of the board, in a pair or not), divided by its length (1
/// for a zero), and a pair's tightness is the dot product of its two. In `Double`, plain sequential loops: the order of the
/// arithmetic is the contract, so the numbers are the digest tool's (cluster.mjs's) to the last bit given the same vectors:
/// no Accelerate, no `simd`, no fused multiply-add, and no `Dictionary` or `Set` iterated to order anything.
func tightness(of links: DocumentLinks, vectors: [[Float]]) -> [DocumentTightness.Pair] {
    // The notes of each board, in key order (`links.nodes` is), by place in it.
    var order: [String?] = [], members: [String?: [Int]] = [:]
    for (index, node) in links.nodes.enumerated() {
        if members[node.board] == nil { order.append(node.board) }
        members[node.board, default: []].append(index)
    }
    var unit: [String: [Double]] = [:]
    for board in order {
        let indices = members[board]!
        let count = Double(indices.count)
        guard let dimensions = indices.first.map({ vectors[$0].count }), dimensions > 0 else { continue }
        var mean = [Double](repeating: 0, count: dimensions)
        for index in indices {
            let vector = vectors[index]
            guard vector.count == dimensions else { continue }
            for i in 0..<dimensions { mean[i] += Double(vector[i]) / count }
        }
        for index in indices {
            let vector = vectors[index]
            guard vector.count == dimensions else { continue }
            var centred = [Double](repeating: 0, count: dimensions)
            var sum = 0.0
            for i in 0..<dimensions {
                let x = Double(vector[i]) - mean[i]
                centred[i] = x
                sum += x * x
            }
            var length = sum.squareRoot()
            if length == 0 { length = 1 }
            for i in 0..<dimensions { centred[i] /= length }
            unit[links.nodes[index].key] = centred
        }
    }
    return links.pairs.map { pair in
        var dot = 0.0
        if let x = unit[pair.a], let y = unit[pair.b], x.count == y.count {
            for i in 0..<x.count { dot += x[i] * y[i] }
        }
        return DocumentTightness.Pair(a: pair.a, b: pair.b, board: pair.board, tightness: dot)
    }
}

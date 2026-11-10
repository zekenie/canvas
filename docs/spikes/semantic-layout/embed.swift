// Embeds data/texts.json with the two on-device models: the sentence embedding and the contextual one (its token vectors averaged).
import Foundation
import NaturalLanguage
let dir = CommandLine.arguments[1]
let items = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/texts.json"))) as! [[String: String]]
let sentence = NLEmbedding.sentenceEmbedding(for: .english)!
let contextual = NLContextualEmbedding(language: .english)!
try contextual.load()
var sv: [String: [Double]] = [:], cv: [String: [Double]] = [:]
let t0 = Date()
for item in items {
  let key = item["key"]!, text = item["text"]!
  sv[key] = sentence.vector(for: text) ?? Array(repeating: 0, count: sentence.dimension)
  let r = try contextual.embeddingResult(for: text, language: .english)
  var sum = Array(repeating: 0.0, count: contextual.dimension); var n = 0.0
  r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in for i in 0..<v.count { sum[i] += v[i] }; n += 1; return true }
  cv[key] = sum.map { $0 / max(n, 1) }
}
FileHandle.standardError.write("embedded \(items.count) in \(Date().timeIntervalSince(t0)) s, max tokens \(contextual.maximumSequenceLength)\n".data(using: .utf8)!)
try JSONSerialization.data(withJSONObject: sv).write(to: URL(fileURLWithPath: dir + "/vec-sentence.json"))
try JSONSerialization.data(withJSONObject: cv).write(to: URL(fileURLWithPath: dir + "/vec-contextual.json"))

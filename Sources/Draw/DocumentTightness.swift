import Foundation

// How alike the two notes of each link are, as `canvas measure --tightness` answers it (`DocumentMeasure.tightness`): the wire
// of the member, which Draw defines and knows no model for. The command that asks the embedding model fills it
// (Automation's `documentTightness`), over the links Draw reads (`DocumentLinks`).

/// The `tightness` of a document's measure: either the pairs, or why there are none to say.
public struct DocumentTightness: Encodable, Sendable {
    /// Two notes a link joins on one board, `a` before `b` in UTF-16 code-unit order.
    public struct Pair: Encodable, Sendable, Equatable {
        public let a: String
        public let b: String
        /// The key of the node that owns the board they are on; nil for the drawing's own board.
        public let board: String?
        /// The cosine of their two vectors, each centred on the board's mean: a `Double`, written as it is.
        public let tightness: Double

        public init(a: String, b: String, board: String?, tightness: Double) {
            self.a = a
            self.b = b
            self.board = board
            self.tightness = tightness
        }
    }

    /// The embedding model's name, which its vectors are kept by (available).
    public let model: String?
    /// How many distinct texts were embedded for this answer (available).
    public let texts: Int?
    /// How many of those the model was asked for; 0 when memory held them all (available).
    public let asked: Int?
    /// One for each pair of notes (available), sorted by `(a, b)` in UTF-16 code-unit order.
    public let pairs: [Pair]?
    /// Why it isn't (unavailable): the error's words.
    public let unavailable: String?
    /// `no_model` (the app has no embedding model), `no_key` (no key, or it was rejected) or `failed` (any other).
    public let reason: String?

    /// The model answered, or memory held every text.
    public static func measured(model: String, texts: Int, asked: Int, pairs: [Pair]) -> DocumentTightness {
        DocumentTightness(model: model, texts: texts, asked: asked, pairs: pairs, unavailable: nil, reason: nil)
    }

    /// The sizes are still answered; this says why the pairs aren't.
    public static func unavailable(_ message: String, reason: String) -> DocumentTightness {
        DocumentTightness(model: nil, texts: nil, asked: nil, pairs: nil, unavailable: message, reason: reason)
    }
}

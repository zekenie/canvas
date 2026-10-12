import Canvas
import DetailPanel
import Foundation

/// The JSON Schema's colors in the code editor: `JSONReader.tokens`, a scan that never fails, so a
/// half-typed schema is colored as far as it goes. A member's name is a string followed by a colon.
enum SchemaCodeColors {
    /// Past this many bytes the text isn't colored: each keystroke scans it all.
    static let maxLength = 200_000

    /// The runs of the shape `id`'s schema `text`, and where it stops being JSON, from the shape's
    /// reading (which its rules, the panel and the sync read too).
    @MainActor
    static func spans(in text: String, for id: ShapeID) -> [DetailCodeSpan] {
        guard text.utf8.count <= maxLength else { return [] }
        return spans(in: text, error: SchemaReadings.reading(of: text, for: id).document.error)
    }

    /// The runs of `text`; the token where `error` is (where the text stops being JSON: a stray
    /// comma's next token, say) marked `.invalid`, unless it's at the end (a text still being typed).
    static func spans(in text: String, error: JSONSyntaxError? = nil) -> [DetailCodeSpan] {
        let utf8 = Array(text.utf8)
        guard utf8.count <= maxLength else { return [] }
        let tokens = JSONReader.tokens(in: text)
        let utf16 = UTF16Offsets(text, utf8Count: utf8.count)
        var spans: [DetailCodeSpan] = []
        spans.reserveCapacity(tokens.count / 2)
        for (i, token) in tokens.enumerated() {
            let role: DetailCodeSpan.Role
            switch token.kind {
            case .string: role = i + 1 < tokens.count && tokens[i + 1].kind == .colon ? .name : .string
            case .number: role = .number
            case .literal: role = .keyword
            case .invalid: role = .invalid
            case .openBrace, .closeBrace, .openBracket, .closeBracket, .colon, .comma: continue
            }
            let start = utf16[token.range.lowerBound], end = utf16[token.range.upperBound]
            spans.append(DetailCodeSpan(role, NSRange(location: start, length: end - start)))
        }
        if let error, let token = tokens.first(where: { $0.range.contains(error.offset) }) {
            let start = utf16[token.range.lowerBound], end = utf16[token.range.upperBound]
            spans.append(DetailCodeSpan(.invalid, NSRange(location: start, length: end - start)))
        }
        return spans
    }

    /// UTF-8 offsets as UTF-16 ones (`NSString`'s): the same while the text is ASCII, as JSON
    /// mostly is; else counted once, a scalar at a time (an offset inside one counts as its start).
    struct UTF16Offsets {
        private let table: [Int]?

        init(_ text: String, utf8Count: Int) {
            guard utf8Count != text.utf16.count else {
                table = nil
                return
            }
            var table = [Int](repeating: 0, count: utf8Count + 1)
            var utf8 = 0, utf16 = 0
            for scalar in text.unicodeScalars {
                let width = UTF8.width(scalar)
                for k in 0..<width { table[utf8 + k] = utf16 }
                utf8 += width
                utf16 += UTF16.width(scalar)
            }
            table[utf8Count] = utf16
            self.table = table
        }

        subscript(offset: Int) -> Int { table?[offset] ?? offset }
    }
}

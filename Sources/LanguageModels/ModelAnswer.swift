import Foundation

/// What every plugin that reads a model's answer as text does first: take off what the model
/// sometimes wraps it in, though its prompt asks for neither (a safety net).
public enum ModelAnswer {
    /// `text` trimmed, and stripped from either end, until nothing changes, of a code-fence line (one
    /// that starts with three backticks), a line that's nothing but a tag (`</output>`, which the
    /// model sometimes ends with), and the answer's own block tags (`<tag>`, `</tag>`, on a line of
    /// their own or not), trimming after each. Anything else is the answer's: another block's tags
    /// on the line with it stay.
    public static func unwrapped(_ text: String, tag: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            let before = text
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if let first = lines.first, isWrapper(first) { lines.removeFirst() }
            if let last = lines.last, isWrapper(last) { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("<\(tag)>") { text = text.dropFirst(tag.count + 2).trimmingCharacters(in: .whitespacesAndNewlines) }
            if text.hasSuffix("</\(tag)>") { text = text.dropLast(tag.count + 3).trimmingCharacters(in: .whitespacesAndNewlines) }
            if text == before { return text }
        }
    }

    /// A fence line, or a line of one tag alone (`<answer>`, `</output>`).
    private static func isWrapper(_ line: Substring) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("```") { return true }
        guard line.hasPrefix("<"), line.hasSuffix(">"), line.count > 2 else { return false }
        let name = line.dropFirst(line.hasPrefix("</") ? 2 : 1).dropLast()
        return !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "_" || $0 == "-") }
    }
}

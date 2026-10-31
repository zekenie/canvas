import Foundation

/// A line that may be a command: its `/` where the line starts, a name, then what the command is
/// given. Ranges are UTF-16, as `NSString` counts, in the text it was read from.
public struct SlashCommandLine: Equatable, Sendable {
    /// The line's text, from its `/` to its end, without its line break: what running the command
    /// takes out of the text.
    public let range: NSRange
    /// The `/` and the name as typed: the line's start to the name's end, what a text view marks as
    /// the command.
    public let nameRange: NSRange
    /// The name as typed, folded to lowercase.
    public let name: String
    /// What follows the name and the whitespace after it, to the line's end, less trailing
    /// whitespace. Empty (at the name's end or the line's) when nothing was typed.
    public let arguments: NSRange

    /// The line the caret (an empty selection at `caret`) is on, if it starts with `/` and a name
    /// ended by whitespace or the line's end, and the caret is after that `/`. A line ends at `\n`,
    /// `\r`, `\r\n`, U+0085, U+2028 or U+2029 (what `NSString` counts); the caret at the very end of
    /// text that ends in a line break is on the empty last line, which is no command. A name is
    /// ASCII letters, digits and hyphens: anything else after the `/`'s letters (a punctuation mark,
    /// a mention's U+FFFC) makes it no command line.
    public init?(in text: NSString, caret: Int) {
        guard caret >= 0, caret <= text.length else { return nil }
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: caret, length: 0))
        guard contentsEnd > start, text.character(at: start) == Self.slash, caret > start, caret <= contentsEnd else { return nil }
        var nameEnd = start + 1
        while nameEnd < contentsEnd, Self.isNameCharacter(text.character(at: nameEnd)) { nameEnd += 1 }
        guard nameEnd > start + 1, nameEnd == contentsEnd || Self.isWhitespace(text.character(at: nameEnd)) else { return nil }
        var argumentsStart = nameEnd
        while argumentsStart < contentsEnd, Self.isWhitespace(text.character(at: argumentsStart)) { argumentsStart += 1 }
        var argumentsEnd = contentsEnd
        while argumentsEnd > argumentsStart, Self.isWhitespace(text.character(at: argumentsEnd - 1)) { argumentsEnd -= 1 }
        range = NSRange(location: start, length: contentsEnd - start)
        nameRange = NSRange(location: start, length: nameEnd - start)
        name = text.substring(with: NSRange(location: start + 1, length: nameEnd - start - 1)).lowercased()
        arguments = NSRange(location: argumentsStart, length: argumentsEnd - argumentsStart)
    }

    /// Whether a command's name is well formed: lowercase ASCII letters and digits, words joined by
    /// single hyphens (`set-title`, `move-into`, `h2`).
    public static func isName(_ name: String) -> Bool {
        var afterHyphen = true                         // a name can't start with one
        for byte in name.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                afterHyphen = false
            case UInt8(ascii: "-"):
                if afterHyphen { return false }
                afterHyphen = true
            default:
                return false
            }
        }
        return !afterHyphen
    }

    /// Whether a character may be typed in a name: an ASCII letter (either case, since a name is
    /// matched folded), a digit or a hyphen.
    public static func isNameCharacter(_ character: unichar) -> Bool {
        switch character {
        case 0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x2D: true
        default: false
        }
    }

    static let slash: unichar = 0x2F
    /// What a mention's pill is in the text (U+FFFC): never a name, nor what the list matches.
    static let pill: unichar = 0xFFFC

    static func isWhitespace(_ character: unichar) -> Bool {
        Unicode.Scalar(character)?.properties.isWhitespace ?? false
    }

    /// Whether a character ends a line, as `NSString` counts: `\n`, `\r`, U+0085, U+2028, U+2029.
    static func isLineBreak(_ character: unichar) -> Bool {
        switch character {
        case 0x0A, 0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }
}

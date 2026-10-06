import Foundation

// A JSON Pointer (RFC 6901): where a value is in a JSON document, by the keys and indexes that lead
// to it from the root. A schema card's highlights name the part of its schema their words say by
// one (`SchemaTarget`'s address), as the model writes it (`LosslessStringConvertible`).

/// An RFC 6901 JSON Pointer: the reference tokens from the root, unescaped (`~1` is "/", `~0` is
/// "~"). Its URI fragment form ("#/properties/key", as a `$ref` writes one) reads the same, though
/// what a fragment would percent-encode isn't decoded.
public struct JSONPointer: Hashable, Sendable, LosslessStringConvertible {
    public var tokens: [String]

    public init(tokens: [String]) { self.tokens = tokens }

    /// Nil for text that isn't a pointer: not empty, and not starting with "/" (after a "#").
    public init?(_ text: String) {
        var text = Substring(text)
        if text.hasPrefix("#") { text = text.dropFirst() }
        guard !text.isEmpty else {
            tokens = []
            return
        }
        guard text.hasPrefix("/") else { return nil }
        // "~01" is "~1": "~1" is read first, then "~0".
        tokens = text.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }

    /// The pointer as RFC 6901 writes it: "" for the root, else "/" before each token, escaped.
    public var description: String {
        tokens.map { "/" + $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined()
    }

    /// What it leads to in `root`: the value, and the member it's the value of when its last token
    /// names an object's member. Nil when a token names no member of an object (of two with the
    /// name, the last, as `JSONNode`'s subscript reads it), no element of an array (an index is
    /// `0` or digits that don't start with `0`; `-`, past the end, is none), or goes into a value
    /// that's neither.
    public func resolve(in root: JSONNode) -> Target? {
        var node = root
        var member: JSONMember?
        for token in tokens {
            switch node.value {
            case .object(let members):
                guard let found = members.last(where: { $0.key == token }) else { return nil }
                member = found
                node = found.value
            case .array(let elements):
                guard let index = Self.index(token), index < elements.count else { return nil }
                member = nil
                node = elements[index]
            default:
                return nil
            }
        }
        return Target(value: node, member: member)
    }

    /// What a pointer leads to.
    public struct Target: Equatable, Sendable {
        public var value: JSONNode
        /// The member whose value it is, when it's an object's.
        public var member: JSONMember?

        /// Where it is in the text, in UTF-8 offsets: from the member's key to the end of its
        /// value (`"summary": { … }`), or the value alone (the root, an array's element).
        public var range: Range<Int> {
            member.map { $0.keyRange.lowerBound..<value.range.upperBound } ?? value.range
        }
    }

    private static func index(_ token: String) -> Int? {
        guard !token.isEmpty, token.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              token == "0" || !token.hasPrefix("0"), token.utf8.count < 19 else { return nil }
        return Int(token)
    }
}

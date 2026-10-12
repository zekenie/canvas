import Foundation

/// What a row is called, and the step a write to it is called, whichever surface writes it.
public enum FieldName {
    /// The field's own `title` when it is a non-empty string (trimmed of surrounding spaces, otherwise as written: a title is the author's), else
    /// its key split into words, lower case: `shippingAddress`, `shipping_address` and `shipping-address`
    /// all read `shipping address`. Split on `_`, `-`, spaces and a step from lower case (or a digit) to
    /// upper (`lineItems`); a run of capitals stays one word and ends before a capital that starts a
    /// lower-case one (`postalURL` is `postal url`, `HTTPServer` is `http server`); digits stay with the
    /// word before them (`address2`).
    public static func words(of field: ChainField) -> String {
        if let title = field.schema["title"]?.string, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let split = words(in: field.name)
        return split.isEmpty ? field.name : split.joined(separator: " ")
    }

    /// `Change Shipping Address`: "Change " and the name's words, each starting with a capital. The undo
    /// step of every write of that field.
    public static func stepName(of field: ChainField) -> String {
        let named = words(of: field).split(whereSeparator: \.isWhitespace).map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }
        return (["Change"] + named).joined(separator: " ")
    }

    private static func words(in key: String) -> [String] {
        let characters = Array(key)
        var words: [String] = [], current = ""
        func flush() {
            if !current.isEmpty { words.append(current.lowercased()) }
            current = ""
        }
        for (place, character) in characters.enumerated() {
            if character == "_" || character == "-" || character.isWhitespace {
                flush()
                continue
            }
            if character.isUppercase, place > 0, !current.isEmpty {
                let before = characters[place - 1]
                if before.isLowercase || before.isNumber {
                    flush()
                } else if before.isUppercase, place + 1 < characters.count, characters[place + 1].isLowercase {
                    flush()
                }
            }
            current.append(character)
        }
        flush()
        return words
    }
}

import Foundation

extension SchemaValue {
    /// The schema as the app writes one: two spaces to a level, an object's members in the order they hold,
    /// `{}` and `[]` when empty, and an array of scalars on one line (`"required": ["a", "b"]`), as the starter
    /// and the sync's writes are laid out. No line break at the end. What a field edit writes back.
    public var pretty: String {
        var out = ""
        write(into: &out, level: 0)
        return out
    }

    private var isScalar: Bool {
        switch self {
        case .object, .array: false
        default: true
        }
    }

    private func write(into out: inout String, level: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let bool): out += bool ? "true" : "false"
        case .number(let number): out += Self.literal(number)
        case .string(let string): out += JSONReader.literal(string)
        case .array(let elements):
            if elements.isEmpty {
                out += "[]"
            } else if elements.allSatisfy(\.isScalar) {
                out += "["
                for (place, element) in elements.enumerated() {
                    if place > 0 { out += ", " }
                    element.write(into: &out, level: level)
                }
                out += "]"
            } else {
                out += "[\n"
                for (place, element) in elements.enumerated() {
                    out += String(repeating: "  ", count: level + 1)
                    element.write(into: &out, level: level + 1)
                    out += place == elements.count - 1 ? "\n" : ",\n"
                }
                out += String(repeating: "  ", count: level) + "]"
            }
        case .object(let members):
            if members.isEmpty {
                out += "{}"
                return
            }
            out += "{\n"
            for (place, member) in members.enumerated() {
                out += String(repeating: "  ", count: level + 1) + JSONReader.literal(member.key) + ": "
                member.value.write(into: &out, level: level + 1)
                out += place == members.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: level) + "}"
        }
    }

    /// A number as it reads back: a whole one under 2^53 as an integer, else Swift's shortest decimal
    /// (an exponent is JSON too); `null` for one that is not finite, which JSON cannot say.
    private static func literal(_ number: Double) -> String {
        guard number.isFinite else { return "null" }
        if number == number.rounded(), abs(number) < 9_007_199_254_740_992 { return String(Int64(number)) }
        return "\(number)"
    }
}

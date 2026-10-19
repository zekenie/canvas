import Canvas
import CanvasRPC
import Foundation

/// The panel's box of JSON for a field no control suits (`Other`): a value as the box shows it, and what the
/// box's text is when it is done.
public enum FieldJSON {
    /// What the box's text says.
    public enum Reading: Equatable, Sendable {
        /// Nothing but space: the field is cleared.
        case empty
        case value(JSONValue)
        /// Not JSON: kept in the box, and nothing is written.
        case invalid
    }

    /// The value as the box shows it: indented, members in key order, slashes as they are.
    public static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// What `text` is as a value of the field: JSON of any kind (a bare number or string too), nothing at all, or neither.
    public static func reading(_ text: String) -> Reading {
        guard !text.allSatisfy(\.isWhitespace) else { return .empty }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return .invalid }
        return .value(value)
    }
}

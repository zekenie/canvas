import Canvas
import Foundation

/// The stored form's shared pieces: its schema definition (`mentions.text`, which every mention
/// text refers to, whatever its scope), each shipped migration step's escaper, frozen, and the
/// bounds check the registry runs. A later grammar gets a new escaper and new steps; a shipped
/// escaper never changes, since a shipped step never does (`PropsMigration`).
public enum MentionTextFormat {
    /// What the definition says the string's content is: an annotation, never checked.
    public static let mediaType = "text/x-canvas-mentions"

    /// The member a scoped use of the definition says what its scope admits under, beside the
    /// reference: `{"kinds": ["schema-card"]}`, or `{"scope": "Blockers"}`.
    public static let annotationKey = "x-canvas-mentions"

    /// The definition: a plain string, and how to read and write the mentions in it.
    static var definition: JSONObject {
        ["type": "string", "contentMediaType": .string(mediaType), "description": .string(grammarDescription)]
    }

    static let grammarDescription = "Text that may mention shapes. A mention is @[name](shape:ID): ID is the id of a shape in the "
        + "same file (a UUID, any case), and name is what it was called when the text was written; the app shows the shape's "
        + "current name, and this one only if the shape isn't there. In a name, \\] stands for ] and \\\\ for \\. In the text, "
        + "\\@[ is a literal @[, and any backslashes just before @[ are doubled: \\\\@[ is one backslash, then a mention. "
        + "@[](shape:ID) mentions a shape without a name. Anything else is text as written."

    /// The migration step for a member that was plain text and now may hold mentions: rewrites
    /// `props[member]` so it reads back as the text it was, however it was written (a look-alike
    /// `@[x](shape:…)` stays text). Frozen: this is the escaper of the grammar's first version,
    /// kept apart from the one that writes text today, so the step it's in never changes. Leaves
    /// a member that's missing, or not a string, as it is. Text with no `@[` in it is unchanged,
    /// byte for byte, so a board without look-alikes migrates to itself.
    public static func escapeLookalikesV1(in props: inout JSONObject, _ member: String) {
        guard case .string(let text)? = props[member] else { return }
        props[member] = .string(escapedV1(text))
    }

    /// Text as version 1 of the stored form writes it: each `@[` as `\@[`, and each run of
    /// backslashes just before an `@[` doubled. Don't change this: write a V2.
    static func escapedV1(_ text: String) -> String {
        let at: Unicode.Scalar = "@", open: Unicode.Scalar = "[", backslash: Unicode.Scalar = "\\"
        let c = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < c.count {
            if c[i] == backslash {
                var k = 0
                while i + k < c.count, c[i + k] == backslash { k += 1 }
                let a = i + k
                let beforeAt = a + 1 < c.count && c[a] == at && c[a + 1] == open
                out.append(contentsOf: repeatElement(backslash, count: beforeAt ? 2 * k : k))
                i = a
                continue
            }
            if c[i] == at, i + 1 < c.count, c[i + 1] == open {
                out.append(backslash)
                out.append(at)
                i += 1
                continue
            }
            out.append(c[i])
            i += 1
        }
        return String(out)
    }

    // MARK: Bounds

    /// The keywords no mention text takes: JSON Schema counts the stored string, where each
    /// mention is some fifty characters nobody sees, so a length bound would warn about what
    /// isn't there. A kind that wants a bound on what people read writes a rule over `plainText`.
    static let refusedKeywords = ["maxLength", "minLength", "pattern"]

    /// Refuses a plugin list in which a kind's schema (its own properties and those it opts into)
    /// puts a length or a pattern beside a reference to mention text, anywhere in it: in a
    /// property, an array's items, a struct's definition. Mentions' points run it
    /// (`ShapeMentions`, and the placements' point), so it runs whenever a list has a
    /// mentionable kind, or one that draws mention text.
    @MainActor
    public static func checkBounds(in registry: Registry) throws {
        let reference = ScopedMentionText<AnyMentionable>.referenceTarget
        for kind in registry.kinds {
            guard let schema = registry.schema(for: kind) else { continue }
            var found: (path: String, keyword: String)?
            walk(.object(schema.json), path: "", reference: reference) { path, keyword in
                if found == nil { found = (path, keyword) }
            }
            if let found {
                throw MentionBoundsError(kind: kind, path: found.path, keyword: found.keyword)
            }
        }
    }

    /// Calls `found` with each place under `value` that refers to mention text with a refused
    /// keyword beside the reference, and the keyword.
    private static func walk(_ value: JSONValue, path: String, reference: String, _ found: (String, String) -> Void) {
        switch value {
        case .object(let object):
            if object["$ref"]?.stringValue == reference, let keyword = refusedKeywords.first(where: { object[$0] != nil }) {
                found(path.isEmpty ? "/" : path, keyword)
            }
            for (key, member) in object.sorted(by: { $0.key < $1.key }) {
                walk(member, path: path + "/" + key, reference: reference, found)
            }
        case .array(let array):
            for (index, element) in array.enumerated() { walk(element, path: path + "/\(index)", reference: reference, found) }
        default:
            break
        }
    }
}

/// A mention text given a length or a pattern: how the registry reports it, for the point whose
/// check found it.
struct MentionBoundsError: Error, CustomStringConvertible {
    let kind: ShapeKind
    let path: String
    let keyword: String

    var description: String {
        "\(kind)'s schema gives mention text \(keyword) at \(path); JSON Schema would count its stored mentions, "
            + "so bound what it reads in a validation rule over plainText instead"
    }
}

extension ScopedMentionText {
    /// Where every mention text's schema refers to: its shared definition.
    static var referenceTarget: String {
        var definitions = SchemaDefinitions()
        return schema(in: &definitions)["$ref"]?.stringValue ?? ""
    }
}

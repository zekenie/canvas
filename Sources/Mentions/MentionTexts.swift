import Canvas
import Draw

/// Draw's mention text, in Mentions: in any text a script writes whose schema says it's mention
/// text (`MentionTextFormat.mediaType`: a note's `text:`, a schema card's `prompt:`, wherever one is
/// inside a value), `@[Title]` mentions the shape called Title, and the shape keeps the stored form
/// with its id (`MentionTextFormat.resolvingNames`), so an agent never handles an id. Which shape a
/// title names is draw's own lookup (`DrawTextContext.shape`: a shape the script draws, or the board
/// it draws on, or the window's, or elsewhere in the file), among the shapes the text may mention:
/// those whose kind can be mentioned and its scope admits (`registry.mentionAdmission`, read from
/// what the schema says beside the text's reference, `x-canvas-mentions`), so a schema card's
/// `prompt:` names the card called Address, not a note called that. A whole mention an agent writes
/// (`@[label](shape:ID)`, from a query's rows) is kept as written, as it always was.
public struct MentionTextsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "mention-texts" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.drawTextFormat(mediaType: MentionTextFormat.mediaType, describes: "@[Title] mentions") { text, context throws(DrawError) in
            let scope = context.schema[MentionTextFormat.annotationKey]?.objectValue
            return try MentionTextFormat.resolvingNames(in: text) { name throws(DrawError) in
                guard !name.allSatisfy(\.isWhitespace) else {
                    throw Self.explained(DrawError("@[] is a mention with no title in it", reason: "invalid_value",
                                                   hint: "write the title of the shape between the brackets, as @[Owner]"), when: true)
                }
                do throws(DrawError) {
                    let shape = try context.shape(called: name) { record in
                        Self.clause(context.registry.mentionAdmission(of: record, scope: scope))
                    }
                    return (shape.id, shape.title)
                } catch {
                    throw Self.explained(error, when: error.reason == Self.noShape)
                }
            }
        }
    }

    /// Why a text can't mention a shape, as the clause that follows its kind (`"Ingest" is a
    /// sticky-note, which can't be mentioned`); nil if it can.
    private static func clause(_ admission: MentionAdmission) -> String? {
        switch admission {
        case .admitted:
            nil
        case .notMentionable:
            "which can't be mentioned"
        case .outsideScope(let kinds):
            "which this text can't mention: " + (kinds.isEmpty ? "no kind of shape can be mentioned here"
                                                 : "it mentions only \(kinds.map(\.rawValue).joined(separator: " or ")) shapes")
        }
    }

    /// The reason of a title no shape has.
    private static let noShape = "unknown_title"

    /// A refusal, with how to write `@[` as text added to its hint when `explaining` (the text's
    /// `\@[`, which a script's string spells `\\@[`). A title no shape has, and a blank one, are the
    /// refusals of a text that may have meant the characters; one that names shapes (two have the
    /// title) or a shape that can't be mentioned was meant as a mention, so its hint says only how to
    /// mend it.
    private static func explained(_ error: DrawError, when explaining: Bool) -> DrawError {
        guard explaining else { return DrawError(error.message, reason: error.reason, hint: error.hint) }
        let literal = #"to write @[ as text, write \\@["#
        let hint = error.hint.map { $0 + ($0.hasSuffix("?") ? " " : "; ") + literal } ?? literal
        return DrawError(error.message, reason: error.reason, hint: hint)
    }
}

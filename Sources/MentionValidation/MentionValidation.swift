import Canvas
import Mentions
import Validation

/// A bridge between two horizontals: warnings about the mentions a shape's text holds, a warning
/// for each problem Mentions finds (`registry.mentionProblems(of:lookup:)`), about the property the
/// text is in: a mention of a shape that can't be mentioned (“Arrow” can’t be mentioned.), one
/// outside its text's scope (“Groceries” can’t be mentioned here.), and text that looks like a
/// mention but isn't one (“@[x](shape: 7C1E…” isn’t a mention.). Never for a mention of a shape
/// that isn't there: its dashed pill says so. Warnings, never errors: a mention that's there
/// stays, as a scope never refuses one.
///
/// It checks the board shown, as Validation does: its targets are looked up there
/// (`context.shape`), so a mention of a shape on another board is checked no more than a missing
/// one, and a change to a target checks its mentioners again. Where shapes are is nothing it
/// reads, so it ignores moves: a drag of a shape mentioned 100 times, or of the whole board, runs
/// it for none. Mentions has never heard of validation, nor Validation of mentions; this module's
/// imports are the only edge between them.
public struct MentionValidationPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "mention-validation" }

    #if DEBUG
    /// How many shapes of kinds that can hold names the rule has checked in this process, debug
    /// builds only: tests hold a move of a target, or of its mentioner, to checking none.
    @MainActor public private(set) static var textsChecked = 0
    #endif

    public func register(into registrar: inout PluginRegistrar) {
        registrar.validateEveryShape(ignoringMoves: true) { shape, context in
            // A shape of a kind that can't hold names has no mention text: one set lookup.
            guard context.registry.namingKinds.contains(shape.kind) else { return [] }
            #if DEBUG
            Self.textsChecked += 1
            #endif
            return context.registry.mentionProblems(of: shape, lookup: context.shape).map { .warning($0.message, field: $0.property) }
        }
    }
}

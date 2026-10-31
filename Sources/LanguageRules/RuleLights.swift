import AppKit
import Canvas
import CanvasRPC
import Mentions
import Palette
import Selection
import Titles
import Types
import Validation

/// What the panel does on the canvas for rules: lights the shapes a highlighted count or line of Shown names (one light,
/// `IssueWalkStyle.light`, the issue walk's too, the core's tinted outlines: a shape on another board is drawn as the shape
/// on the board shown that holds it), goes to shapes, and says how a shape reads in a list. A view lights by a name of its
/// own and lets go only of what it lit.
@MainActor
public final class RuleLights {
    private weak var editor: CanvasEditor?
    /// What is lit, and by whom.
    private var lit: (by: String, shapes: [ShapeID])?
    /// What the canvas outlines for it now.
    private(set) var outlines = Outlines()

    init(editor: CanvasEditor) { self.editor = editor }

    /// Lights `shapes` for `owner`; nil lets go of what `owner` lit.
    public func light(_ shapes: [ShapeID]?, by owner: String) {
        if let shapes {
            lit = (owner, shapes)
        } else if lit?.by == owner {
            lit = nil
        } else {
            return
        }
        place()
    }

    /// The shapes lit now, by whoever lit them.
    public var litShapes: [ShapeID] { lit?.shapes ?? [] }

    /// Selects `ids` and shows them, on the next turn (the click's view goes with the panel), one step back.
    public func go(to ids: [ShapeID]) {
        guard let editor, !ids.isEmpty else { return }
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in editor?.goTo(ids) }
    }

    /// Begins `key`'s walk (Validation's issue walk, narrowed to the rule) at `entry`, on the next turn like `go(to:)`: the walk
    /// chooses the Issues tab, which takes the Rules tab's button that was clicked with it. Nothing for a rule that is gone.
    /// Without the walk (a list that has no `IssueWalkPlugin`) it goes to `fallback`, the shapes themselves.
    public func walk(_ key: RuleKey, at entry: IssueEntry, orGoTo fallback: [ShapeID] = []) {
        guard let editor else { return }
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in
            guard let editor else { return }
            guard let walk = editor.issueWalk else { return editor.goTo(fallback) }
            if let scope = editor.registry.issueScope(for: key.source, in: editor) { walk.begin(scope, at: entry) }
        }
    }

    /// A type's chip, as the panel draws it: its color's ink on a wash of it.
    func look(of type: ShapeID) -> (ink: NSColor, fill: NSColor)? {
        guard let look = editor?.types?.look(of: type) else { return nil }
        return (NSColor(look.swatch.ink), NSColor(look.swatch.wash))
    }

    /// A line of Shown: a shape by its title (else its kind's name), its kind's symbol, its types; a type with its words
    /// under it; a group that is no shape ("the board's top level") by what it says.
    func line(_ group: RuleShownGroup, _ row: Int, isType: Bool) -> ShownRow {
        guard let editor, group.shapes.indices.contains(row) else {
            return ShownRow(symbol: "square.dashed", name: group.place ?? "", detail: nil, caption: nil)
        }
        let id = group.shapes[row]
        guard let record = editor.withoutObservingDocument({ editor.shape(inFile: id) }) else {
            return ShownRow(symbol: "questionmark.square.dashed", name: RulesStyle.gone, detail: nil, caption: nil)
        }
        let label = editor.registry.label(of: record.kind)
        let title = TitleProperty.folded(record[TitleProperty.self])
        if isType {
            return ShownRow(symbol: RulesStyle.typeSymbol, name: title ?? RulesStyle.untitled, detail: nil, caption: words(of: record))
        }
        let types = (record[IsAProperty.self] ?? []).compactMap { editor.types?.name(of: $0.shape) }
        return ShownRow(symbol: label.systemImage ?? "square", name: title ?? label.name,
                        detail: types.isEmpty ? nil : types.joined(separator: ", "), caption: nil)
    }

    /// A shape's words on one line, mentions by their names: a type's, under it.
    private func words(of record: AnyShapeRecord) -> String? {
        guard let editor, let key = RuleChecks.readings(of: editor.registry)[record.kind]?.words,
              let stored = record.propertiesJSON?[key]?.stringValue else { return nil }
        let labels = editor.mentions?.labels ?? MentionLabels()
        let text = MentionText.plainText(stored: stored, label: labels.label(of:))
            .split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return text?.isEmpty == false ? text : nil
    }

    /// Where the lit shapes are drawn: each on the board shown as itself, else as the shape there that holds it, else
    /// not at all. Asks the canvas to draw only when that changed.
    private func place() {
        guard let editor else { return }
        var next = Outlines()
        if let shapes = lit?.shapes, !shapes.isEmpty {
            let file = editor.withoutObservingDocument { editor.file }, board = editor.board
            var drawn: [ShapeID] = [], seen: Set<ShapeID> = []
            for id in shapes {
                guard let on = file.board(containing: id) else { continue }
                guard let shape = on == board ? id : file.shape(on: board, holding: id), seen.insert(shape).inserted else { continue }
                drawn.append(shape)
            }
            if !drawn.isEmpty { next = Outlines(tinted: [TintedOutlines(color: IssueWalkStyle.light, shapes: drawn)]) }
        }
        guard next != outlines else { return }
        outlines = next
        editor.setNeedsDisplay()
    }
}

extension RuleLights: EditorService {
    public func documentDidChange(_ changes: ChangeSet, in _: CanvasEditor) {
        if lit != nil, !changes.removed.isEmpty || !changes.elsewhere.isEmpty || changes.replacedDocument { place() }
    }

    public func boardDidChange(_: BoardChange, in _: CanvasEditor) {
        if lit != nil { place() }
    }
}

extension CanvasEditor {
    /// What rules light on the canvas for the panel: nil without RuleDetailsPlugin.
    public var ruleLights: RuleLights? { service(RuleLights.self) }
}

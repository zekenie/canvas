import Canvas
import CoreGraphics
import Keyboard
import Selection
import Titles

// Rows written as lines, any kind's: a horizontal a kind opts into with `lineRows(_:)`, whose shapes' rows are written a
// line each (a table's columns, an enum's values). Three parts: Field (the line field and the grammar a role's lines are
// read and printed in), Folds (the kinds written as lines, and the lines a shape shows: folded to its marked rows, a header
// closed, Find's hits peeking) and Session (the stops, keys and commits of a shape being edited, which its kind's editing
// view is). The module knows no table: a kind gives its model (`LineModel`) and its grammars.

extension ShapeRegistrar {
    /// This kind's rows are written as lines, as `model` says (`LineModel`): its editing view is
    /// `LineRowsView.make(_:context:model:title:)`, LineRows' faces reach its shapes (`.lineRows`), and it folds (⌃⌘↑) to
    /// the rows the model marks. Its layout reads `LineRowsLayout`'s inputs.
    ///
    ///     table.lineRows(TableLines())
    public mutating func lineRows<Model: LineModel>(_ model: Model) where Model.Props == Definition.Props {
        contribute(LineRowsContribution(
            noun: model.noun,
            rows: { record in
                record.typed(as: Model.Props.self).map { shape in
                    model.rows(of: shape.props).map { FoldRow(id: model.id(of: $0), isHeader: model.isHeader($0)) }
                }
            },
            marked: { record, reading in record.typed(as: Model.Props.self).map { model.marked($0, in: reading) } ?? [] },
            lineRect: { line, frame in model.lineRect(line, in: frame) }), to: LineRowsKinds.self)
    }
}

extension CanvasCommand {
    /// View › Fold Rows (⌃⌘↑): the selection's shapes written as lines, or every one on the board shown with nothing
    /// selected, folded to the rows their kinds mark.
    public static let foldRows: CanvasCommand = "foldRows"
    /// View › Unfold Rows (⌃⌘↓): every row shown again.
    public static let unfoldRows: CanvasCommand = "unfoldRows"
}

/// View's section of Fold Rows and Unfold Rows.
public enum RowFoldsSection {}
extension RowFoldsSection: MenuBarSection {
    public static var menu: MenuBarMenu { "View" }
}

/// Rows written as lines: the sessions' service (the light an offer puts on the board, Tab's hops to the next shape of a
/// kind, the layout inputs taken back as editing ends) and the light's outline; folds (`RowFolds`), the lines a folded
/// shape shows provided to its layout, ⌃⌘↑ and ⌃⌘↓, and the "+N ›" line a click, Return or Space opens. The keys a row has
/// are listed by the kind that opts in (the Keyboard Shortcuts window leaves out those of a kit that's off).
public struct LineRowsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .lineRows }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { LineRowsService(editor: $0) }
        registrar.service { RowFolds(editor: $0) }
        registrar.outlines { editor in editor.service(LineRowsService.self)?.outlines() ?? Outlines() }
        // What a folded shape shows, asked as it's laid out, and how wide one is while a line typed in it is wider.
        registrar.layoutInput(LineRowsLayout.shown) { record, reading in reading.service(RowFolds.self)?.shown(of: record, in: reading) }
        registrar.layoutInput(LineRowsLayout.width) { record, reading in reading.service(LineRowsService.self)?.width(of: record.id) }
        // ⌃⌘↑ ⌃⌘↓: a view, no step; never while a shape is edited (it shows every row then), so the text keeps the keys.
        registrar.command(.foldRows, title: LineFoldStyle.foldTitle, in: RowFoldsSection.self,
                          shortcut: KeyChord(KeyChord.upArrow.key, [.control, .command]), runs: .whenIdle,
                          isEnabled: { subject in Folding.targets(subject).contains { subject.editor.rowFolds?.fold(of: $0)?.toMarked != true } }) { subject in
            Folding.fold(Folding.targets(subject), in: subject.editor)
        }
        registrar.command(.unfoldRows, title: LineFoldStyle.unfoldTitle, in: RowFoldsSection.self,
                          shortcut: KeyChord(KeyChord.downArrow.key, [.control, .command]), runs: .whenIdle,
                          isEnabled: { subject in Folding.targets(subject).contains { subject.editor.rowFolds?.isFolded($0) == true } }) { subject in
            Folding.unfold(Folding.targets(subject), in: subject.editor)
        }
        // The "+N ›" line and a closed header: a click opens it; reached with ⌥Tab, Return or Space opens it.
        registrar.shapeFaces(at: { editor, record, point in Folding.line(at: point, on: record, in: editor) },
                             click: { line, editor in Folding.open(line, in: editor) })
        registrar.forShapes(adopting: .lineRows) { kinds in
            kinds.shapeParts(named: "FoldLines") { editor, record in Folding.parts(of: record, in: editor) }
        }
    }
}

/// What the fold commands and the "+N ›" line do, over the editor.
@MainActor
enum Folding {
    /// A line a fold drew that a click opens: the "+N ›" line, or a closed header.
    struct Line: Hashable, Sendable {
        let shape: ShapeID
        /// The header, nil for "+N ›".
        let header: PartID?
    }

    /// What ⌃⌘↑ and ⌃⌘↓ act on: the selection's shapes written as lines, or, with nothing selected, every one on the board
    /// shown.
    static func targets(_ subject: CommandSubject) -> [ShapeID] {
        let editor = subject.editor, registry = editor.registry
        if subject.shapes.isEmpty {
            return editor.document.shapes.compactMap { registry.lineRows(of: $0.kind) == nil ? nil : $0.id }
        }
        return subject.shapes.filter { id in editor.document[id].map { registry.lineRows(of: $0.kind) != nil } ?? false }
    }

    static func fold(_ ids: [ShapeID], in editor: CanvasEditor) {
        guard let folds = editor.rowFolds, !ids.isEmpty else { return }
        folds.fold(ids)
        if ids.count == 1, let id = ids.first, let record = editor.document[id], let kind = editor.registry.lineRows(of: record.kind) {
            let total = kind.rows(record)?.count ?? 0
            let shown = editor.shapeContext.layoutInput(LineRowsLayout.shown, of: record).map(\.shownRows) ?? total
            editor.announce(LineFoldStyle.folded(editor.registry.title(of: record), shown: shown, of: total, noun: kind.noun))
        } else {
            editor.announce(LineFoldStyle.foldedMany(ids.count))
        }
    }

    static func unfold(_ ids: [ShapeID], in editor: CanvasEditor) {
        guard let folds = editor.rowFolds else { return }
        folds.unfold(ids)
        editor.announce(LineFoldStyle.unfolded)
    }

    /// The fold's line of `record` under `point` (world units): its "+N ›" line or a closed header.
    static func line(at point: CGPoint, on record: AnyShapeRecord, in editor: CanvasEditor) -> Line? {
        guard editor.rowFolds?.isFolded(record.id) == true, let kind = editor.registry.lineRows(of: record.kind) else { return nil }
        let shapes = editor.shapeContext
        guard let shown = shapes.layoutInput(LineRowsLayout.shown, of: record), let frame = shapes.frame(of: record) else { return nil }
        for (index, line) in shown.lines.enumerated() where kind.lineRect(index, frame).contains(point) {
            switch line {
            case .more: return Line(shape: record.id, header: nil)
            case .header(let row, _): return Line(shape: record.id, header: shown.ids[row])
            case .row: return nil
            }
        }
        return nil
    }

    static func open(_ line: Line, in editor: CanvasEditor) {
        guard let folds = editor.rowFolds else { return }
        if let header = line.header {
            folds.setClosed(false, header: header, of: line.shape)
        } else {
            folds.openMore(of: line.shape)
        }
        editor.announce(LineFoldStyle.unfolded)
    }

    /// A folded shape's lines a click opens, as parts the keys reach (⌥Tab, then Return or Space): its closed headers and
    /// its "+N ›" line, in reading order.
    static func parts(of record: AnyShapeRecord, in editor: CanvasEditor) -> [ShapePart] {
        guard editor.rowFolds?.isFolded(record.id) == true, let kind = editor.registry.lineRows(of: record.kind) else { return [] }
        let shapes = editor.shapeContext
        guard let shown = shapes.layoutInput(LineRowsLayout.shown, of: record), let frame = shapes.frame(of: record) else { return [] }
        var parts: [ShapePart] = []
        for (index, line) in shown.lines.enumerated() {
            let rect = kind.lineRect(index, frame)
            switch line {
            case .more(let count):
                let opened = Line(shape: record.id, header: nil)
                parts.append(ShapePart(id: opened, title: LineFoldStyle.more(count, noun: kind.noun), rect: rect) { open(opened, in: $0) })
            case .header(let row, let hiding):
                let opened = Line(shape: record.id, header: shown.ids[row])
                let name = editor.accessibleName(of: PartAddress(record.id, part: shown.ids[row])) ?? ""
                parts.append(ShapePart(id: opened, title: LineFoldStyle.header(name, hiding: hiding, noun: kind.noun), rect: rect) { open(opened, in: $0) })
            case .row:
                continue
            }
        }
        return parts
    }
}

/// What folds say: their items' titles and what VoiceOver hears.
@MainActor
enum LineFoldStyle {
    static let foldTitle = "Fold Rows"
    static let unfoldTitle = "Unfold Rows"
    static let unfolded = "Unfolded"

    /// "products folded, 3 of 40 columns shown".
    static func folded(_ name: String?, shown: Int, of total: Int, noun: LineNoun) -> String {
        let what = "\(shown) of \(noun.counted(total)) shown"
        return name.map { "\($0) folded, \(what)" } ?? "Folded, \(what)"
    }

    /// "12 shapes folded".
    static func foldedMany(_ count: Int) -> String { "\(count) shapes folded" }

    /// The "+N ›" line, as VoiceOver reads it: "37 more columns".
    static func more(_ count: Int, noun: LineNoun) -> String { "\(count) more \(count == 1 ? noun.singular : noun.plural)" }

    /// A closed header: "/orders, 4 endpoints hidden".
    static func header(_ name: String, hiding: Int, noun: LineNoun) -> String { "\(name), \(noun.counted(hiding)) hidden" }
}

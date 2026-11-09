import Canvas
import Connections
import ContextMenus
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
            lineRect: { line, frame in model.lineRect(line, in: frame) },
            card: { editor, record, part in
                guard let shape = record.typed(as: Model.Props.self),
                      let row = model.rows(of: shape.props).first(where: { model.id(of: $0) == part }) else { return nil }
                let context = LineContext(editor: editor, shape: record.id, row: part)
                guard let card = model.card(of: row, in: context) else { return nil }
                return LineRowCard(name: card.header.name, lines: card.lines.map { LineRowCard.Line(label: $0.label, value: $0.printed(row, in: context)) })
            },
            peeks: { record, part, ranges in
                guard let shape = record.typed(as: Model.Props.self) else { return true }
                let rows = model.rows(of: shape.props)
                guard let index = rows.firstIndex(where: { model.id(of: $0) == part }) else { return true }
                return model.peeks(rows[index], at: index, of: rows, hitAt: ranges)
            },
            opener: { record, index, line in
                // The line up to where the header's words start: its chevron, drawn in its indent.
                let rows = record.typed(as: Model.Props.self).map { model.rows(of: $0.props) } ?? []
                let start = model.style.textInset + (rows.indices.contains(index) ? model.indent(at: index, of: rows, isNew: false) : 0)
                return CGRect(x: line.minX, y: line.minY, width: min(line.width, start), height: line.height)
            }), to: LineRowsKinds.self)
        // Its rows selected on the canvas (Selection's items) and moved as wholes.
        lineRowItems(model)
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
        registrar.service { editor in
            let service = LineRowsService(editor: editor)
            // A row's card (⌘↓): the Card part's, shown for the session.
            service.cards = LineCards(editor: editor)
            return service
        }
        registrar.service { RowFolds(editor: $0) }
        // How the connections at shapes written as lines are drawn among those sharing their path (after the folds, which say
        // where each row's connections end): bundles, slots, fans and entries, Connections' `ConnectionBundle`.
        registrar.service { RowBundles(editor: $0) }
        registrar.service { RowCuts(editor: $0) }
        registrar.layoutInput(ConnectionBundle.input) { record, reading in reading.service(RowBundles.self)?.answer(for: record, in: reading) }
        // A press on a bundle's line selects every connection it draws for.
        registrar.selectionUnits { editor, id in editor.service(RowBundles.self)?.unit(of: id) }
        registrar.outlines { editor in editor.service(LineRowsService.self)?.outlines() ?? Outlines() }
        // What a folded shape shows, asked as it's laid out, and how wide one is while a line typed in it is wider.
        registrar.layoutInput(LineRowsLayout.shown) { record, reading in reading.service(RowFolds.self)?.shown(of: record, in: reading) }
        registrar.layoutInput(LineRowsLayout.width) { record, reading in reading.isResting ? nil : reading.service(LineRowsService.self)?.width(of: record.id) }
        // ⌃⌘↑ ⌃⌘↓: a view, no step; never while a shape is edited (it shows every row then), so the text keeps the keys.
        registrar.command(.foldRows, title: LineFoldStyle.foldTitle, in: RowFoldsSection.self,
                          shortcut: KeyChord(KeyChord.upArrow.key, [.control, .command]), runs: .whenIdle,
                          isEnabled: { subject in Folding.targets(subject).contains { subject.editor.rowFolds?.isFoldedWhole($0) == false } }) { subject in
            Folding.fold(Folding.targets(subject), in: subject.editor)
        }
        registrar.command(.unfoldRows, title: LineFoldStyle.unfoldTitle, in: RowFoldsSection.self,
                          shortcut: KeyChord(KeyChord.downArrow.key, [.control, .command]), runs: .whenIdle,
                          isEnabled: { subject in Folding.targets(subject).contains { subject.editor.rowFolds?.isFolded($0) == true } }) { subject in
            Folding.unfold(Folding.targets(subject), in: subject.editor)
        }
        // The "+N ›" line and a closed header's opener (its chevron): a click opens it; reached with ⌥Tab, Return or Space
        // opens it. A click on a closed header's words selects it as an item, which → and Space open.
        registrar.shapeFaces(at: { editor, record, point in Folding.line(at: point, on: record, in: editor) },
                             click: { line, editor in Folding.open(line, in: editor) })
        registrar.forShapes(adopting: .lineRows) { kinds in
            kinds.shapeParts(named: "FoldLines") { editor, record in Folding.parts(of: record, in: editor) }
        }
        // With rows selected on the canvas, the selection's menu takes them out into a shape of their own, one step.
        registrar.contextMenuForCanvas {
            MenuItems(in: RowsMenuGroup.self, id: "take-out-rows") { subject in
                if let item = RowItems.takeOutItem(subject) { item }
            }
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
        /// The fold the line was drawn by (`RowFolds.epoch`): a line the keys had focus on and opened is not the next one.
        let epoch: Int
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
        // VoiceOver hears what changed: the shapes that were not folded and now hide a row.
        let hiding = folds.fold(ids).compactMap { id -> (record: AnyShapeRecord, shown: RowsShown)? in
            guard let record = editor.document[id], let shown = editor.shapeContext.layoutInput(LineRowsLayout.shown, of: record) else { return nil }
            return (record, shown)
        }
        if hiding.count == 1, let (record, shown) = hiding.first, let kind = editor.registry.lineRows(of: record.kind) {
            let rows = kind.rows(record) ?? []
            let closed = shown.lines.filter { if case .header = $0 { true } else { false } }.count
            if closed > 0 {
                // An API's groups: "orders API folded, 7 groups closed".
                editor.announce(LineFoldStyle.foldedGroups(editor.registry.title(of: record), closed: closed))
            } else {
                let total = rows.count
                editor.announce(LineFoldStyle.folded(editor.registry.title(of: record), shown: shown.shownRows, of: total, noun: kind.noun))
            }
        } else if hiding.isEmpty {
            editor.announce(LineFoldStyle.nothingToFold)
        } else {
            editor.announce(LineFoldStyle.foldedMany(hiding.count))
        }
    }

    static func unfold(_ ids: [ShapeID], in editor: CanvasEditor) {
        guard let folds = editor.rowFolds else { return }
        folds.unfold(ids)
        editor.announce(LineFoldStyle.unfolded)
    }

    /// The fold's line of `record` under `point` (world units): its "+N ›" line or a closed header.
    static func line(at point: CGPoint, on record: AnyShapeRecord, in editor: CanvasEditor) -> Line? {
        guard let folds = editor.rowFolds, folds.isFolded(record.id), let kind = editor.registry.lineRows(of: record.kind) else { return nil }
        let epoch = folds.epoch, shapes = editor.shapeContext
        guard let shown = shapes.layoutInput(LineRowsLayout.shown, of: record), let frame = shapes.frame(of: record) else { return nil }
        for (index, line) in shown.lines.enumerated() where kind.lineRect(index, frame).contains(point) {
            switch line {
            case .more: return Line(shape: record.id, header: nil, epoch: epoch)
            case .header(let row, _):
                // Only its opener (the chevron) opens it: a click on its words is the item ladder's, selecting the header.
                guard kind.opener(record, row, kind.lineRect(index, frame)).contains(point) else { return nil }
                return Line(shape: record.id, header: shown.ids[row], epoch: epoch)
            case .row: return nil
            }
        }
        return nil
    }

    static func open(_ line: Line, in editor: CanvasEditor) {
        guard let folds = editor.rowFolds else { return }
        let said = toggled(line.header, of: line.shape, opening: true, in: editor)
        if let header = line.header {
            folds.setClosed(false, header: header, of: line.shape)
        } else {
            folds.openMore(of: line.shape)
        }
        editor.announce(said)
    }

    /// What VoiceOver hears as a header or the "+N ›" line (`header` nil) of `shape` opens or closes, worked out before it does:
    /// "/refunds opened, 6 endpoints", "/refunds closed", "37 more columns shown".
    static func toggled(_ header: PartID?, of shape: ShapeID, opening: Bool, in editor: CanvasEditor) -> String {
        guard let record = editor.document[shape], let kind = editor.registry.lineRows(of: record.kind) else {
            return opening ? LineFoldStyle.unfolded : LineFoldStyle.closed
        }
        let shown = editor.shapeContext.layoutInput(LineRowsLayout.shown, of: record)
        guard let header else {
            return LineFoldStyle.moreShown(shown?.more?.count ?? 0, noun: kind.noun)
        }
        let name = editor.registry.parts(of: record)?.first { $0.id == header }?.name ?? ""
        guard opening else { return LineFoldStyle.headerClosed(name) }
        // How many it hides now, closed; an open one's members (under it until the next header) where it isn't.
        let rows = kind.rows(record) ?? []
        var count = 0
        if let shown, let line = shown.line(standingFor: header), case .header(_, let hiding) = shown.lines[line] {
            count = hiding
        } else if let at = rows.firstIndex(where: { $0.id == header }) {
            count = rows[(at + 1)...].prefix { !$0.isHeader }.count
        }
        return LineFoldStyle.headerOpened(name, members: count, noun: kind.noun)
    }

    /// A folded shape's lines a click opens, as parts the keys reach (⌥Tab, then Return or Space): its closed headers and
    /// its "+N ›" line, in reading order.
    static func parts(of record: AnyShapeRecord, in editor: CanvasEditor) -> [ShapePart] {
        guard let folds = editor.rowFolds, folds.isFolded(record.id), let kind = editor.registry.lineRows(of: record.kind) else { return [] }
        let epoch = folds.epoch, shapes = editor.shapeContext
        guard let shown = shapes.layoutInput(LineRowsLayout.shown, of: record), let frame = shapes.frame(of: record) else { return [] }
        var parts: [ShapePart] = []
        for (index, line) in shown.lines.enumerated() {
            let rect = kind.lineRect(index, frame)
            switch line {
            case .more(let count):
                let opened = Line(shape: record.id, header: nil, epoch: epoch)
                parts.append(ShapePart(id: opened, title: LineFoldStyle.more(count, noun: kind.noun), rect: rect) { open(opened, in: $0) })
            case .header(let row, let hiding):
                let opened = Line(shape: record.id, header: shown.ids[row], epoch: epoch)
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
public enum LineFoldStyle {
    static let foldTitle = "Fold Rows"
    static let unfoldTitle = "Unfold Rows"
    static let unfolded = "Unfolded"
    /// A header closed with ←.
    static let closed = "Closed"
    /// Folded, and every row is one its kind keeps (or it was folded already).
    static let nothingToFold = "Nothing to fold"

    /// "products folded, 3 of 40 columns shown".
    static func folded(_ name: String?, shown: Int, of total: Int, noun: LineNoun) -> String {
        let what = "\(shown) of \(noun.counted(total)) shown"
        return name.map { "\($0) folded, \(what)" } ?? "Folded, \(what)"
    }

    /// "orders API folded, 7 groups closed".
    static func foldedGroups(_ name: String?, closed: Int) -> String {
        let what = "\(LineNoun("group").counted(closed)) closed"
        return name.map { "\($0) folded, \(what)" } ?? "Folded, \(what)"
    }

    /// "12 shapes folded".
    static func foldedMany(_ count: Int) -> String { "\(count) shapes folded" }

    /// The "+N ›" line, as VoiceOver reads it: "37 more columns".
    static func more(_ count: Int, noun: LineNoun) -> String { "\(count) more \(count == 1 ? noun.singular : noun.plural)" }

    /// A closed header: "/orders, 4 endpoints hidden".
    static func header(_ name: String, hiding: Int, noun: LineNoun) -> String { "\(name), \(noun.counted(hiding)) hidden" }

    /// A header opened (→, Space, its chevron): "/refunds opened, 6 endpoints".
    static func headerOpened(_ name: String, members: Int, noun: LineNoun) -> String {
        name.isEmpty ? "Opened, \(noun.counted(members))" : "\(name) opened, \(noun.counted(members))"
    }

    /// A header closed (←, Space): "/refunds closed".
    static func headerClosed(_ name: String) -> String { name.isEmpty ? closed : "\(name) closed" }

    /// The "+N ›" line opened: "37 more columns shown".
    static func moreShown(_ count: Int, noun: LineNoun) -> String { "\(more(count, noun: noun)) shown" }

    /// A closed item's title, as VoiceOver reads it among the shape's rows: "/orders, path prefix, 4 endpoints, closed" where the
    /// kind's words count its rows already (as a whole count, never "4 endpoints" within "14 endpoints"), else "fruit/, closed,
    /// 2 entries". Where the kind's count is of more than the fold hides (Find shows some rows of a closed group), the two are
    /// said as one count: "/orders, path prefix, closed, 10 of 14 endpoints hidden".
    public static func closedItem(_ title: String, hiding: Int, noun: LineNoun) -> String {
        let counted = noun.counted(hiding)
        if title == counted || title.hasSuffix(", " + counted) || title.contains(", " + counted + ",") { return "\(title), closed" }
        // The last part of the title, if it is a count of this kind's rows: "14 rows".
        let pieces = title.split(separator: ",", omittingEmptySubsequences: false)
        if pieces.count > 1, let tail = pieces.last?.dropFirst() {
            let parts = tail.split(separator: " ", maxSplits: 1)
            if parts.count == 2, let members = Int(parts[0]), String(parts[1]) == noun.singular || String(parts[1]) == noun.plural {
                return "\(pieces.dropLast().joined(separator: ",")), closed, \(hiding) of \(noun.counted(members)) hidden"
            }
        }
        return "\(title), closed, \(counted)"
    }
}

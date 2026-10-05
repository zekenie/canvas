import AppKit
import Canvas
import DetailPanel
import Selection
import SwiftUI
import Titles
import Topology

/// What stands for a shape, in its panel: a tab of the shape's state that comes and goes, beside
/// Mentioned In (order 300), shown on every shape that can be public while anything stands for it,
/// whatever it is that stands in (Publishing knows no such kind, only Topology's stand-ins). A
/// public shape something stands for is held public: this says what. The panel switches to it when
/// a click on the chip, or `/private`, is refused.
public enum ReferencedInTab {}

extension ReferencedInTab: DetailTab {
    public static var title: String { PublicStyle.referencedIn }
    public static var order: Int { 300 }
}

// MARK: How a stand-in's row reads

/// How a kind that stands in describes its own row in a shape's Referenced In: the symbol it leads
/// with (a reference to one shape, a reference to many), and, if it has some, the words of line one.
/// Without words, line one names what's connected through the stand-in, else the board it's on.
public struct StandInRow {
    public var symbol: String
    /// The symbol's tint; nil for the secondary color.
    public var tint: NSColor?
    /// What line one says, when the kind has words of its own (a reference's, in curly quotes).
    public var text: String?

    public init(symbol: String, tint: NSColor? = nil, text: String? = nil) {
        self.symbol = symbol
        self.tint = tint
        self.text = text
    }
}

/// What `StandInRows` stores: how a kind's stand-in describes its row. Only the sugar makes one.
@MainActor
public struct StandInRowRule {
    let describe: @MainActor (_ record: AnyShapeRecord, _ registry: Registry) -> StandInRow?
}

/// A stand-in kind's description of its row in Referenced In: at most one per kind. A kind without
/// one has the kind's own symbol, and line one the names of what's connected through it, or its
/// board.
public enum StandInRows {}

extension StandInRows: KeyedExtensionPoint {
    public typealias Contribution = StandInRowRule
    public static var owner: PluginID { .publishing }
    public static func uniqueKeys(of _: StandInRowRule, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: StandInRowRule, for target: ShapeTarget) -> String { "referenced-in row → \(target)" }
}

extension ShapeRegistrar {
    /// How this kind's shapes, standing for another shape, read in its Referenced In: from the
    /// record, pure.
    ///
    ///     reference.standInRow { shape, _ in StandInRow(symbol: "magnifyingglass", text: "“\(shape.props.words)”") }
    public mutating func standInRow(_ describe: @escaping @MainActor (_ shape: ShapeRecord<Definition.Props>, _ registry: Registry) -> StandInRow?) {
        contribute(StandInRowRule(describe: { record, registry in
            record.typed(as: Definition.Props.self).flatMap { describe($0, registry) }
        }), to: StandInRows.self)
    }
}

// MARK: The rows

/// One line of a shape's Referenced In: a shape that stands for it.
public struct ReferencedInRow: Equatable {
    /// The shape that stands for it.
    public let standIn: ShapeID
    public let symbol: String
    public let tint: NSColor?
    /// Line one: what the kind says (a reference's words), else the names of what's connected through
    /// the stand-in (up to two, then " +n"), else the board it's on.
    public let name: String
    /// The board it's on, at the row's end: left out for a stand-in on the board shown, and where line
    /// one says it already.
    public let detail: String?
}

extension PublishingState {
    /// A row for each shape that stands for `target`, in file order. Observes the shape's edges
    /// (`topology.revision(of:)`), so a view that reads it draws again when what stands for it
    /// changes, an answer provided with no commit included.
    public func referencedInRows(of target: ShapeID) -> [ReferencedInRow] {
        guard let topology = editor.topology else { return [] }
        _ = topology.revision(of: target)
        let snapshot = topology.snapshot()
        let ordered = topology.standIns(for: target).sorted { a, b in
            switch (snapshot.fileOrderKey(of: a), snapshot.fileOrderKey(of: b)) {
            case (let x?, let y?): x.lexicographicallyPrecedes(y)
            case (_?, nil): true
            default: false
            }
        }
        return ordered.compactMap { row(for: $0, in: topology) }
    }

    private func row(for standIn: ShapeID, in topology: TopologyIndex) -> ReferencedInRow? {
        guard let record = editor.shape(inFile: standIn) else { return nil }
        let registry = editor.registry
        let described = registry.contributions(to: StandInRows.self, for: record.kind).first?.describe(record, registry)
        let label = registry.label(of: record.kind)
        let board = editor.file.board(containing: standIn)
        let boardLabel = board.map(boardName(of:))
        let name = described?.text ?? connected(through: standIn, in: topology) ?? boardLabel ?? PublicStyle.boardName
        let isShown = board == nil || board == editor.board
        return ReferencedInRow(standIn: standIn, symbol: described?.symbol ?? label.systemImage ?? PublicStyle.fallbackSymbol,
                               tint: described?.tint, name: name, detail: isShown || name == boardLabel ? nil : boardLabel)
    }

    /// The names of what's connected through a stand-in: the other end of each edge forwarded
    /// through it, each shape once, as written ("stickies, ports"; "stickies, ports +1"). Nil if
    /// nothing is.
    private func connected(through standIn: ShapeID, in topology: TopologyIndex) -> String? {
        var seen: [ShapeID] = []
        for edge in topology.edges(through: standIn) {
            let other = edge.literalTarget == standIn ? edge.literalSource : edge.literalTarget
            if other != standIn, !seen.contains(other) { seen.append(other) }
        }
        guard !seen.isEmpty else { return nil }
        let shown = seen.prefix(PublicStyle.namesShown).map(name(of:)).joined(separator: ", ")
        return seen.count > PublicStyle.namesShown ? shown + " +\(seen.count - PublicStyle.namesShown)" : shown
    }

    /// What a shape is called in a row: its title, else its kind's name.
    private func name(of id: ShapeID) -> String {
        guard let record = editor.shape(inFile: id) else { return PublicStyle.fallbackName }
        return editor.registry.title(of: record) ?? editor.registry.label(of: record.kind).name
    }

    /// What a board is called: its owner's title, else its owner's kind's name; "Board" for the root
    /// (its name is the file's, which the host knows). For what names shapes on boards (a reference's
    /// panel says which board its shape is on).
    public func boardName(of board: BoardID) -> String {
        guard let owner = editor.owner(of: board) else { return PublicStyle.boardName }
        return editor.registry.title(of: owner) ?? editor.registry.label(of: owner.kind).name
    }

    /// Goes to the stand-in, as a click on a Mentioned In line goes to what mentions: its board shown
    /// first if it's on another, selected, in view (one step back).
    public func goToStandIn(_ id: ShapeID) {
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in editor?.goTo([id]) }
    }

    /// The pointer on a row hovers its stand-in on the canvas, if it's on the board shown; leaving it
    /// (`endHover`) lets go, if the stand-in is still what's hovered.
    public func hover(_ id: ShapeID) {
        guard editor.document[id] != nil else { return }
        editor.hovered = id
    }

    public func endHover(_ id: ShapeID) {
        if editor.hovered == id { editor.hovered = nil }
    }
}

// MARK: The tab

@MainActor
func registerReferencedIn(into registrar: inout PluginRegistrar) {
    registrar.detailsForEveryShape(where: { _ in true }) {
        DetailSection<AnyShapeRecord>(in: ReferencedInTab.self, id: "referenced-in") { shape in
            ReferencedInList(target: shape.shapeID, publishing: shape.service(PublishingState.self))
        }
        .shownWhile { shape, context in context.service(PublishingState.self)?.isReferenced(shape) == true }
        .enabledWhileReadOnly()
    }
}

/// A line per stand-in, in file order. It observes the shape's edges alone (`topology.revision`), so
/// it redraws when what stands for the shape changes, though the shape doesn't.
struct ReferencedInList: View {
    let target: ShapeID
    let publishing: PublishingState?

    var body: some View {
        if let publishing {
            let rows = publishing.referencedInRows(of: target)
            ForEach(rows, id: \.standIn) { row in
                ReferencedInLine(row: row, publishing: publishing)
            }
        }
    }
}

/// One stand-in: the pointer on it hovers it on the canvas, if it's on the board shown, and a click
/// goes to it.
struct ReferencedInLine: View {
    let row: ReferencedInRow
    let publishing: PublishingState

    var body: some View {
        let id = row.standIn
        Button { publishing.goToStandIn(id) } label: {
            DetailShapeRow(symbol: row.symbol, tint: row.tint, name: row.name, detail: row.detail)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .onHover { inside in
            if inside { publishing.hover(id) } else { publishing.endHover(id) }
        }
        .onDisappear { publishing.endHover(id) }
    }
}

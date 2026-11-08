import AppKit
import Canvas
import Connections
import Draw
import LineRows
import Palette
import TextEditing
import Titles
import Topology

// An endpoint's connections, in its card (E4 panel 1): a line each, `writes refunds`, `reads payments`, `calls Stripe API.POST
// /v1/refunds`, the relation in its pill and what it goes to after it. Each is its arrow (the arrows leaving the endpoint's row on
// `writes`, `reads` and `calls`), nothing kept on the row: the lines are read from Topology's edges, and a line written makes,
// changes or takes out the arrow, in a step of the line's own the kind names by what changed (Connect, Change Relation, Change
// Connection, Delete Arrow). After a relation the list offers what it goes to: the file's tables after writes and reads, nearest
// first, and its endpoints after calls, each lit; a table or an endpoint on another board is reached through a pill on this one, as a
// key's table is (an endpoint's pill stands for the endpoint). Typing never makes a shape public: a far shape no pill can stand for as
// it is makes no arrow, and the line's words stay unwritten.

/// One of an endpoint's connections as its card's line says it: the relation and where it goes (a table, or an endpoint's row).
public struct EndpointLink: Hashable, Sendable {
    public var channel: ChannelID
    public var target: PartAddress

    public init(channel: ChannelID, target: PartAddress) {
        self.channel = channel
        self.target = target
    }
}

/// The relations an endpoint's card writes, in the order its list offers them.
@MainActor
enum EndpointRelations {
    /// Each relation, its word, and its tint as one `NSColor`, so a span's fill is equal to itself from line to line.
    static let all: [(id: ChannelID, title: String, tint: NSColor)] = [
        (Writes.id, KitStyle.writesTitle, NSColor(KitStyle.writesTint)),
        (Reads.id, KitStyle.readsTitle, NSColor(KitStyle.readsTint)),
        (Calls.id, KitStyle.callsTitle, NSColor(KitStyle.callsTint)),
    ]

    static func channel(titled word: String) -> ChannelID? { all.first { $0.title == word.lowercased() }?.id }
    static func title(of channel: ChannelID) -> String? { all.first { $0.id == channel }?.title }
    static func tint(of channel: ChannelID) -> NSColor? { all.first { $0.id == channel }?.tint }

    /// Whether a relation ends on a table as a whole (writes, reads), not an endpoint (calls).
    static func endsOnTable(_ channel: ChannelID) -> Bool { channel != Calls.id }
}

/// An endpoint's connection line: its relation's word in a pill of its tint, then what it goes to, a table's name or an endpoint's
/// `API.METHOD /path` (its API's name, a dot, its method and full path), standing for it once it names one. Printed with live names.
struct EndpointLinkGrammar: LineGrammar {
    typealias Row = EndpointLink

    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<EndpointLink> {
        let text = line.string as NSString
        let words = ColumnGrammar.placedWords(of: line.string)
        guard let first = words.first, let channel = EndpointRelations.channel(titled: first.text), let tint = EndpointRelations.tint(of: channel) else {
            return LineReading(row: nil, spans: words.map { LineSpan($0.range, .plain) })
        }
        var spans = [LineSpan(first.range, .chip(tint, ink: .white))]
        guard words.count > 1 else { return LineReading(row: nil, spans: spans) }
        let start = words[1].range.location, end = NSMaxRange(words[words.count - 1].range)
        let range = NSRange(location: start, length: end - start)
        let words2 = text.substring(with: range)
        let target = Self.target(words2, at: range, in: line, channel: channel, context)
        spans.append(LineSpan(range, target == nil ? .plain : .code))
        return LineReading(row: target.map { EndpointLink(channel: channel, target: $0) }, spans: spans)
    }

    /// What words after a relation name: the run's reference (printed or picked), else a table by name (writes, reads) or an endpoint
    /// by its API's name and full name, or its full name alone (calls), nearest first.
    static func target(_ words: String, at range: NSRange, in line: LineText, channel: ChannelID, _ context: LineContext) -> PartAddress? {
        let editor = context.editor
        if let found = line.references.first(where: { NSIntersectionRange($0.range, range).length > 0 })?.target, editor.shape(inFile: found.shape) != nil,
           EndpointRelations.endsOnTable(channel) == (found.part == nil) {
            return found
        }
        let names = editor.service(KitNames.self)
        if EndpointRelations.endsOnTable(channel) { return names?.tableNamed(words, besides: context.shape).map { PartAddress($0) } }
        return names?.endpoint(named: words, near: context.shape)
    }

    func print(_ link: EndpointLink, in context: LineContext) -> LineText {
        guard let title = EndpointRelations.title(of: link.channel), let written = Self.written(link.target, context.editor) else { return LineText("") }
        let start = (title as NSString).length + 1
        return LineText("\(title) \(written)", references: [LineReference(range: NSRange(location: start, length: (written as NSString).length), target: link.target)])
    }

    /// What a line says a connection goes to, by the names it has now: a table's name, or `Stripe API.POST /v1/refunds`. Nil for one
    /// that's gone, or has no name.
    static func written(_ target: PartAddress, _ editor: CanvasEditor) -> String? {
        guard let record = editor.shape(inFile: target.shape), let name = editor.registry.title(of: record) else { return nil }
        guard let part = target.part else { return name }
        guard let row = editor.registry.parts(of: record)?.first(where: { $0.id == part }) else { return nil }
        return "\(name).\(row.name)"
    }

    func offers(at caret: Int, in line: LineText, reading: LineReading<EndpointLink>, context: LineContext) -> LineOffers? {
        let words = ColumnGrammar.placedWords(of: line.string)
        let at = words.firstIndex { caret >= $0.range.location && caret <= NSMaxRange($0.range) }
        let index = at ?? words.filter { NSMaxRange($0.range) < caret }.count
        if index == 0 {
            let range = at.map { words[$0].range } ?? NSRange(location: caret, length: 0)
            let typed = at.map { String(words[$0].text.utf16.prefix(caret - words[$0].range.location)) ?? "" } ?? ""
            return LineOffers(range: range, query: typed, items: EndpointRelations.all.map { relation in
                LineOffer(CaretCompletion(label: relation.title, insert: relation.title + " ", chip: relation.tint))
            })
        }
        guard let channel = words.first.flatMap({ EndpointRelations.channel(titled: $0.text) }), words.count >= 1 else { return nil }
        // What it goes to: the words after the relation, as far as the caret, one run.
        let start = words.count > 1 ? words[1].range.location : caret
        let end = max(caret, words.count > 1 ? NSMaxRange(words[words.count - 1].range) : caret)
        guard caret >= start else { return nil }
        let range = NSRange(location: start, length: end - start)
        let typed = (line.string as NSString).substring(with: NSRange(location: start, length: caret - start))
        let editor = context.editor
        guard let names = editor.service(KitNames.self) else { return nil }
        if EndpointRelations.endsOnTable(channel) {
            var seen: Set<String> = []
            return LineOffers(range: range, query: typed, items: names.tables.compactMap { table in
                guard seen.insert(table.name).inserted else { return nil }
                return LineOffer(CaretCompletion(label: table.name, detail: names.boardName(table.board), insert: table.name), light: PartAddress(table.id))
            })
        }
        // An endpoint, its API's name before it: the line says which API, the list which board.
        return LineOffers(range: range, query: typed, items: names.endpoints.compactMap { endpoint in
            guard endpoint.address != PartAddress(context.shape, part: context.row) else { return nil }
            return LineOffer(CaretCompletion(label: endpoint.name, detail: endpoint.api, insert: "\(endpoint.api).\(endpoint.name)"), light: endpoint.address)
        })
    }

    func spoken(_ link: EndpointLink, in context: LineContext) -> String {
        guard let title = EndpointRelations.title(of: link.channel) else { return "" }
        return [title, context.editor.accessibleName(of: link.target) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// An endpoint's connections, read from the board and written as arrows.
@MainActor
enum EndpointLinks {
    /// The arrows leaving `endpoint` (a row of the API `api`) on the three relations, in the order of their edges, each with what it
    /// goes to (through a pill, what the pill stands for and the row its binding names).
    static func held(_ endpoint: PartID, of api: ShapeID, in editor: CanvasEditor) -> [(link: EndpointLink, arrow: ShapeID)] {
        guard let topology = editor.topology else { return [] }
        let types = EndpointRelations.all.map { EdgeTypeID(rawValue: $0.id.rawValue) }
        return topology.edges(of: api, part: endpoint, .outgoing, types: .only(types), view: .resolved).compactMap { edge in
            guard edge.isConnection, edge.sourcePart == endpoint else { return nil }
            return (EndpointLink(channel: ChannelID(rawValue: edge.type.rawValue), target: PartAddress(edge.target, part: edge.targetPart)), edge.carrier)
        }
    }

    /// The links a card shows: those that print.
    static func shown(_ endpoint: PartID, of api: ShapeID, in editor: CanvasEditor) -> [EndpointLink] {
        held(endpoint, of: api, in: editor).map(\.link).filter { EndpointLinkGrammar.written($0.target, editor) != nil }
    }

    /// Writes `wanted` as `endpoint`'s connections, one step named by what changed: a link the board doesn't have is made (an arrow on
    /// its relation from the row; one to a shape on another board through a pill here), one the lines no longer say is deleted, and one
    /// line changed from one to the other is its arrow re-aimed (a relation changed alone keeps the arrow). False, with nothing
    /// written, where an arrow can't be made (the board takes nothing, the API is locked, no pill can reach the far shape).
    static func write(_ wanted: [EndpointLink], for endpoint: PartID, of api: ShapeID, in editor: CanvasEditor) -> Bool {
        let held = held(endpoint, of: api, in: editor).filter { EndpointLinkGrammar.written($0.link.target, editor) != nil }
        var removed = held, added: [EndpointLink] = []
        for link in wanted {
            if let at = removed.firstIndex(where: { $0.link == link }) { removed.remove(at: at) } else { added.append(link) }
        }
        guard !removed.isEmpty || !added.isEmpty else { return true }
        // A line changed: its arrow, re-aimed. Only a relation changed: the arrow keeps everything but its channel.
        var rechanneled: [(arrow: ShapeID, channel: ChannelID)] = []
        var replaced: [ShapeID] = []
        for (index, link) in added.enumerated().reversed() where !removed.isEmpty {
            if let at = removed.firstIndex(where: { $0.link.target == link.target }) {
                rechanneled.append((removed[at].arrow, link.channel))
                removed.remove(at: at)
                added.remove(at: index)
            }
        }
        let pairs = min(removed.count, added.count)
        replaced = removed.prefix(pairs).map(\.arrow)
        let step: String = if !rechanneled.isEmpty && added.isEmpty && removed.isEmpty { APIStyle.changeRelationStep }
            else if pairs > 0 { APIStyle.changeConnectionStep }
            else if !added.isEmpty { APIStyle.connectStep }
            else { APIStyle.deleteArrowStep }
        let registry = editor.registry
        let done: Bool? = editor.transactWhole(step, shaking: [api]) { transaction in
            guard let source = transaction.document[api], !transaction.isReadOnly(source) else { throw Transaction.Refused([api]) }
            for (arrow, channel) in rechanneled {
                transaction.update(arrow) { $0[ChannelProperty.self] = channel }
            }
            let gone = Set(removed.map(\.arrow) + replaced)
            if !gone.isEmpty { transaction.delete(gone) }
            var put: [CGRect] = []
            for link in added {
                guard let end = reach(link.target, from: api, avoiding: put, in: &transaction, editor: editor) else { throw Transaction.Refused([api]) }
                if let box = transaction.document[end.address.shape]?.box, editor.document[end.address.shape] == nil { put.append(box) }
                let request = ConnectionRequest(from: api, to: end.address.shape, fromPart: endpoint, toPart: end.address.part, channel: link.channel)
                guard let made = registry.connection(request, in: transaction.shapes) else { throw Transaction.Refused([api]) }
                transaction.insert(made)
                guard transaction.document[made.id] != nil else { throw Transaction.Refused([api]) }
            }
            return true
        }
        guard done == true else { return false }
        editor.announce(step)
        return true
    }

    /// Where a link to `target` ends on the transaction's board: the shape (or row) itself, there; else a pill for it there, reused or
    /// made and put down, the row on the binding (an endpoint's own pill). Nil where none can be (typing never makes a shape public).
    private static func reach(_ target: PartAddress, from api: ShapeID, avoiding put: [CGRect], in transaction: inout Transaction,
                              editor: CanvasEditor) -> (address: PartAddress, kind: ShapeKind?)? {
        if transaction.document[target.shape] != nil { return (target, nil) }
        guard editor.board == transaction.board, let far = editor.shape(inFile: target.shape) else { return nil }
        let verdicts = FarVerdicts(editor)
        let alone = target.part.flatMap { part in editor.registry.parts(of: far)?.first { $0.id == part } }.map(\.standsAlone) == true
        let label = target.part.flatMap { part in editor.registry.parts(of: far)?.first { $0.id == part }?.name } ?? editor.registry.title(of: far) ?? ""
        guard verdicts.verdict(of: target.shape) == .reads, let route = verdicts.route,
              let placed = route.placePill(standingFor: target.shape, row: alone ? target.part : nil, label: label, beside: api, edgeIs: .from,
                                           sharing: .any, avoiding: put, reading: transaction.document, verdicts: verdicts, in: editor),
              (try? placed.claim(in: &transaction, registry: editor.registry)) != nil, let pill = try? placed.put(in: &transaction) else { return nil }
        return (PartAddress(pill, part: target.part), placed.farKind)
    }
}

extension KitNames {
    /// What a list says of a board: its owner's name, or the file's for the root.
    func boardName(_ board: BoardID) -> String {
        guard let owner = board.owner, let record = editor.file.record(owner) else { return "" }
        return editor.registry.title(of: record) ?? ""
    }

    /// Every endpoint of the file's named APIs, the board shown's first: its address, its full name, its API's name.
    var endpoints: [(address: PartAddress, name: String, api: String)] {
        let file = editor.file, registry = editor.registry, shown = editor.board
        let boards = [shown] + file.everyBoard.filter { $0 != shown }.sorted { ($0.owner?.description ?? "") < ($1.owner?.description ?? "") }
        var found: [(address: PartAddress, name: String, api: String)] = []
        for board in boards {
            for record in file[board].shapes where record.kind == API.kind {
                guard let api = registry.title(of: record), let parts = registry.parts(of: record) else { continue }
                for part in parts where part.standsAlone { found.append((PartAddress(record.id, part: part.id), part.name, api)) }
            }
        }
        return found
    }

    /// The endpoint `words` name, nearest `shape`: `API.METHOD /path` (its API's name, a dot, its full name), or its full name alone.
    func endpoint(named words: String, near shape: ShapeID) -> PartAddress? {
        let folded = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let all = endpoints
        if let match = all.first(where: { "\($0.api).\($0.name)" == folded }) { return match.address }
        return all.first { $0.name == folded }?.address
    }
}

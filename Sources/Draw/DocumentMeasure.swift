import Adornments
import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import Foundation
import Topology

// `canvas measure` of a document: how big each node would be drawn, how wide a pill for each node an edge reaches would be
// where it would sit, and which edges the app would refuse, by key, for a render layer that lays a document out before it
// applies it. Each node is a shape statement named by an id picked for it, written with every property the document gives
// it (so a type's schema, a note's `is` by key and its values, and the ends between them size it as a draw does), measured
// by `measure`'s own drawing on a board of its own; nothing is placed and no board is touched.

/// What a document's measure answers.
public struct DocumentMeasure: Encodable {
    struct Node: Encodable {
        /// Width and height, world units: the room it takes once drawn.
        let size: [CGFloat]
        /// How far its title's pill and chips reach above it, at 100% (0 for none).
        let above: CGFloat
        /// How wide it must be for its title (a pill, or a tab on its edge) and chips to show whole (0 for none).
        let titleWidth: CGFloat
    }

    struct Pill: Encodable {
        /// The key of the node it stands for.
        let target: String
        /// The key of the node holding the shape it would sit beside (a frame, or a node that holds a board); nil for the top
        /// of the drawing's board.
        let from: String?
        let size: [CGFloat]

        enum CodingKeys: String, CodingKey {
            case target = "for"
            case from, size
        }
    }

    struct RefusedEdge: Encodable {
        let edge: Int
        let from: String
        let to: String
        let refused: DocumentError.Refusal
    }

    let nodes: [String: Node]
    let pills: [Pill]
    let edges: [RefusedEdge]
    let constants: MeasureResult.Constants
    let warnings: [String]?
}

/// Measures `text`, a graph document, over `registry`'s kinds; `editor`, the open file, if any, whose types and names a
/// value's title finds (a key names a node of the document). `target` is the board it will be drawn on as `apply`'s `--on`
/// names it; left out, where the open file's drawing of that name was drawn, else the root: a pill says where its shape is
/// from there. Refused as `apply` refuses a document it can't read.
@MainActor
public func measure(document text: String, on target: String? = nil, program: String, in registry: Registry,
                    namesBeyond editor: CanvasEditor?) throws(DocumentError) -> DocumentMeasure {
    let document = try DrawDocument(parsing: text, registry: registry)
    // The board the drawing goes on, as apply puts it, and the names of what holds that board, outermost first, which every
    // place a pill there says starts from; the ones among them that own a board.
    var top: BoardID = .root
    if let editor {
        if let target {
            top = try DocumentRun.board(named: target, in: editor, program: program)
        } else if let name = document.drawing, let record = registry.drawRecording?.read(name, editor.file),
                  let recorded = BoardID(recorded: record.board), editor.canShow(recorded) {
            top = recorded
        }
    }
    var prefix: [String] = [], prefixOpening: Set<String> = []
    if let editor, let owner = top.owner {
        for id in Drawing.containers(above: owner, in: editor).reversed() + [owner] {
            guard let record = editor.file.record(id) else { continue }
            let name = registry.drawNaming?.name(record, registry) ?? registry.label(of: record.kind).name
            prefix.append(name)
            if registry.boardOwningKinds.contains(record.kind) { prefixOpening.insert(name) }
        }
    }
    var ids: [String: ShapeID] = [:]
    for node in document.nodes { ids[node.key] = ShapeID() }
    let reserved = Set(ids.values)

    // Every node, with what it is; then every edge, laid out with them (an end gives the notes of its types a row).
    var lines: [String] = [], about: [DocumentRun.Subject] = []
    for node in document.nodes {
        var line = "\(node.kind.rawValue) \(ShapeName.idMark)\(ids[node.key]!)"
        let vocabulary = KindVocabulary(node.kind, in: registry)
        for (key, value) in node.props.sorted(by: { $0.key < $1.key }) {
            if key == LanguageKey.title.rawValue || key == vocabulary.namingProperty {
                if let title = value.stringValue { line += " \(LanguageKey.title.rawValue): \(DrawDocument.quotedLiteral(title))" }
                continue
            }
            if key == LanguageKey.size.rawValue {
                line += " \(key): \(value.stringValue ?? value.compactText)"
                continue
            }
            let takesText: Bool = if case .string? = vocabulary.schema.shape(of: key) { true } else { false }
            line += " \(key): \(DrawDocument.literal(value, takesText: takesText))"
        }
        lines.append(line)
        about.append(.node(node.key))
    }
    let edgeKind = registry.drawEdging.flatMap { $0.kind(registry) }
    let edgeVocabulary = edgeKind.map { KindVocabulary($0, in: registry) }
    for edge in document.edges {
        var line = "\(Keyword.edge.rawValue) \(ShapeName.idMark)\(ids[edge.from]!) -> \(ShapeName.idMark)\(ids[edge.to]!)"
        for (key, value) in edge.props.sorted(by: { $0.key < $1.key }) {
            let takesText: Bool = if case .string? = edgeVocabulary?.schema.shape(of: key) { true } else { false }
            line += " \(key): \(DrawDocument.literal(value, takesText: takesText))"
        }
        lines.append(line)
        about.append(.edge(edge.index))
    }
    let options = DrawOptions(reserved: reserved, keys: ids, program: true)
    let measured: (result: MeasureResult, drawing: Drawing, scratch: CanvasEditor)
    do throws(DrawError) {
        measured = try Draw.measured(script: lines.joined(separator: "\n"), program: program, options: options, in: registry, namesBeyond: editor)
    } catch {
        throw DocumentError((error.errors.isEmpty ? [error] : error.errors).map { problem in
            var key: String?, index: Int?
            if let line = problem.line, line >= 1, line <= about.count {
                switch about[line - 1] {
                case .node(let found): key = found
                case .edge(let found): index = found
                }
            }
            return DocumentError.Refusal(key: key, edge: index, reason: problem.reason, message: said(problem.message, ids), hint: problem.hint.map { said($0, ids) })
        })
    }
    let (result, drawing, scratch) = measured

    // The document's shapes on the scratch board, so what they show of each other reads them: a node's type chips name the
    // document's own types (not a type the board lacks, "Deleted"), as wide as they are drawn.
    let nodeRecords = drawing.items.compactMap { item -> AnyShapeRecord? in
        guard item.statement.line >= 1, item.statement.line <= document.nodes.count, case .node = about[item.statement.line - 1] else { return nil }
        return item.record
    }
    scratch.transact("Measure") { transaction in for record in nodeRecords { transaction.insert(record) } }

    var nodes: [String: DocumentMeasure.Node] = [:]
    for item in drawing.items {
        guard item.statement.line >= 1, item.statement.line <= document.nodes.count,
              case .node(let key) = about[item.statement.line - 1] else { continue }
        var record = item.record
        record.box = CGRect(origin: .zero, size: item.room)
        nodes[key] = DocumentMeasure.Node(size: [item.room.width, item.room.height], above: scratch.adornmentExtent(of: record),
                                          titleWidth: scratch.adornmentLeastWidth(of: record))
    }

    // Where each node is: the board it is on (the top, or a node that holds a board), and its containers' titles, outermost first.
    let naming = registry.drawNaming
    func title(_ key: String) -> String? {
        guard let node = document.node(key), let text = node.props[LanguageKey.title.rawValue]?.stringValue else { return nil }
        return naming?.fold(text) ?? text
    }
    func chain(_ key: String?) -> [String] {
        var keys: [String] = [], at = key
        while let current = at, let node = document.node(current) {
            keys.insert(current, at: 0)
            at = node.container
        }
        return keys
    }
    func board(_ key: String) -> String? {
        var at = document.node(key)?.container
        while let current = at, let node = document.node(current) {
            if registry.boardOwningKinds.contains(node.kind) { return current }
            at = node.container
        }
        return nil
    }

    // A pill for each end of an edge that a pill can stand for, sized where it would sit: in the container of the other end.
    let standIns = registry.standIns
    var pillKinds: [ShapeKind: ShapeKind?] = [:]
    func pillKind(of kind: ShapeKind) -> ShapeKind? {
        if let known = pillKinds[kind] { return known }
        let found = registry.placement(for: kind).flatMap { placement -> ShapeKind? in
            let blank = placement.shape(at: .zero)
            return standIns.makers.first { maker in
                var probe = blank
                return standIns.fulfil(maker, &probe)
            }
        }
        pillKinds[kind] = .some(found)
        return found
    }
    var pills: [DocumentMeasure.Pill] = [], seen: Set<String> = []
    for edge in document.edges {
        for (far, near) in [(edge.to, edge.from), (edge.from, edge.to)] {
            guard let node = document.node(far), let kind = pillKind(of: node.kind) else { continue }
            let from = document.node(near)?.container
            guard seen.insert(far + "\u{0}" + (from ?? "")).inserted else { continue }
            let label = title(far) ?? far
            guard var record = standIns.make(kind, standingFor: ShapeID(), label: label), record.box != nil else { continue }
            // Each container by the name the chains give it (its title, else its key), so an untitled one that owns a board keeps
            // its weight; both from the board the drawing goes on.
            let name = { (key: String) -> String in title(key) ?? key }
            let owning = { (key: String) -> Bool in document.node(key).map { registry.boardOwningKinds.contains($0.kind) } ?? false }
            let shape = prefix + chain(node.container).map(name), seat = prefix + chain(from).map(name)
            let opening = prefixOpening.union(chain(node.container).filter(owning).map(name)).union(chain(from).filter(owning).map(name))
            standIns.seat(&record, at: .written(shape: shape, seat: seat, opening: opening, root: editor?.rootName ?? ""), in: scratch.shapeContext)
            let size = record.box!.size
            pills.append(DocumentMeasure.Pill(target: far, from: from, size: [size.width, size.height]))
        }
    }

    // The edges the app won't draw between their ends where they are: asked of what makes edges, as `draw` asks it, over the
    // two ends alone (what a drag would refuse: two kinds that share no channel). An edge between boards goes through a pill
    // and is the render layer's to lay out.
    var refused: [DocumentMeasure.RefusedEdge] = []
    if let edging = registry.drawEdging {
        let records = Dictionary(uniqueKeysWithValues: drawing.items.compactMap { item -> (String, AnyShapeRecord)? in
            guard item.statement.line >= 1, item.statement.line <= document.nodes.count, case .node(let key) = about[item.statement.line - 1] else { return nil }
            return (key, item.record)
        })
        for edge in document.edges where board(edge.from) == board(edge.to) {
            guard let from = records[edge.from], let to = records[edge.to] else { continue }
            let alone = CanvasDocument(shapes: from.id == to.id ? [from] : [from, to])
            var attributes: [String: String] = [:]
            for key in edging.attributes { if let value = edge.props[key] { attributes[key] = value.stringValue ?? value.compactText } }
            let request = EdgeRequest(from: from.id, to: to.id, attributes: attributes, fromName: quoted(edge.from), toName: quoted(edge.to),
                                      written: "\(quoted(edge.from)) -> \(quoted(edge.to))")
            do throws(DrawError) {
                _ = try edging.make(request, nil, ShapeContext(document: alone, registry: registry))
            } catch {
                refused.append(DocumentMeasure.RefusedEdge(edge: edge.index, from: edge.from, to: edge.to,
                                                           refused: DocumentError.Refusal(edge: edge.index, reason: error.reason, message: said(error.message, ids),
                                                                                          hint: error.hint.map { said($0, ids) })))
            }
        }
    }
    let warnings = (result.warnings ?? []).map { warning -> String in
        let subject = warning.line >= 1 && warning.line <= about.count ? about[warning.line - 1] : nil
        let what: String = switch subject {
        case .node(let key)?: quoted(key) + ": "
        case .edge(let index)?: "edges[\(index)]: "
        case nil: ""
        }
        return what + said(warning.message, ids)
    }
    return DocumentMeasure(nodes: nodes, pills: pills, edges: refused, constants: result.constants, warnings: warnings.isEmpty ? nil : warnings)
}

/// A message with each node's id said as its key.
@MainActor
private func said(_ message: String, _ ids: [String: ShapeID]) -> String {
    guard message.contains(ShapeName.idMark) else { return message }
    var out = message
    for (key, id) in ids where out.contains(id.description) { out = out.replacingOccurrences(of: "\(ShapeName.idMark)\(id)", with: quoted(key)) }
    return out
}

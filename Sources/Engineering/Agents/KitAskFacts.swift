import Canvas
import Connections
import Foundation
import Titles
import Topology

// What `--ask` is told of the kit's shapes, beside the titles: `<tables>`, each table a line, its columns in their grammar with
// their keys (`customer_id uuid → customers.id`) and the database it's in, and each enum its values; `<apis>`, each API a line
// (its server) and its routes a line each, whole paths, with what each writes, reads and calls and what calls it. So a question
// about a column or an endpoint finds the table or the API that holds it. Names, types and paths only, as a table's or an API's
// lines show them: never a note's text or a value. Each block at most `blockLimit` characters, the shapes whose words the question
// names first, then in file order; past the limit, the rest named on a last line, as many as fit.

@MainActor
enum KitAskFacts {
    /// The blocks' tags.
    nonisolated static let tablesTag = "tables"
    nonisolated static let apisTag = "apis"
    /// The most characters a block holds, as `<fields>`'s.
    static let blockLimit = 8_000

    /// One shape's lines and the words they share with a question.
    struct Entry {
        var name: String
        var lines: [String]
        var words: Set<String>
    }

    /// `<tables>`: a table a line, `orders (in "shop"): id uuid pk; customer_id uuid → customers.id`, and an enum a line,
    /// `order_status (enum-type): pending, paid, refunded`. Empty for a file with neither.
    static func tables(in editor: CanvasEditor, question: String) -> String {
        guard let snapshot = editor.topology?.snapshot() else { return "" }
        let registry = editor.registry, keys = editor.service(KeyIndex.self), names = editor.service(KitNames.self)
        var entries: [Entry] = []
        snapshot.forEachShape(inFileOrder: { record, _ in
            if let table = record.typed(as: DatabaseTable.self) {
                let name = self.name(of: record, registry)
                let columns = table.props.columns.map { column in
                    var column = column
                    if let id = column.type.shape, let now = names?.name(of: id) { column.type.words = now }
                    var line = ColumnGrammar.print(column)
                    if let target = keys?.target(of: column.id, in: record.id), let written = ColumnLineGrammar.written(target, editor) {
                        line += " \(ColumnGrammar.arrow) \(written)"
                    }
                    return line
                }
                let database = record.container.flatMap { snapshot.shape($0) }.flatMap { registry.title(of: $0) }
                let head = name + (database.map { " (in \(quoted($0)))" } ?? "")
                entries.append(Entry(name: name, lines: [columns.isEmpty ? head : head + ": " + columns.joined(separator: "; ")],
                                     words: words(in: ([name] + table.props.columns.map(\.name) + table.props.columns.map(\.type.words)).joined(separator: " "))))
            } else if let type = record.typed(as: DatabaseEnum.self) {
                let name = self.name(of: record, registry)
                let values = type.props.values.map(\.text)
                entries.append(Entry(name: name, lines: ["\(name) (\(DatabaseEnum.kind)): " + values.joined(separator: ", ")],
                                     words: words(in: ([name] + values).joined(separator: " "))))
            }
        })
        return block(entries, question: question, noun: ("table", "tables"))
    }

    /// `<apis>`: an API a line, `orders API (api.shop.dev/v1 bearer)`, then its routes a line each, `- POST /orders/{id}/refunds
    /// (NewRefund) → 201 Refund; writes "refunds"; calls "Stripe API" POST /v1/refunds`, whole paths. Empty for a file with none.
    static func apis(in editor: CanvasEditor, question: String) -> String {
        guard let snapshot = editor.topology?.snapshot() else { return "" }
        let registry = editor.registry
        let relations = [Writes.id, Reads.id, Calls.id].map { EdgeTypeID(rawValue: $0.rawValue) }
        var entries: [Entry] = []
        snapshot.forEachShape(inFileOrder: { record, _ in
            guard let api = record.typed(as: API.self) else { return }
            let name = self.name(of: record, registry)
            var about: [String] = []
            if !api.props.server.isEmpty { about.append(ServerGrammar.print(api.props.server)) }
            if api.props.deprecated { about.append("deprecated") }
            var lines = [name + (about.isEmpty ? "" : " (\(about.joined(separator: ", ")))")]
            var said = [name]
            for (index, row) in api.props.endpoints.enumerated() {
                guard var endpoint = row.endpoint else { continue }
                endpoint.path = APIGroups.fullPath(of: index, in: api.props.endpoints)
                var line = "- " + EndpointGrammar.print(endpoint)
                said.append(line)
                // What it does first (writes, reads, calls), then what calls it, each once.
                var seen: Set<String> = []
                for direction in [EdgeDirection.outgoing, .incoming] {
                    for edge in snapshot.edges(of: record.id, part: endpoint.id, direction, types: .only(relations)) where edge.isConnection {
                        let far = direction == .outgoing ? PartAddress(edge.target, part: edge.targetPart) : PartAddress(edge.source, part: edge.sourcePart)
                        guard let written = self.written(far, snapshot, registry) else { continue }
                        let said = "\(direction == .outgoing ? edge.type.rawValue : "called by") \(written)"
                        if seen.insert(said).inserted { line += "; " + said }
                    }
                }
                lines.append(line)
            }
            entries.append(Entry(name: name, lines: lines, words: words(in: said.joined(separator: " "))))
        })
        return block(entries, question: question, noun: ("API", "APIs"))
    }

    /// A shape's name as a block writes it: its title, else `#` and its id, which an agent may be given.
    private static func name(of record: AnyShapeRecord, _ registry: Registry) -> String {
        registry.title(of: record).flatMap { $0.isEmpty ? nil : $0 } ?? "#" + record.id.description
    }

    /// What a relation goes to, as a line says it: a shape's name in quotes, then the row's name (an endpoint's method and path).
    private static func written(_ far: PartAddress, _ snapshot: TopologySnapshot, _ registry: Registry) -> String? {
        guard let record = snapshot.shape(far.shape) else { return nil }
        let shape = quoted(name(of: record, registry))
        guard let part = far.part else { return shape }
        guard let row = registry.parts(of: record)?.first(where: { $0.id == part }), !row.name.isEmpty else { return shape }
        return "\(shape) \(row.name)"
    }

    private static func quoted(_ name: String) -> String { "\"\(name)\"" }

    /// The words of a text, lowercased, split at anything that isn't a letter or a digit (`customer_id` is two).
    static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
    }

    /// The entries as a block: those sharing a word with the question first, then in file order, whole while they fit with a last
    /// line naming the rest; an entry too long for the block alone keeps the lines that fit and says how many it left out.
    static func block(_ entries: [Entry], question: String, noun: (one: String, many: String), limit: Int = blockLimit) -> String {
        guard !entries.isEmpty else { return "" }
        let asked = words(in: question)
        let ranked = entries.enumerated().sorted { a, b in
            let named = (!a.element.words.isDisjoint(with: asked), !b.element.words.isDisjoint(with: asked))
            if named.0 != named.1 { return named.0 }
            return a.offset < b.offset
        }.map(\.element)
        var kept: [String] = [], size = 0, taken = 0
        for entry in ranked {
            let more = ranked.count - taken - 1
            let reserve = more > 0 ? omission(of: [], count: more, noun: noun).count + 1 : 0
            let text = entry.lines.joined(separator: "\n")
            if size + text.count + 1 + reserve <= limit {
                kept.append(text)
                size += text.count + 1
                taken += 1
                continue
            }
            // The first entry alone too long for the block: its lines while they fit, and how many are left.
            if taken == 0 {
                var lines: [String] = []
                for (index, line) in entry.lines.enumerated() {
                    let left = entry.lines.count - index - 1
                    let note = left > 0 ? "- and \(left) more" : ""
                    guard size + line.count + 1 + note.count + 1 + reserve <= limit else {
                        let missing = entry.lines.count - index
                        lines.append("- and \(missing) more")
                        size += lines.last!.count + 1
                        break
                    }
                    lines.append(line)
                    size += line.count + 1
                }
                kept.append(lines.joined(separator: "\n"))
                taken = 1
            }
            break
        }
        if taken < ranked.count {
            kept.append(omission(of: ranked[taken...].map(\.name), count: ranked.count - taken, noun: noun, room: limit - size))
        }
        return kept.joined(separator: "\n")
    }

    /// `and 3 more tables: a, b, c`, the names as many as `room` holds, then `…`.
    private static func omission(of names: [String], count: Int, noun: (one: String, many: String), room: Int = .max) -> String {
        let lead = "and \(count) more \(count == 1 ? noun.one : noun.many): "
        guard !names.isEmpty else { return lead + "…" }
        var line = lead
        for (place, name) in names.enumerated() {
            let next = line + (place == 0 ? "" : ", ") + name
            guard next.count + (place == names.count - 1 ? 0 : 2) <= room else { return line + (place == 0 ? "" : ", ") + "…" }
            line = next
        }
        return line
    }
}

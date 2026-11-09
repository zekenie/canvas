import AppKit
import Canvas
import LineRows
import Mentions
import Palette
import TextEditing
import Titles
import Types

// An API's rows written as lines (LineRows): its server, a fixed first line; then a row a line, an endpoint
// (`METHOD /path/{param} [(Body)] [→ [status] [Response]]`) or a path-prefix header (a path alone). As a line reads: the method in
// its chip, the path in code with its parameters in the chip's color, a body's and a response's type in its pill (dashed while it
// names no type note), the grammar's own words grey. What fits at the caret: the methods at a line's start; for a path's segment,
// the file's tables and the API's other paths; after `(` and after a response's status, the file's types and "New type X" last
// (an action). A commit joins what the line says onto the row, so what only the card shows (a name, a summary, more responses)
// stays; its step is named by what changed (Add Endpoint, Change Method, Rename Path Prefix).

/// An API's row as a line reads.
struct APILineGrammar: LineGrammar {
    typealias Row = APIRow

    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<APIRow> {
        let scan = EndpointGrammar.scan(line.string, id: id)
        guard var row = scan.row else { return LineReading(row: nil) }
        let editor = context.editor
        let method = row.endpoint?.method ?? ""
        var spans: [LineSpan] = []
        var body: ShapeID?, response: ShapeID?
        // A body's type may be words (an unclosed bracket's): one run, bound as one.
        let bodyWords = scan.words.filter { $0.role == .body }
        if let first = bodyWords.first, let last = bodyWords.last {
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            body = APITypes.bound((line.string as NSString).substring(with: range), at: range, in: line, near: context.shape, editor)
            spans.append(LineSpan(range, APITypes.look(of: body, editor, onPaper: true)))
        }
        for word in scan.words {
            switch word.role {
            case .method: spans += Self.methodSpans(word.range, typed: word.text, method: method, in: line)
            case .path: spans += Self.pathSpans(word.range, parameters: scan.parameters, method: method, isHeader: row.header != nil)
            case .bracket, .arrow, .status: spans.append(LineSpan(word.range, .keyword))
            case .body: break
            case .response:
                response = APITypes.bound(word.text, at: word.range, in: line, near: context.shape, editor)
                spans.append(LineSpan(word.range, APITypes.look(of: response, editor, onPaper: true)))
            case .unread: spans.append(LineSpan(word.range, .plain))
            }
        }
        if case .endpoint(var endpoint) = row {
            if endpoint.body != nil { endpoint.body?.shape = body }
            if !endpoint.responses.isEmpty, endpoint.responses[0].type != nil { endpoint.responses[0].type?.shape = response }
            row = .endpoint(endpoint)
        }
        return LineReading(row: row, spans: spans)
    }

    /// A method's spans: its chip, and the room after it (and after the space that follows) that lays the path out where the
    /// rest draws it (`APIStyle.chipKerns`).
    static func methodSpans(_ range: NSRange, typed: String, method: String, in line: LineText) -> [LineSpan] {
        var spans = [LineSpan(range, .chip(APIStyle.chipFill(method), ink: APIStyle.chipInk))]
        let text = line.string as NSString
        let end = NSMaxRange(range)
        guard end < text.length, text.character(at: end) == 0x20 else { return spans }
        let width = (typed as NSString).size(withAttributes: [.font: KitStyle.chipFont]).width
        let space = (" " as NSString).size(withAttributes: [.font: KitStyle.codeFont]).width
        let kerns = APIStyle.chipKerns(textWidth: width, spaceWidth: space)
        spans.append(LineSpan(NSRange(location: end - 1, length: 1), .spacing(kerns.afterMethod)))
        spans.append(LineSpan(NSRange(location: end, length: 1), .spacing(kerns.afterSpace)))
        return spans
    }

    /// A path's spans: code, its parameters in the method's color (a header's in the ink).
    static func pathSpans(_ range: NSRange, parameters: [NSRange], method: String, isHeader: Bool) -> [LineSpan] {
        var spans: [LineSpan] = []
        var at = range.location
        for parameter in parameters where NSLocationInRange(parameter.location, range) {
            if parameter.location > at { spans.append(LineSpan(NSRange(location: at, length: parameter.location - at), .code)) }
            spans.append(LineSpan(parameter, isHeader ? .code : .tinted(APIStyle.parameterInk(method))))
            at = NSMaxRange(parameter)
        }
        if NSMaxRange(range) > at { spans.append(LineSpan(NSRange(location: at, length: NSMaxRange(range) - at), .code)) }
        return spans
    }

    /// The line a row is printed as: a type a body or a response names as it's called now, standing for it.
    func print(_ row: APIRow, in context: LineContext) -> LineText {
        guard case .endpoint(var endpoint) = row else { return LineText(EndpointGrammar.print(row)) }
        let editor = context.editor
        // What a type is called now, and the note its words name (written before one was, or made another way since).
        if let body = endpoint.body {
            endpoint.body?.words = APITypes.printed(body, editor)
            endpoint.body?.shape = APITypes.resolved(body, types: editor.types)
        }
        if let type = endpoint.responses.first?.type {
            endpoint.responses[0].type?.words = APITypes.printed(type, editor)
            endpoint.responses[0].type?.shape = APITypes.resolved(type, types: editor.types)
        }
        let string = EndpointGrammar.print(endpoint)
        var references: [LineReference] = []
        let words = EndpointGrammar.scan(string).words
        // A body's words, one run; a response's type, the name without its quotes.
        let bodyWords = words.filter { $0.role == .body }
        if let shape = endpoint.body?.shape, let first = bodyWords.first, let last = bodyWords.last {
            references.append(LineReference(range: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location), target: PartAddress(shape)))
        }
        if let shape = endpoint.responses.first?.type?.shape, let word = words.first(where: { $0.role == .response }) {
            references.append(LineReference(range: word.range, target: PartAddress(shape)))
        }
        return LineText(string, references: references)
    }

    func offers(at caret: Int, in line: LineText, reading: LineReading<APIRow>, context: LineContext) -> LineOffers? {
        let words = ColumnGrammar.placedWords(of: line.string)
        let at = words.firstIndex { caret >= $0.range.location && caret <= NSMaxRange($0.range) }
        let index = at ?? words.filter { NSMaxRange($0.range) < caret }.count
        let range = at.map { words[$0].range } ?? NSRange(location: caret, length: 0)
        let typed = at.map { String(words[$0].text.utf16.prefix(caret - words[$0].range.location)) ?? "" } ?? ""
        // At the start: the methods (a path typed there is a header's, and offered nothing).
        if index == 0 {
            guard !typed.hasPrefix("/") else { return nil }
            return LineOffers(range: range, query: typed, items: EndpointGrammar.methods.map { method in
                LineOffer(CaretCompletion(label: method, insert: method + " ", chip: APIStyle.chipFill(method)))
            })
        }
        let word = at.map { words[$0] }
        // A path's segment: the file's tables, and what the API's other paths go on with.
        if let word, word.text.hasPrefix("/"), index == 1, EndpointGrammar.method(words[0].text) != nil {
            return pathOffers(typed, word: word, context)
        }
        let stems = APITypes.stems(ofPath: APITypes.fullPath(reading.row?.endpoint?.path ?? "", in: context))
        let scan = EndpointGrammar.scan(line.string)
        // A body's type, after its bracket: its words, as far as they're typed.
        let bodyWords = scan.words.filter { $0.role == .body }
        if let first = bodyWords.first, let last = bodyWords.last, caret >= first.range.location, caret <= NSMaxRange(last.range) {
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            let typed = (line.string as NSString).substring(with: NSRange(location: range.location, length: caret - range.location))
            return APITypes.offers(typed, range: range, stems: stems, context)
        }
        if let word, word.text.hasPrefix("(") {
            let inner = String(typed.dropFirst())
            let start = word.range.location + 1
            let end = word.text.hasSuffix(")") && word.text.count > 1 ? NSMaxRange(word.range) - 1 : NSMaxRange(word.range)
            guard caret >= start, caret <= end else { return nil }
            return APITypes.offers(inner, range: NSRange(location: start, length: end - start), stems: stems, context)
        }
        // A response's type: after the arrow, past a status; its words, as far as they're typed, quoted where they're several.
        guard let arrow = words.firstIndex(where: { $0.text == EndpointGrammar.arrow || $0.text == EndpointGrammar.typedArrow }),
              caret > NSMaxRange(words[arrow].range) else { return nil }
        var first = arrow + 1
        if first < words.count, EndpointGrammar.isStatus(words[first].text), caret > NSMaxRange(words[first].range) { first += 1 }
        if first >= words.count || caret < words[first].range.location {
            return APITypes.offers("", range: NSRange(location: caret, length: 0), quoting: true, stems: stems, context)
        }
        // The type is one word, or a quoted run: past it, words are no type's.
        let begin = words[first].range.location
        guard caret <= NSMaxRange(words[first].range) else { return nil }
        var query = (line.string as NSString).substring(with: NSRange(location: begin, length: caret - begin))
        var quoted = false
        if let quote = query.first, quote == "\"" || quote == "'" {
            query.removeFirst()
            quoted = true
            // Its closing quote is no letter of the name: `"Refund Request"` names Refund Request.
            if query.last == quote { query.removeLast() }
        }
        guard !EndpointGrammar.isStatusPrefix(query) else { return nil }
        var offers = APITypes.offers(query, range: words[first].range, quoting: true, stems: stems, context)
        // The list sits at the name's first letter, past the opening quote, with the caret before or after the closing one.
        if quoted { offers?.anchor = begin + 1 }
        return offers
    }

    /// What a path's last segment may be, typed so far over `word`: the file's tables by name (each lit while highlighted), then what
    /// the API's other paths go on with past what's typed up to the segment (`refunds/{refundId}`).
    private func pathOffers(_ typed: String, word: (text: String, range: NSRange), _ context: LineContext) -> LineOffers? {
        guard let slash = typed.lastIndex(of: "/") else { return nil }
        let head = String(typed[...slash])
        let segment = String(typed[typed.index(after: slash)...])
        let start = word.range.location + (head as NSString).length
        let range = NSRange(location: start, length: NSMaxRange(word.range) - start)
        let editor = context.editor
        var items: [LineOffer] = []
        var seen: Set<String> = []
        for table in editor.service(KitNames.self)?.tables ?? [] where seen.insert(table.name).inserted {
            items.append(LineOffer(CaretCompletion(label: table.name, detail: APIStyle.tableDetail, insert: table.name), light: PartAddress(table.id)))
        }
        // The API's paths, as written and whole, that go on past what's typed: what's left of each, once.
        var paths: [String] = []
        if let rows = editor.document[context.shape]?.typed(as: API.self)?.props.endpoints {
            for (index, row) in rows.enumerated() where row.id != context.row {
                guard let endpoint = row.endpoint else { continue }
                paths.append(endpoint.path)
                paths.append(APIGroups.fullPath(of: index, in: rows))
            }
        }
        var rests: [String] = []
        for path in paths where path.hasPrefix(head) && path.count > head.count {
            let rest = String(path.dropFirst(head.count))
            if rest != segment, !rests.contains(rest) { rests.append(rest) }
        }
        items += rests.filter { seen.insert($0).inserted }.map { LineOffer(CaretCompletion(label: $0, detail: APIStyle.pathDetail, insert: $0)) }
        return items.isEmpty ? nil : LineOffers(range: range, query: segment, items: items)
    }

    var substitutions: [LineSubstitution] { [LineSubstitution(EndpointGrammar.typedArrow, becomes: EndpointGrammar.arrow)] }

    /// "POST /orders/{id}/refunds, createRefund, deprecated": its full name, then its name, then whether it is retired; a header "/orders, path prefix, 4 endpoints".
    func spoken(_ row: APIRow, in context: LineContext) -> String {
        let rows = context.editor.document[context.shape]?.typed(as: API.self)?.props.endpoints ?? []
        let index = rows.firstIndex { $0.id == row.id }
        switch row {
        case .header(let header):
            let count = index.map { APIGroups.members(of: $0, in: rows) } ?? 0
            return [header.prefix, APIStyle.prefixWord.lowercased(), APIStyle.accessibleRows(count)].joined(separator: ", ")
        case .endpoint(let endpoint):
            let full = index.map { APIGroups.fullName(of: $0, in: rows) } ?? APIGroups.fullName(method: endpoint.method, path: endpoint.path)
            return [full, endpoint.name, endpoint.deprecated ? APIStyle.deprecatedState : ""].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }
}

/// An API's server, its fixed first line: its host in code, how a client signs in after it (a scheme the grammar knows grey);
/// after the host, the schemes offered.
struct ServerLineGrammar: LineGrammar {
    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<APIServer> {
        let words = ColumnGrammar.placedWords(of: line.string)
        guard let server = ServerGrammar.read(line.string) else { return LineReading(row: nil) }
        let spans = words.enumerated().map { index, word in
            LineSpan(word.range, index == 0 ? .code : ServerGrammar.isScheme(word.text) ? .keyword : .plain)
        }
        return LineReading(row: server, spans: spans)
    }

    func print(_ server: APIServer, in context: LineContext) -> LineText { LineText(ServerGrammar.print(server)) }

    func offers(at caret: Int, in line: LineText, reading: LineReading<APIServer>, context: LineContext) -> LineOffers? {
        let words = ColumnGrammar.placedWords(of: line.string)
        let at = words.firstIndex { caret >= $0.range.location && caret <= NSMaxRange($0.range) }
        let index = at ?? words.filter { NSMaxRange($0.range) < caret }.count
        guard index == 1 else { return nil }
        let range = at.map { words[$0].range } ?? NSRange(location: caret, length: 0)
        let typed = at.map { String(words[$0].text.utf16.prefix(caret - words[$0].range.location)) ?? "" } ?? ""
        return LineOffers(range: range, query: typed, items: ServerGrammar.schemes.map { LineOffer(CaretCompletion(label: $0, insert: $0)) })
    }

    func spoken(_ server: APIServer, in context: LineContext) -> String { [server.host, server.auth].filter { !$0.isEmpty }.joined(separator: ", ") }
}

/// An API written as lines: its server, its rows, the grammar, its steps, and its endpoints' cards.
struct APILines: LineModel {
    typealias Props = API
    typealias Row = APIRow

    var noun: LineNoun { LineNoun("endpoint") }
    var headerNoun: LineNoun? { LineNoun("path prefix", plural: "path prefixes") }
    /// As wide as every row's path and pills read whole at rest (`APIDrawing.wholeWidth`, as a pasted API is made): a commit
    /// widens it so.
    func wholeWidth(of props: API, in editor: CanvasEditor) -> CGFloat? { APIDrawing.wholeWidth(of: props.endpoints) }
    var style: LineStyle { APILooks.line }
    func rows(of props: API) -> [APIRow] { props.endpoints }
    func setRows(_ rows: [APIRow], in props: inout API) { props.endpoints = rows }
    func id(of row: APIRow) -> PartID { row.id }
    func role(of row: APIRow) -> LineRole { row.header == nil ? APILooks.endpoint : APILooks.header }
    func roleOfNewRow(at index: Int, in props: API) -> LineRole { APILooks.endpoint }
    func grammar(for role: LineRole) -> any LineGrammar<APIRow> { APILineGrammar() }
    func lineRect(_ line: Int, in frame: CGRect) -> CGRect { APIRows.rowRect(line, in: frame) }
    func isHeader(_ row: APIRow) -> Bool { row.header != nil }
    /// A folded endpoint shows while Find is open for hits in its method or its own path; a hit only in its group's prefix is drawn
    /// on the header, which stays closed (E8 panel 3).
    func peeks(_ row: APIRow, at index: Int, of rows: [APIRow], hitAt ranges: [Range<Int>]) -> Bool {
        guard let text = EndpointText.of(index, in: rows) else { return true }
        return ranges.contains(where: text.isOnRow)
    }
    /// A row under another id: one moved into an API that holds its id already (rows moved as wholes, LineRows' `Moves`).
    func renaming(_ row: APIRow, to id: PartID) -> APIRow {
        switch row {
        case .header(var header):
            header.id = id
            return .header(header)
        case .endpoint(var endpoint):
            endpoint.id = id
            return .endpoint(endpoint)
        }
    }
    var showsCardChevron: Bool { true }

    var fixedLine: LineFixedLine<API>? { Self.server }

    /// Its server: the API's fixed first line.
    private static let server = LineFixedLine<API>(name: APIStyle.serverName, placeholder: APIStyle.serverPlaceholder, stepName: APIStyle.changeServerStep,
                                                   grammar: ServerLineGrammar(), rect: APIRows.serverRect(in:),
                                                   get: { $0.server.isEmpty ? nil : $0.server }, set: { $0.server = $1 ?? APIServer() })

    /// A header's prefix starts after its chevron, and the endpoints under a header as far in.
    func indent(at index: Int, of rows: [APIRow], isNew: Bool) -> CGFloat {
        if !isNew, rows.indices.contains(index), rows[index].header != nil { return APIStyle.memberIndent }
        let above = rows[..<min(max(0, index), rows.count)]
        // An endpoint's method starts where its chip's glyphs do at rest, in from the chip's edge.
        return (above.contains { $0.header != nil } ? APIStyle.memberIndent : 0) + APIStyle.chipPadding
    }

    /// What a line doesn't say stays: an endpoint's name, summary, scope, parameters' types, its responses past the first, deprecated.
    func merged(_ read: APIRow, onto held: APIRow) -> APIRow {
        guard case .endpoint(var line) = read, case .endpoint(let kept) = held else {
            if case .header(var header) = read { header.id = held.id; return .header(header) }
            return read
        }
        line.id = kept.id
        line.name = kept.name
        line.summary = kept.summary
        line.authScope = kept.authScope
        line.parameters = kept.parameters
        line.deprecated = kept.deprecated
        line.responses = Array(line.responses.prefix(1)) + kept.responses.dropFirst()
        return .endpoint(line)
    }

    /// What a change does to the rows, keeping each endpoint's full path where the change isn't about it: a header taken out (or
    /// retyped as an endpoint) leaves its members holding the full paths they had, a header moved takes its group with it, and an
    /// endpoint that leaves every group takes its prefix along. A header retyped as a header is the rename, which every member's
    /// full path follows, as it is typed; an endpoint moved under a header that covers its full path keeps it (so a move back is
    /// exact), and one moved across to another keeps its own path under the new one.
    func applying(_ change: LineChange<APIRow>, to rows: inout [APIRow]) -> Bool {
        let old = rows
        switch change {
        case .add(let added, let index):
            rows.insert(contentsOf: added, at: min(max(0, index), rows.count))
            // A header put in among rows (typed, pasted) heads those after it: each keeps the full path it had, written under it
            // where it covers it, else put where a full path of its own goes, never adopted.
            if added.contains(where: { $0.header != nil }) { rows = APIGroups.regrouped(rows, from: old) }
        case .change(let from, let to):
            guard let at = rows.firstIndex(where: { $0.id == from.id }) else { return false }
            rows[at] = to
            if from.header != nil, to.header == nil { rows = APIGroups.regrouped(rows, from: old, except: [to.id]) }
            // An endpoint retyped as a header heads those after it, as one added there does: each keeps the full path it had.
            if from.header == nil, to.header != nil { rows = APIGroups.regrouped(rows, from: old) }
        case .delete(let gone):
            let ids = Set(gone.map(\.id))
            rows.removeAll { ids.contains($0.id) }
            rows = APIGroups.regrouped(rows, from: old)
        case .move(let row, let index):
            guard let at = rows.firstIndex(where: { $0.id == row.id }) else { return false }
            if row.header != nil {
                // Its group goes with it, past the one it passes; at the first or last, nowhere (written as it was).
                if index != at, let moved = APIGroups.movingGroup(at: at, down: index > at, in: rows) {
                    rows = moved
                } else if index < at, let adopted = APIGroups.adoptingAbove(at: at, in: rows) {
                    // The first header, with endpoints under none above it: up past them, taking the nearest it covers.
                    rows = adopted
                }
                return true
            }
            let was = APIGroups.fullPath(of: at, in: rows)
            let held = rows.remove(at: at)
            let to = min(max(0, index), rows.count)
            rows.insert(held, at: to)
            if case .endpoint(var endpoint) = held, let path = Self.path(of: endpoint, was: was, from: APIGroups.header(of: at, in: old),
                                                                            to: APIGroups.header(of: to, in: rows)) {
                endpoint.path = path
                rows[to] = .endpoint(endpoint)
            }
        }
        return true
    }

    /// Rows pasted, dropped or moved in (a paste in a line, ⌘V of rows, a drag of them from another API), each endpoint's full path
    /// kept: in an API that has headers, an endpoint goes under the longest header its full path starts with, its path as written
    /// under it, else at the top; in one without, where it was wanted. A header that comes with them (its endpoints after it, as
    /// they were under it) goes in whole where a group can stand without taking another's endpoints under it: at the first header
    /// from where it was wanted on, else at the end.
    func placing(pasted made: [APIRow], at index: Int, among rows: [APIRow]) -> [LineChange<APIRow>] {
        let hasHeaders = rows.contains { $0.header != nil }
        let split = made.firstIndex { $0.header != nil } ?? made.count
        guard hasHeaders || split < made.count else { return [.add(made, at: index)] }
        let loose = Array(made[..<split]), group = Array(made[split...])
        let wanted = index < rows.count ? rows[index].id : nil
        var working = rows
        var changes: [LineChange<APIRow>] = []
        if hasHeaders {
            for row in loose {
                guard case .endpoint(var endpoint) = row else { continue }
                let spot = APIGroups.place(endpoint.path, in: working)
                endpoint.path = spot.path
                working.insert(.endpoint(endpoint), at: spot.index)
                changes.append(.add([.endpoint(endpoint)], at: spot.index))
            }
        } else if !loose.isEmpty {
            working.insert(contentsOf: loose, at: min(max(0, index), working.count))
            changes.append(.add(loose, at: min(max(0, index), rows.count)))
        }
        if !group.isEmpty {
            let from = wanted.flatMap { id in working.firstIndex { $0.id == id } } ?? working.count
            let at = working[from...].firstIndex { $0.header != nil } ?? working.count
            changes.append(.add(group, at: at))
        }
        return changes
    }

    /// Rows moved within the API as a block (⌥↑ ⌥↓ on rows selected as items, a drag), each endpoint's path as the line's move
    /// leaves it (`path(of:was:from:to:)`), and one a header landed among or left keeping the full path it had, put back where
    /// its header is if the header it falls under now doesn't cover it.
    func reordering(_ moved: Set<PartID>, to index: Int, in rows: [APIRow]) -> [APIRow] {
        var rest = rows.filter { !moved.contains($0.id) }
        rest.insert(contentsOf: rows.filter { moved.contains($0.id) }, at: min(max(0, index), rest.count))
        var full: [PartID: (path: String, header: PathHeader?)] = [:]
        for (at, row) in rows.enumerated() where moved.contains(row.id) && row.header == nil {
            full[row.id] = (APIGroups.fullPath(of: at, in: rows), APIGroups.header(of: at, in: rows))
        }
        var kept: Set<PartID> = []
        for (at, row) in rest.enumerated() {
            guard case .endpoint(var endpoint) = row, let was = full[row.id] else { continue }
            if let path = Self.path(of: endpoint, was: was.path, from: was.header, to: APIGroups.header(of: at, in: rest)) {
                endpoint.path = path
                rest[at] = .endpoint(endpoint)
            }
            kept.insert(row.id)
        }
        return APIGroups.regrouped(rest, from: rows, except: kept)
    }

    /// The path an endpoint moved from under `from` to under `to` is written with, its full path `was` before; nil to keep it as it
    /// is. Under none now, its whole path (it takes its prefix along); under a header that covers its full path, the rest of it, so
    /// its full path is what it was and a move back is exact; under another header, its own path, as a file moved between folders.
    static func path(of endpoint: Endpoint, was: String, from: PathHeader?, to: PathHeader?) -> String? {
        guard from?.id != to?.id else { return nil }
        guard let to else { return was }
        return APIGroups.fits(was, under: to.prefix) ? APIGroups.relative(was, under: to.prefix) : nil
    }

    /// Endpoints taken out are a new API (⌘X then ⌘V on the board, Move Endpoints to New API, a drag onto the board): served where
    /// this one is, as wide, each endpoint its full path and a header taken with its endpoints still theirs; its name typed at once.
    func takeOut(_ rows: [APIRow], from shape: ShapeRecord<API>) -> API {
        let frame = shape.props.frame
        return API(frame: CGRect(origin: frame.origin, size: CGSize(width: frame.width, height: APIRows.height(lines: rows.count))),
                   server: shape.props.server, endpoints: rows)
    }
    var takeOutEditsTitle: Bool { true }

    /// One endpoint taken out alone is an endpoint of its own (decided 20, E3 panel 4): under its row's id, so what was bound to the
    /// row is bound to it, its path whole, put where the API was, as wide; titled by its name. Several, or a header, are a new API.
    func takeOutShape(_ rows: [APIRow], from shape: ShapeRecord<API>) -> AnyShapeRecord? {
        guard rows.count == 1, let endpoint = rows[0].endpoint else { return nil }
        var alone = StandaloneEndpoint(frame: CGRect(origin: shape.props.frame.origin, size: CGSize(width: shape.props.frame.width, height: 0)),
                                       endpoint: endpoint)
        EndpointDefinition().derive(&alone)
        return AnyShapeRecord(ShapeRecord(alone))
    }

    /// "Take Out Endpoint" for one endpoint alone; the noun's ("Move Endpoints to New API") for more.
    func takeOutStep(of rows: [APIRow]) -> String? {
        rows.count == 1 && rows[0].endpoint != nil ? EndpointStyle.takeOutStep : nil
    }

    /// An endpoint standing alone, dropped on an API or pasted in one, is its row again.
    func takesRows(of kind: ShapeKind) -> Bool { kind == StandaloneEndpoint.kind }

    func rows(taken record: AnyShapeRecord) -> [APIRow]? {
        record.typed(as: StandaloneEndpoint.self).map { [.endpoint($0.props.endpoint)] }
    }

    /// An endpoint's chip's click: its method menu, the method it has checked (E5 panel 2).
    func leadAction(of row: APIRow, at index: Int, among rows: [APIRow], in context: LineContext) -> LineLeadAction? {
        guard case .endpoint(let endpoint) = row else { return nil }
        return EndpointMethods.leadAction(endpoint, of: context.shape)
    }

    /// An endpoint's lead is its method chip (decided 21): a press there drags the row, selected or not. A header has none.
    func lead(of row: APIRow, at index: Int, among rows: [APIRow], line: CGRect, in context: LineContext) -> CGRect? {
        guard case .endpoint(let endpoint) = row else { return nil }
        return APIDrawing.chipRect(endpoint.method, member: APIGroups.isMember(index, in: rows), in: line)
    }

    /// "Endpoint 3 of 7", "Path prefix 1 of 2": each counted among its own.
    func accessibleLabel(of row: APIRow, at index: Int, among rows: [APIRow]) -> String {
        let isHeader = row.header != nil
        let place = rows[..<min(index, rows.count)].filter { ($0.header != nil) == isHeader }.count + 1
        let total = rows.filter { ($0.header != nil) == isHeader }.count
        let said = "\(isHeader ? APIStyle.prefixWord : noun.title) \(place) of \(total)"
        return row.endpoint?.deprecated == true ? "\(said), \(APIStyle.deprecatedState)" : said
    }

    /// Add Endpoint (Add Path Prefix for a header), Paste Endpoints (Paste Path Prefixes, every row a header), Change Method (the
    /// method alone changed), Rename Path Prefix (a header retyped), Change Endpoint, Delete Endpoint (Delete Path Prefix, and Delete
    /// Endpoints or Delete Path Prefixes for several, as `headerNoun` names a block of headers), Move Endpoint.
    func stepName(of change: LineChange<APIRow>) -> String {
        switch change {
        case .add(let rows, _):
            rows.count == 1 ? (rows[0].header == nil ? APIStyle.addEndpointStep : APIStyle.addPrefixStep)
                : rows.allSatisfy({ $0.header != nil }) ? APIStyle.pastePrefixesStep : APIStyle.pasteEndpointsStep
        case .change(let from, let to):
            switch (from, to) {
            case (.header, .header): APIStyle.renamePrefixStep
            case (.endpoint, .header): APIStyle.addPrefixStep
            case (.endpoint(let was), .endpoint(let now)) where Self.onlyMethod(was, now): APIStyle.changeMethodStep
            case (.endpoint(let was), .endpoint(let now)) where Self.onlyDeprecated(was, now):
                now.deprecated ? APIStyle.deprecateStep : APIStyle.undeprecateStep
            default: APIStyle.changeEndpointStep
            }
        case .delete(let rows):
            rows.count == 1 ? (rows[0].header == nil ? APIStyle.deleteEndpointStep : APIStyle.deletePrefixStep)
                : rows.allSatisfy({ $0.header != nil }) ? APIStyle.deletePrefixesStep : APIStyle.deleteEndpointsStep
        case .move(let row, _): row.header == nil ? APIStyle.moveEndpointStep : APIStyle.movePrefixStep
        }
    }

    /// Whether `now` is `was` with only whether it's deprecated changed (the card's toggle).
    static func onlyDeprecated(_ was: Endpoint, _ now: Endpoint) -> Bool {
        var changed = was
        changed.deprecated = now.deprecated
        return changed == now && was.deprecated != now.deprecated
    }

    /// Whether `now` is `was` with only its method changed.
    static func onlyMethod(_ was: Endpoint, _ now: Endpoint) -> Bool {
        var changed = was
        changed.method = now.method
        return changed == now && was.method != now.method
    }

    /// An endpoint's card (⌘↓, or the "›" on its row): its name (operationId), summary, auth scope, each path parameter's type, its
    /// body, its responses a line each, and deprecated. A header has none.
    func card(of row: APIRow, in context: LineContext) -> LineCard<APIRow>? {
        guard case .endpoint(let endpoint) = row else { return nil }
        let rows = context.editor.document[context.shape]?.typed(as: API.self)?.props.endpoints ?? []
        let held = rows.firstIndex { $0.id == row.id }
        let full = held.map { APIGroups.fullName(of: $0, in: rows) } ?? APIGroups.fullName(method: endpoint.method, path: endpoint.path)
        // Its parameters are its full path's, its header's prefix's too (`/{workspace}`): each a line, in the path's order.
        let path = held.map { APIGroups.fullPath(of: $0, in: rows) } ?? endpoint.path
        var lines: [LineCardLine<APIRow>] = [
            .field(APIStyle.nameLine, grammar: WordsGrammar(), get: { row, _ in row.endpoint.flatMap { $0.name.isEmpty ? nil : $0.name } },
                   set: { row, value, _ in row = Self.changing(row) { $0.name = value ?? "" } }),

            .field(APIStyle.summaryLine, grammar: WordsGrammar(), get: { row, _ in row.endpoint.flatMap { $0.summary.isEmpty ? nil : $0.summary } },
                   set: { row, value, _ in row = Self.changing(row) { $0.summary = value ?? "" } }),
            .field(APIStyle.authLine, grammar: WordsGrammar(code: true), get: { row, _ in row.endpoint.flatMap { $0.authScope.isEmpty ? nil : $0.authScope } },
                   set: { row, value, _ in row = Self.changing(row) { $0.authScope = value ?? "" } }),
        ]
        for name in EndpointGrammar.parameterNames(in: path) {
            lines.append(.field("{\(name)}", grammar: WordsGrammar(code: true),
                                get: { row, _ in row.endpoint?.parameters.first { $0.name == name }.flatMap { $0.type.isEmpty ? nil : $0.type } },
                                set: { row, value, _ in row = Self.changing(row) { Self.setParameter(name, to: value, in: &$0, path: path) } }))
        }
        lines += [
            .field(APIStyle.bodyLine, grammar: TypeNameGrammar(), get: { row, _ in row.endpoint?.body },
                   set: { row, value, _ in row = Self.changing(row) { $0.body = value } }),
            .list(APIStyle.responsesLine, grammar: ResponseGrammar(), get: { row, _ in row.endpoint?.responses ?? [] },
                  set: { row, value, _ in row = Self.changing(row) { $0.responses = value } }),
            // Its method, one of the five (and the one it has, if another): Space opens them, the current checked; "Change Method".
            .choice(APIStyle.methodLine, options: EndpointMethods.options(current: endpoint.method), get: { $0.endpoint?.method },
                    set: { row, method in row = Self.changing(row) { $0.method = method } }),
            // Space: "Deprecate Endpoint" (E5 panel 3), the row's chip hollow and its words faint.
            .toggle(APIStyle.deprecatedLine, get: { $0.endpoint?.deprecated ?? false }, set: { row, on in row = Self.changing(row) { $0.deprecated = on } }),
            // Its connections, a line each (`writes refunds`): each its arrow, written in a step of the line's own.
            .list(APIStyle.connectionsLine, grammar: EndpointLinkGrammar(),
                  get: { row, context in EndpointLinks.shown(row.id, of: context.shape, in: context.editor) },
                  writing: { links, unread, row, context in EndpointLinks.write(links, unreadLines: unread, for: row.id, of: context.shape, in: context.editor) }),
        ]
        return LineCard(header: LineCardHeader(name: full), lines: lines, width: APIStyle.cardWidth)
    }

    /// `row`, an endpoint, changed by `change`; a header as it is.
    static func changing(_ row: APIRow, _ change: (inout Endpoint) -> Void) -> APIRow {
        guard case .endpoint(var endpoint) = row else { return row }
        change(&endpoint)
        return .endpoint(endpoint)
    }

    /// A path parameter's type set (none: taken out), the parameters kept in the order of `path`, the endpoint's full path (its own
    /// where it's under no header).
    static func setParameter(_ name: String, to type: String?, in endpoint: inout Endpoint, path: String? = nil) {
        // The first of that name only: a query parameter that shares it (a card shows the path's) stays.
        if let at = endpoint.parameters.firstIndex(where: { $0.name == name }) { endpoint.parameters.remove(at: at) }
        guard let type, !type.isEmpty else { return }
        endpoint.parameters.append(PathParameter(name: name, type: type))
        let order = EndpointGrammar.parameterNames(in: path ?? endpoint.path)
        endpoint.parameters.sort { (order.firstIndex(of: $0.name) ?? .max) < (order.firstIndex(of: $1.name) ?? .max) }
    }
}

/// Where an API's lines are, world units: the server's band at the top, then its rows, 24 apart, as a table's are.
@MainActor
enum APIRows {
    /// The server's line on paper at `frame`.
    static func serverRect(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY + KitStyle.topInset, width: frame.width, height: KitStyle.rowHeight)
    }

    /// The paper the rows are on: below the server's band.
    static func rowsFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY + APIStyle.serverBand, width: frame.width, height: max(0, frame.height - APIStyle.serverBand))
    }

    /// Line `line`'s rect on paper at `frame`.
    static func rowRect(_ line: Int, in frame: CGRect) -> CGRect { KitStyle.rowRect(line, in: rowsFrame(frame)) }

    /// How tall an API of `lines` lines is.
    static func height(lines: Int) -> CGFloat { APIStyle.serverBand + KitStyle.height(rows: lines) }
}

/// How an API's lines look while typed: code, as at rest, so nothing moves as editing starts.
@MainActor
enum APILooks {
    static let endpoint: LineRole = "endpoint"
    static let header: LineRole = "header"

    /// The band behind the row with the caret lets the paper's drawing under it through: a header keeps its chevron and count
    /// while its prefix is typed (E5 panel 1).
    static let line: LineStyle = {
        var style = LineStyle(font: KitStyle.codeFont, codeFont: KitStyle.codeFont, ink: NSColor(KitStyle.ink),
                              secondaryInk: NSColor(KitStyle.secondaryInk), textInset: APIStyle.inset,
                              trailingInset: KitStyle.trailingInset, gutterMiddle: APIStyle.inset / 2, markSize: KitStyle.markSize,
                              band: LineStyle.defaultBand.withAlphaComponent(APIStyle.bandAlpha))
        style.chipFont = KitStyle.chipFont
        return style
    }()
}

/// The kit's API grammars, for what reads a line as typing does (a test's corpus).
@MainActor
public enum EngineeringAPILines {
    /// An endpoint's or a header's line.
    public static var rows: any LineGrammar<APIRow> { APILineGrammar() }
    /// An API's server line.
    public static var server: any LineGrammar<APIServer> { ServerLineGrammar() }
    /// An endpoint's connection line, in its card: `writes refunds`, `calls Stripe API.POST /v1/refunds`.
    public static var links: any LineGrammar<EndpointLink> { EndpointLinkGrammar() }
}

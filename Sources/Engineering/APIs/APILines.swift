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
        for word in scan.words {
            switch word.role {
            case .method: spans.append(LineSpan(word.range, .chip(APIStyle.chipFill(method), ink: APIStyle.chipInk)))
            case .path: spans += Self.pathSpans(word.range, parameters: scan.parameters, method: method, isHeader: row.header != nil)
            case .bracket, .arrow, .status: spans.append(LineSpan(word.range, .keyword))
            case .body:
                body = APITypes.bound(word.text, at: word.range, in: line, near: context.shape, editor)
                spans.append(LineSpan(word.range, APITypes.look(of: body, editor, onPaper: true)))
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
        if let body = endpoint.body { endpoint.body?.words = APITypes.printed(body, editor) }
        if let type = endpoint.responses.first?.type { endpoint.responses[0].type?.words = APITypes.printed(type, editor) }
        let string = EndpointGrammar.print(endpoint)
        var references: [LineReference] = []
        for word in EndpointGrammar.scan(string).words {
            let shape: ShapeID? = switch word.role {
            case .body: endpoint.body?.shape
            case .response: endpoint.responses.first?.type?.shape
            default: nil
            }
            if let shape { references.append(LineReference(range: word.range, target: PartAddress(shape))) }
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
        guard let at else { return nil }
        let word = words[at]
        // A path's segment: the file's tables, and what the API's other paths go on with.
        if word.text.hasPrefix("/"), index == 1, EndpointGrammar.method(words[0].text) != nil {
            return pathOffers(typed, word: word, context)
        }
        // A body's type, after its bracket.
        if word.text.hasPrefix("(") {
            let inner = String(typed.dropFirst())
            let start = word.range.location + 1
            let end = word.text.hasSuffix(")") && word.text.count > 1 ? NSMaxRange(word.range) - 1 : NSMaxRange(word.range)
            guard caret >= start, caret <= end else { return nil }
            return APITypes.offers(inner, range: NSRange(location: start, length: end - start), context)
        }
        // A response's type: after the arrow, past a status.
        let before = words.prefix(index).map(\.text)
        if let arrow = before.lastIndex(where: { $0 == EndpointGrammar.arrow || $0 == EndpointGrammar.typedArrow }) {
            let after = before[(arrow + 1)...]
            guard after.isEmpty || (after.count == 1 && EndpointGrammar.isStatus(after.first!)), !EndpointGrammar.isStatus(typed) else { return nil }
            return APITypes.offers(typed, range: range, context)
        }
        return nil
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

    /// "POST /orders/{id}/refunds, createRefund": its full name, then its name; a header "/orders, path prefix, 4 endpoints".
    func spoken(_ row: APIRow, in context: LineContext) -> String {
        let rows = context.editor.document[context.shape]?.typed(as: API.self)?.props.endpoints ?? []
        let index = rows.firstIndex { $0.id == row.id }
        switch row {
        case .header(let header):
            let count = index.map { APIGroups.members(of: $0, in: rows) } ?? 0
            return [header.prefix, APIStyle.prefixWord.lowercased(), APIStyle.accessibleRows(count)].joined(separator: ", ")
        case .endpoint(let endpoint):
            let full = index.map { APIGroups.fullName(of: $0, in: rows) } ?? APIGroups.fullName(method: endpoint.method, path: endpoint.path)
            return [full, endpoint.name].filter { !$0.isEmpty }.joined(separator: ", ")
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
    var style: LineStyle { APILooks.line }
    func rows(of props: API) -> [APIRow] { props.endpoints }
    func setRows(_ rows: [APIRow], in props: inout API) { props.endpoints = rows }
    func id(of row: APIRow) -> PartID { row.id }
    func role(of row: APIRow) -> LineRole { row.header == nil ? APILooks.endpoint : APILooks.header }
    func roleOfNewRow(at index: Int, in props: API) -> LineRole { APILooks.endpoint }
    func grammar(for role: LineRole) -> any LineGrammar<APIRow> { APILineGrammar() }
    func lineRect(_ line: Int, in frame: CGRect) -> CGRect { APIRows.rowRect(line, in: frame) }
    func isHeader(_ row: APIRow) -> Bool { row.header != nil }
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
        return above.contains { $0.header != nil } ? APIStyle.memberIndent : 0
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

    /// Add Endpoint (Add Path Prefix for a header), Paste Endpoints, Change Method (the method alone changed), Rename Path Prefix (a
    /// header retyped), Change Endpoint, Delete Endpoint, Move Endpoint.
    func stepName(of change: LineChange<APIRow>) -> String {
        switch change {
        case .add(let rows, _):
            rows.count == 1 ? (rows[0].header == nil ? APIStyle.addEndpointStep : APIStyle.addPrefixStep) : APIStyle.pasteEndpointsStep
        case .change(let from, let to):
            switch (from, to) {
            case (.header, .header): APIStyle.renamePrefixStep
            case (.endpoint(let was), .endpoint(let now)) where Self.onlyMethod(was, now): APIStyle.changeMethodStep
            default: APIStyle.changeEndpointStep
            }
        case .delete(let rows):
            rows.count == 1 ? (rows[0].header == nil ? APIStyle.deleteEndpointStep : APIStyle.deletePrefixStep) : APIStyle.deleteEndpointsStep
        case .move(let row, _): row.header == nil ? APIStyle.moveEndpointStep : APIStyle.movePrefixStep
        }
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
        let full = rows.firstIndex { $0.id == row.id }.map { APIGroups.fullName(of: $0, in: rows) }
            ?? APIGroups.fullName(method: endpoint.method, path: endpoint.path)
        var lines: [LineCardLine<APIRow>] = [
            .field(APIStyle.nameLine, grammar: WordsGrammar(), get: { row, _ in row.endpoint.flatMap { $0.name.isEmpty ? nil : $0.name } },
                   set: { row, value, _ in row = Self.changing(row) { $0.name = value ?? "" } }),
            .field(APIStyle.summaryLine, grammar: WordsGrammar(), get: { row, _ in row.endpoint.flatMap { $0.summary.isEmpty ? nil : $0.summary } },
                   set: { row, value, _ in row = Self.changing(row) { $0.summary = value ?? "" } }),
            .field(APIStyle.authLine, grammar: WordsGrammar(code: true), get: { row, _ in row.endpoint.flatMap { $0.authScope.isEmpty ? nil : $0.authScope } },
                   set: { row, value, _ in row = Self.changing(row) { $0.authScope = value ?? "" } }),
        ]
        for name in EndpointGrammar.parameterNames(in: endpoint.path) {
            lines.append(.field("{\(name)}", grammar: WordsGrammar(code: true),
                                get: { row, _ in row.endpoint?.parameters.first { $0.name == name }.flatMap { $0.type.isEmpty ? nil : $0.type } },
                                set: { row, value, _ in row = Self.changing(row) { Self.setParameter(name, to: value, in: &$0) } }))
        }
        lines += [
            .field(APIStyle.bodyLine, grammar: TypeNameGrammar(), get: { row, _ in row.endpoint?.body },
                   set: { row, value, _ in row = Self.changing(row) { $0.body = value } }),
            .list(APIStyle.responsesLine, grammar: ResponseGrammar(), get: { row, _ in row.endpoint?.responses ?? [] },
                  set: { row, value, _ in row = Self.changing(row) { $0.responses = value } }),
            .toggle(APIStyle.deprecatedLine, get: { $0.endpoint?.deprecated ?? false }, set: { row, on in row = Self.changing(row) { $0.deprecated = on } }),
        ]
        return LineCard(header: LineCardHeader(name: full), lines: lines)
    }

    /// `row`, an endpoint, changed by `change`; a header as it is.
    static func changing(_ row: APIRow, _ change: (inout Endpoint) -> Void) -> APIRow {
        guard case .endpoint(var endpoint) = row else { return row }
        change(&endpoint)
        return .endpoint(endpoint)
    }

    /// A path parameter's type set (none: taken out).
    static func setParameter(_ name: String, to type: String?, in endpoint: inout Endpoint) {
        endpoint.parameters.removeAll { $0.name == name }
        guard let type, !type.isEmpty else { return }
        endpoint.parameters.append(PathParameter(name: name, type: type))
        let order = EndpointGrammar.parameterNames(in: endpoint.path)
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
    static let line = LineStyle(font: KitStyle.codeFont, codeFont: KitStyle.codeFont, ink: NSColor(KitStyle.ink),
                                secondaryInk: NSColor(KitStyle.secondaryInk), textInset: APIStyle.inset,
                                trailingInset: KitStyle.trailingInset, gutterMiddle: APIStyle.inset / 2, markSize: KitStyle.markSize,
                                band: LineStyle.defaultBand.withAlphaComponent(APIStyle.bandAlpha))
}

/// The kit's API grammars, for what reads a line as typing does (a test's corpus).
@MainActor
public enum EngineeringAPILines {
    /// An endpoint's or a header's line.
    public static var rows: any LineGrammar<APIRow> { APILineGrammar() }
    /// An API's server line.
    public static var server: any LineGrammar<APIServer> { ServerLineGrammar() }
}

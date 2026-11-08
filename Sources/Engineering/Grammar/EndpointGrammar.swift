import Canvas
import Foundation

// An API's lines: an endpoint written `METHOD /path/{param} [(Body)] [→ [status] [Response]]`, each bracketed part left out
// as it may be; a path-prefix header written as a path alone; and the API's fixed first line, its server, `host[/path] [bearer
// | basic | apikey NAME | oauth2]`. One reader and one printer each, pure, shared by typing, a pasted block and `canvas draw`'s
// `endpoints:` and `server:`. Words a grammar can't place stay in the row (`unread`), shown plain, never marked; printing what
// was read loses no word. And the grouping every writer of full paths shares (`APIGroups`): a group is a header and the
// endpoints after it, an endpoint's full path its header's prefix and its own path.

/// The endpoint grammar's reader and printer: an API's row as a line, an endpoint or a header.
public enum EndpointGrammar {
    /// The methods a line starts with, as printed: any case reads.
    public static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE"]
    /// What a response follows.
    public static let arrow = ColumnGrammar.arrow
    static let typedArrow = ColumnGrammar.typedArrow

    /// What each word of an API's line is.
    public enum WordRole: Hashable, Sendable {
        /// Its method.
        case method
        /// Its path (a header's prefix too).
        case path
        /// The body's brackets.
        case bracket
        /// The body's type.
        case body
        /// The arrow a response follows.
        case arrow
        /// A response's status.
        case status
        /// A response's type.
        case response
        /// Words nothing reads, kept as written.
        case unread
    }

    /// A word of a line and what it is (UTF-16).
    public struct Word: Hashable, Sendable {
        public var role: WordRole
        public var range: NSRange
        public var text: String
    }

    /// A line read: the row it says (nil for a line with nothing on it), each word's role and place, and where the path's
    /// parameters are (`{id}`, braces included).
    public struct Scan: Sendable {
        public var row: APIRow?
        public var words: [Word]
        public var parameters: [NSRange]
    }

    /// The row a line says, its id `id`; nil for a line with nothing on it.
    public static func read(_ line: String, id: PartID = PartID()) -> APIRow? { scan(line, id: id).row }

    /// Whether a word is a method's, in any case.
    public static func method(_ word: String) -> String? {
        let upper = word.uppercased()
        return methods.contains(upper) ? upper : nil
    }

    /// Whether a word is a response's status: three characters, a digit then digits or X (`201`, `4XX`), or `default`.
    public static func isStatus(_ word: String) -> Bool {
        if word.lowercased() == "default" { return true }
        let characters = Array(word.uppercased())
        guard characters.count == 3, let first = characters.first, ("1"..."5").contains(first) else { return false }
        return characters.dropFirst().allSatisfy { $0.isASCII && ($0.isNumber || $0 == "X") }
    }

    /// Whether a word typed after a response's arrow is, so far, a status (`2`, `20`, `201`, `4X`, `de`): what isn't yet a type's.
    public static func isStatusPrefix(_ word: String) -> Bool {
        let characters = Array(word.uppercased())
        if let first = characters.first, ("1"..."5").contains(first), characters.count <= 3 {
            return characters.dropFirst().allSatisfy { $0.isASCII && ($0.isNumber || $0 == "X") }
        }
        return characters.count >= 2 && "default".hasPrefix(word.lowercased())
    }

    /// Reads a line as `read` does, saying too what each word is and where.
    public static func scan(_ line: String, id: PartID = PartID()) -> Scan {
        let words = ColumnGrammar.placedWords(of: line).map { (text: $0.text, range: $0.range) }
        guard let first = words.first else { return Scan(row: nil, words: [], parameters: []) }
        var roles: [Word] = []
        var index = 0
        var endpoint = Endpoint(id: id, method: "", path: "")
        if let method = method(first.text) {
            endpoint.method = method
            roles.append(Word(role: .method, range: first.range, text: first.text))
            index = 1
        } else if words.count == 1, first.text.hasPrefix("/") {
            // A path alone, no method: a header.
            return Scan(row: .header(PathHeader(id: id, prefix: first.text)), words: [Word(role: .path, range: first.range, text: first.text)],
                        parameters: parameters(in: first.text, at: first.range.location))
        }
        var parameterRanges: [NSRange] = []
        if index < words.count, words[index].text.hasPrefix("/") {
            endpoint.path = words[index].text
            roles.append(Word(role: .path, range: words[index].range, text: words[index].text))
            parameterRanges = parameters(in: words[index].text, at: words[index].range.location)
            index += 1
        }
        // A body: from a word that opens a bracket to the one that closes it.
        if index < words.count, words[index].text.hasPrefix("(") {
            // A bracket left open runs to the arrow (or the line's end): a type's name of several words, typed so far.
            let arrowAt = words[(index + 1)...].firstIndex { $0.text == arrow || $0.text == typedArrow }
            let close = words[index...].firstIndex(where: { $0.text.hasSuffix(")") }) ?? arrowAt.map { $0 - 1 } ?? words.count - 1
            let run = words[index...close]
            let text = run.map(\.text).joined(separator: " ")
            let inner = String(text.dropFirst().dropLast(text.hasSuffix(")") && text.count > 1 ? 1 : 0)).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty {
                endpoint.body = TypeRef(inner)
                roles += bodyWords(run)
                index = close + 1
            }
        }
        // A response: the arrow, then a status, a type, or both.
        if index < words.count, words[index].text == arrow || words[index].text == typedArrow, index + 1 < words.count,
           words[index + 1].text != arrow, words[index + 1].text != typedArrow {
            roles.append(Word(role: .arrow, range: words[index].range, text: words[index].text))
            index += 1
            var response = EndpointResponse(status: "")
            if isStatus(words[index].text) {
                response.status = words[index].text
                roles.append(Word(role: .status, range: words[index].range, text: words[index].text))
                index += 1
            }
            if index < words.count, words[index].text != arrow, words[index].text != typedArrow, !words[index].text.hasPrefix("(") {
                // A type's name of several words is quoted; the quotes aren't its name's.
                let (name, range) = unquoted(words[index])
                response.type = TypeRef(name)
                roles.append(Word(role: .response, range: range, text: name))
                index += 1
            }
            endpoint.responses = [response]
        }
        let rest = words[index...]
        endpoint.unread = rest.map { $0.text == typedArrow ? arrow : $0.text }.joined(separator: " ")
        roles += rest.map { Word(role: .unread, range: $0.range, text: $0.text) }
        return Scan(row: .endpoint(endpoint), words: roles, parameters: parameterRanges)
    }

    /// A word without the quotes round it, and where what's left is; the word as it is without them.
    static func unquoted(_ word: (text: String, range: NSRange)) -> (text: String, range: NSRange) {
        guard word.text.count > 2, let quote = word.text.first, quote == "\"" || quote == "'", word.text.last == quote else { return word }
        return (String(word.text.dropFirst().dropLast()), NSRange(location: word.range.location + 1, length: word.range.length - 2))
    }

    /// A type's name as a line writes it: quoted where it's more than one word, so the line reads back the name whole.
    static func written(_ type: String) -> String {
        guard type.contains(where: \.isWhitespace) else { return type }
        let quote = type.contains("\"") ? "'" : "\""
        return quote + type + quote
    }

    /// A body's words: its brackets and the type between them, each where it is.
    private static func bodyWords(_ run: ArraySlice<(text: String, range: NSRange)>) -> [Word] {
        var words: [Word] = []
        for (offset, word) in run.enumerated() {
            var start = word.range.location, end = NSMaxRange(word.range)
            var text = word.text
            if offset == 0, text.hasPrefix("(") {
                words.append(Word(role: .bracket, range: NSRange(location: start, length: 1), text: "("))
                start += 1
                text.removeFirst()
            }
            var closing: Word?
            if offset == run.count - 1, text.hasSuffix(")") {
                end -= 1
                text.removeLast()
                closing = Word(role: .bracket, range: NSRange(location: end, length: 1), text: ")")
            }
            if end > start { words.append(Word(role: .body, range: NSRange(location: start, length: end - start), text: text)) }
            if let closing { words.append(closing) }
        }
        return words
    }

    /// Where a path's parameters are (`{id}`, braces included), UTF-16 from `start`.
    public static func parameters(in path: String, at start: Int = 0) -> [NSRange] {
        let text = path as NSString
        var ranges: [NSRange] = []
        var at = 0
        while at < text.length {
            let open = text.range(of: "{", options: [], range: NSRange(location: at, length: text.length - at))
            guard open.location != NSNotFound else { break }
            let close = text.range(of: "}", options: [], range: NSRange(location: open.location, length: text.length - open.location))
            guard close.location != NSNotFound else { break }
            ranges.append(NSRange(location: start + open.location, length: NSMaxRange(close) - open.location))
            at = NSMaxRange(close)
        }
        return ranges
    }

    /// A path's parameters' names, in order, without their braces: `id`, `itemId`.
    public static func parameterNames(in path: String) -> [String] {
        let text = path as NSString
        return parameters(in: path).map { text.substring(with: NSRange(location: $0.location + 1, length: $0.length - 2)) }
    }

    /// A row printed as its line reads: a header its prefix; an endpoint `METHOD /path (Body) → status Response unread`, what it
    /// has, its first response only (the rest are its card's).
    public static func print(_ row: APIRow) -> String {
        switch row {
        case .header(let header): return header.prefix
        case .endpoint(let endpoint): return print(endpoint)
        }
    }

    public static func print(_ endpoint: Endpoint) -> String {
        var words: [String] = []
        if !endpoint.method.isEmpty { words.append(endpoint.method) }
        if !endpoint.path.isEmpty { words.append(endpoint.path) }
        if let body = endpoint.body, !body.words.isEmpty { words.append("(\(body.words))") }
        if let response = endpoint.responses.first, !response.status.isEmpty || response.type.map({ !$0.words.isEmpty }) == true {
            words.append(arrow)
            if !response.status.isEmpty { words.append(response.status) }
            if let type = response.type, !type.words.isEmpty { words.append(written(type.words)) }
        }
        if !endpoint.unread.isEmpty { words.append(endpoint.unread) }
        return words.joined(separator: " ")
    }

    /// The rows of a block, one a line, blank lines left out, each a new id.
    public static func read(lines text: String) -> [APIRow] {
        text.split(whereSeparator: \.isNewline).compactMap { read(String($0)) }
    }
}

/// The server grammar: an API's first line, `host[/path] [bearer | basic | apikey NAME | oauth2]`. Its first word is the host,
/// the rest how a client signs in, as written (a scheme it doesn't know too: no word is lost).
public enum ServerGrammar {
    /// The ways a client signs in a line names: `apikey` takes the name of its header after it.
    public static let schemes = ["bearer", "basic", "apikey", "oauth2"]

    /// The server a line says; nil for a line with nothing on it.
    public static func read(_ line: String) -> APIServer? {
        let words = ColumnGrammar.placedWords(of: line).map(\.text)
        guard let host = words.first else { return nil }
        return APIServer(host: host, auth: words.dropFirst().joined(separator: " "))
    }

    public static func print(_ server: APIServer) -> String {
        [server.host, server.auth].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whether a word is a scheme's, in any case.
    public static func isScheme(_ word: String) -> Bool { schemes.contains(word.lowercased()) }
}

/// How an API's rows group: a header heads the endpoints after it, up to the next header, and an endpoint's full path is its
/// header's prefix with its own path joined on (`/orders` and `/{id}` is `/orders/{id}`; `/` alone under it is `/orders`). What
/// every writer of full paths shares (`canvas draw`'s `endpoints:`, later a paste of OpenAPI and Group by Prefix): a full path goes
/// under the longest header it starts with, else at the top.
public enum APIGroups {
    /// `prefix` and `path` joined: one slash between, `/` alone (or nothing) the prefix itself.
    public static func joined(_ prefix: String, _ path: String) -> String {
        guard !prefix.isEmpty else { return path }
        if path.isEmpty || path == "/" { return prefix }
        let head = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return path.hasPrefix("/") ? head + path : head + "/" + path
    }

    /// The header row `index` is under: the nearest one above it; nil for one under none (and a header itself).
    public static func header(of index: Int, in rows: [APIRow]) -> PathHeader? {
        guard rows.indices.contains(index), rows[index].header == nil else { return nil }
        for row in rows[..<index].reversed() {
            if let header = row.header { return header }
        }
        return nil
    }

    /// Row `index`'s full path: its header's prefix and its own path; a header's, its prefix.
    public static func fullPath(of index: Int, in rows: [APIRow]) -> String {
        guard rows.indices.contains(index) else { return "" }
        switch rows[index] {
        case .header(let header): return header.prefix
        case .endpoint(let endpoint): return joined(header(of: index, in: rows)?.prefix ?? "", endpoint.path)
        }
    }

    /// Every row's full path, in order: one pass, each header's prefix carried along, never found again for each row (what
    /// `fullPath(of:in:)` does for one). What agents' answers over a large API read (`:route`, `--ask`'s `<apis>`).
    public static func fullPaths(in rows: [APIRow]) -> [String] {
        var prefix = "", paths: [String] = []
        paths.reserveCapacity(rows.count)
        for row in rows {
            switch row {
            case .header(let header):
                prefix = header.prefix
                paths.append(prefix)
            case .endpoint(let endpoint):
                paths.append(joined(prefix, endpoint.path))
            }
        }
        return paths
    }

    /// The full name of the row with the id `part`, in one pass; nil for none: what a connection's end bound to a row says in a
    /// query's answer, for as many ends as the answer has.
    public static func fullName(ofRow part: PartID, in rows: [APIRow]) -> String? {
        var prefix = ""
        for row in rows {
            switch row {
            case .header(let header):
                prefix = header.prefix
                if header.id == part { return prefix }
            case .endpoint(let endpoint):
                if endpoint.id == part { return fullName(method: endpoint.method, path: joined(prefix, endpoint.path)) }
            }
        }
        return nil
    }

    /// What an endpoint is called wherever it's listed (a pill, Find, the picker, agents): `POST /orders/{id}/refunds`.
    public static func fullName(method: String, path: String) -> String {
        [method, path].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Row `index`'s full name: an endpoint's method and full path, a header's prefix.
    public static func fullName(of index: Int, in rows: [APIRow]) -> String {
        guard rows.indices.contains(index) else { return "" }
        return fullName(method: rows[index].endpoint?.method ?? "", path: fullPath(of: index, in: rows))
    }

    /// Whether `path` is `prefix` or under it, by whole segments (`/orders/{id}` is under `/orders`; `/ordersX` isn't).
    public static func isUnder(_ path: String, _ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        let head = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return path == head || path.hasPrefix(head + "/")
    }

    /// `path` as written under `prefix`: what's left past it (`/{id}`), `/` for the prefix itself.
    public static func relative(_ path: String, under prefix: String) -> String {
        let head = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        guard isUnder(path, prefix) else { return path }
        let rest = String(path.dropFirst(head.count))
        return rest.isEmpty ? "/" : rest
    }

    /// The index of the header a full path goes under: the longest prefix it's under; nil for none.
    public static func longestHeader(for path: String, in rows: [APIRow]) -> Int? {
        var best: (index: Int, length: Int)?
        for (index, row) in rows.enumerated() {
            guard let header = row.header, isUnder(path, header.prefix) else { continue }
            if best == nil || header.prefix.count > best!.length { best = (index, header.prefix.count) }
        }
        return best?.index
    }

    /// Where a new endpoint of full path `path` goes among `rows`, and its path as written there: at the end of the group of the
    /// longest header it's under, relative to it; else at the top, after the endpoints under no header, its path whole.
    public static func place(_ path: String, in rows: [APIRow]) -> (index: Int, path: String) {
        if let header = longestHeader(for: path, in: rows), let prefix = rows[header].header?.prefix {
            let end = rows[(header + 1)...].firstIndex { $0.header != nil } ?? rows.count
            return (end, relative(path, under: prefix))
        }
        return (rows.firstIndex { $0.header != nil } ?? rows.count, path)
    }

    /// The index of the endpoint of `method` and full path `path`; nil for none. What a writer of full paths joins by. One pass: each
    /// header's prefix carried along, never found again for each row.
    public static func index(of method: String, _ path: String, in rows: [APIRow]) -> Int? {
        var prefix = ""
        for (index, row) in rows.enumerated() {
            switch row {
            case .header(let header): prefix = header.prefix
            case .endpoint(let endpoint): if endpoint.method == method, joined(prefix, endpoint.path) == path { return index }
            }
        }
        return nil
    }

    /// `rows`, after a change to what were `old`, with each endpoint whose header the change took away, or put another in its
    /// place, holding the full path it had: written relative to the header it's under now where that covers it (its place kept),
    /// whole where it's under none, and, where the header it fell under doesn't cover it, put where a full path of its own goes
    /// (`place`). An endpoint in `kept` is as the change wrote it. What deleting a header, or leaving every group, asks: only
    /// retyping a header moves its members' full paths with it.
    public static func regrouped(_ rows: [APIRow], from old: [APIRow], except kept: Set<PartID> = []) -> [APIRow] {
        var was: [PartID: (header: PartID?, full: String)] = [:]
        var header: PathHeader?
        for (index, row) in old.enumerated() {
            switch row {
            case .header(let found): header = found
            case .endpoint(let endpoint): was[endpoint.id] = (header?.id, fullPath(of: index, in: old))
            }
        }
        var result: [APIRow] = []
        var strays: [(endpoint: Endpoint, full: String)] = []
        var current: PathHeader?
        for row in rows {
            switch row {
            case .header(let found):
                current = found
                result.append(row)
            case .endpoint(var endpoint):
                guard !kept.contains(endpoint.id), let before = was[endpoint.id], before.header != current?.id else { result.append(row); continue }
                if let current {
                    guard isUnder(before.full, current.prefix) else { strays.append((endpoint, before.full)); continue }
                    endpoint.path = relative(before.full, under: current.prefix)
                } else {
                    endpoint.path = before.full
                }
                result.append(.endpoint(endpoint))
            }
        }
        for stray in strays {
            var endpoint = stray.endpoint
            let spot = place(stray.full, in: result)
            endpoint.path = spot.path
            result.insert(.endpoint(endpoint), at: spot.index)
        }
        return result
    }

    /// `rows` with the group of the header at `index` (it and the endpoints after it) moved past the group after it (`down`), or
    /// above the one before it; nil where there is none to pass (the first group, the top endpoints' above it, never goes under a
    /// header).
    public static func movingGroup(at index: Int, down: Bool, in rows: [APIRow]) -> [APIRow]? {
        guard rows.indices.contains(index), rows[index].header != nil else { return nil }
        let end = rows[(index + 1)...].firstIndex { $0.header != nil } ?? rows.count
        if down {
            guard end < rows.count else { return nil }
            let after = rows[(end + 1)...].firstIndex { $0.header != nil } ?? rows.count
            return Array(rows[..<index] + rows[end..<after] + rows[index..<end] + rows[after...])
        }
        guard let before = rows[..<index].lastIndex(where: { $0.header != nil }) else { return nil }
        return Array(rows[..<before] + rows[index..<end] + rows[before..<index] + rows[end...])
    }

    /// How many endpoints a header heads: those after it, up to the next header.
    public static func members(of index: Int, in rows: [APIRow]) -> Int {
        guard rows.indices.contains(index), rows[index].header != nil else { return 0 }
        return rows[(index + 1)...].prefix { $0.header == nil }.count
    }

    /// Whether row `index` is under a header (a member: drawn indented).
    public static func isMember(_ index: Int, in rows: [APIRow]) -> Bool {
        rows.indices.contains(index) && rows[index].header == nil && rows[..<index].contains { $0.header != nil }
    }

    /// `endpoints` (each path whole, in order) grouped by prefix, the kit's one rule (Group by Prefix's, and a paste of OpenAPI's):
    /// a header for each first path segment two or more of them share (`/orders` for `/orders` and `/orders/{id}`), in the order
    /// each is first met, its endpoints after it in their order, each path written relative to it; the endpoints that share
    /// their first segment with none first, in their order, whole. So three endpoints under three segments stay ungrouped (E1),
    /// and sixty under seven make seven groups (E8).
    public static func byPrefix(_ endpoints: [Endpoint]) -> [APIRow] {
        func segment(_ path: String) -> String? { path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) }
        var counts: [String: Int] = [:], order: [String] = []
        for endpoint in endpoints {
            guard let first = segment(endpoint.path) else { continue }
            if counts[first] == nil { order.append(first) }
            counts[first, default: 0] += 1
        }
        let shared = Set(order.filter { counts[$0, default: 0] > 1 })
        var rows: [APIRow] = endpoints.filter { segment($0.path).map { !shared.contains($0) } ?? true }.map(APIRow.endpoint)
        for first in order where shared.contains(first) {
            let prefix = "/" + first
            rows.append(.header(PathHeader(prefix: prefix)))
            for var endpoint in endpoints where segment(endpoint.path) == first {
                endpoint.path = relative(endpoint.path, under: prefix)
                rows.append(.endpoint(endpoint))
            }
        }
        return rows
    }
}

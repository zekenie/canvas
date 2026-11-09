import AppKit
import Canvas
import CoreText
import Find
import LineRows

// Find over an API (E8 panel 3): an endpoint is found by its method and full path ("POST /orders/{id}/refunds"), a text a row in
// row order, each by its row's id (the field), as Find's list and its steps read it. Where a hit is drawn follows where each part of
// that text is drawn: the method on its chip, the group's prefix on the group's header (so a word only in the prefix stops on the
// header once for each endpoint under it), the rest on the row's own path. A header with no endpoints under it is found by its
// prefix. A closed group shows the rows whose own words hold hits while Find is open (LineRows' peeks); a hit only in the prefix
// leaves it closed, its header lit.

/// Where each part of an endpoint's found text is: its method, its group's prefix, and its own path (UTF-16 offsets).
struct EndpointText: Equatable {
    let text: String
    let method: Range<Int>
    /// The prefix as the full path holds it (its trailing slash dropped), drawn on the header.
    let prefix: Range<Int>
    /// The rest of the full path, drawn on the row: `own` less `ownSkip` leading characters the row doesn't draw (the slash a path
    /// written without one is joined with).
    let own: Range<Int>
    let ownSkip: Int

    /// The found text of row `index` of `rows`: an endpoint's method and full path; a header's prefix (nil for a header with
    /// endpoints under it: found through them).
    static func of(_ index: Int, in rows: [APIRow]) -> EndpointText? {
        guard rows.indices.contains(index) else { return nil }
        switch rows[index] {
        case .header(let header):
            guard APIGroups.members(of: index, in: rows) == 0, !header.prefix.isEmpty else { return nil }
            let length = (header.prefix as NSString).length
            return EndpointText(text: header.prefix, method: 0..<0, prefix: 0..<length, own: length..<length, ownSkip: 0)
        case .endpoint(let endpoint):
            let prefix = APIGroups.header(of: index, in: rows)?.prefix ?? ""
            let full = APIGroups.joined(prefix, endpoint.path)
            let method = (endpoint.method as NSString).length
            let start = method + (method > 0 && !full.isEmpty ? 1 : 0)
            let text = APIGroups.fullName(method: endpoint.method, path: full)
            let total = (text as NSString).length
            // The prefix's share of the full path: all of it where the row's own path is "/" or empty, else its head.
            let head = prefix.isEmpty ? 0 : (endpoint.path.isEmpty || endpoint.path == "/") ? (full as NSString).length
                : ((prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix) as NSString).length
            let skip = !prefix.isEmpty && !endpoint.path.isEmpty && endpoint.path != "/" && !endpoint.path.hasPrefix("/") ? 1 : 0
            return EndpointText(text: text, method: 0..<method, prefix: start..<min(total, start + head), own: min(total, start + head)..<total, ownSkip: skip)
        }
    }

    /// Whether a hit at `range` is drawn on the row: in its method or its own path, not only in the group's prefix.
    func isOnRow(_ range: Range<Int>) -> Bool {
        range.overlaps(method) || range.overlaps(own) || (prefix.isEmpty && own.isEmpty)
    }
}

@MainActor
enum APIFind {
    static func register(into registrar: inout PluginRegistrar) {
        registrar.findableTexts("rows", of: API.self, texts: { shape, _ in
            let rows = shape.props.endpoints
            return rows.indices.compactMap { index in
                EndpointText.of(index, in: rows).map { FindableText(field: rows[index].id.description, text: $0.text) }
            }
        }, rects: { shape, field, ranges, context in
            rects(of: shape, field: field, ranges: ranges, in: context.editor)
        })
    }

    /// Where `ranges` of row `field`'s found text are drawn, line rects from the shape's bounds' top-left: the method on its chip,
    /// the prefix on the group's header, the rest on the row's path.
    static func rects(of shape: ShapeRecord<API>, field: String, ranges: [Range<Int>], in editor: CanvasEditor) -> [[CGRect]] {
        let shapes = editor.shapeContext, rows = shape.props.endpoints
        guard let index = rows.firstIndex(where: { $0.id.description == field }), let laid = EndpointText.of(index, in: rows),
              let bounds = shapes.geometry(of: shape.id)?.bounds, !bounds.isNull else { return ranges.map { _ in [] } }
        let frame = shapes.frame(of: shape), kit = KitRows(shape, in: shapes)
        let line = APIRows.rowRect(kit.line(of: index), in: frame)
        let start = line.minX + APIStyle.inset
        let header = rows[..<index].lastIndex { $0.header != nil }
        return ranges.map { range in
            var found: [CGRect] = []
            switch rows[index] {
            case .header(let header):
                let text = RowText.line(header.prefix, .code)
                found.append(span(text, at: start + APIStyle.memberIndent, range.clamped(to: laid.prefix), in: line))
            case .endpoint(let endpoint):
                let member = header != nil
                if range.overlaps(laid.method), let chip = APIDrawing.chipRect(endpoint.method, member: member, in: line) {
                    found.append(chip.insetBy(dx: -1, dy: -1))
                }
                if range.overlaps(laid.prefix), let header, case .header(let group) = rows[header] {
                    // The prefix drawn on its header, from where the prefix begins.
                    let headerLine = APIRows.rowRect(kit.line(of: header), in: frame)
                    let local = (range.clamped(to: laid.prefix).lowerBound - laid.prefix.lowerBound)..<(range.clamped(to: laid.prefix).upperBound - laid.prefix.lowerBound)
                    found.append(span(RowText.line(group.prefix, .code), at: headerLine.minX + APIStyle.inset + APIStyle.memberIndent, local, in: headerLine))
                }
                if range.overlaps(laid.own) {
                    let x = APIDrawing.chipRect(endpoint.method, member: member, in: line).map { $0.maxX + APIStyle.gap }
                        ?? start + (member ? APIStyle.memberIndent : 0)
                    let clamped = range.clamped(to: laid.own)
                    let from = max(0, clamped.lowerBound - laid.own.lowerBound - laid.ownSkip), to = max(from, clamped.upperBound - laid.own.lowerBound - laid.ownSkip)
                    found.append(span(RowText.line(endpoint.path, .code), at: x, from..<to, in: line))
                }
            }
            return found.map { $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
        }
    }

    /// Where UTF-16 `range` of `text`, drawn from `x` on `row`, is: as tall as a row's hit.
    private static func span(_ text: RowText.Line, at x: CGFloat, _ range: Range<Int>, in row: CGRect) -> CGRect {
        let from = CTLineGetOffsetForStringIndex(text.line, range.lowerBound, nil)
        let to = CTLineGetOffsetForStringIndex(text.line, range.upperBound, nil)
        let height = KitStyle.findHitHeight
        let right = min(x + to, row.maxX - KitStyle.trailingInset)
        return CGRect(x: x + from, y: row.midY - height / 2, width: max(0, right - x - from), height: height)
    }
}

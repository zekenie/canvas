import Adornments
import AppKit
import Canvas
import Geometry
import LineRows
import Palette
import Titles
import Types

/// An API, at rest: its paper (a table's), its server line (where it's served in grey code, faint "server" while it says
/// nothing, a lock and how a client signs in at the right, a hairline under it), then a row a line, 24 apart: a path-prefix
/// header (a chevron, the prefix, its endpoints' count at the right) or an endpoint (its method's chip, its path in code with its
/// parameters in the chip's color, and at the right its body's pill, an arrow, its first response's status and its type's pill,
/// the path cut short first), an endpoint under a header indented. Its width is its own, its height its rows' (`LaidOutBox`).
/// Its rows are its parts, an endpoint's named by its method and full path. Edited, its title is typed in its pill, its server
/// and its rows a line each (LineRows).
@MainActor
struct APIDefinition {}

extension APIDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<API>, in context: RenderContext) {
        let frame = context.shapes.frame(of: shape)
        KitPaper.draw(frame, in: context)
        let api = shape.props, rows = KitRows(shape, in: context.shapes), cg = context.cg
        let server = APIRows.serverRect(in: frame)
        if context.shapes.layoutInput(LineRowsLayout.fixed, of: shape) != true { APIDrawing.drawServer(api.server, in: server, cg) }
        let hairline = server.maxY + APIStyle.hairlineDrop
        cg.setFillColor(APIStyle.hairline.cgColor)
        cg.fill(CGRect(x: frame.minX + APIStyle.inset, y: hairline, width: max(0, frame.width - APIStyle.inset - KitStyle.trailingInset), height: 1 / max(context.zoom, 1)))
        let rowsFrame = APIRows.rowsFrame(frame)
        let lines = KitPaper.rowsInView(rows.lines(api.endpoints.count), in: rowsFrame, context)
        guard !lines.isEmpty else { return }
        let types = context.shapes.service(TypeIndex.self)
        let more = rows.more
        // A row after the first header is a member (headers aside): found once, not a row at a time.
        let firstHeader = api.endpoints.firstIndex { $0.header != nil } ?? api.endpoints.count
        for line in lines {
            let rect = KitStyle.rowRect(line, in: rowsFrame)
            if line == more?.line, let more {
                MoreLine.draw(more.count, in: rect, context)
                continue
            }
            guard let index = rows.row(atLine: line) else { continue }
            let focused = api.endpoints[index].id == rows.focused
            switch api.endpoints[index] {
            case .header(let header):
                // Its chevron and count stay while the field has its prefix (E5 panel 1).
                let closed: Bool = if case .header? = rows.shown?.lines[line] { true } else { false }
                APIDrawing.drawHeader(focused ? nil : header.prefix, count: APIGroups.members(of: index, in: api.endpoints), closed: closed, in: rect, cg)
            case .endpoint where focused:
                continue
            case .endpoint(let endpoint):
                APIDrawing.drawEndpoint(endpoint, member: index > firstHeader, types: types, in: rect, cg)
            }
        }
    }

    /// Its laid-out frame, and a part a row.
    func geometry(of shape: ShapeRecord<API>, in context: ShapeContext) -> ShapeGeometry {
        let frame = context.frame(of: shape), rows = KitRows(shape, in: context)
        // A header heads its endpoints and is no end of a connection: no dots, no arrow bound to it.
        let parts = shape.props.endpoints.enumerated().map {
            PartFrame(id: $1.id, rect: APIRows.rowRect(rows.line(of: $0), in: frame), isShown: rows.isShown($0), isConnectable: $1.header == nil)
        }
        return ShapeGeometry(outline: frame.polygon, bounds: frame, parts: PartFrames(parts))
    }

    func indicatorPath(of shape: ShapeRecord<API>, in context: ShapeContext) -> CGPath {
        KitStyle.paperPath(context.frame(of: shape))
    }
}

/// As wide as it stores, as tall as its server's band and its rows.
extension APIDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<API>, in context: ShapeContext) -> CGSize {
        let rows = KitRows(shape, in: context)
        return CGSize(width: rows.width(stored: shape.frame.width), height: APIRows.height(lines: rows.lines(shape.props.endpoints.count)))
    }
}

/// Its stored height is kept in step with its rows wherever it's made from properties (`canvas draw`).
extension APIDefinition: DerivedProps {
    func derive(_ api: inout API) {
        api.frame.size.height = APIRows.height(lines: api.endpoints.count)
    }
}

/// Given a frame (a resize, `size:`), it takes its place and its width; its height stays its rows'.
extension APIDefinition: CustomSizing {
    func size(_ shape: inout ShapeRecord<API>, to frame: CGRect, giving axes: SizeAxes, in context: ShapeContext) {
        shape.props.frame.origin = frame.origin
        if axes.contains(.width) { shape.props.frame.size.width = frame.width }
        derive(&shape.props)
    }
}

/// Its rows are its parts: an endpoint by its method and full path ("POST /orders/{id}/refunds", standing alone, its method in a
/// chip before it), a header by its prefix; taken out by their ids (`canvas draw`'s `delete`).
extension APIDefinition: PartedShape {
    func parts(of shape: ShapeRecord<API>) -> [PartName] {
        // One pass, the header each endpoint is under carried along.
        var prefix = ""
        return shape.props.endpoints.map { row in
            switch row {
            case .header(let header):
                prefix = header.prefix
                return PartName(id: header.id, name: header.prefix, kindWord: APIStyle.prefixWord, isConnectable: false)
            case .endpoint(let endpoint):
                return PartName(id: endpoint.id, name: APIGroups.fullName(method: endpoint.method, path: APIGroups.joined(prefix, endpoint.path)),
                                kindWord: APIStyle.endpointWord, lead: endpoint.method.isEmpty ? .none : .chip(endpoint.method, fill: APIStyle.chipRGB(endpoint.method)), standsAlone: true)
            }
        }
    }

    func removing(_ parts: Set<PartID>, from shape: ShapeRecord<API>) -> API? {
        var api = shape.props
        // A header taken out alone leaves its endpoints their full paths (they take the prefix back).
        api.endpoints = APIGroups.regrouped(shape.props.endpoints.filter { !parts.contains($0.id) }, from: shape.props.endpoints)
        guard api.endpoints.count < shape.props.endpoints.count else { return nil }
        derive(&api)
        return api
    }
}

/// Zoomed out: its paper, a bar for its server, and a bar a row (a method's and its path's, a header's prefix), one fill.
extension APIDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<API>, in context: RenderContext) {
        let frame = context.shapes.frame(of: shape)
        KitPaper.drawSkeleton(frame, in: context)
        let api = shape.props, rows = KitRows(shape, in: context.shapes)
        guard KitStyle.rowHeight * context.zoom >= KitStyle.skeletonLeastRow else { return }
        var bars: [CGRect] = []
        let server = APIRows.serverRect(in: frame)
        let start = frame.minX + APIStyle.inset, end = frame.maxX - KitStyle.trailingInset
        if let bar = KitPaper.bar(columns: SkeletonText.columns(of: api.server.host, upTo: KitStyle.skeletonMostColumns), column: APIStyle.skeletonColumn,
                                  at: start, in: server, room: end - start) {
            bars.append(bar)
        }
        let rowsFrame = APIRows.rowsFrame(frame), more = rows.more
        let firstHeader = api.endpoints.firstIndex { $0.header != nil } ?? api.endpoints.count
        for line in KitPaper.skeletonRowsInView(rows.lines(api.endpoints.count), in: rowsFrame, context) {
            let rect = KitStyle.rowRect(line, in: rowsFrame)
            if line == more?.line, let more {
                if let bar = MoreLine.bar(more.count, in: rect) { bars.append(bar) }
                continue
            }
            guard let index = rows.row(atLine: line) else { continue }
            let x = start + (index >= firstHeader ? APIStyle.memberIndent : 0)
            switch api.endpoints[index] {
            case .header(let header):
                if let bar = KitPaper.bar(columns: SkeletonText.columns(of: header.prefix, upTo: KitStyle.skeletonMostColumns), column: APIStyle.skeletonColumn,
                                          at: x, in: rect, room: end - x) { bars.append(bar) }
            case .endpoint(let endpoint):
                let chip = APIStyle.chipLeast
                if !endpoint.method.isEmpty { bars.append(CGRect(x: x, y: rect.midY - KitStyle.skeletonBarHeight / 2, width: chip, height: KitStyle.skeletonBarHeight)) }
                let path = x + chip + APIStyle.gap
                if let bar = KitPaper.bar(columns: SkeletonText.columns(of: endpoint.path, upTo: KitStyle.skeletonMostColumns), column: APIStyle.skeletonColumn,
                                          at: path, in: rect, room: end - path) { bars.append(bar) }
            }
        }
        context.fillSkeletonText(bars)
    }
}

/// Edited, its name is typed in its pill, and its server and its rows a line each.
extension APIDefinition: Editable {
    func editingFrame(of shape: ShapeRecord<API>, in context: ShapeContext) -> CGRect? {
        TitleField.editingFrame(around: context.frame(of: shape), zoom: context.zoom)
    }

    func makeEditingView(for shape: ShapeRecord<API>, context: EditContext<API>) -> EditingView {
        LineRowsView.make(shape, context: context, model: APILines(), title: LineTitle { title in
            TitleField(title: title, systemImage: APIStyle.symbol, tint: nil, name: APIStyle.titleFieldName)
        })
    }

    var editingStepName: String? { APIStyle.renameStep }
}

/// What an API's lines draw at rest, world units: the server, a header, an endpoint.
@MainActor
enum APIDrawing {
    /// The server: its host in grey code (faint "server", slanted, while there's none), and at the right a lock and how a client
    /// signs in.
    static func drawServer(_ server: APIServer, in rect: CGRect, _ cg: CGContext) {
        let start = rect.minX + APIStyle.inset, end = rect.maxX - KitStyle.trailingInset, middle = rect.midY
        var right = end
        if !server.auth.isEmpty {
            let auth = RowText.line(server.auth, .faintCode)
            let width = min(auth.width, (end - start) / 2)
            right -= width
            RowText.draw(auth, at: right, middle: middle, room: width, in: cg)
            right -= KitStyle.markSize / 2 + APIStyle.gap / 2
            RowMarks.draw(APIStyle.lockSymbol, color: KitStyle.secondaryInk, centeredAt: CGPoint(x: right, y: middle))
            right -= KitStyle.markSize / 2 + APIStyle.gap
        }
        if server.host.isEmpty {
            RowText.draw(RowText.line(APIStyle.serverPlaceholder, .placeholder), at: start, middle: middle, room: right - start, in: cg)
        } else {
            RowText.draw(RowText.line(server.host, .faintCode), at: start, middle: middle, room: right - start, in: cg)
        }
    }

    /// A path-prefix header: its chevron (down while open, right while closed), its prefix (none while the field has it), its
    /// endpoints' count at the right.
    static func drawHeader(_ prefix: String?, count: Int, closed: Bool, in rect: CGRect, _ cg: CGContext) {
        let start = rect.minX + APIStyle.inset, end = rect.maxX - KitStyle.trailingInset, middle = rect.midY
        RowMarks.draw(closed ? APIStyle.closedChevron : APIStyle.openChevron, color: KitStyle.secondaryInk, size: APIStyle.chevronSize,
                      centeredAt: CGPoint(x: start + APIStyle.memberIndent / 2 - 2, y: middle))
        let counted = RowText.line(count.formatted(), .faintCode)
        RowText.draw(counted, at: end - counted.width, middle: middle, in: cg)
        let x = start + APIStyle.memberIndent
        guard let prefix else { return }
        RowText.draw(RowText.line(prefix, .code), at: x, middle: middle, room: end - counted.width - APIStyle.gap - x, in: cg)
    }

    /// An endpoint: its chip, its path (its parameters in the chip's color, its unread words after it), and at the right its body,
    /// an arrow, its first response's status and type; the path cut short first.
    static func drawEndpoint(_ endpoint: Endpoint, member: Bool, types: TypeIndex?, in rect: CGRect, _ cg: CGContext) {
        let start = rect.minX + APIStyle.inset + (member ? APIStyle.memberIndent : 0), end = rect.maxX - KitStyle.trailingInset
        let middle = rect.midY
        var x = start
        if !endpoint.method.isEmpty {
            let text = RowText.line(endpoint.method, .chip)
            let width = max(APIStyle.chipLeast, text.width + 2 * APIStyle.chipPadding)
            let chip = CGRect(x: x, y: middle - APIStyle.chipHeight / 2, width: width, height: APIStyle.chipHeight)
            cg.addPath(CGPath(roundedRect: chip, cornerWidth: APIStyle.chipRadius, cornerHeight: APIStyle.chipRadius, transform: nil))
            cg.setFillColor(APIStyle.chipFill(endpoint.method).cgColor)
            cg.fillPath()
            RowText.draw(text, at: chip.midX - text.width / 2, middle: middle, in: cg)
            x = chip.maxX + APIStyle.gap
        }
        // The right side, laid from the right: the response's pill, its status, the arrow, the body's pill.
        var right = end
        var drawn: [@MainActor () -> Void] = []
        func place(width: CGFloat, _ draw: @escaping @MainActor (CGFloat) -> Void) {
            guard right - width >= x else { return }
            right -= width
            let at = right
            drawn.append { draw(at) }
            right -= APIStyle.pillGap
        }
        if let response = endpoint.responses.first {
            if let type = response.type, !type.words.isEmpty {
                let label = APITypes.pill(type, types: types)
                let size = label.contentSize
                place(width: size.width) { at in label.draw(at: CGPoint(x: at, y: middle - size.height / 2), in: cg) }
            }
            if !response.status.isEmpty {
                let status = RowText.line(response.status, .faintCode)
                place(width: status.width) { at in RowText.draw(status, at: at, middle: middle, in: cg) }
            }
            let arrow = RowText.line(EndpointGrammar.arrow, .faintCode)
            place(width: arrow.width) { at in RowText.draw(arrow, at: at, middle: middle, in: cg) }
        }
        if let body = endpoint.body, !body.words.isEmpty {
            let label = APITypes.pill(body, types: types)
            let size = label.contentSize
            place(width: size.width) { at in label.draw(at: CGPoint(x: at, y: middle - size.height / 2), in: cg) }
        }
        for draw in drawn { draw() }
        drawPath(endpoint, from: x, room: right + APIStyle.pillGap - APIStyle.gap - x, middle: middle, cg)
    }

    /// A path in code, its parameters in the method's color, the words no part reads after it; cut short with an ellipsis where
    /// it's longer than `room`.
    static func drawPath(_ endpoint: Endpoint, from x: CGFloat, room: CGFloat, middle: CGFloat, _ cg: CGContext) {
        guard room > 0 else { return }
        let path = endpoint.path as NSString
        var pieces: [(String, RowText.Role)] = []
        var at = 0
        let parameter = RowText.Role.coloredCode(APIStyle.parameterHex(endpoint.method))
        for range in EndpointGrammar.parameters(in: endpoint.path) {
            if range.location > at { pieces.append((path.substring(with: NSRange(location: at, length: range.location - at)), .code)) }
            pieces.append((path.substring(with: range), parameter))
            at = NSMaxRange(range)
        }
        if at < path.length { pieces.append((path.substring(from: at), .code)) }
        if !endpoint.unread.isEmpty { pieces.append(((endpoint.path.isEmpty ? "" : " ") + endpoint.unread, .code)) }
        var left = x, rest = room
        for (text, role) in pieces where !text.isEmpty {
            let line = RowText.line(text, role)
            RowText.draw(line, at: left, middle: middle, room: rest, in: cg)
            left += line.width
            rest -= line.width
            guard rest > 0 else { return }
        }
    }
}

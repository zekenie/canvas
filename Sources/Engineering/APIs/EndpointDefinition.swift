import Adornments
import AppKit
import Canvas
import Geometry
import LineRows
import Types

// One endpoint standing alone (E3 panel 4: the row dragged out by its chip is createRefund): the `endpoint` kind, drawn as the
// row's card open on the API's paper. Its first line is the row as an API draws it (its method's chip, its full path with its
// parameters in the chip's color, at the right a lock and its scope), a hairline, its path parameters' types and its body, a
// hairline, its responses a line each. Its one part is its row, under the row's id it was taken out as, on that first line, so a
// call, a write or a pill for it on another board stays bound to it; it has a row's dots and its chip (the method menu, a drag into
// an API, where it becomes a row again). Its title is derived (its name, else its method and path); it isn't edited in place.

/// Where an endpoint's card lays out its lines, world units.
@MainActor
enum EndpointCard {
    /// What the card says under its first line: a path parameter's type, or the body.
    enum Detail: Equatable {
        case parameter(name: String, type: String)
        case body(TypeRef)
    }

    /// Its path's parameters (each with its type, or none yet) and its body, if it has one.
    static func details(of endpoint: Endpoint) -> [Detail] {
        var details = EndpointGrammar.parameterNames(in: endpoint.path).map { name in
            Detail.parameter(name: name, type: endpoint.parameters.first { $0.name == name }?.type ?? "")
        }
        if let body = endpoint.body, !body.words.isEmpty { details.append(.body(body)) }
        return details
    }

    /// Its first line (the row's), at `frame`.
    static func headerRect(in frame: CGRect) -> CGRect { KitStyle.rowRect(0, in: frame) }

    /// Where detail `index` is, at `frame`.
    static func detailRect(_ index: Int, in frame: CGRect) -> CGRect {
        let top = headerRect(in: frame).maxY + EndpointStyle.sectionGap
        return CGRect(x: frame.minX, y: top + CGFloat(index) * KitStyle.rowHeight, width: frame.width, height: KitStyle.rowHeight)
    }

    /// Where response `index` is, at `frame`, under `details` details.
    static func responseRect(_ index: Int, details: Int, in frame: CGRect) -> CGRect {
        let above = details == 0 ? headerRect(in: frame).maxY : detailRect(details - 1, in: frame).maxY
        let top = above + EndpointStyle.sectionGap
        return CGRect(x: frame.minX, y: top + CGFloat(index) * KitStyle.rowHeight, width: frame.width, height: KitStyle.rowHeight)
    }

    /// How tall its card is: its first line, then each section that has lines, a gap before it.
    static func height(of endpoint: Endpoint) -> CGFloat {
        let details = details(of: endpoint).count, responses = endpoint.responses.count
        var height = KitStyle.topInset + KitStyle.rowHeight + KitStyle.bottomInset
        if details > 0 { height += EndpointStyle.sectionGap + CGFloat(details) * KitStyle.rowHeight }
        if responses > 0 { height += EndpointStyle.sectionGap + CGFloat(responses) * KitStyle.rowHeight }
        return height
    }
}

/// An endpoint standing alone, at rest.
@MainActor
struct EndpointDefinition {}

extension EndpointDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<StandaloneEndpoint>, in context: RenderContext) {
        let frame = context.shapes.frame(of: shape)
        KitPaper.draw(frame, in: context)
        let endpoint = shape.props.endpoint, cg = context.cg
        let rows = KitRows(shape, in: context.shapes)
        rows.drawing(endpoint.id, in: cg) {
            drawCard(endpoint, in: frame, types: context.shapes.service(TypeIndex.self), cg)
        }
    }

    /// The card: its first line, a hairline, its details, a hairline, its responses; deprecated, its chip hollow and the rest faint.
    private func drawCard(_ endpoint: Endpoint, in frame: CGRect, types: TypeIndex?, _ cg: CGContext) {
        let header = EndpointCard.headerRect(in: frame)
        var x = frame.minX + APIStyle.inset
        if let chip = APIDrawing.chipRect(endpoint.method, member: false, in: header) {
            APIDrawing.drawChip(endpoint.method, deprecated: endpoint.deprecated, in: chip, cg)
            x = chip.maxX + APIStyle.gap
        }
        APIDrawing.fading(endpoint.deprecated, in: cg, over: frame) { drawLines(endpoint, from: x, in: frame, types: types, cg) }
    }

    /// All but the chip: the path and scope, the details and the responses.
    private func drawLines(_ endpoint: Endpoint, from x: CGFloat, in frame: CGRect, types: TypeIndex?, _ cg: CGContext) {
        let header = EndpointCard.headerRect(in: frame)
        let start = frame.minX + APIStyle.inset, end = frame.maxX - KitStyle.trailingInset, middle = header.midY
        var right = end
        if !endpoint.authScope.isEmpty {
            let scope = RowText.line(endpoint.authScope, .faintCode)
            let width = min(scope.width, (end - start) / 3)
            right -= width
            RowText.draw(scope, at: right, middle: middle, room: width, in: cg)
            right -= KitStyle.markSize / 2 + APIStyle.gap / 2
            RowMarks.draw(APIStyle.lockSymbol, color: KitStyle.secondaryInk, centeredAt: CGPoint(x: right, y: middle))
            right -= KitStyle.markSize / 2 + APIStyle.gap
        }
        APIDrawing.drawPath(endpoint, from: x, room: right - x, middle: middle, cg)
        let details = EndpointCard.details(of: endpoint)
        let value = start + EndpointStyle.valueOffset
        if !details.isEmpty {
            hairline(above: EndpointCard.detailRect(0, in: frame), in: frame, cg)
            for (index, detail) in details.enumerated() {
                let rect = EndpointCard.detailRect(index, in: frame)
                switch detail {
                case .parameter(let name, let type):
                    RowText.draw(RowText.line("{\(name)}", .coloredCode(APIStyle.parameterHex(endpoint.method))), at: start, middle: rect.midY,
                                 room: value - start - APIStyle.gap, in: cg)
                    if !type.isEmpty { RowText.draw(RowText.line(type, .faintCode), at: value, middle: rect.midY, room: end - value, in: cg) }
                case .body(let type):
                    RowText.draw(RowText.line(EndpointStyle.bodyLabel, .code), at: start, middle: rect.midY, room: value - start - APIStyle.gap, in: cg)
                    drawTyped(type, at: value, in: rect, end: end, types: types, cg)
                }
            }
        }
        guard !endpoint.responses.isEmpty else { return }
        hairline(above: EndpointCard.responseRect(0, details: details.count, in: frame), in: frame, cg)
        for (index, response) in endpoint.responses.enumerated() {
            let rect = EndpointCard.responseRect(index, details: details.count, in: frame)
            RowText.draw(RowText.line(response.status, .code), at: start, middle: rect.midY, room: value - start - APIStyle.gap, in: cg)
            if let type = response.type, !type.words.isEmpty { drawTyped(type, at: value, in: rect, end: end, types: types, cg) }
        }
    }

    /// `→` and a type's pill (dashed while its words name no type note), from `x`.
    private func drawTyped(_ type: TypeRef, at x: CGFloat, in rect: CGRect, end: CGFloat, types: TypeIndex?, _ cg: CGContext) {
        let arrow = RowText.line(EndpointGrammar.arrow, .faintCode)
        RowText.draw(arrow, at: x, middle: rect.midY, in: cg)
        let label = APITypes.pill(type, types: types)
        let size = label.contentSize, left = x + arrow.width + APIStyle.pillGap
        guard left + size.width <= end else { return }
        label.draw(at: CGPoint(x: left, y: rect.midY - size.height / 2), in: cg)
    }

    /// The hairline between two sections, in the gap above `rect`.
    private func hairline(above rect: CGRect, in frame: CGRect, _ cg: CGContext) {
        cg.setFillColor(APIStyle.hairline.cgColor)
        cg.fill(CGRect(x: frame.minX + APIStyle.inset, y: rect.minY - EndpointStyle.sectionGap / 2,
                       width: max(0, frame.width - APIStyle.inset - KitStyle.trailingInset), height: 1))
    }

    /// Its laid-out frame, and its one part, its row, on its first line.
    func geometry(of shape: ShapeRecord<StandaloneEndpoint>, in context: ShapeContext) -> ShapeGeometry {
        let frame = context.frame(of: shape)
        return ShapeGeometry(outline: frame.polygon, bounds: frame,
                             parts: PartFrames([PartFrame(id: shape.props.endpoint.id, rect: EndpointCard.headerRect(in: frame))]))
    }

    func indicatorPath(of shape: ShapeRecord<StandaloneEndpoint>, in context: ShapeContext) -> CGPath {
        KitStyle.paperPath(context.frame(of: shape))
    }
}

/// As wide as it stores, as tall as what its card shows.
extension EndpointDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<StandaloneEndpoint>, in context: ShapeContext) -> CGSize {
        CGSize(width: shape.frame.width, height: EndpointCard.height(of: shape.props.endpoint))
    }
}

/// Its stored height kept in step with its card wherever it's made from properties (`canvas draw`, a take-out).
extension EndpointDefinition: DerivedProps {
    func derive(_ endpoint: inout StandaloneEndpoint) {
        endpoint.frame.size.height = EndpointCard.height(of: endpoint.endpoint)
    }
}

/// Given a frame (a resize, `size:`), it takes its place and its width; its height stays its card's.
extension EndpointDefinition: CustomSizing {
    func size(_ shape: inout ShapeRecord<StandaloneEndpoint>, to frame: CGRect, giving axes: SizeAxes, in context: ShapeContext) {
        shape.props.frame.origin = frame.origin
        if axes.contains(.width) { shape.props.frame.size.width = frame.width }
        derive(&shape.props)
    }
}

/// Its one part is its row: named by its method and full path, its method in a chip before it, standing alone.
extension EndpointDefinition: PartedShape {
    var isAllItsOneRow: Bool { true }

    func parts(of shape: ShapeRecord<StandaloneEndpoint>) -> [PartName] {
        let endpoint = shape.props.endpoint
        return [PartName(id: endpoint.id, name: APIGroups.fullName(method: endpoint.method, path: endpoint.path), kindWord: APIStyle.endpointWord,
                         lead: endpoint.method.isEmpty ? .none : .chip(endpoint.method, fill: APIStyle.chipRGB(endpoint.method)), standsAlone: true, isItsShape: true)]
    }
}

/// Zoomed out: its paper, a bar for its method and its path, and a bar a line below.
extension EndpointDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<StandaloneEndpoint>, in context: RenderContext) {
        let frame = context.shapes.frame(of: shape)
        KitPaper.drawSkeleton(frame, in: context)
        guard KitStyle.rowHeight * context.zoom >= KitStyle.skeletonLeastRow else { return }
        let endpoint = shape.props.endpoint
        let start = frame.minX + APIStyle.inset, end = frame.maxX - KitStyle.trailingInset
        var bars: [CGRect] = []
        let header = EndpointCard.headerRect(in: frame)
        var x = start
        if !endpoint.method.isEmpty {
            bars.append(CGRect(x: x, y: header.midY - KitStyle.skeletonBarHeight / 2, width: APIStyle.chipLeast, height: KitStyle.skeletonBarHeight))
            x += APIStyle.chipLeast + APIStyle.gap
        }
        if let bar = KitPaper.bar(columns: SkeletonText.columns(of: endpoint.path, upTo: KitStyle.skeletonMostColumns), column: APIStyle.skeletonColumn,
                                  at: x, in: header, room: end - x) { bars.append(bar) }
        let details = EndpointCard.details(of: endpoint).count
        var lines = (0..<details).map { EndpointCard.detailRect($0, in: frame) }
        lines += endpoint.responses.indices.map { EndpointCard.responseRect($0, details: details, in: frame) }
        for line in lines {
            if let bar = KitPaper.bar(columns: EndpointStyle.skeletonLineColumns, column: APIStyle.skeletonColumn, at: start, in: line, room: end - start) {
                bars.append(bar)
            }
        }
        APIDrawing.fading(endpoint.deprecated, in: context.cg, over: frame) { context.fillSkeletonText(bars) }
    }
}

/// An endpoint's look standing alone, besides an API's (`APIStyle`). World units.
@MainActor
enum EndpointStyle {
    static let label = "Endpoint"
    /// Its row in the table of contents while it has no name.
    static let placeholder = "Untitled Endpoint"
    /// A gap between two sections of its card, a hairline in its middle.
    static let sectionGap: CGFloat = 10
    /// Where a detail's value starts, past the line's text inset (E3 panel 4's `uuid`, `→ NewRefund`).
    static let valueOffset: CGFloat = 92
    /// What its body's line is labeled.
    static let bodyLabel = "body"
    /// Zoomed out, how many columns a detail's or a response's bar stands for.
    static let skeletonLineColumns = 12
    /// One endpoint taken out of an API: the step.
    static let takeOutStep = "Take Out Endpoint"

    /// What it's called: its name (`createRefund`), else its method and path.
    static func title(of endpoint: Endpoint) -> String {
        endpoint.name.isEmpty ? APIGroups.fullName(method: endpoint.method, path: endpoint.path) : endpoint.name
    }

    /// What VoiceOver says of it after its name and kind: its method and path ("createRefund, Endpoint, POST /orders/{id}/refunds");
    /// nothing more where those are its name already.
    static func accessibleValue(of endpoint: Endpoint) -> String? {
        endpoint.name.isEmpty ? nil : APIGroups.fullName(method: endpoint.method, path: endpoint.path)
    }
}

// The kit's kinds take what is bound to them along (the core's `TakesBoundShapes`), an API and an endpoint as a table does: deleting
// one deletes the arrows bound to it ("Delete API and 3 Arrows"), taking a row out the arrows at it ("Delete Endpoint and 3 Arrows",
// E6 panel 2), and a copy of several takes the arrows among them. A pill for one on another board keeps its arrow, dashed (E6 panel 3).
extension APIDefinition: TakesBoundShapes {}
extension EndpointDefinition: TakesBoundShapes {}

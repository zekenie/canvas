import Canvas
import CoreGraphics
import Geometry
import Selection

/// Per editor: which adornments each kind's shapes may show, found once per kind (the registry is
/// frozen), and what each shape shows, laid out: its labels made once, with their faces (text set
/// and measured, symbols' images), and kept until a commit names the shape or
/// `adornmentsDidChange` does. A shape drawn as a skeleton, zoomed out (`editor.drawsSkeleton(of:)`),
/// shows only its tab (`AdornmentPlacement.onTopEdge`): nothing else is made, drawn or pointed at for
/// it, a shape with no tab has nothing made at all, and what was kept goes as the canvas starts or stops
/// drawing skeletons, but for the shape being edited, drawn in full, which has its own.
/// Where they go is worked out when it's asked, from what's kept: it follows the zoom, and
/// geometry that follows other shapes, neither of which reaches a service. Tabs, which give way to each
/// other across shapes, are placed together for the shapes in a region (`tabs(in:)`: the view), and kept
/// while nothing they're placed by changes. Drawing and hit testing go through the same layout, so what
/// answers the pointer is what's drawn.
@MainActor
final class AdornmentState {
    private unowned let editor: CanvasEditor
    /// No plugin places any: nothing is looked at.
    let isEmpty: Bool
    /// Some adornment is clickable. Without one, no point is looked at for a button.
    private let hasButtons: Bool
    /// Some adornment is a tab (`AdornmentPlacement.onTopEdge`). Without one, a skeleton shows nothing and
    /// no tabs are placed.
    let hasTabs: Bool
    /// Each kind's tab contributions, found once.
    private var tabCandidatesKept: [ShapeKind: Bool] = [:]
    /// The tabs placed lately, newest last, and what each was placed for: the view's, and a few asked about
    /// a shape out of view, so asking about one doesn't throw the view's away.
    private var tabsKept: [(key: TabsKey, tabs: PlacedTabs)] = []
    /// The region the overlay last placed tabs for: what pointing and `adornmentFrames(of:)` place them
    /// for too, so what's hit is what's drawn.
    private var drawnTabRegion: CGRect?
    /// Counts what changes where a tab goes (a shape with a tab added, changed, removed or its labels
    /// forgotten; a board shown; the level of detail): tabs placed before it are placed again. A shape with
    /// no tab changes nothing of them: tabs give way only to tabs.
    private var generation = 0
    /// The shapes the tabs placed last are on, so a commit that removes one places them again.
    private var tabShapesPlaced: Set<ShapeID> = []
    /// Each kind's contributions in claim order: its own (and other plugins' for it), then those whose
    /// scope reaches it, less those of a type it has its own of; sorted by order, then first appearance.
    private var candidates: [ShapeKind: [AdornmentContribution]] = [:]
    /// Each shape's shown adornments (none, for most), laid out: its labels, each with its face.
    /// Dropped for the shapes each commit names and `adornmentsDidChange` names, and for all of them
    /// as the canvas starts drawing skeletons.
    private var kept: [ShapeID: LaidOutAdornments] = [:]
    /// The "+N" faces made, by text and place: the same on every shape.
    private var overflowFacesKept: [OverflowKey: AdornmentStyle.Face] = [:]
    /// The kinds' contributions at a label's lead, found once.
    private var leadCandidatesKept: [ShapeKind: [AdornmentContribution]] = [:]
    /// The faces measured for each lead label.
    private var leadFacesKept: [AdornmentLabel: AdornmentLead.Faces] = [:]
    /// What the layout input last answered the editor's geometry, by shape: for the shapes whose kind has a lead.
    private var leadAnswered: [ShapeID: LeadAnswer] = [:]
    /// The same, kept for the answer to be reused while the shape and what it reads are as they were (dropped as `kept` is).
    private var leadMemo: [ShapeID: LeadAnswer] = [:]
    #if DEBUG
    /// How many faces have been made: labels' text set and measured, symbols' images found.
    private(set) var facesMade = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        let contributions = editor.registry.contributions(to: ShapeAdornments.self)
        isEmpty = contributions.isEmpty
        hasButtons = contributions.contains { $0.value.click != nil }
        hasTabs = contributions.contains { $0.value.adornment.placement == .onTopEdge }
    }

    var keptCount: Int { kept.count }
    /// Those of them that show something: their faces are made.
    var keptShowingCount: Int { kept.values.reduce(0) { $0 + ($1.shown.isEmpty ? 0 : 1) } }

    // MARK: What a shape shows

    /// The adornments a shape shows, in claim order (its kind's candidates whose labels say
    /// something: text that isn't blank, or a symbol), each with its face; nil for none, and on a
    /// shape kept aside. Callers go by `editor.drawsSkeleton(of:)` first: a skeleton shows only its tab
    /// (`tabsOnly`), and not a placeholder's.
    func laidOut(_ record: AnyShapeRecord, keeping: Bool = true, tabsOnly: Bool = false) -> LaidOutAdornments? {
        guard !isEmpty, !record.isOpaque else { return nil }
        if tabsOnly, !hasTab(record.kind) { return nil }
        let candidates = candidates(for: record.kind)
        guard !candidates.isEmpty else { return nil }
        if keeping, let known = kept[record.id], known.tabsOnly == tabsOnly { return known.shown.isEmpty ? nil : known }
        let context = AdornmentContext(editor: editor)
        // Each contribution's labels that say something, one adornment each, in order; a group's
        // know how many follow them, for the "+N" chip that stands for them.
        var shown: [ShownAdornment] = []
        for (index, candidate) in candidates.enumerated() where !tabsOnly || candidate.adornment.placement == .onTopEdge {
            let labels = candidate.labels(record, context).filter { $0.showsSomething && !(tabsOnly && $0.isPlaceholder) }
            for (position, label) in labels.enumerated() {
                shown.append(ShownAdornment(candidate, label: label, group: candidate.isGroup ? index : nil, remaining: labels.count - position))
            }
        }
        guard !shown.isEmpty else {
            if keeping {
                kept[record.id] = LaidOutAdornments(shown: [], items: [], faces: [], compactFaces: [], overflowFaces: [], leadLooks: [],
                                                    tabsOnly: tabsOnly)
            }
            return nil
        }
        let faces = shown.map { AdornmentStyle.face(of: $0.label, in: $0.id.placement) }
        let compactFaces: [AdornmentStyle.Face?] = shown.map { adornment in
            adornment.label.compactFace.map { AdornmentStyle.face(of: $0, in: adornment.id.placement) }
        }
        let overflowFaces: [AdornmentStyle.Face?] = shown.map { adornment in
            adornment.overflowLabel.map { overflowFace(of: $0, in: adornment.id.placement) }
        }
        #if DEBUG
        facesMade += faces.count + compactFaces.filter { $0 != nil }.count + overflowFaces.filter { $0 != nil }.count
        #endif
        let items = (0..<shown.count).map {
            shown[$0].item(width: faces[$0].width, compactWidth: compactFaces[$0]?.width, overflowWidth: overflowFaces[$0]?.width)
        }
        let leadLooks: [[(label: AdornmentLabel, face: AdornmentStyle.Face)]] = shown.indices.map { index in
            guard shown[index].id.placement == .inLabelLead else { return [] }
            return [(shown[index].label, faces[index])] + shown[index].label.narrowerFaces.map { ($0, AdornmentStyle.face(of: $0, in: .inLabelLead)) }
        }
        let laidOut = LaidOutAdornments(shown: shown, items: items, faces: faces, compactFaces: compactFaces, overflowFaces: overflowFaces,
                                        leadLooks: leadLooks, tabsOnly: tabsOnly)
        if keeping { kept[record.id] = laidOut }
        return laidOut
    }

    /// These shapes' labels are made again when they're next asked for.
    func forget(_ ids: Set<ShapeID>) {
        for id in ids {
            kept[id] = nil
            leadMemo[id] = nil
        }
        if touchesTabs(ids) { generation += 1 }
    }

    /// Whether any of these shapes has, or had, a tab: what changes where tabs go.
    private func touchesTabs<S: Sequence>(_ ids: S) -> Bool where S.Element == ShapeID {
        guard hasTabs else { return false }
        return ids.contains { id in tabShapesPlaced.contains(id) || editor.document[id].map { hasTab($0.kind) } == true }
    }

    // MARK: Tabs

    /// Whether a kind's shapes may show a tab: some contribution it has is one. Found once a kind.
    private func hasTab(_ kind: ShapeKind) -> Bool {
        if let known = tabCandidatesKept[kind] { return known }
        let found = hasTabs && candidates(for: kind).contains { $0.adornment.placement == .onTopEdge }
        tabCandidatesKept[kind] = found
        return found
    }

    /// How far past a region tabs are placed with those in it, in view points, so one that a tab just
    /// outside it pushes along is placed as it would be with the region moved a little: the view's tabs
    /// are placed alike from frame to frame as it pans.
    static let tabMargin: CGFloat = 240

    /// Where the tabs of the shapes in `region` (world units: the view) and `tabMargin` past it go, each
    /// clear of the others: placed in rank, the outermost shape first (fewest containers, the core's
    /// containment), then the larger, then the higher, then the farther left; each slid along its edge past
    /// those placed before it (`AdornmentLayout.tabs`); an untitled shape's placeholder after every title, so
    /// a word that names nothing never pushes a name along. Only closed shapes have one. Kept while the
    /// region, the zoom, the shapes with tabs and their labels are as they were, so drawing a frame and
    /// pointing in it place them once. Costs a look at each shape in the region (a kind's lookup), and a
    /// sort of those with one.
    func tabs(in region: CGRect) -> PlacedTabs {
        let zoom = editor.camera.zoom
        let key = TabsKey(region: region, zoom: zoom, generation: generation, editing: editor.editingShapeID)
        if let known = tabsKept.last(where: { $0.key == key }) { return known.tabs }
        let unit = 1 / zoom, shapes = editor.shapeContext, document = editor.document, kinds = editor.registry.containingKinds
        let grown = region.insetBy(dx: -(Self.tabMargin + AdornmentLayout.tabHeight) * unit, dy: -(Self.tabMargin + AdornmentLayout.tabHeight) * unit)
        struct Asked {
            let id: ShapeID
            let order: Int
            let isPlaceholder: Bool
            let depth: Int
            let bounds: CGRect
            let request: AdornmentLayout.TabRequest
        }
        var asked: [Asked] = []
        for (order, record) in editor.paintOrder(in: grown).enumerated() where hasTab(record.kind) {
            guard let geometry = shapes.geometry(of: record.id), geometry.isClosed, !geometry.bounds.isNull,
                  let laidOut = laidOut(record, tabsOnly: editor.drawsSkeleton(of: record.id)),
                  let index = laidOut.shown.firstIndex(where: { $0.id.placement == .onTopEdge }) else { continue }
            let bounds = geometry.bounds
            let rect = CGRect(x: bounds.minX / unit, y: bounds.minY / unit, width: bounds.width / unit, height: bounds.height / unit)
            asked.append(Asked(id: record.id, order: order, isPlaceholder: laidOut.shown[index].label.isPlaceholder,
                               depth: document.containers(of: record.id, containingKinds: kinds).count,
                               bounds: bounds, request: AdornmentLayout.TabRequest(shape: rect, item: laidOut.items[index])))
        }
        let ranked = asked.sorted { a, b in
            if a.isPlaceholder != b.isPlaceholder { return b.isPlaceholder }
            if a.depth != b.depth { return a.depth < b.depth }
            let areas = (a.bounds.width * a.bounds.height, b.bounds.width * b.bounds.height)
            if areas.0 != areas.1 { return areas.0 > areas.1 }
            if a.bounds.minY != b.bounds.minY { return a.bounds.minY < b.bounds.minY }
            if a.bounds.minX != b.bounds.minX { return a.bounds.minX < b.bounds.minX }
            return a.order < b.order
        }
        var placed: [ShapeID: AdornmentLayout.Tab] = [:]
        for (asked, tab) in zip(ranked, AdornmentLayout.tabs(ranked.map(\.request))) {
            guard var tab else { continue }
            // From the shape's top-left corner, as a slot is.
            tab.frame = tab.frame.offsetBy(dx: -asked.request.shape.minX, dy: -asked.request.shape.minY)
            placed[asked.id] = tab
        }
        let tabs = PlacedTabs(tabs: placed, shapes: asked.filter { placed[$0.id] != nil }.map(\.id), unit: unit)
        tabShapesPlaced.formUnion(asked.lazy.map(\.id))
        if tabsKept.count >= 4 { tabsKept.removeFirst() }
        tabsKept.append((key, tabs))
        return tabs
    }

    /// The tabs the overlay draws for the view it draws: kept as the region pointing goes by.
    func drawnTabs(in visible: CGRect) -> PlacedTabs {
        drawnTabRegion = visible
        return tabs(in: visible)
    }

    /// The region whose tabs are placed together for a shape or a point at `rect`: the one last drawn where
    /// `rect` meets it, so what's hit is what's drawn; else the view the editor has, where it meets it; else
    /// `rect` itself.
    func tabRegion(around rect: CGRect) -> CGRect {
        let near = rect.insetBy(dx: -1, dy: -1)
        if let drawn = drawnTabRegion, drawn.intersects(near) { return drawn }
        let size = editor.viewportSize
        if size.width > 0, size.height > 0 {
            let visible = editor.camera.toWorld(CGRect(origin: .zero, size: size))
            if visible.intersects(rect.insetBy(dx: -1, dy: -1)) { return visible }
        }
        return rect
    }

    /// A shape's tab into its slot, where it was placed (`tabs(in:)`).
    private func placeTab(of laidOut: LaidOutAdornments, id: ShapeID, tabs: PlacedTabs?, into slots: inout [AdornmentLayout.Slot?]) {
        guard let tabs, let tab = tabs.tabs[id], let index = laidOut.shown.firstIndex(where: { $0.id.placement == .onTopEdge }) else { return }
        slots[index] = AdornmentLayout.Slot(frame: tab.frame, isFromRight: false, tabUnit: tabs.unit, isTurned: tab.isTurned)
    }

    // MARK: A label's lead

    /// What the lead of a shape's label says its faces are, answered for the layout input geometry reads
    /// (`AdornmentLead.faces`): from the first of the shape's contributions at `inLabelLead` that shows anything.
    /// Nil for a shape with none, which is what a kind that places none costs: a lookup. `recording` (the editor's own
    /// reading, not a transaction's) keeps the answer, so that a change of what the pill says with no commit to the shape
    /// can tell the layout (`leadsMayHaveChanged`). Faces are measured once for each label.
    func leadFaces(of record: AnyShapeRecord, recording: Bool) -> AdornmentLead.Faces? {
        let leads = leadCandidates(for: record.kind)
        guard !leads.isEmpty, !isEmpty else { return nil }
        // A shape that only moved (a note it is bound to was dragged) has the answer it had, as its labels are: kept until a commit names it
        // or `adornmentsDidChange` does.
        if recording, let known = leadMemo[record.id] { return known.faces }
        let faces = leadFaces(of: record, among: leads)
        if recording {
            leadAnswered[record.id] = LeadAnswer(faces: faces, revision: editor.revision)
            leadMemo[record.id] = LeadAnswer(faces: faces, revision: editor.revision)
        }
        return faces
    }

    private func leadFaces(of record: AnyShapeRecord, among leads: [AdornmentContribution]) -> AdornmentLead.Faces? {
        let context = AdornmentContext(editor: editor)
        for lead in leads {
            guard let label = lead.labels(record, context).first(where: \.showsSomething) else { continue }
            if let known = leadFacesKept[label] { return known }
            let ladder = [label] + label.narrowerFaces
            let sizes = ladder.map { label -> CGSize in
                let face = AdornmentStyle.face(of: label, in: .inLabelLead)
                return CGSize(width: face.width, height: face.height(in: .inLabelLead))
            }
            let faces = AdornmentLead.Faces(sizes: sizes, tint: label.tint)
            if leadFacesKept.count >= 512 { leadFacesKept.removeAll(keepingCapacity: true) }
            leadFacesKept[label] = faces
            return faces
        }
        return nil
    }

    private func leadCandidates(for kind: ShapeKind) -> [AdornmentContribution] {
        if let known = leadCandidatesKept[kind] { return known }
        let found = candidates(for: kind).filter { $0.adornment.placement == .inLabelLead }
        leadCandidatesKept[kind] = found
        return found
    }

    /// What the pill of these shapes says may have changed with no commit to them (a type renamed, a field added, a
    /// check that turned): the shapes whose answer is not what geometry last read are laid out again, once every
    /// service has settled the change being delivered, if one is (`onceSettled`: a pill's label asks other plugins'
    /// services), and the select tool then looks again under the pointer, its buttons where the pills are now.
    func leadsMayHaveChanged(_ ids: Set<ShapeID>) {
        guard !leadAnswered.isEmpty, !ids.isEmpty else { return }
        let asked = !leadsToLookAt.isEmpty
        leadsToLookAt.formUnion(ids)
        guard !asked else { return }
        editor.onceSettled { [weak self] in self?.lookAtLeadsToldOf() }
    }

    /// The leads told of (`leadsMayHaveChanged`), looked at once every service has settled.
    private var leadsToLookAt: Set<ShapeID> = []

    private func lookAtLeadsToldOf() {
        let ids = leadsToLookAt
        leadsToLookAt = []
        var moved: [ShapeID] = []
        for id in ids {
            guard let known = leadAnswered[id], let record = editor.document[id] ?? editor.shape(inFile: id) else { continue }
            let leads = leadCandidates(for: record.kind)
            if leadFaces(of: record, among: leads) != known.faces { moved.append(id) }
        }
        guard !moved.isEmpty else { return }
        editor.shapesDidChangeLayout(moved)
        editor.canvasButtonsDidChange()
    }

    /// What was answered, and as of which commit.
    private struct LeadAnswer {
        let faces: AdornmentLead.Faces?
        let revision: Int
    }

    /// A group's "+N" face: the same text, in the same place, is the same face on every shape, so it is made
    /// once (measuring text is what a face costs).
    private func overflowFace(of label: AdornmentLabel, in placement: AdornmentPlacement) -> AdornmentStyle.Face {
        let key = OverflowKey(text: label.text ?? "", placement: placement)
        if let known = overflowFacesKept[key] { return known }
        let face = AdornmentStyle.face(of: label, in: placement)
        if overflowFacesKept.count < 64 { overflowFacesKept[key] = face }
        return face
    }

    private struct OverflowKey: Hashable {
        let text: String
        let placement: AdornmentPlacement
    }

    private func candidates(for kind: ShapeKind) -> [AdornmentContribution] {
        if let known = candidates[kind] { return known }
        let registry = editor.registry
        guard registry.definition(for: kind) != nil else { return [] }
        // A kind's own come first, so each takes the place of a scoped one of its type; then each goes
        // where its order puts it, counted from there.
        var seen = Set<AdornmentID>()
        let found = OrderRule.arranged(registry.contributions(to: ShapeAdornments.self, for: kind).filter { seen.insert($0.adornment).inserted }) {
            ($0.adornment.anchor, $0.adornment.order)
        }
        candidates[kind] = found
        return found
    }

    /// Whether a shape in `AdornmentLayout.area(showing:scale:)` can have an adornment in `visible`: nothing is made, laid out or
    /// drawn for one that cannot. The area is the widest case (a row slid along a slanted open shape reaches 400 view points
    /// either way), which a closed shape has no part in: its own reach is `AdornmentLayout.reach(ofClosed:scale:)`. An open
    /// shape stays.
    func mayShow(_ record: AnyShapeRecord, in visible: CGRect, scale: CGFloat, shapes: ShapeContext) -> Bool {
        guard let geometry = shapes.geometry(of: record.id), !geometry.outline.isEmpty, !geometry.bounds.isNull else { return false }
        guard geometry.isClosed else { return true }
        return visible.intersects(AdornmentLayout.reach(ofClosed: geometry.bounds, scale: scale))
    }

    // MARK: Where

    /// The rect a shape's adornments are laid out against, in world units, at `zoom`: a closed
    /// shape's bounds. An open shape's (a wire's), its label's if it has one (`geometry.label`:
    /// the chips sit above the words), else the middle of its outline, a point; and either widened
    /// about its center to `minAnchorWidth` view points where it is narrower, so a row of chips has
    /// room. Nil for a shape without an outline (nothing drawn), which has none.
    static func anchor(of id: ShapeID, in shapes: ShapeContext, zoom: CGFloat) -> CGRect? {
        anchored(of: id, in: shapes, zoom: zoom)?.rect
    }

    /// A shape's anchor, and for an open shape the slope of its chord (the outline's first point to its last:
    /// dy / dx in world units, y down; 0 when level or a point, infinite when upright), which slides what is
    /// laid out against the anchor clear of its body. Nil slope for a closed shape: nothing is read for it.
    struct Anchored {
        let rect: CGRect
        let slope: CGFloat?
        /// An open shape with no label: the anchor is a point widened, and the row is centred on it.
        var isPoint = false
        /// The room its geometry keeps at the start of its label for a pill (`ShapeGeometry.labelLead`).
        var lead: CGRect?
    }

    static func anchored(of id: ShapeID, in shapes: ShapeContext, zoom: CGFloat) -> Anchored? {
        guard let geometry = shapes.geometry(of: id), !geometry.outline.isEmpty, !geometry.bounds.isNull else { return nil }
        if geometry.isClosed { return Anchored(rect: geometry.bounds, slope: nil) }
        let label = geometry.label.flatMap { $0.isNull ? nil : $0 }
        var anchor = label ?? CGRect(origin: geometry.outline[geometry.outline.count / 2], size: .zero)
        let least = AdornmentLayout.minAnchorWidth * AdornmentLayout.scale(atZoom: zoom)
        if anchor.width < least { anchor = CGRect(x: anchor.midX - least / 2, y: anchor.minY, width: least, height: anchor.height) }
        var slope: CGFloat = 0
        if let first = geometry.outline.first, let last = geometry.outline.last {
            let dx = last.x - first.x, dy = last.y - first.y
            if dx != 0 { slope = dy / dx } else if dy != 0 { slope = .infinity }
        }
        return Anchored(rect: anchor, slope: slope, isPoint: label == nil, lead: label == nil ? nil : geometry.labelLead)
    }

    /// A shape's adornments' slots, into `slots`: the layout against its anchor, and the slope of an open shape's
    /// chord, which slides the row clear of its body (a closed shape reads nothing of the sort); its tab where
    /// `tabs` placed it (none where they didn't).
    /// Returns how far the row slid, in view points (`AdornmentLayout.slots`).
    @discardableResult
    func slots(of laidOut: LaidOutAdornments, id: ShapeID, anchored: Anchored, scale: CGFloat, tabs: PlacedTabs?,
               into slots: inout [AdornmentLayout.Slot?]) -> CGFloat {
        let slant = anchored.slope.map {
            AdornmentLayout.Slant(anchorHeight: anchored.rect.height / scale, slope: $0, maxSlide: AdornmentLayout.slideLimit(atScale: scale),
                                  centersRow: anchored.isPoint)
        }
        let shift = AdornmentLayout.slots(of: laidOut.items, width: anchored.rect.width / scale, slant: slant, into: &slots)
        placeLeads(of: laidOut, in: anchored, into: &slots)
        if laidOut.hasTab { placeTab(of: laidOut, id: id, tabs: tabs, into: &slots) }
        return shift
    }

    /// The lead of the shape's label, where its geometry kept room for it, in the face that room is the size of;
    /// nothing where the geometry kept none.
    private func placeLeads(of laidOut: LaidOutAdornments, in anchored: Anchored, into slots: inout [AdornmentLayout.Slot?]) {
        guard laidOut.hasLead, let lead = anchored.lead else { return }
        for index in laidOut.shown.indices where laidOut.shown[index].id.placement == .inLabelLead {
            let looks = laidOut.leadLooks[index]
            var best = 0, nearest = CGFloat.infinity
            for (face, look) in looks.enumerated() {
                let size = CGSize(width: look.face.width, height: look.face.height(in: .inLabelLead))
                let distance = abs(size.width - lead.width) + abs(size.height - lead.height)
                if distance < nearest { (best, nearest) = (face, distance) }
            }
            slots[index] = AdornmentLayout.Slot(frame: CGRect(origin: .zero, size: lead.size), isFromRight: false, lead: (lead, best))
        }
    }

    /// The anchor of a shape moved along with its row: where something that hangs from the row hangs (a card, a
    /// menu), world units. The anchor itself where the row did not slide, nothing is shown, or the shape is closed.
    func rowAnchor(of id: ShapeID) -> CGRect? {
        let shapes = editor.shapeContext, zoom = editor.camera.zoom
        guard let anchored = Self.anchored(of: id, in: shapes, zoom: zoom) else { return nil }
        guard anchored.slope != nil, let record = editor.document[id], !editor.drawsSkeleton(of: id), let laidOut = laidOut(record) else { return anchored.rect }
        let scale = AdornmentLayout.scale(atZoom: zoom)
        var slots: [AdornmentLayout.Slot?] = []
        let shift = self.slots(of: laidOut, id: id, anchored: anchored, scale: scale, tabs: nil, into: &slots)
        return anchored.rect.offsetBy(dx: shift * scale, dy: 0)
    }

    /// Where a shape's adornments are now, in world units: on a shape drawn as a skeleton, only its tab.
    func frames(of record: AnyShapeRecord) -> [AdornmentFrame] {
        let shapes = editor.shapeContext, zoom = editor.camera.zoom
        let skeleton = editor.drawsSkeleton(of: record.id)
        guard !skeleton || hasTabs, let laidOut = laidOut(record, tabsOnly: skeleton),
              let anchored = Self.anchored(of: record.id, in: shapes, zoom: zoom) else { return [] }
        let anchor = anchored.rect, scale = AdornmentLayout.scale(atZoom: zoom)
        let tabs = laidOut.hasTab ? self.tabs(in: tabRegion(around: anchor)) : nil
        var slots: [AdornmentLayout.Slot?] = []
        self.slots(of: laidOut, id: record.id, anchored: anchored, scale: scale, tabs: tabs, into: &slots)
        return laidOut.shown.indices.compactMap { index in
            slots[index].map {
                AdornmentFrame(adornment: laidOut.shown[index].id, label: laidOut.look(of: index, in: $0).label,
                               rect: $0.worldRect(in: anchor, scale: scale), isOverflow: $0.isOverflow)
            }
        }
    }

    // MARK: Pointing

    /// The front-most adornment within `hitMargin` of a world point, of the shapes `include`
    /// accepts, where they are (not where a shake draws them), as it's drawn: of one shape's, the
    /// nearest. On a shape drawn as a skeleton, only its tab.
    func hit(at point: CGPoint, where include: (AnyShapeRecord) -> Bool) -> (shape: ShapeID, adornment: ShownAdornment, isOverflow: Bool)? {
        guard !isEmpty, !editor.drawsSkeletons || editor.editingShapeID != nil || hasTabs else { return nil }
        let zoom = editor.camera.zoom, scale = AdornmentLayout.scale(atZoom: zoom), shapes = editor.shapeContext
        let at = CGRect(origin: point, size: .zero)
        let near = at.insetBy(dx: -AdornmentLayout.hitMargin * scale, dy: -AdornmentLayout.hitMargin * scale)
        // Zoomed out, only tabs and the shape being edited show anything: with none edited, only the tabs near the point.
        var area = editor.drawsSkeletons && editor.editingShapeID == nil ? at : AdornmentLayout.area(around: point, scale: scale)
        // A tab's shape meets the point grown by half the tab's height, as large on screen at every zoom.
        let tabs = hasTabs ? self.tabs(in: tabRegion(around: at)) : nil
        if tabs != nil {
            let reach = (AdornmentLayout.tabHeight / 2 + AdornmentLayout.hitMargin) / zoom
            area = area.union(at.insetBy(dx: -reach, dy: -reach))
        }
        for record in editor.paintOrder(in: area).reversed() where include(record) {
            let skeleton = editor.drawsSkeleton(of: record.id), hasTab = tabs?.tabs[record.id] != nil
            guard skeleton ? hasTab : hasTab || mayShow(record, in: near, scale: scale, shapes: shapes),
                  let laidOut = laidOut(record, tabsOnly: skeleton),
                  let anchored = Self.anchored(of: record.id, in: shapes, zoom: zoom) else { continue }
            let anchor = anchored.rect
            var nearest: (index: Int, distance: CGFloat, isOverflow: Bool)?
            var slots: [AdornmentLayout.Slot?] = []
            self.slots(of: laidOut, id: record.id, anchored: anchored, scale: scale, tabs: tabs, into: &slots)
            for (index, slot) in slots.enumerated() {
                guard let slot else { continue }
                let corner = slot.corner(in: anchor), unit = slot.unit(scale)
                let local = CGPoint(x: (point.x - corner.x) / unit, y: (point.y - corner.y) / unit)
                // A tab is a rounded rect with a tab's corners; the rest are capsules.
                let distance = slot.tabUnit == nil ? AdornmentLayout.distance(from: local, to: slot.frame)
                                                   : AdornmentLayout.distance(from: local, to: slot.frame, radius: AdornmentLayout.tabRadius)
                if distance <= AdornmentLayout.hitMargin, distance < nearest?.distance ?? .infinity { nearest = (index, distance, slot.isOverflow) }
            }
            if let nearest { return (record.id, laidOut.shown[nearest.index], nearest.isOverflow) }
        }
        return nil
    }

    /// The front-most shape, of those `include` accepts, with an adornment under a world point: the
    /// shape a press, a hover or a right-click there is on (`DecorationHits`).
    func shape(at point: CGPoint, where include: (AnyShapeRecord) -> Bool) -> ShapeID? {
        hit(at: point, where: include)?.shape
    }

    /// The clickable adornment under a view point: what the select tool clicks there
    /// (`CanvasButtons`). Only when the front-most adornment there is one, so a front shape's pill
    /// over a back shape's lock takes the press, as it's drawn over it.
    func button(atViewPoint point: CGPoint) -> AdornmentButton? {
        guard hasButtons, let hit = hit(at: editor.camera.toWorld(point), where: { _ in true }), hit.adornment.isClickable else { return nil }
        return AdornmentButton(hit.adornment.id, on: hit.shape, tag: hit.isOverflow ? nil : hit.adornment.label.tag, isOverflow: hit.isOverflow)
    }

    /// A click on a clickable adornment: its type's `click`.
    func click(_ button: AdornmentButton) {
        guard let record = editor.document[button.shape],
              let click = candidates(for: record.kind).first(where: { $0.adornment == button.adornment })?.click else { return }
        let rect = frames(of: record).first { $0.adornment == button.adornment && $0.tag == button.tag && $0.isOverflow == button.isOverflow }?.rect ?? .null
        click(AdornmentClick(shape: button.shape, tag: button.tag, rect: rect, isOverflow: button.isOverflow), editor)
    }
}

extension AdornmentState: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        // A shape that only moved (a drag) has the labels it had: they are laid out against its bounds when
        // asked, never kept at a place. Everything else a commit touched is made again.
        for id in changes.added {
            kept[id] = nil
            leadMemo[id] = nil
        }
        for id in changes.removed {
            kept[id] = nil
            leadAnswered[id] = nil
            leadMemo[id] = nil
        }
        // A shape the commit changed has its geometry worked out again, with an answer of its own: what was answered before this
        // commit (not what a service that heard before this one asked for during it) is void.
        if !leadAnswered.isEmpty {
            for id in changes.edited where leadAnswered[id].map({ $0.revision < editor.revision }) == true {
                leadAnswered[id] = nil
            }
        }
        for id in changes.changed where !changes.moved.contains(id) {
            kept[id] = nil
            leadMemo[id] = nil
        }
        if touchesTabs(changes.added) || touchesTabs(changes.changed) || touchesTabs(changes.removed) { generation += 1 }
    }

    /// Another board is shown: what the board left's shapes showed goes, and the shown board's
    /// labels are made as they're asked for, as the first read of a board's makes them. Kept per board
    /// on purpose, it would cost more than it saves: labels are made only for the shapes a frame
    /// draws, so going back makes at most a frame's worth, and what a label reads beyond its shape
    /// (Locking's lock, open and fading) is let go of on a switch without a word to Adornments, so a
    /// label kept would come back stale.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        kept = [:]
        leadAnswered = [:]
        leadMemo = [:]
        leadsToLookAt = []
        generation += 1
        tabsKept = []
        tabShapesPlaced = []
        drawnTabRegion = nil
    }

    /// The canvas started or stopped drawing skeletons: zoomed out, a skeleton shows only its tab, so
    /// what's kept goes (the shape being edited makes its own again as it's drawn); zoomed in, the
    /// labels and faces of what's in view are made again as it's drawn, the tabs kept zoomed out with them.
    /// What's under a still pointer, a button come or gone, the select tool looks for again (Selection
    /// hears this too, first), and the layouts it reads answer at the new level whether this has heard it
    /// or not.
    func drawsSkeletonsDidChange(in editor: CanvasEditor) {
        kept = [:]
        generation += 1
    }
}

/// The tabs placed for a region (`AdornmentState.tabs(in:)`): each shape's, from its top-left corner in view
/// points, `unit` world units a point (the same size on screen at every zoom), and the shapes that have one,
/// in paint order.
struct PlacedTabs {
    let tabs: [ShapeID: AdornmentLayout.Tab]
    let shapes: [ShapeID]
    let unit: CGFloat
}

/// What tabs were placed for: they're placed again when any of it changes.
struct TabsKey: Equatable {
    let region: CGRect
    let zoom: CGFloat
    let generation: Int
    let editing: ShapeID?
}

/// A shape's adornments, laid out: each label, with how wide it's laid out (its face's width), and
/// each one's face.
@MainActor
struct LaidOutAdornments {
    let shown: [ShownAdornment]
    let items: [AdornmentLayout.Item]
    let faces: [AdornmentStyle.Face]
    /// Each shown adornment's compact face, if its label has one (`AdornmentLabel.compact(_:)`): the
    /// layout says which of the two is drawn.
    let compactFaces: [AdornmentStyle.Face?]
    /// Each group member's "+N" face, the one that stands for it and those after it.
    let overflowFaces: [AdornmentStyle.Face?]
    /// For an adornment at a label's lead, each face it may take: the whole one, then the narrower ones, widest
    /// first (empty for any other).
    let leadLooks: [[(label: AdornmentLabel, face: AdornmentStyle.Face)]]
    /// Made for a shape drawn as a skeleton: only its tab, and not a placeholder's.
    let tabsOnly: Bool

    /// Some adornment is at a label's lead.
    var hasLead: Bool { shown.contains { $0.id.placement == .inLabelLead } }
    /// Some adornment is a tab.
    var hasTab: Bool { shown.contains { $0.id.placement == .onTopEdge } }

    /// The label and face drawn for adornment `index` in `slot`: its compact ones where the layout
    /// placed those, the "+N" chip's where it folded into one, the face of a label's lead that its room is the size of.
    func look(of index: Int, in slot: AdornmentLayout.Slot) -> (label: AdornmentLabel, face: AdornmentStyle.Face) {
        if let lead = slot.lead, leadLooks[index].indices.contains(lead.face) { return leadLooks[index][lead.face] }
        if slot.isOverflow, let face = overflowFaces[index], let label = shown[index].overflowLabel { return (label, face) }
        if slot.isCompact, let face = compactFaces[index], let label = shown[index].label.compactFace { return (label, face) }
        return (shown[index].label, faces[index])
    }
}

/// One adornment as a shape shows it: its label, which says something (text that isn't blank, or a
/// symbol), and the room its text needs besides itself (`lead`: a symbol before it, a number after it).
@MainActor
struct ShownAdornment {
    let id: AdornmentID
    let label: AdornmentLabel
    let isClickable: Bool
    /// Text, which gives way at the row's left end; otherwise a symbol's disc.
    let isText: Bool
    let lead: CGFloat
    /// The contribution it's one of several of (a group), and the "+N" that stands for it and the
    /// labels after it: nil for an adornment on its own.
    let group: Int?
    let overflowLabel: AdornmentLabel?

    /// A label that shows something (`AdornmentLabel.showsSomething`): the caller leaves the others
    /// out. `remaining` is how many of its group's labels there are from this one on.
    init(_ contribution: AdornmentContribution, label: AdornmentLabel, group: Int?, remaining: Int) {
        id = contribution.adornment
        self.label = label
        isClickable = contribution.click != nil
        isText = label.text != nil
        // The layout leaves text the room it needs besides this: its symbol before it, and its number after it.
        lead = AdornmentStyle.lead(of: label, in: id.placement) + AdornmentStyle.countRoom(of: label, in: id.placement)
        self.group = group
        overflowLabel = group == nil ? nil : AdornmentLabel(AdornmentStyle.overflowPrefix + String(remaining))
    }

    func item(width: CGFloat, compactWidth: CGFloat?, overflowWidth: CGFloat?) -> AdornmentLayout.Item {
        AdornmentLayout.Item(id.placement, width: width, isText: isText, lead: lead, compact: compactWidth.map { .init(width: $0) },
                             group: group, overflowWidth: overflowWidth ?? 0)
    }

    /// Whether this, on `shape`, is `button` (the one hovered or pressed): the same label, or the
    /// group's "+N" chip, which its labels share.
    func isButton(_ button: AdornmentButton?, on shape: ShapeID, isOverflow: Bool = false) -> Bool {
        guard let button, button.adornment == id, button.shape == shape, button.isOverflow == isOverflow else { return false }
        return isOverflow || button.tag == label.tag
    }
}

// MARK: Parts

/// Each clickable adornment a shape shows, as a part of the shape (Selection's `ShapeParts`), listed in the
/// scope the adornment is registered in (its sugar lists them): its rect where it is laid out now, its title
/// its label's text (else the type's `partTitle`), and a press that is its click. One that shows for a
/// moment and fades (`ChipFade`) is left out, and so is any on a shape drawn as a skeleton (none shows).
@MainActor
enum AdornmentParts {
    static func isClickable<A: Adornment>(_: A.Type) -> Bool { A.self is any ClickableAdornment.Type }

    static func parts<A: Adornment>(of _: A.Type, on id: ShapeID, in editor: CanvasEditor) -> [ShapePart] {
        guard let clickable = A.self as? any ClickableAdornment.Type, editor.adornmentState != nil,
              editor.service(ChipFade.self)?.isShowing(A.self, on: id) != true else { return [] }
        let adornment = AdornmentID.of(A.self)
        return editor.adornmentFrames(of: id).filter { $0.adornment == adornment }.map { frame in
            let button = AdornmentButton(adornment, on: id, tag: frame.tag, isOverflow: frame.isOverflow)
            return ShapePart(id: button, title: frame.label.text ?? clickable.partTitle, role: clickable.partRole, rect: frame.rect) { editor in
                editor.adornmentState?.click(button)
            }
        }
    }
}

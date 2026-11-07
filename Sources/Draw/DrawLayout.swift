import Canvas
import CoreGraphics
import DrawScript
import Geometry

// Placing a script's shapes: the layout problem DrawScript solves, built from the board as the run
// starts. The shapes that move are its free boxes (new shapes, and shapes restated with
// placements); the boxes their placements name that stay put are fixed (board shapes, shapes
// restated without placements, `board`, `view`); every board shape with a solid
// (`ShapeContext.solidBounds(of:)`) that the script doesn't move or delete is an obstacle. The
// obstacles are filed once a run (`ObstacleIndex`, a pass over the board, into DrawScript's
// `ObstacleGrid`), and the solver asks for them by region, each answer kept: however many times it
// asks, a question costs what's near the box it's about. A shape `in` a container on the board (a
// frame) is kept within it, as `inside` keeps one; a container that moves takes what it holds
// along, which is never in its way, and which every other shape the script places meets where the
// container takes it, never where it is now (`LayoutProblem.Free.carries`).

extension Drawing {
    /// Places every shape the script moves, or says why it can't (the solver's first problem), and
    /// builds each shape as it will be.
    mutating func place() throws(DrawError) {
        let target = target, context = target.shapes, document = target.document, registry = registry
        for index in items.indices where !items[index].moves || items[index].exact != nil {
            // Where a program's run puts it, exactly: its room there, never solved; where it already is, but for what arithmetic
            // in another order leaves over (a frame's origin and a place from it, added), as the solver's are.
            if let exact = items[index].exact {
                var rect = CGRect(origin: exact, size: items[index].room)
                if let current = items[index].existing.flatMap({ context.frame(of: $0.id) }), Self.isNearly(rect, current) { rect = current }
                items[index].placed = rect
                continue
            }
            guard let box = items[index].existing?.box else { throw broken(items[index], "it has no frame") }
            items[index].placed = CGRect(origin: CGPoint(x: box.minX + items[index].roomOffset.x, y: box.minY + items[index].roomOffset.y), size: items[index].room)
        }

        // What's in the way: board shapes that stay, those restated in place at their new size.
        var excluded = deleted
        for item in items where item.moves { if let id = item.existing?.id { excluded.insert(id) } }
        var resized: [ShapeID: CGRect] = [:]
        for item in items where !item.moves {
            if let existing = item.existing, let placed = item.placed, placed != context.frame(of: existing.id), context.solidBounds(of: existing.id) != nil {
                resized[existing.id] = placed
            }
        }
        let filed = ObstacleIndex(target.paintOrder(), document: document, context: context, excluding: excluded, resized: resized)
        let obstacles: (CGRect) -> [LayoutProblem.Obstacle] = { area in filed.obstacles(in: area) }

        // The boxes that move, in script order; a container among them with what it holds, which
        // goes along with it (`carried`, by place in the document: what goes where those go).
        let kinds = registry.containingKinds
        var free: [LayoutProblem.Free] = []
        var carried: Set<Int> = []
        for index in items.indices where items[index].moves && items[index].exact == nil {
            let item = items[index]
            items[index].free = free.count
            let carries = item.existing.map { existing in
                kinds.isEmpty ? [] : Set(document.descendants(of: existing.id, containingKinds: kinds).compactMap { document.index(of: $0) })
            } ?? []
            carried.formUnion(carries)
            free.append(LayoutProblem.Free(line: item.statement.line, name: subject(of: item), size: item.room, gap: item.shape.gap,
                                           overlapAllowed: item.shape.overlapAllowed, current: item.existing.flatMap { context.frame(of: $0.id) }, carries: carries,
                                           implied: item.implied))
        }

        // What their placements name.
        var fixed: [LayoutProblem.Fixed] = []
        var fixedNames: [String] = []
        var fixedShapes: [ShapeID: Int] = [:]
        var fixedWords: [PlaceWord: Int] = [:]
        let needsBoard = items.contains { item in item.targets.joined().contains { if case .board = $0 { true } else { false } } }
            || items.contains { $0.existing == nil && $0.shape.clauses.isEmpty && $0.exact == nil }
        // The board's shapes as they stay: what a container the script moves takes along isn't
        // where it is now, any more than the container is.
        let boardBounds = needsBoard ? filed.bounds(excluding: carried) : nil
        func fixedShape(_ record: AnyShapeRecord, rect: CGRect, gap: Gap?) -> LayoutProblem.Ref {
            if let at = fixedShapes[record.id] { return .fixed(at) }
            let obstacle = context.solidBounds(of: record.id) != nil ? document.index(of: record.id) : nil
            fixedShapes[record.id] = fixed.count
            fixed.append(LayoutProblem.Fixed(rect: rect, gap: gap, obstacle: obstacle))
            fixedNames.append(named(record))
            return .fixed(fixed.count - 1)
        }
        func fixedWord(_ word: PlaceWord, rect: CGRect) -> LayoutProblem.Ref {
            if let at = fixedWords[word] { return .fixed(at) }
            fixedWords[word] = fixed.count
            fixed.append(LayoutProblem.Fixed(rect: rect, word: word))
            fixedNames.append(word.rawValue)
            return .fixed(fixed.count - 1)
        }

        for index in items.indices {
            guard let box = items[index].free else { continue }
            let item = items[index]
            var clauses: [LayoutProblem.ResolvedClause] = []
            for (clause, found) in zip(item.shape.clauses, item.targets) {
                var refs: [LayoutProblem.Ref] = []
                var parts: [Int: CGRect] = [:]
                for (place, (target, what)) in zip(clause.targets, found).enumerated() {
                    // A corner on a shape's outline, when its outline isn't its bounds (a round shape's).
                    var outline: (points: [CGPoint], rect: CGRect)?
                    switch what {
                    case .item(let other):
                        let them = items[other]
                        if let theirs = them.free {
                            refs.append(.free(theirs))
                        } else if let existing = them.existing, let placed = them.placed {
                            refs.append(fixedShape(existing, rect: placed, gap: them.shape.gap))
                        }
                        if target.part?.isCorner == true {
                            outline = Drawing.outline(of: them.record, at: CGRect(origin: .zero, size: them.room), in: registry)
                        }
                    case .shape(let record):
                        guard let geometry = context.geometry(of: record.id), !geometry.bounds.isNull, geometry.bounds.isFinite else {
                            throw DrawError(item.statement, .unsupported, "\(named(record)) has nothing drawn to be placed against",
                                            hint: "place \(subject(of: item)) against another shape")
                        }
                        let bounds = geometry.bounds
                        refs.append(fixedShape(record, rect: bounds, gap: nil))
                        if geometry.isClosed {
                            outline = (geometry.outline.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }, CGRect(origin: .zero, size: bounds.size))
                        }
                    case .board:
                        guard let boardBounds else {
                            throw DrawError(item.statement, .unknownTitle, "\(subject(of: item)) is \(clause.written), and the board has nothing on it yet",
                                            hint: "leave the shape unplaced to draw it in view")
                        }
                        refs.append(fixedWord(.board, rect: boardBounds))
                    case .view:
                        guard let view else { throw DrawError(item.statement, .noView, "the board isn't in a window") }
                        refs.append(fixedWord(.view, rect: view))
                    case .origin:
                        refs.append(fixedWord(.origin, rect: .zero))
                    }
                    if let part = target.part, part.isCorner, let outline, let corner = Self.corner(part, on: outline.points, in: outline.rect) {
                        parts[place] = corner
                    }
                }
                clauses.append(LayoutProblem.ResolvedClause(clause, refs: refs, partRects: parts))
            }
            free[box].clauses = clauses
            // What holds it (`in "F"`) keeps it within.
            if let holder = item.holder {
                let ref: LayoutProblem.Ref
                if let other = items.firstIndex(where: { $0.existing?.id == holder.id }), let theirs = items[other].free {
                    ref = .free(theirs)
                } else if let other = items.firstIndex(where: { $0.existing?.id == holder.id }), let placed = items[other].placed {
                    ref = fixedShape(holder, rect: placed, gap: items[other].shape.gap)
                } else {
                    guard let bounds = context.geometry(of: holder.id)?.bounds, !bounds.isNull, bounds.isFinite else { throw broken(item, "what holds it has no bounds") }
                    ref = fixedShape(holder, rect: bounds, gap: nil)
                }
                free[box].holder = LayoutProblem.Holder(ref, written: "in \(named(holder))")
            }
        }

        // Solve.
        let freeNames = free.map(\.name), names = fixedNames
        let naming = self.naming, boardNames = self.names, editor = self.editor
        // A board shape as a message names it: its title in quotes, or its path when the title is not its alone.
        let shapeName: (AnyShapeRecord) -> String? = { record in
            guard let title = Drawing.title(of: record, names: boardNames, naming: naming, registry: registry) else { return nil }
            guard (boardNames.ids[title]?.count ?? 0) > 1, let naming else { return quoted(title) }
            return (Drawing.path(of: record.id, in: editor, naming: naming) ?? ShapePath(head: .board, rest: [title])).written
        }
        let problem = LayoutProblem(
            free: free, fixed: fixed, obstacles: obstacles, boardBounds: boardBounds,
            viewMiddle: view.map { CGPoint(x: $0.midX, y: $0.midY) } ?? target.shapes.camera.toWorld(CGPoint.zero), view: view,
            name: { ref in
                switch ref {
                case .free(let box): return freeNames[box]
                case .fixed(let box): return names[box]
                case .obstacle(let id):
                    guard document.shapes.indices.contains(id) else { return "a shape" }
                    let record = document.shapes[id]
                    return shapeName(record) ?? Drawing.location(of: record, in: context)
                }
            })
        let solution: LayoutSolution
        do throws(ScriptError) {
            solution = try problem.solve()
        } catch {
            throw DrawError(error, statement: text(ofLine: error.line))
        }

        for index in items.indices {
            guard let box = items[index].free else { continue }
            var rect = solution.rects[box]
            // Where it already is, but for what arithmetic in another order leaves over.
            if let current = items[index].existing.flatMap({ context.frame(of: $0.id) }), Self.isNearly(rect, current) { rect = current }
            guard rect.isFinite, rect.width > 0, rect.height > 0 else { throw broken(items[index], "it was placed nowhere (\(rect))") }
            items[index].placed = rect
            items[index].zones = solution.zones[box].map { document.shapes[$0.id].id }
        }
        try refuseCarriedTargets()
        /// What a box was pushed past, as a row names it and as a message does.
        func pushed(_ ref: LayoutProblem.Ref) -> (plain: String, quoted: String) {
            switch ref {
            case .free(let box):
                let item = items.first { $0.free == box }!
                let location = "\(item.kind) at \(point(CGPoint(x: item.placed!.midX, y: item.placed!.midY)))"
                return (item.title ?? location, subject(of: item))
            case .obstacle(let id):
                let record = document.shapes[id], title = Drawing.title(of: record, names: boardNames, naming: naming, registry: registry)
                let location = Drawing.location(of: record, in: context)
                return (title ?? location, shapeName(record) ?? location)
            case .fixed(let box):
                return (names[box], names[box])
            }
        }
        // Every push is said. A shape pushed past another says so on its row (`pushedPast`) and in a
        // warning, once for each thing it went past. One that only moved along with a shape that
        // was (placed against it, or that one against it) was kept clear of nothing itself, and the
        // placement to fix is the other's: its row has no `pushedPast` for it, and its warning
        // names the shape it went with and what that one went past, once for each shape it went
        // with and way it went. What it went past is said once for each way it went: a shape
        // pushed past a wall isn't also said to have gone along past it with another, and one that
        // went along past it with several (a list's members go as one, each pushed past it in
        // turn) is said to have gone with the first in script order. They're said in script order.
        struct Went: Hashable { var item: Int, leader: Int, way: Direction }
        var said: [(item: Int, way: Direction, along: Int?, past: [String], holds: Bool)] = []
        var went: [Went: Int] = [:]
        var itemOf: [Int: Int] = [:]
        for index in items.indices { if let box = items[index].free { itemOf[box] = index } }
        for push in solution.pushes {
            guard let index = itemOf[push.box] else { continue }
            let past = pushed(push.past)
            if let along = push.along {
                guard let leader = itemOf[along] else { continue }
                if let at = went[Went(item: index, leader: leader, way: push.way)] {
                    if !said[at].past.contains(past.quoted) { said[at].past.append(past.quoted) }
                } else {
                    went[Went(item: index, leader: leader, way: push.way)] = said.count
                    said.append((index, push.way, leader, [past.quoted], push.placementsHold))
                }
            } else if !items[index].pushedPast.contains(past.plain) {
                items[index].pushedPast.append(past.plain)
                said.append((index, push.way, nil, [past.quoted], push.placementsHold))
            }
        }
        // A shape slid along the axis its placement leaves free, to stay inside what holds it, says so.
        for slide in solution.slides {
            guard let index = itemOf[slide.box] else { continue }
            let how = switch slide.way {
            case .right: "right"
            case .left: "left"
            case .below: "down"
            default: "up"
            }
            notes.append(DrawWarning(line: items[index].statement.line,
                                     "\(subject(of: items[index])) was slid \(how) to stay inside \(pushed(slide.inside).quoted)"))
        }
        // What each shape went past each way: its own pushes first, then what it went along past,
        // with the shapes it went with in script order.
        struct Way: Hashable { var item: Int, way: Direction }
        var told: [Way: Set<String>] = [:]
        for push in said where push.along == nil { told[Way(item: push.item, way: push.way), default: []].formUnion(push.past) }
        for at in said.indices.filter({ said[$0].along != nil }).sorted(by: { (said[$0].along!, $0) < (said[$1].along!, $1) }) {
            let key = Way(item: said[at].item, way: said[at].way)
            said[at].past.removeAll { told[key]?.contains($0) == true }
            told[key, default: []].formUnion(said[at].past)
        }
        for push in said.indices.sorted(by: { (said[$0].item, $0) < (said[$1].item, $1) }).map({ said[$0] }) where !push.past.isEmpty {
            notes.append(DrawWarning(line: items[push.item].statement.line,
                                     pushMessage(items[push.item], past: push.past, way: push.way, along: push.along.map { items[$0] }, holds: push.holds)))
        }
        // A zone (a board shape that wholly holds the shape where it is now, what it's placed
        // against, where it lands among other shapes, or the view it's placed against or drawn in)
        // isn't in that shape's way, but doesn't keep it in either: one that hangs over its edge
        // is said.
        // What a shape is `inside` or `on` is no zone of it. Nor is a container's edge said: put down
        // over one, a shape is nudged wholly in or out (`Transaction.settle`), which is said then.
        for index in items.indices where !items[index].shape.overlapAllowed {
            let item = items[index]
            guard let box = item.free, let placed = item.placed else { continue }
            for zone in solution.zones[box] {
                guard Self.overlaps(zone.rect, placed, by: Self.overhang), !zone.rect.insetBy(dx: -Self.overhang, dy: -Self.overhang).contains(placed) else { continue }
                let record = document.shapes[zone.id]
                if registry.isContainer(record) { continue }
                notes.append(DrawWarning(line: item.statement.line,
                                         "\(subject(of: item)) hangs over the edge of \(named(record)) — make \(named(record)) bigger, or place \(subject(of: item)) elsewhere"))
            }
        }

        // Each shape as it'll be: where it goes, its title as it was (unless renamed), and changed
        // only if it may be.
        for index in items.indices {
            let item = items[index]
            var record = item.record
            // Written at the size it is stored at; the room it takes is the layout's (`ShapeItem.room`). A shape left where it is
            // keeps the box it has, bit for bit: the frame less the offset its kind lays it out at can come back a hair off.
            record.box = item.placed.map { CGRect(origin: CGPoint(x: $0.minX - item.roomOffset.x, y: $0.minY - item.roomOffset.y), size: item.size) }
            if let existing = item.existing, let box = existing.box, box.size == item.size, let placed = item.placed,
               placed == context.frame(of: existing.id) {
                record.box = box
            }
            guard record.box?.isFinite == true else { throw broken(item, "its frame isn't finite") }
            if let title = item.title, item.existing != nil, item.rename == nil { try keepsName(record, title, item) }
            if let existing = item.existing, record != existing, target.isReadOnly(existing), target.isReadOnly(record) {
                throw DrawError(item.statement, .readOnly, "\(subject(of: item)) is read-only (locked, say), so it stays as it is",
                                hint: "leave it out of the script, or ask the user to unlock it")
            }
            items[index].record = record
            // Resized where it stays, over what's around it: not one a container the script moves
            // takes along, which doesn't stay where it is.
            if let existing = item.existing, !item.moves, let placed = item.placed, placed.size != context.frame(of: existing.id)?.size, !item.shape.overlapAllowed,
               !(document.index(of: existing.id).map(carried.contains) ?? false) {
                // Over a container's edge, it's put down again, wholly in or out (`Transaction.settle`),
                // and so is what a container resized holds, or reaches beside it: said then.
                let level = registry.container(of: existing, in: document)
                let settles = { (other: AnyShapeRecord) -> Bool in
                    guard !registry.isContainer(other) else { return true }
                    guard registry.isContainer(existing) else { return false }
                    let theirs = registry.container(of: other, in: document)
                    return theirs == existing.id || theirs == level
                }
                let over = filed.entries(in: placed).map { filed.entries[$0] }.filter { other in
                    other.record.id != existing.id && Self.overlaps(other.rect, placed) && !(other.rect.contains(placed) || placed.contains(other.rect))
                        && !settles(other.record)
                }.map(\.record)
                if let first = over.first {
                    notes.append(DrawWarning(line: item.statement.line,
                                              "\(subject(of: item)) was resized where it is, and now overlaps \(named(first)) — place it to move it clear"))
                }
            }
        }
    }

    /// Refuses a placement against a shape that a container this script moves takes along (a frame's
    /// contents), and a shape in one (`in`): the layout has it where it was, and it won't be there.
    private func refuseCarriedTargets() throws(DrawError) {
        let kinds = registry.containingKinds, document = target.document
        guard !kinds.isEmpty else { return }
        var carriedBy: [ShapeID: AnyShapeRecord] = [:]
        for item in items where item.free != nil {
            guard let existing = item.existing, registry.isContainer(existing), let from = existing.box?.origin, let to = item.placed?.origin, from != to else { continue }
            for id in document.descendants(of: existing.id, containingKinds: kinds) where carriedBy[id] == nil { carriedBy[id] = existing }
        }
        guard !carriedBy.isEmpty else { return }
        for item in items where item.free != nil {
            var named: [(written: String, shape: AnyShapeRecord)] = []
            for (clause, found) in zip(item.shape.clauses, item.targets) {
                for target in found {
                    switch target {
                    case .shape(let record): named.append((clause.written, record))
                    case .item(let other) where items[other].free == nil:
                        if let existing = items[other].existing { named.append((clause.written, existing)) }
                    default: break
                    }
                }
            }
            if let holder = item.holder { named.append(("in \(self.named(holder))", holder)) }
            for (written, shape) in named {
                guard let container = carriedBy[shape.id] else { continue }
                throw DrawError(item.statement, .unsupported,
                                "\(subject(of: item)) is \(written), and \(self.named(shape)) moves with \(self.named(container)), which this script moves",
                                hint: "place it against \(self.named(container)), or in a run of its own after this one")
            }
        }
    }

    /// `"Why" was pushed right past "DB" to keep clear of it, so it no longer sits against "API"`,
    /// or, for a shape that went along with one pushed, `"D" moved right along with "N", which was
    /// pushed past "Q" to keep clear of it`. What it no longer sits against is said only when a
    /// placement of its own was loosened (`holds` false): a push that would take a shape off its
    /// centering or an alignment isn't made (it goes along the other axis, or it's `unordered`), so
    /// only a direction's gap grows.
    private func pushMessage(_ item: ShapeItem, past: [String], way: Direction, along leader: ShapeItem?, holds: Bool) -> String {
        let how = switch way {
        case .right: "right"
        case .left: "left"
        case .below: "down"
        default: "up"
        }
        var so = ""
        if !holds, let loosened = loosened(item, way) {
            so = ", so \(leader == nil ? "it" : subject(of: item)) no longer sits against \(listed(loosened))"
        }
        // A stand-in the run put beside an end has no placement of its own to change: the edge says
        // which side of the end it's beside. One its edge places is moved by those placements, and an
        // edge says no overlap:.
        let sides = "\(EdgeKey.from.rawValue): or \(EdgeKey.to.rawValue):"
        guard let leader else {
            let advice = item.implied ? "name another side for it with \(sides)"
                : item.standsFor == nil ? "place it on another side, or say overlap: allow" : "place it on another side"
            return "\(subject(of: item)) was pushed \(how) past \(listed(past)) to keep clear of it\(so) — \(advice)"
        }
        let them = past.count == 1 ? "it" : "them"
        let advice = leader.implied ? "name another side for \(subject(of: leader)) with \(sides)"
            : leader.standsFor == nil ? "place \(subject(of: leader)) on another side, or give \(subject(of: leader)) overlap: allow"
            : "place \(subject(of: leader)) on another side"
        return "\(subject(of: item)) moved \(how) along with \(subject(of: leader)), which was pushed past \(listed(past)) to keep clear of \(them)\(so) — \(advice)"
    }

    /// What a push loosened: the targets of the shape's first placement that holds it from the side
    /// it went away from (`right of` for a push right), whose gap is what grew.
    private func loosened(_ item: ShapeItem, _ way: Direction) -> [String]? {
        let found = item.shape.clauses.firstIndex { clause in
            guard let direction = clause.direction else { return false }
            return way.horizontal != 0 ? direction.horizontal == way.horizontal : direction.vertical == way.vertical
        }
        guard let index = found else { return nil }
        // A stand-in's placements beside its end are the run's, against shapes it names by what they are
        // (the end of a column of stand-ins has no title).
        guard item.implied, item.targets.indices.contains(index) else { return item.shape.clauses[index].targets.map(\.written) }
        return item.targets[index].map { target in
            switch target {
            case .item(let other): subject(of: items[other])
            case .shape(let record): standIn(at: record.id, in: self.target.document) != nil ? standInName(record) : named(record)
            case .board: PlaceWord.board.rawValue
            case .view: PlaceWord.view.rawValue
            case .origin: PlaceWord.origin.rawValue
            }
        }
    }

    private func broken(_ item: ShapeItem, _ why: String) -> DrawError {
        DrawError(item.statement, .internal, "\(subject(of: item)) couldn't be drawn: \(why)")
    }

    /// The statement or style written on a line, as an error quotes it.
    func text(ofLine line: Int) -> String? {
        script.statements.first { $0.line == line }?.text ?? script.styles.first { $0.line == line }?.text
    }

    // MARK: Geometry

    /// A shape's outline, as it would be with its box at `rect` (in world units); nil for one
    /// without an inside.
    static func outline(of record: AnyShapeRecord, at rect: CGRect, in registry: Registry) -> (points: [CGPoint], rect: CGRect)? {
        var placed = record
        placed.box = rect
        let context = ShapeContext(document: CanvasDocument(shapes: [placed]), registry: registry)
        guard let geometry = context.geometry(of: placed.id), geometry.isClosed, geometry.outline.count >= 3 else { return nil }
        return (geometry.outline, rect)
    }

    /// Where a corner of a box sits on an outline inside it: where the ray from the box's middle
    /// toward the corner last crosses the outline, from the box's top-left. Nil where that's the
    /// box's own corner (a rectangle's), or the outline doesn't cross.
    static func corner(_ part: Part, on outline: [CGPoint], in rect: CGRect) -> CGRect? {
        let local = part.rect(in: rect.size)
        let target = CGPoint(x: rect.minX + local.minX, y: rect.minY + local.minY), middle = CGPoint(x: rect.midX, y: rect.midY)
        guard let t = intersections(ofSegmentFrom: middle, to: target, withPolygon: outline).filter({ $0 >= 0 && $0 <= 1 + 1e-9 }).max() else {
            return nil
        }
        let point = middle + (target - middle) * t
        guard point.distance(to: target) > 1e-6 else { return nil }
        return CGRect(origin: CGPoint(x: point.x - rect.minX, y: point.y - rect.minY), size: .zero)
    }

    static func overlaps(_ a: CGRect, _ b: CGRect, by least: CGFloat = 1e-6) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) > least && min(a.maxY, b.maxY) - max(a.minY, b.minY) > least
    }

    /// How far over a zone's edge a shape goes before it's said to hang over it, world units: less
    /// is arithmetic.
    static let overhang: CGFloat = 0.5

    static func isNearly(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
    }

    /// What a board shape is called, if anything.
    static func title(of record: AnyShapeRecord, names: BoardNames, naming: DrawNaming?, registry: Registry) -> String? {
        names.name(of: record) ?? naming?.name(record, registry)
    }

    /// Where a shape is, for a message about one with no title: `card at 400,300`, its middle.
    static func location(of record: AnyShapeRecord, in context: ShapeContext) -> String {
        let bounds = context.geometry(of: record.id)?.bounds ?? record.box ?? .zero
        return "\(record.kind) at \(point(CGPoint(x: bounds.midX, y: bounds.midY)))"
    }
}

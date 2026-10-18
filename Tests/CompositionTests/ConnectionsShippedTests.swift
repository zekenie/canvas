import AppKit
import Arrows
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Frames
import LanguageModels
import Locking
import Mentions
import Neighbors
import Publishing
import References
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

// The Connections tab as shipped: the list of what a shape is connected to, on every shape's panel.

/// A row of a Connections list as the panel draws it.
struct ConnectionRow: Equatable {
    let id: ShapeID
    let name: String
    /// The board it's on, when that isn't the board shown.
    let detail: String?
    let caption: String?
    let symbol: String
}

/// A list of the Connections tab as it shows: its title, how many shapes it counts, and its rows.
struct ConnectionGroup: Equatable {
    let title: String
    let count: Int
    let rows: [ConnectionRow]
}

extension NeighborList {
    /// A list's place among `groups`, by its title.
    func index(of title: String) -> Int { groups.firstIndex { $0.title == title } ?? -1 }

    /// The lists the panel shows now: those with something in them, with the rows it draws.
    var panel: [ConnectionGroup] {
        groups.indices.compactMap { index in
            let listed = shown(in: index)
            guard listed.count > 0 else { return nil }
            return ConnectionGroup(title: groups[index].title, count: listed.count, rows: listed.rows.map { row in
                let line = self.line(for: row, in: index)
                return ConnectionRow(id: row.id, name: line.name, detail: line.detail, caption: line.caption, symbol: line.symbol)
            })
        }
    }

    /// Runs the main run loop until the answer for the subject has landed, and nothing is on its way.
    @discardableResult
    func settled(file: StaticString = #fileID, line: UInt = #line) -> [ConnectionGroup] {
        spinRunLoop(until: { !self.isAsking && self.hasLanded }, file: file, line: line)
        return panel
    }
}

extension CanvasEditor {
    /// What the Connections tab lists for `id`, read as a panel showing it would: the shape the list was of
    /// is let go of, `id` becomes the subject, and the answer is waited for.
    func connections(of id: ShapeID, file: StaticString = #fileID, line: UInt = #line) throws -> [ConnectionGroup] {
        let list = try require(neighborList, "the Connections list is in the shipped plugins")
        if let subject = list.subject { list.unwatch(subject) }
        list.watch(id)
        return list.settled(file: file, line: line)
    }
}

// MARK: Fixtures

private func titled<P: ShapeProps>(_ id: ShapeID, _ props: P, _ title: String?, in container: ShapeID? = nil) -> AnyShapeRecord {
    var shape = ShapeRecord(id: id, props)
    shape[TitleProperty.self] = title
    let record = AnyShapeRecord(shape)
    return container.map { record.copy(as: id, container: $0) } ?? record
}

/// A note titled `title`, 200 square, in the grid cell (`column`, `row`) 400 apart, saying `text`.
private func card(_ id: ShapeID, _ title: String?, _ column: Int, _ row: Int, text: MentionText = "", in container: ShapeID? = nil) -> AnyShapeRecord {
    titled(id, StickyNote(frame: CGRect(x: column * 400, y: row * 400, width: 200, height: 200), text: text), title, in: container)
}

/// An arrow bound at the middle of both ends, on no channel, of the types `types` names.
private func link(_ id: ShapeID = ShapeID(), from start: ShapeID, to end: ShapeID, is types: [ShapeID] = []) -> AnyShapeRecord {
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    var shape = ShapeRecord(id: id, Arrow(start: bound(start), end: bound(end)))
    if !types.isEmpty { shape[IsAProperty.self] = types.map(TypeLink.init) }
    return AnyShapeRecord(shape)
}

/// A note titled `title` in the grid cell (`column`, `row`): a type (the starter schema) if `type`, a
/// relationship type if `relationship` too, and of the types `types` names.
private func typed(_ id: ShapeID, _ title: String, _ column: Int, _ row: Int, type: Bool = false, relationship: Bool = false,
                   is types: [ShapeID] = [], in container: ShapeID? = nil) -> AnyShapeRecord {
    var shape = ShapeRecord(id: id, StickyNote(frame: CGRect(x: column * 400, y: row * 400, width: 200, height: 200)))
    shape[TitleProperty.self] = title
    if type { shape[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) }
    if relationship { shape[RelationshipProperty.self] = true }
    if !types.isEmpty { shape[IsAProperty.self] = types.map(TypeLink.init) }
    let record = AnyShapeRecord(shape)
    return container.map { record.copy(as: id, container: $0) } ?? record
}

/// The shipped editor over a file of `root`'s shapes, and boards of `children`'s, on a private pasteboard.
@MainActor private func connected(_ root: [AnyShapeRecord], children: [ShapeID: [AnyShapeRecord]] = [:], _ pasteboard: NSPasteboard) throws -> EditorHarness {
    try EditorHarness { scheduler in
        CanvasEditor(registry: try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()),
                     file: CanvasFile(root: CanvasDocument(shapes: root), children: children.mapValues { CanvasDocument(shapes: $0) }), scheduler: scheduler)
    }
}

extension ConnectionGroup {
    var ids: [ShapeID] { rows.map(\.id) }
    var names: [String] { rows.map(\.name) }
}

@MainActor let connectionsShippedTests = Suite("Connections, as shipped", [
    test("every kind's panel has the Connections tab: a note's first, a subboard's after its Description, a type note's after its Schema") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let note = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Milk"))
        let subboard = editor.add(Subboard(frame: CGRect(x: 300, y: 0, width: 240, height: 160)))
        let frame = editor.add(Frame(frame: CGRect(x: 600, y: 0, width: 300, height: 200)))
        let arrow = editor.add(Arrow(start: .free(CGPoint(x: 0, y: 300)), end: .free(CGPoint(x: 200, y: 400))))
        let reference = editor.add(Reference(frame: CGRect(x: 300, y: 300, width: Reference.defaultSize.width, height: Reference.defaultSize.height)))
        let type = editor.addTypeNote(TypeSchemaProperty.starter, frame: CGRect(x: 600, y: 300, width: 200, height: 200))
        let panel = try require(editor.detailPanel)
        var kinds: Set<ShapeKind> = []
        var tabs: [[String]] = []
        for id in [note, subboard, frame, arrow, reference, type] {
            let record = try require(editor.document[id])
            kinds.insert(record.kind)
            tabs.append(panel.layout(for: record).tabs.map(\.title))
        }
        expectEqual(kinds, Set(editor.registry.kinds), "every kind there is")
        expectEqual(tabs, [["Connections", "Style"], ["Description", "Connections", "Style"], ["Connections", "Style"], ["Connections", "Style"], ["Connections"], ["Schema", "Connections", "Style"]])
    },

    test("a note with an arrow out and an arrow in lists the notes at the other ends under Points To and Pointed To By, and no arrow, with a count each") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (a, b, c, d, e) = (ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID())
        let (ab, ca, ad, ae) = (ShapeID(), ShapeID(), ShapeID(), ShapeID())
        let h = try connected([card(a, "Alpha", 1, 1), card(b, "Beta", 2, 1), card(c, "Gamma", 0, 1), card(d, nil, 1, 2),
                               card(e, nil, 2, 2, text: "Call the bank\nbefore noon"),
                               link(ab, from: a, to: b), link(ca, from: c, to: a), link(ad, from: a, to: d), link(ae, from: a, to: e)], pasteboard)
        let groups = try h.editor.connections(of: a)
        expectEqual(groups.map(\.title), ["Points To", "Pointed To By"])
        expectEqual(groups.map(\.count), [3, 1])
        expectEqual(Set(groups[0].ids), [b, d, e], "the notes it points to")
        expectEqual(groups[0].names.sorted(), ["Beta", "Call the bank before noon", "Empty Note"],
                    "a note without a title is called what the table of contents calls it: its text on one line, or what it says of an empty one")
        expectEqual(groups[1].ids, [c])
        expectEqual(groups[1].names, ["Gamma"])
        expect(!groups.flatMap(\.ids).contains { [ab, ca, ad, ae].contains($0) }, "the arrows themselves aren't listed")
        // The notes at the other ends are connected to Alpha alone.
        let toB = try h.editor.connections(of: b)
        expectEqual(toB.map(\.title), ["Pointed To By"])
        expectEqual(toB.first?.ids, [a])
        expectEqual(try h.editor.connections(of: c).map(\.title), ["Points To"])
    },
    test("an arrow selected lists the note it ends at under Points To and the note it starts at under Pointed To By") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (a, b, ab) = (ShapeID(), ShapeID(), ShapeID())
        let h = try connected([card(a, "Alpha", 0, 0), card(b, "Beta", 1, 0), link(ab, from: a, to: b)], pasteboard)
        let groups = try h.editor.connections(of: ab)
        expectEqual(groups.map(\.title), ["Points To", "Pointed To By"])
        expectEqual(groups[0].ids, [b])
        expectEqual(groups[1].ids, [a])
        expectEqual(groups.map(\.count), [1, 1])
    },
    test("a note that mentions another and is mentioned lists them under Mentions and Mentioned By, the mentioner with its text around the mention") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (m, n, o) = (ShapeID(), ShapeID(), ShapeID())
        let h = try connected([
            card(m, "Mid", 1, 0, text: MentionText([.text("Ask "), .mention(n, label: "North"), .text(" about it")])),
            card(n, "North", 0, 0),
            card(o, "Other", 2, 0, text: MentionText([.text("See "), .mention(m, label: "Mid"), .text(" first")])),
        ], pasteboard)
        let mid = try h.editor.connections(of: m)
        expectEqual(mid.map(\.title), ["Mentions", "Mentioned By"])
        expectEqual(mid.map(\.count), [1, 1])
        expectEqual(mid[0].ids, [n])
        expectEqual(mid[0].rows.first?.caption, nil, "what it mentions has no line under it")
        expectEqual(mid[1].ids, [o])
        expectEqual(mid[1].names, ["Other"])
        expectEqual(mid[1].rows.first?.caption, "See @Mid first", "the text around the mention")
        let north = try h.editor.connections(of: n)
        expectEqual(north.map(\.title), ["Mentioned By"])
        expectEqual(north.first?.rows.first?.caption, "Ask @North about it")
    },
    test("a subboard whose description mentions notes lists them under Mentions, one on its own board too; each lists the subboard under Mentioned By, with the description around the mention") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (s, n, l) = (ShapeID(), ShapeID(), ShapeID())
        let description = MentionText([.text("Owned by "), .mention(n, label: "North"), .text("; see "), .mention(l, label: "Ledger")])
        let h = try connected([card(n, "North", 0, 0), titled(s, Subboard(frame: CGRect(x: 400, y: 0, width: 240, height: 160), description: description), "Payments")],
                              children: [s: [card(l, "Ledger", 0, 0)]], pasteboard)
        let payments = try h.editor.connections(of: s)
        expectEqual(payments.map(\.title), ["Mentions", "Contains"])
        expectEqual(payments[0].ids, [n, l], "in file order: the root's, then what its board holds")
        expectEqual(payments[0].rows.map(\.detail), [nil, nil], "the root is shown, and Ledger is on the subboard's own board")
        let north = try h.editor.connections(of: n)
        expectEqual(north.map(\.title), ["Mentioned By"])
        expectEqual(north.first?.ids, [s])
        expectEqual(north.first?.rows.first?.caption, "Owned by @North; see @Ledger")
        let ledger = try h.editor.connections(of: l)
        expectEqual(ledger.map(\.title), ["Mentioned By", "Inside"])
        expectEqual(ledger.first?.names, ["Payments"])
        expectEqual(ledger.first?.rows.first?.caption, "Owned by @North; see @Ledger")
    },
    test("a note in a frame on a subboard's board is Inside the subboard, then the frame; the subboard Contains the frame and the loose note, the frame its note") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (s, f, n, p) = (ShapeID(), ShapeID(), ShapeID(), ShapeID())
        let h = try connected([titled(s, Subboard(frame: CGRect(x: 0, y: 0, width: 240, height: 160)), "Plans")], children: [s: [
            titled(f, Frame(frame: CGRect(x: 0, y: 0, width: 900, height: 600)), "Sprint"),
            card(n, "Task", 0, 0, in: f),
            card(p, "Loose", 3, 0),
        ]], pasteboard)
        let task = try h.editor.connections(of: n)
        expectEqual(task.map(\.title), ["Inside"])
        expectEqual(task[0].ids, [s, f], "the subboard, then the frame: outermost first")
        expectEqual(task[0].names, ["Plans", "Sprint"])
        let plans = try h.editor.connections(of: s)
        expectEqual(plans.map(\.title), ["Contains"])
        expectEqual(Set(plans[0].ids), [f, p], "its board's shapes in no frame, not what the frame holds")
        expectEqual(plans[0].count, 2)
        let sprint = try h.editor.connections(of: f)
        expectEqual(sprint.map(\.title), ["Inside", "Contains"])
        expectEqual(sprint[0].ids, [s])
        expectEqual(sprint[1].ids, [n])
        expectEqual(sprint[1].names, ["Task"])
        let loose = try h.editor.connections(of: p)
        expectEqual(loose.map(\.title), ["Inside"])
        expectEqual(loose[0].ids, [s])
    },
    test("a row for a shape on another board says that board's name, and none for a shape on the board shown: the root's, the file's, as the path calls it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (s, f, n) = (ShapeID(), ShapeID(), ShapeID())
        let h = try connected([titled(s, Subboard(frame: CGRect(x: 0, y: 0, width: 240, height: 160)), "Plans")], children: [s: [
            titled(f, Frame(frame: CGRect(x: 0, y: 0, width: 900, height: 600)), "Sprint"),
            card(n, "Task", 0, 0, in: f),
        ]], pasteboard)
        // The root is shown: the subboard is on it, the frame and the note are on its board.
        expectEqual(try h.editor.connections(of: n)[0].rows.map(\.detail), [nil, "Plans"])
        expectEqual(try h.editor.connections(of: s)[0].rows.map(\.detail), [nil], "what it holds is on its own board, which needs no saying")
        // The subboard's board is shown: what's on it needs no board's name, and the subboard is on the root.
        h.enter(s)
        expectEqual(try h.editor.connections(of: n)[0].rows.map(\.detail), ["Board", nil], "the root, while the file has no name")
        expectEqual(try h.editor.connections(of: s)[0].rows.map(\.detail), [nil])
        h.editor.nameRoot("Roadmap")
        expectEqual(try h.editor.connections(of: n)[0].rows.map(\.detail), ["Roadmap", nil], "the file's name")
    },
    test("the lists come in the order of the lights, then Inside and Contains; one with nothing in it isn't shown, and a shape connected to nothing has none") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (x, b, c, d, e, o, z) = (ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID())
        let h = try connected([
            titled(o, Frame(frame: CGRect(x: -100, y: -100, width: 1600, height: 1000)), "Outer"),
            card(x, "Hub", 0, 0, text: MentionText([.text("To "), .mention(d, label: "Dee")]), in: o),
            card(b, "Bee", 1, 0, in: o), card(c, "Sea", 2, 0, in: o), card(d, "Dee", 0, 1, in: o),
            card(e, "Eee", 1, 1, text: MentionText([.mention(x, label: "Hub")]), in: o), card(z, "Zed", 5, 5),
            link(from: x, to: b), link(from: c, to: x),
        ], pasteboard)
        let list = try require(h.editor.neighborList)
        expectEqual(list.groups.map(\.title), ["Points To", "Pointed To By", "Mentions", "Mentioned By", "Instances", "Inside", "Contains"])
        expectEqual(list.groups.map { $0.color != nil }, [true, true, true, true, true, false, false], "a light's list has its color; the two besides have none")
        let hub = try h.editor.connections(of: x)
        expectEqual(hub.map(\.title), ["Points To", "Pointed To By", "Mentions", "Mentioned By", "Inside"])
        expectEqual(hub.map(\.ids), [[b], [c], [d], [e], [o]])
        expectEqual(list.total, 5)
        let zed = try h.editor.connections(of: z)
        expectEqual(zed, [])
        expect(list.hasLanded, "the answer is in: nothing to list")
        expectEqual(list.total, 0)
    },
    test("a type lists what is of it under Instances, after the arrows' lists and before Inside: a note on a subboard's board with that board's name, and a type built on it but not what is of that one; a relationship type lists its arrows") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (o, table, owns, staging, orders, items, stage, users, s, end, owning) = (ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID(),
                                                                                       ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID())
        let h = try connected([
            titled(o, Frame(frame: CGRect(x: -100, y: -100, width: 1000, height: 1000)), "Types"),
            typed(table, "Table", 0, 0, type: true, in: o), typed(owns, "owns", 1, 0, type: true, relationship: true, in: o),
            typed(staging, "Staging Table", 0, 1, type: true, is: [table], in: o),
            typed(orders, "orders", 3, 0, is: [table]), typed(items, "items", 4, 0), typed(stage, "stage_orders", 3, 1, is: [staging]),
            titled(s, Subboard(frame: CGRect(x: 1600, y: 1200, width: 240, height: 160)), "Commerce"),
            link(end, from: owns, to: table), link(owning, from: orders, to: items, is: [owns]),
        ], children: [s: [typed(users, "users", 0, 0, is: [table])]], pasteboard)
        let tableLists = try h.editor.connections(of: table)
        expectEqual(tableLists.map(\.title), ["Pointed To By", "Instances", "Inside"])
        expectEqual(tableLists[0].ids, [owns])
        let instances = tableLists[1]
        expectEqual(Set(instances.ids), [staging, orders, users], "what lists it, never what is of a type built on it")
        expectEqual(instances.rows.first { $0.id == users }?.detail, "Commerce", "the board it's on")
        expectEqual(instances.rows.filter { $0.id != users }.map(\.detail), [nil, nil], "the board shown needs no saying")
        let ownsLists = try h.editor.connections(of: owns)
        expectEqual(ownsLists.map(\.title), ["Points To", "Instances", "Inside"])
        expectEqual(ownsLists[1].ids, [owning], "a relationship type's instances are its arrows")
        // An instance lists no Instances: its types are its chips' and its Types tab's.
        expectEqual(try h.editor.connections(of: orders).map(\.title), ["Points To"])
        // Nor does a shape no longer a type, though shapes still name it (their chips dashed); its undo lists them again.
        h.editor.removeType(table)
        expectEqual(try h.editor.connections(of: table).map(\.title), ["Pointed To By", "Inside"])
        h.editor.undo()
        expectEqual(try h.editor.connections(of: table).map(\.title), ["Pointed To By", "Instances", "Inside"])
    },
    test("a note connected two ways is listed under both; one that points or mentions itself doesn't list itself; a mentioner on another board has that board's name and its text") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (a, b, s, deep) = (ShapeID(), ShapeID(), ShapeID(), ShapeID())
        let h = try connected([
            card(a, "Alpha", 0, 0, text: MentionText([.text("Mine, "), .mention(a, label: "Alpha"), .text(" and "), .mention(b, label: "Beta")])),
            card(b, "Beta", 1, 0, text: MentionText([.text("Back to "), .mention(a, label: "Alpha")])),
            titled(s, Subboard(frame: CGRect(x: 0, y: 800, width: 240, height: 160)), "Plans"),
            link(from: a, to: b), link(from: a, to: a),
        ], children: [s: [card(deep, "Deep", 0, 0, text: MentionText([.text("Per "), .mention(a, label: "Alpha"), .text(", always")]))]], pasteboard)
        let alpha = try h.editor.connections(of: a)
        // B is pointed to and mentioned; A is itself the end of its own arrow and its own mention, and is no neighbor of itself.
        expectEqual(alpha.map(\.title), ["Points To", "Mentions", "Mentioned By"])
        expectEqual(alpha.map(\.ids), [[b], [b], [b, deep]].map { $0 as [ShapeID] })
        expectEqual(alpha.map(\.count), [1, 1, 2])
        let mentioned = alpha[2]
        expectEqual(mentioned.rows.map(\.name), ["Beta", "Deep"])
        expectEqual(mentioned.rows.map(\.detail), [nil, "Plans"], "the mentioner on the subboard's board says whose board")
        expectEqual(mentioned.rows.map(\.caption), ["Back to @Alpha", "Per @Alpha, always"])
        expectEqual(try h.editor.connections(of: b).map(\.title), ["Pointed To By", "Mentions", "Mentioned By"])
        // The watched note deleted: nothing is left to list, nothing breaks, and its undo brings the lists back.
        let list = try require(h.editor.neighborList)
        h.editor.transact("Delete") { $0.delete([b]) }
        h.wait(100)
        expectEqual(list.settled(), [])
        h.editor.undo()
        h.wait(100)
        expectEqual(list.settled().map(\.title), ["Pointed To By", "Mentions", "Mentioned By"])
    },
    test("a reference and the public note it stands for: the pill is under the note's Pointed To By, the note under the pill's Points To; an arrow into the pill counts for the note") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (target, x, r) = (ShapeID(), ShapeID(), ShapeID())
        var orders = card(target, "Orders", 2, 0)
        orders[PublicProperty.self] = true
        var props = Reference(frame: CGRect(x: 800, y: 600, width: Reference.defaultSize.width, height: Reference.defaultSize.height))
        ReferenceEdits.pick(&props, ReferenceTarget(id: target, label: "Orders"))
        let h = try connected([orders, AnyShapeRecord(ShapeRecord(id: r, props)), card(x, "Checkout", 0, 1)], pasteboard)
        let note = try h.editor.connections(of: target)
        expectEqual(note.map(\.title), ["Pointed To By"])
        expectEqual(note[0].ids, [r], "the pill that stands for it")
        let pill = try h.editor.connections(of: r)
        expectEqual(pill.map(\.title), ["Points To"])
        expectEqual(pill[0].ids, [target])
        expectEqual(pill[0].names, ["Orders"])
        // An arrow from Checkout into the pill is, to the graph, an arrow into the note: both are what it points to, the pill as drawn.
        let into = ShapeID()
        h.editor.transact("Arrow") { $0.insert(link(into, from: x, to: r)) }
        let checkout = try h.editor.connections(of: x)
        expectEqual(checkout.map(\.title), ["Points To"])
        expectEqual(Set(checkout[0].ids), [target, r])
        expectEqual(Set(try h.editor.connections(of: target)[0].ids), [x, r], "the note is pointed to by Checkout and the pill")
        let drawn = try h.editor.connections(of: r)
        expectEqual(drawn.map(\.title), ["Points To", "Pointed To By"])
        expectEqual(drawn[0].ids, [target])
        expectEqual(drawn[1].ids, [x])
    },
    test("a Make Private refused on a shape that stands for others switches its panel to the Connections tab, which lists what stands for it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (s, r) = (ShapeID(), ShapeID())
        var plans = titled(s, Subboard(frame: CGRect(x: 0, y: 0, width: 240, height: 160)), "Plans")
        plans[PublicProperty.self] = true
        var props = Reference(frame: CGRect(x: 600, y: 0, width: Reference.defaultSize.width, height: Reference.defaultSize.height))
        ReferenceEdits.pick(&props, ReferenceTarget(id: s, label: "Plans"))
        let h = try connected([plans, AnyShapeRecord(ShapeRecord(id: r, props))], pasteboard)
        let panel = try require(h.editor.detailPanel)
        let tab = DetailTabID.of(NeighborsTab.self)
        @MainActor func current() throws -> DetailTabID? {
            let record = try require(h.editor.document[s])
            return panel.currentTab(in: panel.layout(for: record), for: record.kind)
        }
        h.editor.selection = s
        panel.choose(.of(StyleTab.self), for: Subboard.kind)
        expect(try current() != tab, "on another tab first")
        expectEqual(h.editor.makePrivate([s]), [s], "held: refused")
        expectEqual(try current(), tab, "the panel is on Connections now")
        expectEqual(h.editor.document[s]?[PublicProperty.self], true, "nothing else changes")
        expectEqual(try h.editor.connections(of: s).map(\.ids), [[r]], "and it lists the pill")
    },
    test("folding a list keeps its count and takes its rows away, and the next shape listed has it folded; unfolding brings the rows back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (hub, b1, b2, b3, c1, j, k1, k2) = (ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID())
        let h = try connected([
            card(hub, "Hub", 1, 1), card(b1, "Beta 1", 2, 0), card(b2, "Beta 2", 2, 1), card(b3, "Beta 3", 2, 2), card(c1, "Gamma", 0, 1),
            card(j, "Jay", 4, 4), card(k1, "Kay 1", 5, 4), card(k2, "Kay 2", 5, 5),
            link(from: hub, to: b1), link(from: hub, to: b2), link(from: hub, to: b3), link(from: c1, to: hub), link(from: j, to: k1), link(from: j, to: k2),
        ], pasteboard)
        let list = try require(h.editor.neighborList)
        let pointsTo = list.index(of: "Points To")
        let open = try h.editor.connections(of: hub)
        expectEqual(open.map { [$0.count, $0.rows.count] }, [[3, 3], [1, 1]])
        expect(!list.isFolded(pointsTo) && list.showsRows(of: pointsTo))
        list.setFolded(pointsTo, true)
        expect(list.isFolded(pointsTo) && !list.showsRows(of: pointsTo))
        expectEqual(list.panel.map { [$0.count, $0.rows.count] }, [[3, 0], [1, 1]], "its count kept, its rows gone")
        expectEqual(list.total, 4)
        // The next shape listed has it folded: counted, its rows not read.
        let next = try h.editor.connections(of: j)
        expectEqual(next.map(\.title), ["Points To"])
        expectEqual(next.map { [$0.count, $0.rows.count] }, [[2, 0]])
        expectEqual(list.listing?.groups[pointsTo].rows == nil, true, "not read")
        // Unfolded, its rows are asked for.
        list.setFolded(pointsTo, false)
        expect(list.isAsking, "its rows were not read")
        let unfolded = list.settled()
        expectEqual(unfolded.map { [$0.count, $0.rows.count] }, [[2, 2]])
        expectEqual(Set(unfolded[0].names), ["Kay 1", "Kay 2"])
    },
    test("searching ranks the rows of every list by name, a folded list's too, and the next shape listed starts without it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (hub, grape, pine, apple, banana, other, cherry) = (ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID(), ShapeID())
        let h = try connected([
            card(hub, "Basket", 0, 0), card(grape, "Grape", 1, 0), card(pine, "Pineapple", 2, 0), card(apple, "Apple", 3, 0), card(banana, "Banana", 4, 0),
            card(other, "Other", 0, 3), card(cherry, "Cherry", 1, 3),
            link(from: hub, to: grape), link(from: hub, to: pine), link(from: hub, to: apple), link(from: hub, to: banana), link(from: other, to: hub),
            link(from: other, to: cherry),
        ], pasteboard)
        let list = try require(h.editor.neighborList)
        let pointsTo = list.index(of: "Points To")
        expectEqual(try h.editor.connections(of: hub).map(\.count), [4, 1])
        list.setSearch("app")
        expect(!list.search.isEmpty && list.showsRows(of: pointsTo))
        var found = list.panel
        expectEqual(found.map(\.title), ["Points To"], "a list with no match isn't shown")
        expectEqual(found[0].names, ["Apple", "Pineapple"], "the best match first, whatever order the engine answered in")
        expectEqual(found[0].count, 2)
        list.setSearch("ban")
        expectEqual(list.panel.map(\.names), [["Banana"]])
        // A folded list is searched too, and folded again when the search is cleared.
        list.setSearch("")
        list.setFolded(pointsTo, true)
        expectEqual(list.panel.map { [$0.count, $0.rows.count] }, [[4, 0], [1, 1]])
        list.setSearch("gra")
        found = list.settled()
        expectEqual(found.map(\.names), [["Grape"]], "searched folded, and the other list has no match")
        list.setSearch("")
        expectEqual(list.panel.map { [$0.count, $0.rows.count] }, [[4, 0], [1, 1]], "folded again")
        // Typing something and moving on to another shape starts that shape's lists unsearched.
        list.setSearch("app")
        _ = try h.editor.connections(of: other)
        expectEqual(list.search, "")
        expectEqual(list.panel.map { [$0.count, $0.rows.count] }, [[2, 0]], "its Points To still folded: counted")
    },
    test("an arrow added, a note renamed and a shape moved into a frame show in the lists once commits have stopped for 100 ms") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (hub, b, m, f) = (ShapeID(), ShapeID(), ShapeID(), ShapeID())
        let h = try connected([
            card(hub, "Hub", 0, 0), card(b, "Beta", 1, 0), card(m, "Mover", 0, 2), titled(f, Frame(frame: CGRect(x: 1000, y: 0, width: 600, height: 400)), "Pen"),
            link(from: hub, to: b),
        ], pasteboard)
        let list = try require(h.editor.neighborList)
        expectEqual(try h.editor.connections(of: hub).map(\.names), [["Beta"]])
        // An arrow: the list is as it was until commits have stopped, and then it has the new note.
        h.editor.transact("Add Arrow") { $0.insert(link(from: hub, to: m)) }
        expectEqual(list.panel.map(\.names), [["Beta"]], "not yet")
        expect(list.isAsking, "asked for in 100 ms")
        h.wait(99)
        expect(list.isAsking, "still not asked")
        h.wait(1)
        expectEqual(list.settled().map { Set($0.names) }, [["Beta", "Mover"]])
        // A rename.
        h.editor.transact("Rename") { $0.update(b) { $0[TitleProperty.self] = "Bravo" } }
        h.wait(100)
        expectEqual(list.settled().map { Set($0.names) }, [["Bravo", "Mover"]])
        expectEqual(list.panel[0].count, 2)
        // A shape moved into a frame: the frame holds it, and it is inside the frame.
        expectEqual(try h.editor.connections(of: f), [])
        h.editor.put([m], in: f)
        h.wait(100)
        let pen = list.settled()
        expectEqual(pen.map(\.title), ["Contains"])
        expectEqual(pen[0].ids, [m])
        expectEqual(try h.editor.connections(of: m).map(\.title), ["Pointed To By", "Inside"])
        // An arrow deleted.
        h.editor.transact("Delete") { $0.delete([b]) }
        h.wait(100)
        expectEqual(list.settled().map(\.title), ["Pointed To By", "Inside"], "a deleted note is no one's neighbor")
        _ = try h.editor.connections(of: hub)
        expectEqual(list.panel.map(\.ids), [[m]])
    },
    test("a drag asks the engine nothing: only commits that do more than move shapes do") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (hub, b, other) = (ShapeID(), ShapeID(), ShapeID())
        let h = try connected([card(hub, "Hub", 0, 0), card(b, "Beta", 1, 0), card(other, "Other", 0, 3), link(from: hub, to: b)], pasteboard)
        let list = try require(h.editor.neighborList)
        expectEqual(try h.editor.connections(of: hub).map(\.names), [["Beta"]])
        #if DEBUG
        let (asked, shown) = (list.asked, list.shown)
        // The events of a drag of the listed note and of another, each a commit that moves a shape.
        let origin = try require(h.editor.document[hub]?.box?.origin)
        for step in 1...8 {
            h.editor.transact { $0.moveBox(hub, to: CGPoint(x: origin.x + Double(step) * 10, y: origin.y)) }
            h.editor.transact { $0.moveBox(other, to: CGPoint(x: Double(step) * 10, y: 1200)) }
            h.wait(16)
        }
        h.wait(300)
        list.settled()
        expectEqual(list.asked, asked, "nothing asked")
        expectEqual(list.shown, shown, "nothing shown again")
        // A drag with the pointer, press to release, as the person makes it.
        let before = try require(h.editor.document[other]?.box?.origin)
        h.press(at: CGPoint(x: before.x + 100, y: before.y + 100))
        h.drag(to: CGPoint(x: before.x + 150, y: before.y + 100))
        h.drag(to: CGPoint(x: before.x + 250, y: before.y + 120))
        h.release()
        h.wait(300)
        list.settled()
        expect(h.editor.document[other]?.box?.origin != before, "the note moved")
        expectEqual(list.asked, asked, "nor does a drag of a note")
        // A commit that renames asks once, however many events it comes in.
        for name in ["A", "Al", "Ali"] {
            h.editor.transact("Rename") { $0.update(b) { $0[TitleProperty.self] = name } }
            h.wait(16)
        }
        h.wait(100)
        list.settled()
        expectEqual(list.asked, asked + 1, "one ask for the run of commits")
        expectEqual(list.panel.map(\.names), [["Ali"]])
        #endif
    },
    test("the pointer on a row hovers its shape: on the canvas if it is on the board shown, else the card that holds it; letting go lets go of that hover and no other; a click goes to the shape") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (a, b, s, n) = (ShapeID(), ShapeID(), ShapeID(), ShapeID())
        let h = try connected([card(a, "Alpha", 0, 0), card(b, "Beta", 1, 0), titled(s, Subboard(frame: CGRect(x: 0, y: 800, width: 240, height: 160)), "Plans"),
                               link(from: a, to: b)], children: [s: [card(n, "Deep", 0, 0)]], pasteboard)
        let list = try require(h.editor.neighborList)
        list.hover(b)
        expectEqual(h.editor.hovered, b)
        list.endHover(a)
        expectEqual(h.editor.hovered, b, "another row's pointer leaving lets go of nothing")
        list.endHover(b)
        expectEqual(h.editor.hovered, nil)
        list.hover(n)
        expectEqual(h.editor.hovered, nil, "it isn't on the board shown")
        expectEqual(h.editor.hoveredElsewhere, n)
        list.endHover(n)
        expectEqual(h.editor.hoveredElsewhere, nil)
        // A click on a row of a shape on another board shows that board, selects it, and is one step back.
        list.go(to: n)
        expectEqual(h.editor.board, .root, "on the scheduler's next turn")
        h.wait(0)
        expectEqual(h.editor.board, BoardID(owner: s))
        expectEqual(h.editor.selectedShapeIDs, [n])
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        list.go(to: b)
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [b])
    },
    test("in the app's window the Connections list shows for a selected note: a click on a row goes to that shape, and Back returns, and nothing is asked once no note is selected") {
        let (a, b, c) = (ShapeID(), ShapeID(), ShapeID())
        let w = try InspectorWindow(file: CanvasFile(root: CanvasDocument(shapes: [
            card(a, "Alpha", 1, 0), card(b, "Beta", 2, 0), card(c, "Gamma", 0, 0), link(from: a, to: b), link(from: c, to: a),
        ])))
        let list = try require(w.editor.neighborList)
        expectEqual(list.subject, nil, "nothing is asked while no list is on screen")
        w.editor.selection = a
        w.window.spin { list.subject == a && list.hasLanded && !list.isAsking }
        expectEqual(list.panel.map(\.names), [["Beta"], ["Gamma"]])
        w.window.spin { w.connectionRows.count == 2 }
        // A click on the first row, Beta, goes to it.
        w.connectionRows[0].performClick(nil)
        w.window.spin { w.editor.selection == b }
        expectEqual(list.subject, b, "the list is of the shape selected now")
        w.editor.goBack()
        expectEqual(w.editor.selection, a)
        // Nothing selected, nothing watched.
        w.editor.selection = nil
        w.window.spin { list.subject == nil }
    },
    test("a locked note's Connections rows are enabled all the same: going to what it is connected to changes nothing of it") {
        let (a, b) = (ShapeID(), ShapeID())
        var locked = card(a, "Alpha", 1, 0)
        locked[LockedProperty.self] = true
        let w = try InspectorWindow(file: CanvasFile(root: CanvasDocument(shapes: [locked, card(b, "Beta", 2, 0), link(from: a, to: b)])))
        let list = try require(w.editor.neighborList)
        w.editor.selection = a
        w.window.spin { list.subject == a && list.hasLanded && !list.isAsking }
        w.window.spin { w.connectionRows.count == 1 }
        expect(w.connectionRows[0].isEnabled, "the row")
        w.connectionRows[0].performClick(nil)
        w.window.spin { w.editor.selection == b }
        expectEqual(w.editor.document[a]?[LockedProperty.self], true, "and it is as it was")
    },
    test("in the app's window a search field heads the lists once they hold twenty shapes, and what is typed in it narrows them") {
        let hub = ShapeID()
        let names = ["Apple", "Banana", "Cherry", "Damson", "Elder", "Fig", "Grape", "Hazel", "Iris", "Juniper", "Kiwi", "Lemon", "Mango",
                     "Nettle", "Olive", "Peach", "Quince", "Rowan", "Sloe", "Thyme"]
        let ids = names.map { _ in ShapeID() }
        let w = try InspectorWindow(file: CanvasFile(root: CanvasDocument(shapes: [card(hub, "Basket", 0, 0)]
            + zip(ids, names).enumerated().map { card($1.0, $1.1, $0 + 1, 1) } + ids.map { link(from: hub, to: $0) })))
        let list = try require(w.editor.neighborList)
        w.editor.selection = hub
        w.window.spin { list.subject == hub && list.hasLanded && !list.isAsking }
        expectEqual(list.total, 20)
        w.window.spin { w.fields.count == 1 }
        w.window.spin { w.connectionRows.count > 0 }
        w.window.focus(try require(w.fields.first))
        w.window.type("an")
        w.window.spin { list.search == "an" }
        w.window.spin { w.connectionRows.count == list.panel.flatMap(\.rows).count }
        expectEqual(list.panel.first?.names.first, "Banana", "the best match first")
        expect(list.panel.flatMap(\.rows).count < 20, "narrowed")
        // Escape in the field hands the keyboard back to the canvas, and the search stays.
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(list.search, "an")
    },
])

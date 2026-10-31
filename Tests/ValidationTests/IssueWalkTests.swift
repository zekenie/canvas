@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Foundation
import Keyboard
import Queries
import Selection
import TestKit
import Topology
import Validation

// The issue walk (`IssueWalk`), over CanvasTesting's cards, pockets and links, with rules of this suite's: a card whose text
// has "bad" has an error, "meh" a warning (with an Ignore that appends "ignored" to the text), "late" a warning once `Late`
// is raised, and "need" still needs something; a link has a warning of no source unless the card it ends at says "ok" (a rule
// that reads another shape). Two more for a warning of no source: "count" has one whose words carry its length, "twice" two
// that read alike, each with an Ignore of its own.

private let rulesPlugin = PluginID("walk-rules")
private let badSource = IssueSource(plugin: rulesPlugin, key: "bad")
private let mehSource = IssueSource(plugin: rulesPlugin, key: "meh")
private let lateSource = IssueSource(plugin: rulesPlugin, key: "late")

/// What a rule reads that is not in a shape: raised from outside, told to the engine by `recheck`.
@MainActor final class Late {
    var raised = false
}

/// What the Card rule counts and can do when a shape says "trigger": how often it was run, and a commit to make once, from inside
/// a check (a commit that lands while a query for every issue is being answered).
@MainActor private enum Checking {
    static var cards = 0
    static var onTrigger: (() -> Void)?
}

/// Whether an observation told.
private final class Flag: @unchecked Sendable {
    var set = false
}

/// The editor an Ignore writes through.
@MainActor private enum Ignoring {
    static weak var editor: CanvasEditor?
}

/// A rule's key a scope goes by, and whether it is there: a rule reworded or deleted.
@MainActor private enum Pick {
    static var key = "meh"
    static var exists = true
    /// Whether a scope that also takes "meh" issues does (`alsoMeh` below): a rule reworded to take one more.
    static var alsoMeh = false
}

/// An Ignore: it adds `suffix` to the card's words, which its rule reads. A card that is stuck takes none: nothing is written.
@MainActor private func ignore(_ id: ShapeID, adding suffix: String = " ignored") {
    guard let text = Ignoring.editor?.document[id]?.typed(as: Card.self)?.props.text, !text.contains("stuck") else { return }
    Ignoring.editor?.transact("Ignore") { $0.update(id, as: Card.self) { $0.props.text += suffix } }
}

private func edges() -> Contributor {
    Contributor(id: "walk-edges") { r in
        r.edgeType(WalkWire.self)
        r.edges(Link.self) { record, _, sink in
            guard let link = record.props as? Link, let from = link.from, let to = link.to else { return }
            sink.emit(WalkWire.id, from: from, to: to)
        }
    }
}

private enum WalkWire {}
extension WalkWire: EdgeType {
    static let id: EdgeTypeID = "walk-wire"
}

@MainActor private func rules(_ late: Late) -> Contributor {
    Contributor(id: rulesPlugin) { r in
        // Card B's changes name X (and F, on the pocket's board) too, though they did not change: a rule that reads a service says so (`affected`).
        // A card's issues follow from its words alone, so its rule ignores moves.
        r.validate(Card.self, ignoringMoves: true, affected: { changes, _ in changes.changed.contains(b) ? [x, f] : [] }) { card, _ in
            Checking.cards += 1
            let text = card.props.text
            if text.contains("trigger"), let action = Checking.onTrigger {
                Checking.onTrigger = nil
                action()
            }
            var issues: [ValidationIssue] = []
            if text.contains("bad") { issues.append(.error("It's bad.", source: badSource)) }
            if text.contains("meh"), !text.contains("ignored") {
                issues.append(.warning("It's so-so.", actions: [IssueAction("Ignore", role: .ignore) { ignore(card.id) }], source: mehSource))
            }
            if text.contains("late"), late.raised { issues.append(.warning("It's late.", source: lateSource)) }
            if text.contains("need") { issues.append(.incomplete("It needs a name.", field: "name")) }
            if text.hasPrefix("count") { issues.append(.warning("Count is \(text.count).", field: "text")) }
            if text.contains("twice") {
                for n in 1...2 where !text.contains("i\(n)") {
                    issues.append(.warning("Twice.", field: "twice", actions: [IssueAction("Ignore", role: .ignore) { ignore(card.id, adding: " i\(n)") }]))
                }
            }
            return issues
        }
        r.validate(Link.self) { link, context in
            if let end = link.props.to.flatMap({ context.shape($0) }), end.typed(as: Card.self)?.props.text.contains("ok") == true { return [] }
            return [.warning("Check this link.")]
        }
        r.issueScopes { source, _ in
            guard source.plugin == rulesPlugin else { return nil }
            // "meh" is a rule that knows the shapes it may flag, as a rule's count does: the cards that say meh and not ignored.
            return source.key == "meh" ? scope("meh", finding: mehCards) : scope(source.key)
        }
        r.boardHeading { board, _ in BoardHeading(board.isRoot ? "Root" : "Texas") }
    }
}

/// The cards, on every board, whose text says meh and has not been ignored.
@MainActor private func mehCards(_ editor: CanvasEditor) -> Set<ShapeID> {
    var found: Set<ShapeID> = []
    for board in editor.file.everyBoard {
        for record in editor.contents(of: board).shapes {
            if let text = record.typed(as: Card.self)?.props.text, text.contains("meh"), !text.contains("ignored") { found.insert(record.id) }
        }
    }
    return found
}

/// The scope of one rule's issues, by its key.
@MainActor private func scope(_ key: String, candidates: Set<ShapeID>? = nil, finding: (@MainActor (CanvasEditor) -> Set<ShapeID>)? = nil) -> IssueScope {
    var ask = finding
    if let found = candidates { ask = { _ in found } }
    return IssueScope(id: key, includes: { $0.source?.key == key }, label: { _ in IssueScopeLabel("Rule \(key)") }, candidates: ask)
}

private let unit = CGRect(x: 0, y: 0, width: 100, height: 60)

/// Shapes in one commit: more than the walk reads one by one (`IssueWalkStyle.readLimit`, 2048), so it asks the query again.
private let pasteSize = 2100

private func ids(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!) }
private func record<P: ShapeProps>(_ n: Int, _ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: ids(n), props)) }

private let a = ids(1), pocketID = ids(2), b = ids(3), q = ids(4), link = ids(5), x = ids(6), c = ids(11), d = ids(12), e = ids(13), f = ids(14)

/// The root: A "bad", a pocket, B "meh", Q "fine", a link from A to B, X "late". The pocket's board: C "bad", D "bad meh" (two
/// issues), E "need" (still needs something, no stop). In board order the stops are A, B, link, C, D, D.
private func walkFile(pocketHolds extra: [AnyShapeRecord] = []) -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: [record(1, Card(unit, text: "bad")), record(2, Pocket(unit)), record(3, Card(unit, text: "meh")),
                                             record(4, Card(unit, text: "fine")), record(5, Link(from: a, to: b)), record(6, Card(unit, text: "late"))]),
               children: [pocketID: CanvasDocument(shapes: [record(11, Card(unit, text: "bad")), record(12, Card(unit, text: "bad meh")),
                                                            record(13, Card(unit, text: "need"))] + extra)])
}

@MainActor private func walkPlugins(_ late: Late, more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), CardsPlugin(), PocketsPlugin(),
     LinksPlugin(), ValidationPlugin(), DetailPanelPlugin(), ValidationDetailsPlugin(), IssueWalkPlugin(),
     QueriesPlugin(), ValidationQueriesPlugin(), edges(), cardTab(), rules(late)] + more
}

@MainActor private func walkHarness(_ late: Late = Late(), file: CanvasFile = walkFile(), more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let h = try EditorHarness(plugins: walkPlugins(late, more: more), file: file)
    h.editor.viewportDidResize(to: CGSize(width: 1000, height: 700))
    Ignoring.editor = h.editor
    Pick.key = "meh"
    Pick.exists = true
    Pick.alsoMeh = false
    Checking.onTrigger = nil
    return h
}

/// This suite's fixture for issueBandTests: the same plugins and file, with the walk's panel and the real scheduler a window's
/// views need; and its shapes (A "bad", a pocket, B "meh", Q "fine", a link from A to B, X "late"; the pocket's board: C "bad",
/// D "bad meh", E "need"), and the scope of a rule's key. `before` are plugins listed before the walk's panel (a takeover listed
/// earlier wins, as Find's does).
@MainActor func walkBandEditor(_ late: Late = Late(), before: [any CanvasPlugin] = [], more: [any CanvasPlugin] = [], file: CanvasFile? = nil) throws -> CanvasEditor {
    let editor = CanvasEditor(registry: try Registry(plugins: walkPlugins(late, more: before + [IssueWalkPanelPlugin()] + more)), file: file ?? walkFile(), scheduler: TaskScheduler())
    editor.viewportDidResize(to: CGSize(width: 700, height: 700))
    Ignoring.editor = editor
    Pick.key = "meh"
    Pick.exists = true
    return editor
}

/// This suite's harness (a manual clock), for the tests of the Issues tab's lines.
@MainActor func walkTestHarness(_ late: Late = Late(), file: CanvasFile? = nil, more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try walkHarness(late, file: file ?? walkFile(), more: more)
}

/// A root board of cards (by text) and corrals (no text), in the order given, with the ids `walkID` gives.
@MainActor func walkRootFile(_ shapes: [(n: Int, text: String?)]) -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: shapes.map { item in
        item.text.map { record(item.n, Card(unit, text: $0)) } ?? record(item.n, Corral(unit))
    }))
}

func walkID(_ n: Int) -> ShapeID { ids(n) }

let walkShapes = (a: a, pocket: pocketID, b: b, q: q, link: link, x: x, c: c, d: d, e: e, f: f)
@MainActor func walkScope(_ key: String, candidates: Set<ShapeID>? = nil) -> IssueScope { scope(key, candidates: candidates) }
let walkMehSource = mehSource
let walkBadSource = badSource

extension IssueWalk {
    /// Begins and waits for the first answer.
    @MainActor fileprivate func started(_ scope: IssueScope = .all, at entry: IssueEntry = .first, forward: Bool = true) {
        begin(scope, at: entry, forward: forward)
        spinRunLoop(until: { !isGathering })
    }

    fileprivate var shapes: [ShapeID] { rows.map(\.shape) }
    fileprivate var states: [IssueRowState] { rows.map(\.state) }
    fileprivate var at: ShapeID? { currentRow?.shape }
}

@MainActor private func walk(_ h: EditorHarness) throws -> IssueWalk { try require(h.editor.issueWalk) }

@MainActor let issueWalkTests = Suite("Walking issues", [
    test("the stops are the issues that show, in board order across boards: the root's shapes, then the board under it; what a shape still needs is none") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started()
        expectEqual(walk.shapes, [a, b, link, c, d, d])
        expectEqual(walk.total, 6)
        expect(!walk.shapes.contains(e), "an issue of the third level is no stop")
        expect(!walk.shapes.contains(x), "a rule that finds nothing yet gives no row")
        expectEqual(walk.number, 1)
        expectEqual(h.editor.selectedShapeIDs, [a])
        for _ in 0..<3 { walk.step(forward: true) }
        expectEqual(walk.at, c)
        expectEqual(h.editor.board, BoardID(owner: pocketID), "the stop's board is shown")
        expectEqual(h.editor.selectedShapeIDs, [c])
    },
    test("a shape with two issues is two stops, the worse first") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(.all, at: .shape(d))
        expectEqual(walk.number, 5)
        expectEqual(walk.currentRow?.severity, .error)
        walk.step(forward: true)
        expectEqual(walk.number, 6)
        expectEqual(walk.at, d)
        expectEqual(walk.currentRow?.severity, .warning)
        expectEqual(h.editor.selectedShapeIDs, [d])
        expectEqual(walk.rows.map(\.key).count, Set(walk.rows.map(\.key)).count, "each stop is named apart")
    },
    test("a step wraps at both ends, and the opposite step undoes it") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(.all, at: .first, forward: false)
        expectEqual(walk.number, 6)
        walk.step(forward: true)
        expectEqual(walk.number, 1, "forward from the last is the first")
        walk.step(forward: false)
        expectEqual(walk.number, 6, "and back from the first is the last")
        for place in 1...6 {
            walk.started(.all, at: .first)
            for _ in 1..<place { walk.step(forward: true) }
            let before = walk.number
            walk.step(forward: true)
            walk.step(forward: false)
            expectEqual(walk.number, before, "next then previous from stop \(place)")
        }
    },
    test("the whole walk, through two boards, is one step back") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started()
        for _ in 0..<5 { walk.step(forward: true) }
        expectEqual(h.editor.board, BoardID(owner: pocketID))
        expect(h.editor.canGoBack)
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "back to where the walk began")
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(!h.editor.canGoBack, "one step, not one for each stop")
    },
    test("with no walk, a step begins one through every issue, at the first stop after the selection, or before it going back") {
        let h = try walkHarness()
        let walk = try walk(h)
        h.editor.goTo([q])
        walk.step(forward: true)
        spinRunLoop(until: { !walk.isGathering })
        expect(walk.isRunning)
        expectEqual(walk.at, link, "Q is a shape with no issue: the first stop after it in board order")
        walk.end()
        h.editor.goTo([q])
        walk.step(forward: false)
        spinRunLoop(until: { !walk.isGathering })
        expectEqual(walk.at, b, "and going back, the last one before it")
        walk.end()
        h.editor.goTo([b])
        walk.step(forward: true)
        spinRunLoop(until: { !walk.isGathering })
        expectEqual(walk.at, link, "from a shape that is a stop, the stop after it")
    },
    test("with several shapes selected, a step begins after the last of them in walk order, or before the first going back") {
        let h = try walkHarness()
        let walk = try walk(h)
        h.editor.goTo([a, q])
        walk.step(forward: true)
        spinRunLoop(until: { !walk.isGathering })
        expectEqual(walk.at, link, "after the last of them (Q, past B), not after A")
        walk.end()
        h.editor.goTo([q, a])
        walk.step(forward: false)
        spinRunLoop(until: { !walk.isGathering })
        expectEqual(walk.at, d, "going back, before the first of them: A is the first stop, so round to the last")
        walk.end()
        h.editor.goTo([b, q])
        walk.step(forward: false)
        spinRunLoop(until: { !walk.isGathering })
        expectEqual(walk.at, a, "the stop before B, which comes before Q")
    },
    test("neither key runs during a gesture, and the walk does not move") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started()
        expect(h.editor.canPerform(.nextIssue) && h.editor.canPerform(.previousIssue))
        h.press(at: CGPoint(x: 50, y: 30))
        expect(!h.editor.canPerform(.nextIssue) && !h.editor.canPerform(.previousIssue), "a press is under way")
        walk.step(forward: true)
        expectEqual(walk.number, 1, "a step mid-gesture goes nowhere")
        h.release()
        expect(h.editor.canPerform(.nextIssue))
        walk.step(forward: true)
        expectEqual(walk.number, 2)
    },
    test("a scope with candidates is read at once, and is held to what its issues include") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.begin(scope("bad", candidates: [a, b]), at: .first)
        expect(!walk.isGathering)
        expectEqual(walk.shapes, [a], "B is a candidate and has no such issue")
        expectEqual(walk.at, a)
        walk.end()
        expect(!walk.isRunning)
        expectEqual(walk.rows.count, 0)
        walk.begin(scope("bad", candidates: []), at: .first)
        expect(!walk.isRunning, "a walk with no stop is no walk")
    },
    test("an Ignore keeps its row in place, dimmed as ignored: the count drops, the number stays, the next stop takes it, one step undoes it") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(scope("meh"))
        expectEqual(walk.shapes, [b, d])
        expectEqual(walk.total, 2)
        expect(walk.canIgnore)
        expect(walk.ignoreCurrent())
        expectEqual(walk.shapes, [b, d], "the row stays in its place")
        expectEqual(walk.states, [.ignored, .open])
        expectEqual(walk.total, 1, "the count drops")
        expectEqual(walk.at, b, "the place does not move")
        expectEqual(walk.number, 1, "the number is kept")
        expectEqual(h.editor.announcements.last, "Ignored, 1")
        expect(!walk.canIgnore, "an ignored stop has nothing to ignore")
        walk.step(forward: true)
        expectEqual(walk.at, d)
        expectEqual(walk.number, 1, "the next stop takes the number")
        h.editor.undo()
        expectEqual(walk.states, [.open, .open], "undo brings the stop back")
        expectEqual(walk.total, 2)
        expectEqual(walk.at, d, "and the place stays where it was")
        expect(h.editor.document[b].flatMap { $0.typed(as: Card.self)?.props.text } == "meh", "one undo step took the ignore back")
    },
    test("the Ignore on an issue's line tells the walk too, so its row reads ignored, and a fix reads holds") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(scope("meh"))
        let lines = try require(h.editor.detailPanel).layout(for: try require(h.editor.document[b])).statuses(in: .of(IssuesTab.self))
        try require(lines.first?.actions.first).perform()
        expectEqual(walk.states, [.ignored, .open], "run from the line, not the walk")
        h.editor.undo()
        h.editor.transact("Fix") { $0.update(b, as: Card.self) { $0.props.text = "fine" } }
        expectEqual(walk.states, [.holds, .open], "a fix makes the stop read holds")
        expectEqual(walk.total, 1)
        expectEqual(walk.number, 1)
        h.editor.undo()
        expectEqual(walk.states, [.open, .open], "undo brings it back")
    },
    test("a stop that goes with its shape leaves, and comes back with the shape") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(scope("meh"), at: .shape(d))
        h.editor.showBoard(.root)
        h.editor.transact("Delete") { $0.delete([b]) }
        expectEqual(walk.shapes, [d])
        expectEqual(walk.at, d)
        h.editor.undo()
        expectEqual(walk.shapes, [b, d])
        expectEqual(walk.at, d)
    },
    test("a stop that arrives on a board not shown joins in board order, and the current stop stays current") {
        let late = Late()
        let h = try walkHarness(late)
        let walk = try walk(h)
        walk.started(.all, at: .shape(d))
        expectEqual(h.editor.board, BoardID(owner: pocketID))
        expectEqual(walk.number, 5)
        late.raised = true
        try require(h.editor.validation).recheck([x])
        h.wait(1)
        expectEqual(walk.shapes, [a, b, link, x, c, d, d], "X is on the root, between the link and the pocket's board")
        expectEqual(walk.at, d, "the current stop is current still")
        expectEqual(walk.number, 6, "its number follows the stop that arrived before it")
        expectEqual(walk.currentRow?.severity, .error)
    },
    test("the stops of a rule that answers later arrive as the answers come") {
        let late = Late()
        let h = try walkHarness(late)
        let walk = try walk(h)
        walk.started(.all, at: .first)
        late.raised = true
        h.editor.transact("Touch") { $0.update(x, as: Card.self) { $0.props.text = "late!" } }
        expectEqual(walk.shapes, [a, b, link, x, c, d, d])
        expectEqual(walk.at, a)
        expectEqual(walk.number, 1)
    },
    test("announcements: the number, the board when it changes, the shape or an arrow by its ends, and what is wrong") {
        let h = try walkHarness()
        let walk = try walk(h)
        let card = h.editor.registry.label(of: Card.kind).name
        walk.started()
        expectEqual(h.editor.announcements.last, "Issue 1 of 6, Root, \(card), It's bad.")
        walk.step(forward: true)
        expectEqual(h.editor.announcements.last, "Issue 2 of 6, \(card), It's so-so.", "the board is named when it changes only")
        walk.step(forward: true)
        expectEqual(h.editor.announcements.last, "Issue 3 of 6, \(card) → \(card), Check this link.", "an arrow by the ends of the connection it carries")
        walk.step(forward: true)
        expectEqual(h.editor.announcements.last, "Issue 4 of 6, Texas, \(card), It's bad.")
        walk.step(forward: true)
        walk.step(forward: true)
        walk.step(forward: true)
        expectEqual(h.editor.announcements.last, "Issue 1 of 6, Root, \(card), It's bad.", "round the end, the board named again")
    },
    test("arriving at a stop chooses the Issues tab for its kind, and ending gives each kind the tab it had") {
        let h = try walkHarness()
        let walk = try walk(h)
        let panel = try require(h.editor.detailPanel)
        panel.choose(.of(CardTab.self), for: Card.kind)
        expectEqual(panel.chosenTab(for: Link.kind), nil)
        walk.started()
        expectEqual(panel.chosenTab(for: Card.kind), .of(IssuesTab.self))
        walk.step(forward: true)
        walk.step(forward: true)
        expectEqual(walk.at, link)
        expectEqual(panel.chosenTab(for: Link.kind), .of(IssuesTab.self))
        walk.end()
        expectEqual(panel.chosenTab(for: Card.kind), .of(CardTab.self), "the tab it had")
        expectEqual(panel.chosenTab(for: Link.kind), nil, "none chosen, as before")
        expect(!walk.isRunning)
        expectEqual(walk.rows.count, 0)
    },
    test("a scope that is made of other things is followed in place, the place kept on its shape; one that no longer exists ends the walk") {
        let h = try walkHarness()
        let walk = try walk(h)
        let reworded = IssueScope(id: "reworded", includes: { $0.source?.key == Pick.key }, label: { _ in Pick.exists ? IssueScopeLabel("Rule") : nil },
                                isChanged: { changes, _ in changes.changed.contains(b) })
        walk.started(reworded, at: .shape(d))
        expectEqual(walk.shapes, [b, d])
        expectEqual(walk.at, d)
        Pick.key = "bad"
        h.editor.showBoard(.root)
        let answered = walk.answers
        h.editor.transact("Reword") { $0.update(b, as: Card.self) { $0.props.text = "meh!" } }
        // The rows are made again from the answer to the question asked again, which does not set `isGathering`.
        spinRunLoop(until: { walk.answers > answered }, timeout: 20)
        expectEqual(walk.shapes, [a, c, d], "made again from the new words")
        expectEqual(walk.at, d, "the place on the shape it was on")
        Pick.exists = false
        h.editor.transact("Touch") { $0.update(b, as: Card.self) { $0.props.text = "meh" } }
        expect(!walk.isRunning, "its rule is gone")
    },
    test("a person who selects elsewhere while a reworded scope's answers are on their way is not pulled back to the old shape") {
        let h = try walkHarness()
        let walk = try walk(h)
        defer { Pick.key = "meh"; Pick.exists = true }
        let reworded = IssueScope(id: "reworded", includes: { $0.source?.key == Pick.key }, label: { _ in Pick.exists ? IssueScopeLabel("Rule") : nil },
                                  isChanged: { changes, _ in changes.changed.contains(b) })
        walk.started(reworded, at: .shape(d))
        expectEqual(walk.at, d)
        Pick.key = "bad"
        h.editor.showBoard(.root)
        let answered = walk.answers
        h.editor.transact("Reword") { $0.update(b, as: Card.self) { $0.props.text = "meh!" } }
        // The answer is asked for and not here yet: the person selects another shape.
        expectEqual(walk.answers, answered)
        h.editor.goTo([c])
        spinRunLoop(until: { walk.answers > answered }, timeout: 20)
        expectEqual(walk.shapes, [a, c, d], "made again from the new words")
        expectEqual(h.editor.selectedShapeIDs, [c], "the selection stays where the person put it")
    },
    test("an issue scope is found by the plugin that owns the source of an issue, and for no other") {
        let h = try walkHarness()
        expectEqual(h.editor.registry.issueScope(for: mehSource, in: h.editor)?.id, "meh")
        expect(h.editor.registry.issueScope(for: IssueSource(plugin: "someone-else", key: "meh"), in: h.editor) == nil)
        let walk = try walk(h)
        walk.started(try require(h.editor.registry.issueScope(for: lateSource, in: h.editor)))
        expect(!walk.isRunning, "a rule with no stop: no walk")
    },
    test("the walk has Go's items and keys: ⌘' next, ⇧⌘' back, ⌥⌘' ignore, End Issue Walk") {
        let h = try walkHarness()
        let walk = try walk(h)
        let registry = h.editor.registry
        expectEqual(registry.title(of: .nextIssue), "Next Issue")
        expectEqual(registry.title(of: .previousIssue), "Previous Issue")
        expectEqual(registry.title(of: .ignoreIssue), "Ignore Issue")
        expectEqual(registry.title(of: .endIssueWalk), "End Issue Walk")
        expectEqual(registry.shortcut(forCommand: .nextIssue)?.chord, KeyChord("'", .command))
        expectEqual(registry.shortcut(forCommand: .previousIssue)?.chord, KeyChord("\"", .command))
        expectEqual(registry.shortcut(forCommand: .ignoreIssue)?.chord, KeyChord("'", [.command, .option]))
        expect(registry.shortcut(forCommand: .endIssueWalk) == nil)
        expect(!h.editor.canPerform(.ignoreIssue) && !h.editor.canPerform(.endIssueWalk), "no walk, nothing to ignore or end")
        h.hold(.command)
        expect(h.key("'"))
        spinRunLoop(until: { !walk.isGathering })
        expectEqual(walk.number, 1)
        h.key("'", isRepeat: true)
        expectEqual(walk.number, 2, "held, it repeats")
        h.hold([.command, .shift])
        expect(h.key("\""))
        expectEqual(walk.number, 1, "⇧⌘' undoes it")
        h.hold([.command, .option])
        expect(!h.key("'"), "A's error has no Ignore: the key goes on")
        h.hold(.command)
        h.key("'")
        h.hold([.command, .option])
        expect(h.key("'"), "B's warning has one")
        expectEqual(walk.states.first { $0 != .open }, .ignored)
        h.hold([])
        expect(h.editor.perform(.endIssueWalk))
        expect(!walk.isRunning)
    },
    test("a file put in place ends the walk") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started()
        h.editor.replaceFile(with: CanvasFile())
        expect(!walk.isRunning)
    },
    test("the place of an issue of a source among the stops, for a line that says 9 of 63") {
        let h = try walkHarness()
        let walk = try walk(h)
        expect(walk.place(of: b, source: mehSource) == nil, "no walk, no place")
        walk.started(scope("meh"))
        expectEqual(walk.place(of: b, source: mehSource), IssuePlace(number: 1, total: 2))
        expectEqual(walk.place(of: d, source: mehSource), IssuePlace(number: 2, total: 2))
        expect(walk.place(of: a, source: mehSource) == nil)
        walk.ignoreCurrent()
        expect(walk.place(of: b, source: mehSource) == nil, "an ignored stop has none")
        expectEqual(walk.place(of: d, source: mehSource), IssuePlace(number: 1, total: 1))
    },
    test("an Ignore that writes nothing sets nothing aside: the stop stays open, the key says it did nothing, and nothing is announced") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(scope("meh"))
        h.editor.transact("Stick") { $0.update(b, as: Card.self) { $0.props.text = "meh stuck" } }
        expectEqual(walk.at, b)
        expect(walk.canIgnore, "the issue has an Ignore")
        let spoken = h.editor.announcements.count, undo = h.editor.undoHistory.undoName
        expect(!walk.ignoreCurrent(), "refused: it did nothing")
        expectEqual(walk.states, [.open, .open])
        expectEqual(walk.total, 2)
        expectEqual(walk.number, 1)
        expectEqual(h.editor.announcements.count, spoken, "no \"Ignored\"")
        expectEqual(h.editor.undoHistory.undoName, undo, "no step")
        expect(walk.canIgnore, "and it can be tried again")
        // The row is not left marked as ignored: when the issue goes by a fix, it reads holds.
        h.editor.transact("Fix") { $0.update(b, as: Card.self) { $0.props.text = "fine" } }
        expectEqual(walk.states, [.holds, .open])
    },
    test("neither key runs while shapes wait to be placed, and the walk goes nowhere") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started()
        walk.step(forward: true)
        expectEqual(walk.number, 2)
        let slab = AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 40, height: 30))))
        expect(h.editor.placeLater(PendingPlacement([slab], stepName: "Add") { _ in [.zero] }))
        let selected = h.editor.selectedShapeIDs
        expect(!walk.canStep)
        expect(!h.editor.canPerform(.nextIssue) && !h.editor.canPerform(.previousIssue), "the commands are off")
        walk.step(forward: true)
        walk.step(forward: false)
        expectEqual(walk.number, 2, "a step would drop the shapes waiting")
        expectEqual(h.editor.selectedShapeIDs, selected)
        expect(h.editor.isPlacingLater, "they wait still")
        walk.end()
        walk.step(forward: true)
        walk.begin(.all, at: .first)
        expect(!walk.isRunning, "and no walk begins")
        expect(h.editor.isPlacingLater)
    },
    test("the shape of the current stop deleted: its stop leaves, the place falls to the stop after it, and undo brings it back") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(.all, at: .shape(b))
        expectEqual(walk.number, 2)
        h.editor.transact("Delete") { $0.delete([b]) }
        expect(walk.isRunning)
        expectEqual(walk.shapes, [a, link, c, d, d])
        expectEqual(walk.at, link, "the stop that took its place")
        expectEqual(walk.number, 2)
        expectEqual(walk.total, 5)
        walk.step(forward: false)
        expectEqual(walk.at, a, "back goes to the stop before")
        walk.step(forward: true)
        walk.step(forward: true)
        expectEqual(walk.at, c)
        h.editor.undo()
        expectEqual(walk.shapes, [a, b, link, c, d, d])
        expectEqual(walk.at, c, "the place is where it was")
    },
    test("the board of the current stop deleted with its owner: its stops leave and the walk goes on over the rest") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(.all, at: .shape(d))
        expectEqual(h.editor.board, BoardID(owner: pocketID))
        h.editor.showBoard(.root)
        h.editor.transact("Delete") { $0.delete([pocketID]) }
        expect(walk.isRunning)
        expectEqual(walk.shapes, [a, b, link])
        expectEqual(walk.total, 3)
        expect(walk.currentRow != nil, "a place on a stop that is there")
        expect(walk.number.map { (1...3).contains($0) } == true)
        walk.step(forward: true)
        expect([a, b, link].contains(walk.at ?? c), "a stop that is still there")
        h.editor.undo()
        expectEqual(walk.shapes, [a, b, link, c, d, d])
    },
    test("a commit of more shapes than the read limit is found again by the query: the new stops join in order, the current stop stays, a stop fixed in it reads holds") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(.all, at: .shape(d))
        expectEqual(walk.number, 5)
        h.editor.showBoard(.root)
        var added: [ShapeID] = []
        h.editor.transact("Paste") {
            for n in 0..<pasteSize {
                let id = ShapeID()
                if n % 500 == 0 { added.append(id) }
                $0.insert(AnyShapeRecord(ShapeRecord(id: id, Card(unit, text: n % 500 == 0 ? "bad" : ""))))
            }
            $0.update(b, as: Card.self) { $0.props.text = "fine" }
        }
        spinRunLoop(until: { walk.shapes.count == 6 + added.count }, timeout: 20)
        expectEqual(walk.shapes, [a, b, link] + added + [c, d, d])
        expectEqual(walk.states[1], .holds, "B was fixed in the same commit")
        expectEqual(walk.at, d)
        expectEqual(walk.currentRow?.severity, .error)
        expectEqual(walk.number, 1 + 1 + added.count + 1 + 1, "A, the link, the new ones and C come before it")
        expectEqual(walk.total, 6 + added.count - 1)
        expect(!walk.isGathering)
    },
    test("a rule that reads another shape: the link's row reads holds when its end card is fixed, and open again on undo") {
        let h = try walkHarness()
        let walk = try walk(h)
        _ = try require(h.editor.validation).results // the board shown has been checked, which is when a rule's lookups are kept
        walk.started(.all, at: .first)
        let row = { walk.rows.first { $0.shape == link }?.state }
        expectEqual(row(), .open)
        h.editor.transact("Fix the end") { $0.update(b, as: Card.self) { $0.props.text = "meh ok" } }
        expectEqual(row(), .holds, "the link was checked again, though only B changed")
        expectEqual(walk.at, a)
        h.editor.undo()
        expectEqual(row(), .open)
    },
    test("a rule's affected names a shape no commit changed, on a board kept aside too, and the walk reads it") {
        let late = Late()
        let h = try walkHarness(late, file: walkFile(pocketHolds: [record(14, Card(unit, text: "late"))]))
        let walk = try walk(h)
        walk.started(.all, at: .first)
        expect(!walk.shapes.contains(x) && !walk.shapes.contains(f))
        late.raised = true
        h.editor.transact("Touch B") { $0.update(b, as: Card.self) { $0.props.text = "meh!" } }
        h.wait(1)
        expectEqual(walk.shapes, [a, b, link, x, c, d, d, f], "X on the board shown, and F at the end of the pocket's, which is kept aside")
        expectEqual(walk.at, a)
    },
    test("words marked stale are read again: a shape whose issue appears with them joins") {
        let late = Late()
        let h = try walkHarness(late)
        let walk = try walk(h)
        walk.started(.all, at: .first)
        late.raised = true
        try require(h.editor.validation).recheckWords([x])
        h.wait(1)
        expectEqual(walk.shapes, [a, b, link, x, c, d, d])
        expectEqual(walk.at, a)
    },
    test("a commit that lands after the query read a shape and before its answer is used is not lost to it") {
        // Q comes first in the file and is checked before T, whose rule makes the commit from inside the query: the answer is
        // made of what Q was when it was read ("fine"), and the commit makes Q "bad" after.
        let q = walkID(21), t = walkID(22)
        let h = try walkHarness(file: walkRootFile([(21, "fine"), (22, "trigger")]))
        let walk = try walk(h)
        var sawGathering = false
        Checking.onTrigger = { [weak h, weak walk] in
            sawGathering = walk?.isGathering == true
            h?.editor.transact("Spoil") { $0.update(q, as: Card.self) { $0.props.text = "bad" } }
        }
        walk.begin(.all, at: .first)
        expect(walk.isGathering, "the query is asked off the main actor")
        spinRunLoop(until: { !walk.isGathering })
        expect(Checking.onTrigger == nil && sawGathering, "the commit landed while the first answer was on its way")
        expectEqual(walk.shapes, [q], "Q gained an issue after the query read it: it is a stop, because the walk kept what the commit named")
        expect(!walk.shapes.contains(t))
    },
    test("a stop with no source is the same stop as its words change: no rows pile up as a value is fixed") {
        let h = try walkHarness()
        let walk = try walk(h)
        h.editor.transact("Count") { $0.update(q, as: Card.self) { $0.props.text = "count 12345" } }
        walk.started(.all, at: .shape(q))
        let rows = walk.rows.count
        expectEqual(walk.currentRow?.message, "Count is 11.")
        for text in ["count 1234", "count 123", "count 12"] {
            h.editor.transact("Delete one") { $0.update(q, as: Card.self) { $0.props.text = text } }
            expectEqual(walk.rows.count, rows, "still one row for the shape")
            expectEqual(walk.at, q)
            expectEqual(walk.currentRow?.message, "Count is \(text.count).", "its words follow")
            expect(walk.states.allSatisfy { $0 == .open })
        }
        h.editor.transact("Fix") { $0.update(q, as: Card.self) { $0.props.text = "fine" } }
        expectEqual(walk.rows.first { $0.shape == q }?.state, .holds)
    },
    test("two issues of one name in a shape are two stops, apart; an Ignore run from the second's line sets the second aside") {
        let h = try walkHarness()
        let walk = try walk(h)
        h.editor.transact("Twice") { $0.update(q, as: Card.self) { $0.props.text = "twice" } }
        walk.started(.all, at: .first)
        let mine = { walk.rows.filter { $0.shape == q } }
        expectEqual(mine().count, 2)
        expectEqual(Set(walk.rows.map(\.key)).count, walk.rows.count, "each stop is named apart")
        let lines = try require(h.editor.detailPanel).layout(for: try require(h.editor.document[q])).statuses(in: .of(IssuesTab.self))
        expectEqual(lines.map(\.text), ["Twice.", "Twice."])
        try require(lines[1].actions.first).perform()
        expectEqual(mine().map(\.state), [.open, .ignored], "the second, not the first")
        expectEqual(walk.total, 7, "eight stops, one set aside")
        h.editor.undo()
        expectEqual(mine().map(\.state), [.open, .open])
    },
    test("with every stop ignored the count is 0 and a step goes nowhere; a step back passes an ignored row; a walk begun back with nothing selected starts at the last stop") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(scope("meh"))
        expect(walk.ignoreCurrent())
        expectEqual(walk.at, b)
        walk.step(forward: true)
        expectEqual(walk.at, d)
        walk.step(forward: false)
        expectEqual(walk.at, d, "back from D passes B, which is ignored, round to D")
        expect(walk.ignoreCurrent())
        expectEqual(walk.total, 0)
        expect(walk.isRunning)
        let spoken = h.editor.announcements.count, selected = h.editor.selectedShapeIDs
        walk.step(forward: true)
        walk.step(forward: false)
        expect(walk.isRunning)
        expectEqual(walk.total, 0)
        expectEqual(h.editor.announcements.count, spoken, "no \"Issue 0 of 0\"")
        expectEqual(h.editor.selectedShapeIDs, selected)
        expect(!walk.canIgnore)
        walk.end()
        h.editor.selectedShapeIDs = []
        walk.step(forward: false)
        spinRunLoop(until: { !walk.isGathering })
        expectEqual(walk.at, d, "the last stop: D's, the only one it has left")
        expectEqual(walk.number, 4, "A, the link and C come before it; B and the warning of D are ignored")
    },
    test("a file put in place while another board is shown ends the walk and gives the tabs back") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(.all, at: .shape(c))
        expectEqual(h.editor.board, BoardID(owner: pocketID))
        let panel = try require(h.editor.detailPanel)
        expectEqual(panel.chosenTab(for: Card.kind), .of(IssuesTab.self))
        h.editor.replaceFile(with: CanvasFile())
        expect(!walk.isRunning)
        expectEqual(walk.rows.count, 0)
        expectEqual(panel.chosenTab(for: Card.kind), nil, "the kind has the choice it had")
    },
    test("an editor let go while the first answer is on its way, or a question asked again: the continuation gives up, reading nothing of the editor") {
        for again in [false, true] {
            weak var editor: CanvasEditor?
            weak var service: IssueWalk?
            // In a pool of its own, so what is let go is gone before the run loop turns (the test's own drains as it ends).
            try autoreleasepool {
                let h = try walkHarness()
                editor = h.editor
                let walk = try walk(h)
                service = walk
                if again {
                    // A scope reworded: the rows are made again from a question asked again.
                    walk.started(.all, at: .first)
                    walk.scopeDidChange(from: .all, to: .all)
                } else {
                    walk.begin(.all, at: .first)
                }
                let answered = walk.answers
                // Its task has started and waits for the query's answer when the editor is let go.
                RunLoop.main.run(mode: .default, before: Date())
                expectEqual(walk.answers, answered, "the answer is still on its way")
            }
            // The answer comes, and the run loop turns for it.
            spinRunLoop(until: { editor == nil && service == nil }, timeout: 10)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            expect(editor == nil && service == nil, "nothing holds the editor or the walk")
        }
    },
    test("an editor let go with the walk running: the turn the scheduler waited for reads nothing") {
        weak var editor: CanvasEditor?
        try autoreleasepool {
            let late = Late()
            let h = try walkHarness(late)
            editor = h.editor
            let walk = try walk(h)
            walk.started(.all, at: .first)
            late.raised = true
            try require(h.editor.validation).recheck([x])
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        expect(editor == nil)
    },
    test("shapes deleted before the stops, then a stop edited: the rows stay in board order") {
        let (n1, n2, a, b) = (walkID(21), walkID(22), walkID(23), walkID(24))
        let h = try walkHarness(file: walkRootFile([(21, "fine"), (22, "fine"), (23, "bad"), (24, "meh")]))
        let walk = try walk(h)
        walk.started(.all, at: .first)
        expectEqual(walk.shapes, [a, b])
        h.editor.transact("Delete") { $0.delete([n1, n2]) }
        expectEqual(walk.shapes, [a, b])
        h.editor.transact("Edit") { $0.update(b, as: Card.self) { $0.props.text = "meh!" } }
        expectEqual(walk.shapes, [a, b], "B is read at a place that was A's before the delete: both keys are taken again")
        expectEqual(walk.number, 1)
        // A shape that arrives after two deletions lands in its place too.
        let c = h.add(Card(unit, text: "bad"))
        h.editor.transact("Edit") { $0.update(c, as: Card.self) { $0.props.text = "bad!" } }
        expectEqual(walk.shapes, [a, b, c])
        h.editor.undo()
        h.editor.undo()
        h.editor.undo()
        expectEqual(walk.shapes, [a, b])
    },
    test("the current stop deleted with a shape before it, whether that one is a stop or not: the place falls to the stop that followed it") {
        let (n, a, b, l, m) = (walkID(21), walkID(22), walkID(23), walkID(24), walkID(25))
        for scoped in [false, true] {
            // Every shape a stop: A and B go together, and the stale keys of both would sort among L's and M's fresh ones.
            let h = try walkHarness(file: walkRootFile([(22, "bad"), (23, "bad"), (24, "bad"), (25, "bad")]))
            let first = try require(h.editor.issueWalk)
            first.started(scoped ? walkScope("bad") : .all, at: .shape(b))
            expectEqual(first.shapes, [a, b, l, m])
            h.editor.transact("Delete") { $0.delete([a, b]) }
            expectEqual(first.shapes, [l, m])
            expectEqual(first.at, l, "the stop that followed B, not M (scoped: \(scoped))")
            expectEqual(first.number, 1)
            h.editor.undo()
            expectEqual(first.shapes, [a, b, l, m])
            // A shape that is no stop goes with the current stop: L's fresh key is below B's stale one.
            let g = try walkHarness(file: walkRootFile([(21, "fine"), (22, "bad"), (23, "bad"), (24, "bad"), (25, "bad")]))
            let other = try require(g.editor.issueWalk)
            other.started(scoped ? walkScope("bad") : .all, at: .shape(b))
            expectEqual(other.shapes, [a, b, l, m])
            g.editor.transact("Delete") { $0.delete([n, b]) }
            expectEqual(other.shapes, [a, l, m])
            expectEqual(other.at, l, "the stop that followed B (scoped: \(scoped))")
            expectEqual(other.number, 2)
        }
    },
    test("the current stop's board goes with a shape before its owner: the boards stay one run each and the place falls to the stop after it") {
        // A commit reaches one board, so the shapes that go on two are a shape of the root and a pocket with its board. A board's
        // own shapes come before the boards under it: the stops are X, Y, then S's board (P, Q, R), T's (U) and W's (V).
        let (x, s, t, w, y) = (walkID(21), walkID(22), walkID(23), walkID(24), walkID(25))
        let (p, q, r, u, v) = (walkID(31), walkID(32), walkID(33), walkID(41), walkID(51))
        func bad(_ n: Int) -> AnyShapeRecord { record(n, Card(unit, text: "bad")) }
        let file = CanvasFile(root: CanvasDocument(shapes: [bad(21), record(22, Pocket(unit)), record(23, Pocket(unit)), record(24, Pocket(unit)), bad(25)]),
                              children: [s: CanvasDocument(shapes: [bad(31), bad(32), bad(33)]), t: CanvasDocument(shapes: [bad(41)]),
                                         w: CanvasDocument(shapes: [bad(51)])])
        let h = try walkHarness(file: file)
        let walk = try walk(h)
        walk.started(.all, at: .shape(q))
        expectEqual(walk.shapes, [x, y, p, q, r, u, v])
        h.editor.showBoard(.root)
        // X and S go: S's rows have no key now, and S's stale keys would tie with W's fresh one.
        h.editor.transact("Delete") { $0.delete([x, s]) }
        expectEqual(walk.shapes, [y, u, v])
        expectEqual(walk.at, u, "the stop that followed Q among the rows that are left, not whichever the stale keys put there")
        expectEqual(walk.number, 2)
        expectEqual(walk.boards.map(\.board), [.root, BoardID(owner: t), BoardID(owner: w)], "one run each, in board order")
        expectEqual(walk.boards.map(\.rows), [0..<1, 1..<2, 2..<3])
        h.editor.undo()
        expectEqual(walk.shapes, [x, y, p, q, r, u, v])
        expectEqual(walk.boards.map(\.board), [.root, BoardID(owner: s), BoardID(owner: t), BoardID(owner: w)])
    },
    test("a closed row whose shape is moved onto another board takes that board with it: ignored or holding, each board one run, undo bringing it back") {
        // An ignored or fixed row is not read again (it has no issue to update from), so retaking the keys is the only thing that can put it
        // on the board its shape is on: else its key says one board and its row another, and the board's rows are in two runs.
        for scoped in [false, true] {
            for fixed in [false, true] {
                let h = try walkHarness()
                let walk = try walk(h)
                walk.started(scoped ? scope("meh") : .all, at: .shape(b))
                if fixed {
                    h.editor.transact("Fix") { $0.update(b, as: Card.self) { $0.props.text = "fine" } }
                } else {
                    expect(walk.ignoreCurrent())
                }
                let row = try require(walk.rows.first { $0.shape == b })
                expect(!row.isOpen, "B's row is closed (scoped: \(scoped), fixed: \(fixed))")
                expectEqual(row.board, .root)
                h.editor.transact(on: .root, "Move To") { t in expect(t.move([b], toBoardOwnedBy: pocketID)) }
                let texas = BoardID(owner: pocketID)
                expectEqual(walk.rows.first { $0.shape == b }?.board, texas, "the row goes with its shape (scoped: \(scoped), fixed: \(fixed))")
                expectEqual(walk.rows.first { $0.shape == b }?.state, row.state, "and stays as closed as it was")
                expectEqual(walk.rows.map(\.board), walk.rows.map { h.editor.file.board(containing: $0.shape) }, "every row is on the board its shape is on")
                expectEqual(Set(walk.boards.map(\.board)).count, walk.boards.count, "one run a board")
                expectEqual(walk.rows.last?.shape, b, "B is on top of Texas's stack: after its rows, in the last run")
                h.editor.undo()
                expectEqual(walk.rows.first { $0.shape == b }?.board, .root, "undo puts the row back on the root")
                expectEqual(Set(walk.boards.map(\.board)).count, walk.boards.count)
            }
        }
    },
    test("a scope reworded while the current stop is deleted, with the new scope's rows differing before its successor: the walk is on the stop after the deleted one") {
        // Rows A, B, L, M with B current; the reworded rule takes N (before B) too, so the old index of B in the new rows is N's.
        let (a, n, b, l, m) = (walkID(21), walkID(22), walkID(23), walkID(24), walkID(25))
        let h = try walkHarness(file: walkRootFile([(21, "bad"), (22, "meh"), (23, "bad"), (24, "bad"), (25, "bad")]))
        let walk = try walk(h)
        let reworded = IssueScope(id: "reworded", includes: { $0.source?.key == "bad" || (Pick.alsoMeh && $0.source?.key == "meh") },
                                  label: { _ in IssueScopeLabel("Rule") }, isChanged: { changes, _ in changes.changed.contains(m) })
        walk.started(reworded, at: .shape(b))
        expectEqual(walk.shapes, [a, b, l, m])
        Pick.alsoMeh = true
        let answered = walk.answers
        h.editor.transact("Reword") { $0.update(m, as: Card.self) { $0.props.text = "bad!" } }
        expectEqual(walk.answers, answered, "the answer to the question asked again is on its way")
        h.editor.transact("Delete") { $0.delete([b]) }
        expectEqual(walk.at, l, "the commit moved the walk to the stop after the deleted one")
        spinRunLoop(until: { walk.answers > answered }, timeout: 20)
        expectEqual(walk.shapes, [a, n, l, m], "made again from the new scope")
        expectEqual(walk.at, l, "still on L, not on whichever row has B's old place among them (N)")
        expectEqual(walk.number, 3)
    },
    test("a restack that moves one stop's shape past another's reorders the rows, the current stop kept") {
        let (a, b, c) = (walkID(21), walkID(22), walkID(23))
        let h = try walkHarness(file: walkRootFile([(21, "bad"), (22, "bad"), (23, "bad")]))
        let walk = try walk(h)
        walk.started(.all, at: .shape(b))
        expectEqual(walk.shapes, [a, b, c])
        h.editor.transact("Front") { $0.bringToFront(a) }
        expectEqual(walk.shapes, [b, c, a], "board order is the stack's")
        expectEqual(walk.at, b, "the current stop is kept")
        expectEqual(walk.number, 1)
        walk.step(forward: true)
        expectEqual(walk.at, c)
        h.editor.transact("Back") { $0.sendToBack(a) }
        expectEqual(walk.shapes, [a, b, c])
        expectEqual(walk.at, c)
        expectEqual(walk.number, 3)
    },
    test("a frame put in a frame changes the order of the stops inside it, though nothing is restacked or named") {
        let (g, n, x, f, y) = (walkID(21), walkID(22), walkID(23), walkID(24), walkID(25))
        let h = try walkHarness(file: walkRootFile([(21, nil), (22, "fine"), (23, "bad"), (24, nil), (25, "bad")]), more: [CorralsPlugin()])
        h.editor.put([y], in: f)
        let walk = try walk(h)
        walk.started(.all, at: .shape(y))
        expectEqual(walk.shapes, [x, y], "X is on the board directly, Y in F, after it")
        let before = h.editor.revision
        h.editor.put([f], in: g)
        expect(h.editor.revision > before)
        expectEqual(walk.shapes, [y, x], "F is in G now, and G comes before X")
        expectEqual(walk.at, y)
        expectEqual(walk.number, 1)
        _ = n
        h.editor.undo()
        expectEqual(walk.shapes, [x, y])
    },
    test("a commit that only moves shapes reads none of them again, and no row is made again; a kind whose rules read where shapes are is the engine's to say") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(.all, at: .first)
        let engine = try require(h.editor.validation)
        expect(!engine.rulesReadPlacement(of: Card.kind), "every rule of a card ignores moves")
        expect(engine.rulesReadPlacement(of: Link.kind), "a link's rule looks another shape up, and does not")
        let told = Flag()
        withObservationTracking {
            _ = walk.rows
            _ = walk.boards
            _ = walk.openCount
        } onChange: { told.set = true }
        let checks = Checking.cards
        for step in 1...3 {
            h.editor.transact("Move") { $0.translate([a, c, d], by: CGPoint(x: 10 * Double(step), y: 0)) }
        }
        expectEqual(Checking.cards, checks, "the stops' rules ran for none of the shapes dragged")
        expect(!told.set, "and nothing the walk shows changed")
        expectEqual(walk.shapes, [a, b, link, c, d, d])
        expectEqual(walk.total, 6)
    },
    test("when the current stop goes with stops before it, the place falls to the stop after it, not to whatever has its index") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(.all, at: .shape(b))
        expectEqual(walk.number, 2)
        h.editor.showBoard(.root)
        h.editor.transact("Delete") { $0.delete([a, b]) }
        expectEqual(walk.shapes, [link, c, d, d])
        expectEqual(walk.at, link, "the stop that followed B, not C, which has B's old index")
        expectEqual(walk.number, 1)
        h.editor.undo()
        expectEqual(walk.shapes, [a, b, link, c, d, d])
        // The last stop, with an earlier one deleted with it: nothing follows it, and the walk wraps as it does.
        walk.started(.all, at: .shape(c))
        h.editor.showBoard(.root)
        h.editor.transact("Delete") { $0.delete([a, link]) }
        expectEqual(walk.shapes, [b, c, d, d])
        expectEqual(walk.at, c, "C is current still")
        h.editor.undo()
        // The current stop's shape goes with the stop before it, and nothing follows: the walk wraps, as it does.
        walk.started(.all, at: .shape(d))
        h.editor.transact("Delete") { $0.delete([c, d]) }
        expectEqual(walk.shapes, [a, b, link])
        expect(walk.at != nil)
    },
    test("a shape that stops being ignored joins a rule's walk by the commit itself, though the rule's flagged set has not heard it yet") {
        final class Flagged { var ids: Set<ShapeID> = [] }
        let flagged = Flagged()
        let h = try walkHarness()
        let walk = try walk(h)
        flagged.ids = [b]
        let stale = scope("meh", finding: { _ in flagged.ids })
        walk.started(stale, at: .first)
        expectEqual(walk.shapes, [b])
        // Q becomes a card the rule finds; the candidates are another service's, and still say B alone.
        h.editor.transact("Stop ignoring") { $0.update(q, as: Card.self) { $0.props.text = "meh" } }
        expectEqual(walk.shapes, [b, q], "read because the commit changed it, whatever the candidates say")
        // What the rules only affect is held to the candidates: A's change names nothing, and X (named by B's) is no candidate.
        h.editor.transact("Touch B") { $0.update(b, as: Card.self) { $0.props.text = "meh!" } }
        expectEqual(walk.shapes, [b, q])
    },
    test("a row that changes where it stands changes the rows in place: the numbers follow a stop that flips, and the boards' counts") {
        let h = try walkHarness()
        let walk = try walk(h)
        walk.started(.all, at: .first)
        expectEqual(walk.boards.map(\.open), [3, 3])
        h.editor.transact("Count") { $0.update(q, as: Card.self) { $0.props.text = "count 12345" } }
        expectEqual(walk.shapes.count, 7, "Q arrives as a stop")
        let told = Flag()
        withObservationTracking {
            _ = walk.boards
            _ = walk.openCount
        } onChange: { told.set = true }
        // Only words change: the rows are told, the boards and the count are not.
        h.editor.transact("Count") { $0.update(q, as: Card.self) { $0.props.text = "count 1234" } }
        expectEqual(walk.rows.first { $0.shape == q }?.message, "Count is 10.")
        expect(!told.set, "a message that changes moves no count")
        // C is fixed: its stop reads holds, and every number after it follows.
        h.editor.showBoard(BoardID(owner: pocketID))
        h.editor.transact("Fix") { $0.update(c, as: Card.self) { $0.props.text = "fine" } }
        expectEqual(walk.boards.map(\.open), [4, 2])
        expectEqual(walk.boards.last?.firstOpen, walk.rows.firstIndex { $0.shape == d })
        expectEqual(walk.place(of: d, source: badSource), IssuePlace(number: 5, total: 6))
        expectEqual(walk.total, 6)
        h.editor.undo()
        expectEqual(walk.boards.map(\.open), [4, 3])
        expectEqual(walk.place(of: d, source: badSource), IssuePlace(number: 6, total: 7))
    },
])

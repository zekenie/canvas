import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Locking
import Mentions
import StickyNotes
import TestKit
import Titles
import Types

// What the model of relationships costs (`RelationshipBenchmarks.swift`): the index keeps the ends of every
// relationship type, and a file with none, or a drag, must cost what it did before the index was there. The
// board is the generated one with notes made into plain types, relationship types, instances, and arrows:
// two ends for each relationship type, and a relationship for four notes in ten (2,500 among 10,000 shapes).
//
// The figures below are the design's proposals; none has been measured on a quiet machine. Run the three
// alone with `TEST_FILTER="Relationship benchmarks" ./build.sh bench` (release, the thread's CPU).

extension Budget {
    /// Opening a file of 10,000 shapes that holds 2,500 relationships of 10 types, the services of Types made
    /// (the thread's CPU, release), over the same file without the relationships' arrows (the types, their marks
    /// and the instances remain): one read of each marked type's edges, no record read but the end arrows'.
    /// A proposal: about 5 ms.
    static let relationshipIndex10k = 5.0
}

extension Budget {
    /// The relationship parts of 10,000 arrows made, the first ask of each (a fit and a words-free verdict, the quote table
    /// not filled): the answers of the whole file made once, as a frame or Validation's first read asks. A proposal: 40 ms.
    static let relationPartMade = 40.0
    /// The sentences of 1,000 misfit arrows made, the first ask of each: a fit, the end's name and what it is, the types'
    /// titles, joined, and the quote table's entry. A proposal: 25 ms.
    static let relationPartWords = 25.0
    /// A commit naming 1,000 shapes in a file where the sentences of 50 arrows quote 50 notes, none of the 1,000 among them: one
    /// dictionary miss each, over the same commit in a file with nothing quoted. A proposal: 0.2 ms more.
    static let quotedNames = 0.2
}

extension Budget {
    /// A drag event that moves every shape of a file of 10,000 shapes that holds 2,500 relationships of 10 types (the arrows following), over
    /// the same event in the same file with those types plain: what the relationship index adds to an event, which returns on counts alone
    /// (`changed.count == moved.count`) before anything is built. The design's: within a drag event's budget.
    static let relationshipDragIdle = Budget.dragInput
}

extension Budget {
    /// 10,000 relationship types, each drawn as a pill (`TypeRows.pill`): the first frame, over the same notes
    /// as plain types, which are full size. Each is asked once for its rows' extent and once for its pill (its title and its
    /// fields' count, and its text measured once for each distinct name), and its size kept (the thread's CPU, release). 82 ms measured over
    /// at 10,000 distinct names (5.5 at 1,000), 12 ms when it was a fixed small paper that measured nothing: the text is measured (Core Text, about
    /// 8 us a name) and kept by what it says, so a board of relationship types named alike measures once. No board has ten thousand; the budget is
    /// moved to 100 ms and it is the measuring that is paid for.
    static let pillLayout = 100.0
}

extension Budget {
    /// A keystroke in an end's label (the words of the arrow from a type into a relationship type) with 1,000 relationships of
    /// the type: one recompile of a few records, no instance named, no layout (the thread's CPU, release). A proposal.
    static let endLabelKeystroke = 2.0
    /// An end drawn at a type with 1,000 instances, and with 10,000, counted at the release: the release itself and the frame
    /// after, which lays the instances out again (the thread's CPU, release), over the same board with no end drawn.
    /// A proposal, `typeEditReach` and `typeEditReachAll`'s order: 30 and 190 ms.
    static let endReach = [1_000: 30.0, 10_000: 190.0]
    /// A port's drag from a type with 10,000 instances across a relationship type, per pointer event: the hover commits the
    /// arrow bound and unbound, and the relationships read nothing and name nothing (`Session.touching`). A proposal: within
    /// a drag event's budget.
    static let relationshipPassIdle = Budget.dragInput
    /// A keystroke in a relationship type's title with 1,000 relationships of it: the arrows' rows in the table of contents
    /// are forgotten and read the title when they are next drawn (the thread's CPU, release). A proposal. (The name card
    /// would commit on Return or blur instead if this were not met.)
    static let relationshipTitleKeystroke = 2.0
}

extension Budget {
    /// What Types' `willDelete` handler (a relationship type's delete takes its end arrows) costs a delete of shapes that are no
    /// relationship type, an id (milliseconds, the thread's CPU, release): one added-value lookup an id and nothing else, in a file
    /// that holds relationship types with their ends. The design's figure, "one lookup an id", is a microsecond an id at most: a
    /// dictionary hit and a read of one added value is some tenth of that. Not measured on a quiet machine.
    static let endDeleteIdle = 0.001
}

/// How many announcements of instances laid out the index made.
@MainActor private final class RelationshipCount {
    var count = 0
    init(_ editor: CanvasEditor) { editor.relationships?.onChange { [weak self] in if !$0.layout.isEmpty { self?.count += 1 } } }
}

/// A drag that changes one shape and nothing else, as a port's drag changes its arrow.
@MainActor private final class BenchDrag {
    let shape: ShapeID
    init(_ shape: ShapeID) { self.shape = shape }
}

extension BenchDrag: Session {
    var touching: Set<ShapeID> { [shape] }
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
}

/// A Person type, a Company type and a relationship type Employment off the top of a board, and `count` notes of Person in a
/// grid under them; no end drawn. The three types and the first Person note are returned beside the document.
@MainActor private func instancesBoard(_ count: Int) -> (document: CanvasDocument, person: ShapeID, employment: ShapeID, note: ShapeID) {
    func type(_ title: String, at x: CGFloat, relationship: Bool = false) -> AnyShapeRecord {
        var note = ShapeRecord(StickyNote(frame: CGRect(x: x, y: -600, width: 200, height: 200), text: MentionText(plain: "")))
        note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        note[TitleProperty.self] = title
        if relationship { note[RelationshipProperty.self] = true }
        return AnyShapeRecord(note)
    }
    let person = type("Person", at: 0), company = type("Company", at: 400), employment = type("Employment", at: 800, relationship: true)
    var shapes = [person, company, employment]
    let columns = Int(Double(count).squareRoot().rounded(.up))
    var first = ShapeID()
    for place in 0..<count {
        var note = ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(place % columns) * 220, y: CGFloat(place / columns) * 220, width: 200, height: 200), text: MentionText(plain: "Ann \(place)")))
        note[IsAProperty.self] = [TypeLink(person.id)]
        if place == 0 { first = note.id }
        shapes.append(AnyShapeRecord(note))
    }
    return (CanvasDocument(shapes: shapes), person.id, employment.id, first)
}

/// A Person, a Company, a relationship type Employment from the one to the other (its two ends), and `count` Persons and as
/// many Companies as notes of them; an Employment from each Person to its Company, the first `misfits` of them run from a
/// Company (so the from end does not fit). The records of the arrows are returned beside the document.
@MainActor private func employmentBoard(arrows count: Int, misfits: Int = 0) -> (document: CanvasDocument, arrows: [AnyShapeRecord], people: [ShapeID]) {
    func note(_ n: Int, _ words: String) -> AnyShapeRecord {
        AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: Double(n % 100) * 220, y: Double(n / 100) * 220, width: 200, height: 200), text: MentionText(plain: words))))
    }
    func anchored(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    var person = note(0, ""), company = note(1, ""), employment = note(2, "")
    for (title, index) in [("Person", 0), ("Company", 1), ("Employment", 2)] {
        var type = [person, company, employment][index]
        type[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        type[TitleProperty.self] = title
        if index == 2 { type[RelationshipProperty.self] = true }
        switch index {
        case 0: person = type
        case 1: company = type
        default: employment = type
        }
    }
    var shapes = [person, company, employment]
    shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: anchored(person.id), end: anchored(employment.id)))))
    shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: anchored(employment.id), end: anchored(company.id)))))
    var arrows: [AnyShapeRecord] = [], people: [ShapeID] = []
    for n in 0..<count {
        var from = note(3 + 2 * n, "Ann \(n)"), to = note(4 + 2 * n, "Acme \(n)")
        from[IsAProperty.self] = [TypeLink(n < misfits ? company.id : person.id)]
        to[IsAProperty.self] = [TypeLink(company.id)]
        var arrow = AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: anchored(from.id), end: anchored(to.id))))
        arrow[IsAProperty.self] = [TypeLink(employment.id)]
        shapes += [from, to, arrow]
        arrows.append(arrow)
        people.append(from.id)
    }
    return (CanvasDocument(shapes: shapes), arrows, people)
}

/// The generated board, its notes made 20 plain types, 10 relationship types and as many instances as there
/// are relationships twice over; and, with `relationships`, an arrow into and out of each relationship type
/// (its ends) and 2,500 per 10,000 shapes arrows between two instances that are of a relationship type.
/// Without `marking`, the ten are plain types and the file holds no relationship type at all.
@MainActor private func relatedBoard(shapes size: Int, relationships: Bool, marking: Bool = true) -> (document: CanvasDocument, relationshipTypes: [ShapeID], count: Int) {
    var shapes = generatedBoard(shapes: size).shapes
    let wanted = size / 4
    var plain: [ShapeID] = [], marked: [ShapeID] = [], instances: [ShapeID] = []
    var at = 0
    for index in shapes.indices where shapes[index].kind == StickyNote.kind {
        defer { at += 1 }
        if at < 20 {
            shapes[index][TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
            shapes[index][TitleProperty.self] = "Type \(at)"
            plain.append(shapes[index].id)
        } else if at < 30 {
            shapes[index][TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
            if marking { shapes[index][RelationshipProperty.self] = true }
            shapes[index][TitleProperty.self] = "Relationship \(at)"
            marked.append(shapes[index].id)
        } else if instances.count < 2 * wanted {
            shapes[index][IsAProperty.self] = [TypeLink(plain[at % plain.count])]
            instances.append(shapes[index].id)
        }
    }
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    var count = 0
    if relationships {
        for (place, type) in marked.enumerated() {
            shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(plain[place]), end: bound(type)))))
            shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(type), end: bound(plain[10 + place])))))
        }
        for pair in 0..<(instances.count / 2) {
            var arrow = AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(instances[2 * pair]), end: bound(instances[2 * pair + 1]))))
            arrow[IsAProperty.self] = [TypeLink(marked[pair % marked.count])]
            shapes.append(arrow)
            count += 1
        }
    }
    return (CanvasDocument(shapes: shapes), marked, count)
}

@MainActor let relationshipBenchmarks = Suite("Relationship benchmarks", [
    test("10,000 asks of arrows whose answers are kept cost the stamp and the relation compare each: within the kept check's budget") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let (document, arrows, _) = employmentBoard(arrows: size)
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
            let checks = try require(editor.fieldChecks)
            for record in arrows { expectEqual(checks.fullCheck(of: record).problems, []) }
            #if DEBUG
            let made = checks.relationPartsMade
            #endif
            let kept = median(runs: 11, onThread: true) { for record in arrows { _ = checks.check(of: record) } }
            #if DEBUG
            expectEqual(checks.relationPartsMade, made, "asking again makes no part")
            #endif
            report(String(format: "%6d asks of kept relationship answers %6.2f ms (budget %.0f)", arrows.count, kept, Budget.fieldChecksKept))
            if holdsToBudgets, size >= 10_000 { expect(kept < Budget.fieldChecksKept, "\(arrows.count) asks of kept answers took \(kept) ms") }
        }
    },

    test("the relationship parts of 10,000 arrows are made by their first ask in the part's budget") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            let (document, arrows, _) = employmentBoard(arrows: size)
            var editor: CanvasEditor?
            let made = median(runs: 5, prepare: { editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler()) }, onThread: true) {
                guard let checks = editor?.fieldChecks else { return }
                for record in arrows { _ = checks.fullCheck(of: record) }
            }
            #if DEBUG
            expectEqual(editor?.fieldChecks?.relationPartsMade, arrows.count, "a part for each arrow")
            #endif
            report(String(format: "%6d relationship parts made %6.2f ms (budget %.0f)", arrows.count, made, Budget.relationPartMade))
            if holdsToBudgets, size >= 10_000 { expect(made < Budget.relationPartMade, "\(arrows.count) relationship parts took \(made) ms") }
        }
    },

    test("the sentences of 1,000 misfit arrows are made by their first ask in the words' budget") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            let count = min(size, 1_000)
            let (document, arrows, _) = employmentBoard(arrows: count, misfits: count)
            var editor: CanvasEditor?
            let made = median(runs: 5, prepare: { editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler()) }, onThread: true) {
                guard let checks = editor?.fieldChecks else { return }
                for record in arrows { _ = checks.fullCheck(of: record) }
            }
            if let checks = editor?.fieldChecks, let first = arrows.first {
                expectEqual(checks.fullCheck(of: first).problems.map(\.message), ["Employment runs from a Person. “Ann 0” is a Company."])
            }
            report(String(format: "%6d misfit sentences made %6.2f ms (budget %.0f)", count, made, Budget.relationPartWords))
            if holdsToBudgets, size >= 1_000 { expect(made < Budget.relationPartWords, "\(count) misfit sentences took \(made) ms") }
        }
    },

    test("a commit naming 1,000 shapes while 50 are quoted costs a dictionary miss each over the same commit with none quoted") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            let count = max(size, 100)
            @MainActor func commit(misfits: Int) throws -> Double {
                let (document, arrows, people) = employmentBoard(arrows: count, misfits: misfits)
                let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                let checks = try require(editor.fieldChecks)
                for record in arrows { _ = checks.fullCheck(of: record) }
                // The people the sentences do not quote: the last thousand of them.
                let named = Array(people.suffix(min(1_000, count - misfits)))
                var n = 0
                return median(runs: 11, onThread: true) {
                    n += 1
                    editor.transact("Words") { transaction in
                        for id in named { transaction.update(id, as: StickyNote.self) { $0.props.text = MentionText(plain: "Ann \(n)") } }
                    }
                }
            }
            let quoted = try commit(misfits: 50), none = try commit(misfits: 0)
            report(String(format: "%6d shapes named, 50 quoted: %6.3f ms against %6.3f with none (+%.3f, budget %.1f)", min(1_000, count - 50), quoted, none, quoted - none, Budget.quotedNames))
            if holdsToBudgets, size >= 10_000 { expect(quoted - none < Budget.quotedNames, "naming 1,000 shapes with 50 quoted took \(quoted - none) ms more") }
        }
    },

    test("10,000 relationship types are laid out as pills in the first frame for little more than the same notes as plain types") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        @MainActor func board(_ count: Int, marked: Bool) -> CanvasDocument {
            let columns = Int(Double(count).squareRoot().rounded(.up))
            return CanvasDocument(shapes: (0..<count).map { place in
                var note = ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(place % columns) * 220, y: CGFloat(place / columns) * 220, width: 200, height: 200), text: ""))
                note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
                note[TitleProperty.self] = "Type \(place)"
                if marked { note[RelationshipProperty.self] = true }
                return AnyShapeRecord(note)
            })
        }
        for size in sizes {
            var small: [Double] = [], full: [Double] = []
            for run in 0..<5 {
                for marked in [true, false] {
                    let document = board(size, marked: marked)
                    let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                    editor.viewportDidResize(to: viewport)
                    let bounds = document.shapes.compactMap(\.box).reduce(CGRect.null) { $0.union($1) }
                    editor.camera = Camera(fitting: bounds, in: viewport, inset: 0)
                    let first = threadCPUTime { draw(editor, into: context, size: viewport) }.milliseconds
                    if marked { small.append(first) } else { full.append(first) }
                    if run == 0, let id = document.shapes.first?.id {
                        expectEqual(editor.shapeContext.frame(of: id)?.size, marked ? TypePills.pill(title: "Type 0", fields: 0).size : CGSize(width: 200, height: 200))
                    }
                }
            }
            let added = small.sorted()[2] - full.sorted()[2]
            report(String(format: "%6d relationship types drawn as pills: the first frame %6.1f ms, %6.1f more than the same notes as plain types (budget %.0f)",
                          size, small.sorted()[2], added, Budget.pillLayout))
            if holdsToBudgets, size >= 10_000 { expect(added < Budget.pillLayout, "laying out \(size) relationship types as pills added \(added) ms to the first frame") }
        }
    },

    test("a keystroke in an end's label with 1,000 relationships of the type costs one recompile: no instance is named and nothing is laid out") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (document, _, _) = employmentBoard(arrows: 1_000)
        let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
        let ends = try require(editor.relationships)
        let end = try require(document.shapes.first { ends.end($0.id)?.side == .from }).id
        var heard: [RelationshipChange] = []
        ends.onChange { heard.append($0) }
        var n = 0
        let keystroke = median(runs: 100, onThread: true) {
            n += 1
            editor.transact { $0.update(end, as: Arrow.self) { $0.props.text = MentionText(plain: String(repeating: "e", count: n)) } }
        }
        expectEqual(editor.document[end]?.typed(as: Arrow.self)?.props.text, MentionText(plain: String(repeating: "e", count: n)), "the keystrokes were written")
        expectEqual(heard.count, n, "one announcement a keystroke")
        expect(heard.allSatisfy { $0.layout.isEmpty && $0.notes.isEmpty }, "no instance named, nothing laid out")
        expect(heard.allSatisfy { $0.arrows.count <= 2 }, "only the end arrows: \(heard.map(\.arrows.count))")
        report(String(format: "1,000 relationships, a keystroke in an end's label: %6.3f ms (budget %.0f)", keystroke, Budget.endLabelKeystroke))
        if holdsToBudgets { expect(keystroke < Budget.endLabelKeystroke, "a keystroke in an end's label took \(keystroke) ms") }
    },

    test("an end drawn at a type with 1,000 and 10,000 instances costs, at the release and in the frame after, the budget; a pass over the relationship type before it costs a drag event's") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in holdsToBudgets ? [1_000, 10_000] : sizes {
            var released: [Double] = [], passes: [Double] = []
            for _ in 0..<3 {
                let board = instancesBoard(size)
                let editor = CanvasEditor(registry: registry, document: board.document, scheduler: ManualScheduler())
                editor.viewportDidResize(to: viewport)
                let bounds = board.document.shapes.compactMap(\.box).reduce(CGRect.null) { $0.union($1) }
                editor.camera = Camera(fitting: bounds, in: viewport, inset: 0)
                draw(editor, into: context, size: viewport)
                // The arrow of a port's drag from Person, bound to it; the drag then passes over the relationship type.
                func bound(_ id: ShapeID) -> ArrowTerminal {
                    .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
                }
                let arrow = ShapeRecord(Arrow(start: bound(board.person), end: .free(CGPoint(x: 1_000, y: -300))))
                editor.transact { $0.insert(arrow) }
                editor.session = BenchDrag(arrow.id)
                let heard = RelationshipCount(editor)
                var over = true
                passes.append(median(runs: 21, onThread: true) {
                    over.toggle()
                    editor.transact("Hover") { $0.update(arrow.id, as: Arrow.self) { $0.props.end = over ? bound(board.employment) : .free(CGPoint(x: 1_000, y: -300)) } }
                })
                expectEqual(heard.count, 0, "a pass over the relationship type names nothing")
                editor.transact("Hover") { $0.update(arrow.id, as: Arrow.self) { $0.props.end = bound(board.employment) } }
                released.append(threadCPUTime {
                    editor.connectionReleased(arrow.id)
                    draw(editor, into: context, size: viewport)
                }.milliseconds)
                expect(editor.relationships?.end(arrow.id)?.type == board.employment, "the release counts the end")
                expect(heard.count > 0, "and names the instances")
                editor.session = nil
            }
            let reach = released.sorted()[1], pass = passes.sorted()[1]
            let budget = Budget.endReach[size] ?? Budget.endReach[10_000] ?? 0
            report(String(format: "%6d instances, an end drawn: the release and the frame after %6.1f ms (budget %.0f); a pass across the relationship type per event %6.3f ms (budget %.0f)",
                          size, reach, budget, pass, Budget.relationshipPassIdle))
            if holdsToBudgets {
                expect(reach < budget, "an end at a type with \(size) instances took \(reach) ms")
                if size >= 10_000 { expect(pass < Budget.relationshipPassIdle, "a pass over a relationship type took \(pass) ms an event") }
            }
        }
    },

    test("a keystroke in a relationship type's title with 1,000 relationships of it costs little: the arrows' rows are forgotten, not made") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (document, arrows, _) = employmentBoard(arrows: 1_000)
        let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
        let employment = try require(document.shapes.first { $0[RelationshipProperty.self] == true }).id
        var n = 0
        let keystroke = median(runs: 100, onThread: true) {
            n += 1
            editor.transact { $0.update(employment) { $0[TitleProperty.self] = String(repeating: "t", count: n) } }
        }
        expectEqual(editor.document[employment]?[TitleProperty.self], String(repeating: "t", count: n), "the keystrokes were written")
        _ = arrows
        report(String(format: "1,000 relationships, a keystroke in the relationship type's title: %6.3f ms (budget %.0f)", keystroke, Budget.relationshipTitleKeystroke))
        if holdsToBudgets { expect(keystroke < Budget.relationshipTitleKeystroke, "a keystroke in a relationship type's title took \(keystroke) ms") }
    },

    test("a keystroke in a note with the relationship index and no relationship in the file costs what it did without it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let (document, _, _) = relatedBoard(shapes: size, relationships: false)
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
            let index = try require(editor.relationships)
            let note = try require(document.shapes.last { $0.kind == StickyNote.kind && $0[TypeSchemaProperty.self] == nil && $0[LockedProperty.self] != true }).id
            var n = 0
            let keystroke = median(runs: 100, onThread: true) {
                n += 1
                editor.transact { $0.update(note, as: StickyNote.self) { $0.props.text = MentionText(plain: String(repeating: "a", count: n)) } }
            }
            expectEqual(editor.document[note]?.typed(as: StickyNote.self)?.props.text, MentionText(plain: String(repeating: "a", count: n)), "the keystrokes were written")
            expect(index.isActive, "the file's marked types are there: the index is active, with no arrow to read")
            report(String(format: "%6d shapes, no relationship, a keystroke in a note: %6.3f ms (budget %.0f)", size, keystroke, Budget.fieldKeystroke))
            if holdsToBudgets { expect(keystroke < Budget.fieldKeystroke, "a keystroke over \(size) shapes took \(keystroke) ms with the relationship index") }
        }
    },

    test("a keystroke in a note of a file with no relationship type at all costs what it did without the index: the first line returns") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let (document, _, _) = relatedBoard(shapes: size, relationships: false, marking: false)
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
            let index = try require(editor.relationships)
            let note = try require(document.shapes.last { $0.kind == StickyNote.kind && $0[TypeSchemaProperty.self] == nil && $0[LockedProperty.self] != true }).id
            let revision = index.revision
            var n = 0
            let keystroke = median(runs: 100, onThread: true) {
                n += 1
                editor.transact { $0.update(note, as: StickyNote.self) { $0.props.text = MentionText(plain: String(repeating: "a", count: n)) } }
            }
            expectEqual(editor.document[note]?.typed(as: StickyNote.self)?.props.text, MentionText(plain: String(repeating: "a", count: n)), "the keystrokes were written")
            expect(!index.isActive, "no relationship type: the index is idle")
            expectEqual(index.revision, revision, "a keystroke moves no end")
            report(String(format: "%6d shapes, no relationship type, a keystroke in a note: %6.3f ms (budget %.0f)", size, keystroke, Budget.fieldKeystroke))
            if holdsToBudgets { expect(keystroke < Budget.fieldKeystroke, "a keystroke over \(size) shapes took \(keystroke) ms with the idle relationship index") }
        }
    },

    test("a drag of every shape of a file that holds 2,500 relationships reads nothing of them: an event costs a drag event's budget more than the same file with no relationship type") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            // The same shapes and arrows twice: once with ten relationship types, once with those ten plain types (the arrows
            // between instances are of a plain type, the end arrows between two plain types). The event moves every shape, the arrows
            // following; what the relationship index adds to it is the difference.
            // The two events alternate, a run of each in turn: the whole event is 40 ms at 10,000 shapes and drifts by a
            // millisecond between one file's runs and the next's, which is the budget.
            let (document, _, count) = relatedBoard(shapes: size, relationships: true)
            let (plain, _, _) = relatedBoard(shapes: size, relationships: true, marking: false)
            let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
            let control = CanvasEditor(registry: registry, document: plain, scheduler: ManualScheduler())
            let index = try require(editor.relationships)
            expectEqual(index.isActive, true, "the index is active when the file holds relationship types")
            expectEqual(control.relationships?.isActive, false, "and idle when it holds none")
            let everything = Set(editor.document.shapes.map(\.id)), controlEverything = Set(control.document.shapes.map(\.id))
            let revision = index.revision
            var withTimes: [Double] = [], withoutTimes: [Double] = []
            for run in 0..<21 {
                @MainActor func event(_ editor: CanvasEditor, _ shapes: Set<ShapeID>) -> Double {
                    threadCPUTime { editor.transact("Move") { $0.translate(shapes, by: CGPoint(x: 1, y: 1)) } }.milliseconds
                }
                if run.isMultiple(of: 2) {
                    withTimes.append(event(editor, everything))
                    withoutTimes.append(event(control, controlEverything))
                } else {
                    withoutTimes.append(event(control, controlEverything))
                    withTimes.append(event(editor, everything))
                }
            }
            expectEqual(index.revision, revision, "a drag moves no end")
            let with = withTimes.sorted()[withTimes.count / 2], without = withoutTimes.sorted()[withoutTimes.count / 2]
            let more = with - without
            report(String(format: "%6d shapes, %d relationships, a drag event of every shape: %6.3f ms, %6.3f more than with no relationship type (%6.3f; budget %.0f more)", size, count, with, more, without, Budget.relationshipDragIdle))
            if holdsToBudgets { expect(more < Budget.relationshipDragIdle, "a drag event of \(size) shapes took \(more) ms more with \(count) relationships than with no relationship type") }
        }
    },

    test("a delete of 1,000 shapes that are no relationship type costs Types' handler one lookup an id, in a file that holds relationship types with their ends") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            // The handler's own time: a stopwatch handler on either side of Types' (handlers run in the plugins' order).
            let watch = ThreadStopwatch()
            var plugins = shippedPlugins(pasteboard)
            let at = try require(plugins.firstIndex { $0.id == .types })
            plugins.insert(Contributor(id: "bench-stopwatch-end") { r in r.willDelete { _, _ in watch.ended = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) } }, at: at + 1)
            plugins.insert(Contributor(id: "bench-stopwatch-start") { r in r.willDelete { _, _ in watch.started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) } }, at: at)
            let registry = try Registry(plugins: plugins)
            let (document, types, _) = relatedBoard(shapes: size, relationships: true)
            let doomed = Set(document.shapes.filter { $0.kind == StickyNote.kind && $0[TypeSchemaProperty.self] == nil }.prefix(1_000).map(\.id))
            var runs: [Double] = []
            var lastEnds: Set<ShapeID> = []
            for _ in 0..<5 {
                let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                let index = try require(editor.relationships)
                lastEnds = types.reduce(into: []) { $0.formUnion(index.endArrows(of: $1)) }
                editor.transact("Delete") { $0.delete(doomed) }
                runs.append(watch.milliseconds)
                expect(types.allSatisfy { editor.document[$0] != nil } && lastEnds.allSatisfy { editor.document[$0] != nil }, "no relationship type or end arrow was touched")
            }
            expect(!lastEnds.isEmpty, "the file's relationship types have their ends")
            let each = middle(runs) / Double(doomed.count)
            report(String(format: "%6d shapes, %d deleted that are no relationship type: the handler %7.5f ms an id (budget %.3f)", size, doomed.count, each, Budget.endDeleteIdle))
            if holdsToBudgets { expect(each < Budget.endDeleteIdle, "Types' delete handler took \(each) ms an id over \(size) shapes") }
        }
    },

    test("the relationship index, made as a file of 2,500 relationships opens, costs the index's budget over the same file without them") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let watch = ThreadStopwatch()
            var plugins = shippedPlugins(pasteboard)
            let at = try require(plugins.firstIndex { $0.id == .types })
            plugins.insert(Contributor(id: "bench-stopwatch-end") { r in r.service { _ in ThreadStopwatchEnd(watch) } }, at: at + 1)
            plugins.insert(Contributor(id: "bench-stopwatch-start") { r in r.service { _ in ThreadStopwatchStart(watch) } }, at: at)
            let registry = try Registry(plugins: plugins)
            @MainActor func opened(_ document: CanvasDocument) throws -> Double {
                var runs: [Double] = []
                for _ in 0..<5 {
                    let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                    runs.append(watch.milliseconds)
                    _ = try require(editor.relationships)
                }
                return middle(runs)
            }
            let (with, types, count) = relatedBoard(shapes: size, relationships: true)
            let (without, _, _) = relatedBoard(shapes: size, relationships: false)
            let editor = CanvasEditor(registry: registry, document: with, scheduler: ManualScheduler())
            let index = try require(editor.relationships)
            expect(types.allSatisfy { index.graph.isRelationshipType($0) })
            expectEqual(index.graph.ends.sides.count, types.count, "every relationship type's ends are read as the file opens")
            let by = try opened(with) - opened(without)
            report(String(format: "%6d shapes, %d relationships of %d types, the relationship index as the file opens: +%6.2f ms (budget %.0f)",
                          size, count, types.count, by, Budget.relationshipIndex10k))
            if holdsToBudgets, size >= 10_000 {
                expect(by < Budget.relationshipIndex10k, "the relationship index for \(size) shapes took \(by) ms more than without relationships")
            }
        }
    },
])

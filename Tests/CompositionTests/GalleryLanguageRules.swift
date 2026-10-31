import AppKit
import Canvas
import CanvasRPC
import CanvasTesting
import DecisionModels
import DetailPanel
import Draw
import LanguageModels
import LanguageRules
import Mentions
import Selection
import SwiftUI
import TestKit
import Titles
import Types
import Validation

// Language rules' look: a type's Rules tab with its counts, a flagged listing's Issues tab (the line, its rules read
// together, Shown), an ignored rule, no key, and the board's rings, over the plan's listings board with the decision
// model scripted by listing. Then the first minute of a rule's chips: a type with no rules, `@` typed in a new rule and
// its list, a chip's line (its query, the sample, what it found), the words being interpreted, no Anthropic key, a
// chip written by an agent and never asked, and the type's Rules chip on the board. Then the walk of a rule's flagged
// listings (a rule's count begins it): the band over the panel with "Rule 1" beside the type's chip, and after an Ignore
// the number kept and dimmed; then the list over a walk across two boards (`Walk3-list`).

private let agrees = "The description agrees with the car's year, model and mileage."
private let noDamage = "The description mentions no damage or wear."

/// A schema of no fields holding `rules`, as draw's `schema:` writes it: JSON inside a quoted string.
private func drawnSchema(_ rules: [String]) -> String {
    let listed = rules.map { #"{\"says\": \"\#($0)\"}"# }.joined(separator: ", ")
    return rules.isEmpty ? #""{\"type\": \"object\", \"properties\": {}}""#
        : #""{\"type\": \"object\", \"properties\": {\"$rules\": {\"const\": [\#(listed)]}}}""#
}

/// The answers by listing: whether the rules read together hold ("all"), and each rule's own.
private let listingAnswers: [String: [String: Double]] = [
    "2021 Toyota Corolla LE": ["all": 0.1, "r0": 0.9, "r1": 0.1],
    "2019 Toyota Camry SE": ["all": 0.1, "r0": 0.1, "r1": 0.9],
    "2010 Toyota Prius": ["all": 0.9, "r0": 0.1, "r1": 0.5],
    "1967 Ford Mustang Coupe": ["all": 0.1, "r0": 0.1, "r1": 0.9],
    "2015 Honda Civic": ["all": 0.1, "r0": 0.9, "r1": 0.1],
]

/// The listings board, checked: Car, Listing (two rules) built on it, four listings. `failing` answers every call with
/// that failure instead.
@MainActor private func listings(_ stage: GalleryStage, failing: DecisionModelError? = nil) throws -> [String: ShapeID] {
    let decisions = try require(stage.editor.decisionModel as? ScriptedDecisionModel)
    decisions.fallback = { request in
        if let failing { return .failure(failing) }
        let answers = listingAnswers[request.state["shape"]?["title"]?.stringValue ?? ""] ?? [:]
        return .success(DecisionAnswers(model: "scripted", yes: Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, answers[$0.id] ?? 0.1) })))
    }
    stage.editor.ruleChecks?.today = { "2026-10-29" }
    _ = try draw(script: """
    sticky-note "Car" text: "A car: its year, make, model and the miles on it." schema: \(drawnSchema([]))
    sticky-note "Listing" right of "Car" is: "Car" text: "A car for sale, described by its seller." schema: \(drawnSchema([agrees, noDamage]))
    sticky-note "2021 Toyota Corolla LE" below "Car" is: "Listing" text: "Barely driven, garage kept, like new inside and out."
    sticky-note "2019 Toyota Camry SE" right of "2021 Toyota Corolla LE" is: "Listing" text: "One owner, dealer serviced, 61k mostly highway miles. Small dent in the rear bumper."
    sticky-note "2010 Toyota Prius" right of "2019 Toyota Camry SE" is: "Listing" text: "High miles, but the hybrid battery was replaced in 2023."
    sticky-note "1967 Ford Mustang Coupe" right of "2010 Toyota Prius" is: "Listing" text: "Original paint with honest patina and some surface rust."
    """, dryRun: false, reveal: false, program: "gallery", in: stage.editor)
    var ids: [String: ShapeID] = [:]
    for record in stage.editor.document.shapes { if let title = record[TitleProperty.self] { ids[title] = record.id } }
    try require(stage.editor.ruleWriter).ignore(noDamage, on: try require(ids["1967 Ford Mustang Coupe"]))
    stage.scheduler.advance(by: .zero)
    stage.scheduler.advance(by: RuleChecks.quiet)
    spinRunLoop(until: { stage.editor.ruleChecks?.isBusy == false })
    stage.editor.selection = nil
    return ids
}

/// The listings board with a second listing the first rule flags (the Civic), and the first rule's walk begun at its first stop:
/// the Corolla's Issues tab under the band.
@MainActor private func walkingRule(_ stage: GalleryStage) throws -> (walk: IssueWalk, corolla: ShapeID) {
    let ids = try listings(stage)
    _ = try draw(script: """
    sticky-note "2015 Honda Civic" right of "1967 Ford Mustang Coupe" is: "Listing" text: "Clean inside, the clutch is worn."
    """, dryRun: false, reveal: false, program: "gallery", in: stage.editor)
    stage.scheduler.advance(by: .zero)
    stage.scheduler.advance(by: RuleChecks.quiet)
    spinRunLoop(until: { stage.editor.ruleChecks?.isBusy == false })
    let key = RuleKey(type: try require(ids["Listing"]), says: agrees)
    let walk = try require(stage.editor.issueWalk)
    walk.begin(try require(stage.editor.registry.issueScope(for: key.source, in: stage.editor)), at: .first)
    return (walk, try require(ids["2021 Toyota Corolla LE"]))
}

/// Listing (one rule, a `make` field) with three listings on the root and two on a subboard Texas's board, all flagged, the
/// first rule's walk begun, the Mustang's stop ignored and the walk on at the Corolla's, and the list open: the root's rows
/// under their head (the Mustang's dimmed, reading ignored), Texas folded, the Corolla's Issues tab under them.
@MainActor private func walkingList(_ stage: GalleryStage) throws -> (walk: IssueWalk, corolla: ShapeID) {
    let decisions = try require(stage.editor.decisionModel as? ScriptedDecisionModel)
    decisions.fallback = { request in
        .success(DecisionAnswers(model: "scripted", yes: Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0.id == "r0" ? 0.9 : 0.1) })))
    }
    stage.editor.ruleChecks?.today = { "2026-10-29" }
    let schema = #""{\"type\": \"object\", \"properties\": {\"$rules\": {\"const\": [{\"says\": \"\#(noDamage)\"}]}, \"make\": {\"type\": \"string\"}}}""#
    _ = try draw(script: """
    sticky-note "Listing" text: "A car for sale, described by its seller." schema: \(schema)
    sticky-note "1967 Ford Mustang Coupe" below "Listing" is: "Listing" text: "Original paint with honest patina and some surface rust." fieldValues: {"make": "Ford"}
    sticky-note "2021 Toyota Corolla LE" right of "1967 Ford Mustang Coupe" is: "Listing" text: "Barely driven, but a dent in the rear bumper." fieldValues: {"make": "Toyota"}
    sticky-note "2015 Honda Civic" right of "2021 Toyota Corolla LE" is: "Listing" text: "Clean inside, the clutch is worn." fieldValues: {"make": "Honda"}
    subboard "Texas" right of "Listing"
    """, dryRun: false, reveal: false, program: "gallery", in: stage.editor)
    _ = try draw(script: """
    sticky-note "2019 Toyota Camry SE" in "Texas" is: "Listing" text: "One owner, a dent in the rear bumper." fieldValues: {"make": "Toyota"}
    sticky-note "2010 Toyota Prius" in "Texas" right of "2019 Toyota Camry SE" is: "Listing" text: "High miles, dents all round." fieldValues: {"make": "Toyota"}
    """, dryRun: false, reveal: false, program: "gallery", in: stage.editor)
    var ids: [String: ShapeID] = [:]
    for record in stage.editor.document.shapes { if let title = record[TitleProperty.self] { ids[title] = record.id } }
    let key = RuleKey(type: try require(ids["Listing"]), says: noDamage)
    stage.scheduler.advance(by: .zero)
    stage.scheduler.advance(by: RuleChecks.quiet)
    spinRunLoop(until: { stage.editor.ruleChecks?.isBusy == false && stage.editor.ruleChecks?.flagged(by: key).count == 5 })
    let walk = try require(stage.editor.issueWalk)
    walk.begin(try require(stage.editor.registry.issueScope(for: key.source, in: stage.editor)), at: .first)
    expect(walk.ignoreCurrent())
    stage.scheduler.advance(by: .zero)
    stage.scheduler.advance(by: RuleChecks.quiet)
    spinRunLoop(until: { stage.editor.ruleChecks?.isBusy == false })
    walk.step(forward: true)
    walk.openList()
    stage.spin(0.2)
    return (walk, try require(ids["2021 Toyota Corolla LE"]))
}

@MainActor let languageRuleStates: [GalleryState] = [
    GalleryState("Rules1-type-tab", answers: "F1", "Listing's Rules tab: its two rules, each with the count of listings it flags (1 and 1, the Mustang's ignored), and add rule",
                 size: CGSize(width: 320, height: 300)) { stage in
        let ids = try listings(stage)
        return .image(try stage.panelPicture(of: try require(ids["Listing"]), tab: .of(RulesTab.self), size: CGSize(width: 320, height: 300)))
    },
    GalleryState("Rules2-flagged-issues", answers: "F5", "the Corolla's Issues tab: the line quoting the rule with Ignore and Show Rule, its rules read together with their states, and Shown",
                 size: CGSize(width: 320, height: 620)) { stage in
        let ids = try listings(stage)
        return .image(try stage.panelPicture(of: try require(ids["2021 Toyota Corolla LE"]), tab: .of(IssuesTab.self), size: CGSize(width: 320, height: 620)))
    },
    GalleryState("Rules3-ignored", answers: "F6", "the Mustang, which ignores the damage rule: no line, the rule ignored with Stop Ignoring",
                 size: CGSize(width: 320, height: 300)) { stage in
        let ids = try listings(stage)
        return .image(try stage.panelPicture(of: try require(ids["1967 Ford Mustang Coupe"]), tab: .of(IssuesTab.self), size: CGSize(width: 320, height: 300)))
    },
    GalleryState("Rules4-unsure", answers: "F6", "the Prius: nothing flags it, one rule holds and one is unsure", size: CGSize(width: 320, height: 300)) { stage in
        let ids = try listings(stage)
        return .image(try stage.panelPicture(of: try require(ids["2010 Toyota Prius"]), tab: .of(IssuesTab.self), size: CGSize(width: 320, height: 300)))
    },
    GalleryState("Rules5-no-key", answers: "F6", "no TypeSafe key: the listing's Rules section says so with Open Settings…", size: CGSize(width: 320, height: 220)) { stage in
        let ids = try listings(stage, failing: DecisionModelError(.noKey, provider: "TypeSafe"))
        return .image(try stage.panelPicture(of: try require(ids["2021 Toyota Corolla LE"]), tab: .of(IssuesTab.self), size: CGSize(width: 320, height: 220)))
    },
    GalleryState("Rules6-board", answers: "F1", "the board: the Corolla and the Camry ringed orange, the Prius and the Mustang not", size: CGSize(width: 1000, height: 420)) { stage in
        _ = try listings(stage)
        let bounds = stage.editor.document.shapes.compactMap(\.box).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -40, dy: -60)
        let zoom = min(1000 / bounds.width, 420 / bounds.height)
        stage.look(at: bounds.origin, zoom: zoom)
        return .image(stage.picture())
    },
    GalleryState("Rules7-empty-tab", "Car's Rules tab: a type with no rules of its own, the box to add one",
                 size: CGSize(width: 320, height: 160)) { stage in
        let ids = try listings(stage)
        return .image(try stage.panelPicture(of: try require(ids["Car"]), tab: .of(RulesTab.self), size: CGSize(width: 320, height: 160)))
    },
    GalleryState("Rules8-at-list", "a new rule on Listing, `@the other` typed: the list of shapes, then the words as a phrase",
                 size: CGSize(width: 320, height: 460)) { stage in
        let ids = try listings(stage)
        return .image(try stage.rulesPanel(of: try require(ids["Listing"]), size: CGSize(width: 320, height: 460), typing: "Not a copy of @the other"))
    },
    GalleryState("Rules9-chip-line", "a rule with a chip: the phrase drawn in the sentence, its line with the query, the sample (‹ ›) and what it found",
                 size: CGSize(width: 320, height: 560)) { stage in
        let ids = try listings(stage)
        let listing = try require(ids["Listing"])
        try stage.chip(listing, query: duplicateQuery)
        return .image(try stage.panelPicture(of: listing, tab: .of(RulesTab.self), size: CGSize(width: 320, height: 560)))
    },
    GalleryState("Rules10-interpreting", "the chip's words being made a query: Interpreting… on its line",
                 size: CGSize(width: 320, height: 460)) { stage in
        let ids = try listings(stage)
        let listing = try require(ids["Listing"])
        try stage.chip(listing, query: nil)
        stage.model.holdsAnswers = true
        stage.editor.ruleChips?.interpret(others, type: listing)
        let picture = try stage.panelPicture(of: listing, tab: .of(RulesTab.self), size: CGSize(width: 320, height: 460))
        stage.model.holdsAnswers = false
        stage.model.release()
        return .image(picture)
    },
    GalleryState("Rules11-no-key", "no Anthropic key: the chip's line says so with Open Settings…",
                 size: CGSize(width: 320, height: 460)) { stage in
        let ids = try listings(stage)
        let listing = try require(ids["Listing"])
        try stage.chip(listing, query: nil)
        stage.translating(.failure(.notSignedIn))
        stage.editor.ruleChips?.interpret(others, type: listing)
        stage.spin(0.2)
        return .image(try stage.panelPicture(of: listing, tab: .of(RulesTab.self), size: CGSize(width: 320, height: 460)))
    },
    GalleryState("Rules12-never-asked", "a chip an agent wrote with no query, never asked: Interpret on its line",
                 size: CGSize(width: 320, height: 460)) { stage in
        let ids = try listings(stage)
        let listing = try require(ids["Listing"])
        try stage.chip(listing, query: nil)
        return .image(try stage.panelPicture(of: listing, tab: .of(RulesTab.self), size: CGSize(width: 320, height: 460)))
    },
    GalleryState("Walk1-band", "a rule's walk at its first stop: the band over the panel (Rule 1 beside Listing's chip, ‹ 1 of 2 › and Done), the Corolla's Issues tab under it with its line (Ignore, Show Rule; the current stop's line says no place, the band does)",
                 size: CGSize(width: 320, height: 620)) { stage in
        let (walk, corolla) = try walkingRule(stage)
        defer { walk.end() }
        return .image(try stage.panelPicture(of: corolla, tab: .of(IssuesTab.self), size: CGSize(width: 320, height: 620)))
    },
    GalleryState("Walk2-ignored", "the same walk after Ignore on the first stop: the band keeps the number, dimmed (1 of 1), the Corolla's rule ignored",
                 size: CGSize(width: 320, height: 620)) { stage in
        let (walk, corolla) = try walkingRule(stage)
        defer { walk.end() }
        expect(walk.ignoreCurrent())
        stage.scheduler.advance(by: .zero)
        stage.scheduler.advance(by: RuleChecks.quiet)
        spinRunLoop(until: { stage.editor.ruleChecks?.isBusy == false })
        stage.spin(0.2)
        return .image(try stage.panelPicture(of: corolla, tab: .of(IssuesTab.self), size: CGSize(width: 320, height: 620)))
    },
    GalleryState("Walk3-list", "the list open over the evidence mid-walk: the root's head and its three rows (the Mustang's dimmed, reading ignored; the others ending in their make), Texas's head folded, the Corolla's warning line and its rules under them, the band over all",
                 size: CGSize(width: 320, height: 620)) { stage in
        let (walk, corolla) = try walkingList(stage)
        defer { walk.end() }
        return .image(try stage.panelPicture(of: corolla, tab: .of(IssuesTab.self), size: CGSize(width: 320, height: 620)))
    },
    GalleryState("Rules13-type-chip", "the types on the board: Listing's pill, the Car it builds on, and Rules 3",
                 size: CGSize(width: 560, height: 220)) { stage in
        let ids = try listings(stage)
        try stage.chip(try require(ids["Listing"]), query: duplicateQuery)
        let car = try require(stage.editor.document[try require(ids["Car"])]?.box)
        stage.look(at: CGPoint(x: car.minX - 30, y: car.minY - 50))
        return .image(stage.picture())
    },
]

private let others = "the other listings"
private let duplicate = "Not a copy of the other listings."
private let duplicateQuery = #"sticky-note:is-a("Listing"):not(:scope)"#

extension GalleryStage {
    /// What the model answers when asked to make a chip's words a query (every other call as the stage answers it).
    func translating(_ answer: Result<String, LanguageModelError>) {
        let highlights = model.fallback
        model.fallback = { request in
            guard request.system?.contains("a phrase in brackets in a rule") == true else {
                return highlights?(request) ?? .failure(.malformedResponse)
            }
            return answer.map { ModelResponse(text: $0) }
        }
    }

    /// Listing given a third rule, its phrase a chip with `query` (nil: never asked), and checked again.
    func chip(_ listing: ShapeID, query: String?) throws {
        let rules = RuleBook.rules(of: listing, in: editor) + [Rule(says: duplicate, find: [RuleChip(phrase: others, query: query)])]
        expect(try require(editor.ruleWriter).setRules(rules, of: listing))
        scheduler.advance(by: RuleChecks.quiet)
        spinRunLoop(until: { self.editor.ruleChecks?.isBusy == false })
        spin(0.2)
        editor.selection = nil
    }

    /// The Rules tab of `type` with `text` typed into its new rule's box, as an unshown window draws it, and the open
    /// list under the caret as `pictureWithList` lays it.
    func rulesPanel(of type: ShapeID, size: CGSize, typing text: String) throws -> NSBitmapImageRep {
        let record = try require(editor.document[type])
        try require(editor.detailPanel).choose(.of(RulesTab.self), for: record.kind)
        editor.selection = type
        let host = NSHostingView(rootView: try require(editor.registry.hostInspector).view(for: editor, onExit: {}))
        host.frame = CGRect(origin: .zero, size: size)
        let panelWindow = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        panelWindow.isReleasedWhenClosed = false
        defer { panelWindow.close() }
        panelWindow.contentView = host
        panelWindow.appearance = appearance
        panelWindow.settle()
        spin(0.15)
        let box = try require(host.descendants.compactMap { $0 as? MentionTextView<AnyMentionable> }.last, "the new rule's box")
        panelWindow.makeFirstResponder(box)
        panelWindow.type(text)
        panelWindow.settle()
        spin(0.15)
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            if let graphics = NSGraphicsContext(bitmapImageRep: rep) {
                graphics.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
                graphics.cgContext.fill(CGRect(origin: .zero, size: size))
                graphics.flushGraphics()
            }
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        let listed = try require(listRows(in: box.caretListWindow), "the list is open")
        let caret = box.firstRect(forCharacterRange: NSRange(location: box.selectedRange().location, length: 0), actualRange: nil)
        var at = host.convert(panelWindow.convertFromScreen(caret), from: nil)
        if !host.isFlipped { at.origin.y = size.height - at.maxY }
        var origin = CGPoint(x: at.minX - 8, y: at.maxY + 4)
        origin.x = min(max(origin.x, 4), size.width - listed.size.width - 4)
        origin.y = min(origin.y, size.height - listed.size.height - 4)
        let frame = CGRect(origin: origin, size: listed.size)
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { throw GalleryFailure("no context to draw the list in") }
        let context = graphics.cgContext
        let drawn = CGRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height)
        appearance.performAsCurrentDrawingAppearance {
            context.saveGState()
            let panel = CGPath(roundedRect: drawn.insetBy(dx: -1, dy: -1), cornerWidth: 6, cornerHeight: 6, transform: nil)
            context.addPath(panel)
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fillPath()
            context.addPath(panel)
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(0.5)
            context.strokePath()
            context.addPath(CGPath(roundedRect: drawn, cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.clip()
            context.draw(listed.image, in: drawn)
            context.restoreGState()
        }
        graphics.flushGraphics()
        return rep
    }
}

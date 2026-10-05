import Canvas
import CanvasTesting
import CoreGraphics
import Observation
import SwiftUI
import TableOfContents
import TestKit

// A row that nests through a service (`contentsRow(nestedUnder:)` with a `ContentsContext`), and a
// service saying rows changed outside a commit (`editor.contentsDidChange(for:)`).

struct Tag: BoxShapeProps {
    static let kind: ShapeKind = "hanger"
    static let properties = Properties<Tag> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect = widgetFrame) { self.frame = frame }
}

extension Tag {
    init() { self.init(widgetFrame) }
}

struct TagDefinition {}

extension TagDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Tag>, in context: RenderContext) {}
}

/// Which shape each tag hangs under, an answer that arrives outside any commit.
@MainActor
final class Hangings {
    var parents: [ShapeID: ShapeID] = [:]
    func hang(_ tag: ShapeID, under parent: ShapeID, in editor: CanvasEditor, telling: Bool = true) {
        parents[tag] = parent
        if telling { editor.contentsDidChange(for: [tag]) }
    }
}

extension Hangings: EditorService {}

struct TagsPlugin: CanvasPlugin {
    var reading = false
    var id: PluginID { "tags" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.service { _ in Hangings() }
        registrar.shape(TagDefinition()) { tag in
            if reading {
                tag.contentsRow(nestedUnder: { tag, context in context.service(Hangings.self)?.parents[tag.id] },
                                affected: { _, _ in [] }) { _, context in
                    ContentsLabel("tag of \(context.service(Hangings.self)?.parents.count ?? 0)")
                }
            } else {
                tag.contentsRow(nestedUnder: { tag, context in context.service(Hangings.self)?.parents[tag.id] }) { _ in ContentsLabel("tag") }
            }
        }
    }
}

@MainActor let serviceNestingTests = Suite("Table of contents: nesting through a service", [
    test("a row nests under the shape a service names, once the service says its rows changed") {
        let editor = try contentsEditor([TagsPlugin()])
        let widget = editor.add(Widget(name: "Home"))
        let tag = editor.add(Tag())
        expectEqual(editor.contents.entries.outline, ["Home", "tag"])
        try require(editor.service(Hangings.self)).hang(tag, under: widget, in: editor, telling: false)
        expectEqual(editor.contents.entries.outline, ["Home", "tag"], "a service that doesn't say, isn't heard: nothing observes it")
        try require(editor.service(Hangings.self)).hang(tag, under: widget, in: editor)
        expectEqual(editor.contents.entries.outline, ["Home", "  tag"])
        expectEqual(editor.contents.entries.count, 1)
    },
    test("the list reads again when a service says so: an observer of the entries is told, and only the named rows are made again") {
        let editor = try contentsEditor([TagsPlugin()])
        let widget = editor.add(Widget(name: "Home"))
        let tag = editor.add(Tag())
        _ = editor.contents.entries
        let heard = Flag()
        withObservationTracking { _ = editor.contents.entries } onChange: { heard.set() }
        let made = widgetRowsMade
        try require(editor.service(Hangings.self)).hang(tag, under: widget, in: editor)
        expect(heard.isSet)
        expectEqual(editor.contents.entries.outline, ["Home", "  tag"])
        expectEqual(widgetRowsMade, made, "the widget's row was kept")
        try require(editor.service(Hangings.self)).parents[tag] = nil
        editor.contentsDidChange(for: [tag])
        expectEqual(editor.contents.entries.outline, ["Home", "tag"], "and out again")
    },
    test("a row read from more than its shape nests through a service too, and a shape that's gone is no trouble") {
        let editor = try contentsEditor([TagsPlugin(reading: true)])
        let widget = editor.add(Widget(name: "Home"))
        let tag = editor.add(Tag())
        expectEqual(editor.contents.entries.outline, ["Home", "tag of 0"])
        try require(editor.service(Hangings.self)).hang(tag, under: widget, in: editor)
        expectEqual(editor.contents.entries.outline, ["Home", "  tag of 1"])
        editor.contentsDidChange(for: [ShapeID(), tag])
        expectEqual(editor.contents.entries.outline, ["Home", "  tag of 1"])
    },
])

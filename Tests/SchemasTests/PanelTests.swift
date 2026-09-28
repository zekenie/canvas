import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Foundation
import LanguageModels
import Schemas
import Selection
import SwiftUI
import TestKit
import Titles
import Validation

/// The panel beside a canvas, in an unshown window, with real time (SwiftUI's updates and the
/// panel's hand-back land as the main run loop runs), and a scripted model. The window is deferred,
/// never given a place in the window server, so each turn lays its views out without drawing their
/// layers, which nothing here looks at (a test that reads pixels draws the panel itself). A test of
/// the sync's timer passes a `ManualScheduler` (the panel's hand-back then waits for it too).
@MainActor
final class SchemaPanelWindow {
    let model = ScriptedLanguageModel()
    let editor: CanvasEditor
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
    let canvas: CanvasView
    let hosting: NSView

    init(document: CanvasDocument = CanvasDocument(), scheduler: any Scheduler = TaskScheduler()) throws {
        editor = try schemaEditor(scheduler: scheduler, model: model, document: document)
        canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 1000 - DetailStyle.idealWidth, height: 800)
        let panel = DetailPanelView(editor: editor) { [unowned canvas, window] in window.makeFirstResponder(canvas) }
        hosting = NSHostingView(rootView: panel)
        hosting.frame = CGRect(x: 1000 - DetailStyle.idealWidth, y: 0, width: DetailStyle.idealWidth, height: 800)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        root.addSubview(canvas)
        root.addSubview(hosting)
        window.contentView = root
        window.appearance = NSAppearance(named: .aqua)
        window.settle()
    }

    /// A card, selected, its panel up.
    func show(_ props: SchemaCard) -> ShapeID {
        let id = editor.add(props)
        editor.selection = id
        window.spin { self.code != nil }
        return id
    }

    /// The prompt's text view (proportional), and the JSON Schema's (monospaced).
    var prompt: NSTextView? { hosting.descendants(NSTextView.self).first { !$0.isFieldEditor && $0.font?.isFixedPitch == false } }
    var code: NSTextView? { hosting.descendants(NSTextView.self).first { !$0.isFieldEditor && $0.font?.isFixedPitch == true } }
    var headerField: NSTextField? {
        hosting.descendants(NSTextField.self).first { $0.isEditable && $0.convert($0.bounds, to: hosting).maxY <= 44 }
    }

    /// The buttons under the header, in order: the status line's (SwiftUI draws their titles, so
    /// they're told apart by where they are).
    var buttons: [NSButton] {
        hosting.descendants(NSButton.self).filter { $0.convert($0.bounds, to: hosting).maxY > 44 }
    }

    /// Gives a text view the keyboard, the caret at `caret` (the end by default).
    func focus(_ view: NSTextView, caret: Int? = nil) {
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: caret ?? (view.string as NSString).length, length: 0))
        window.settle()
    }

    func card(_ id: ShapeID) -> SchemaCard? { editor.schemaCard(id) }

    /// Where a view is in the panel: points from its top-left (the hosting view is flipped).
    func frame(of view: NSView) -> CGRect { view.convert(view.bounds, to: hosting) }
    /// The prompt's box and the JSON Schema's, where they are; nil while collapsed.
    var promptBox: CGRect? { prompt?.enclosingScrollView.map(frame(of:)) }
    var codeBox: CGRect? { code?.enclosingScrollView.map(frame(of:)) }
    /// The spinners showing (a busy status line's), where they are.
    var spinners: [CGRect] { hosting.descendants(NSProgressIndicator.self).filter { !$0.isHiddenOrHasHiddenAncestor }.map(frame(of:)) }

    /// The status lines under the JSON Schema's box, top to bottom, as they draw (SwiftUI draws
    /// them, so there's no view to read): each one's symbol, by its tone, where there are words
    /// beside it.
    func statusMarks() throws -> [StatusMark] {
        guard let box = codeBox else { return [] }
        let image = try snapshot()
        let scale = CGFloat(image.pixelsWide) / hosting.bounds.width
        var marks: [StatusMark] = []
        var tones: [StatusMark: Int] = [:], top = 0
        for y in Int(box.maxY * scale)..<image.pixelsHigh {
            var row: [StatusMark: Int] = [:]
            for x in 0..<Int(DetailStyle.idealWidth / 3 * scale) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), let tone = StatusMark(color) else { continue }
                row[tone, default: 0] += 1
            }
            if !row.isEmpty {
                if tones.isEmpty { top = y }
                tones.merge(row, uniquingKeysWith: +)
            } else if let tone = tones.max(by: { $0.value < $1.value })?.key {
                // Words beside it: ink to its right, on its rows.
                let rows = CGRect(x: 36, y: CGFloat(top) / scale, width: 150, height: CGFloat(y - top) / scale)
                if hasInk(image, in: rows, below: 120) { marks.append(tone) }
                tones = [:]
            }
        }
        return marks
    }

    /// The panel as it draws, a pixel a point.
    func snapshot() throws -> NSBitmapImageRep {
        let image = try require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        image.size = hosting.bounds.size
        return image
    }

    /// Whether a busy status line shows under `box` (and above `before`, if given): a spinner, with
    /// words beside it.
    func busyLine(under box: CGRect, above before: CGRect? = nil) throws -> Bool {
        let bitmap = try snapshot()
        return spinners.contains { spinner in
            spinner.minY >= box.maxY && spinner.maxY <= (before?.minY ?? .infinity)
                && hasInk(bitmap, in: CGRect(x: spinner.maxX + 2, y: spinner.minY - 2, width: 120, height: spinner.height + 4))
        }
    }

    /// The panel as it draws, for a look (SCHEMA_PANEL_PNG_DIR).
    func render(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SCHEMA_PANEL_PNG_DIR"],
              let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}

/// Answers the app's Settings action, as the app's delegate does.
@MainActor
final class SettingsCatcher: NSObject, NSApplicationDelegate {
    var shown = 0
    @objc func showSettings(_ sender: Any?) { shown += 1 }
}

let blankCard = SchemaCard(frame: CGRect(x: 40, y: 40, width: 240, height: 67))

@MainActor let panelTests = Suite("Schema card panel", [
    test("a card's panel: the name in the header, the Schema tab (Description over the JSON), then Arrange") {
        let editor = try schemaEditor()
        let order = editor.add(card(fixture(6)))
        let layout = try require(editor.detailPanel?.layout(for: try require(editor.document[order])))
        expectEqual(layout.tabs.map(\.title), ["Schema", "Arrange"])
        expectEqual(layout.sections(in: .of(SchemaTab.self)).map(\.section), ["Description", "JSON"])
        let header = try require(layout.header(as: TitleHeader.self))
        expectEqual([header.title, header.placeholder, header.subtitle], ["Order", "Untitled", "6 fields"])
        expectEqual([header.isEnabled, header.isRenamable], [true, true])
        // How many fields it shows; nothing where it shows none (the card says so).
        for (text, subtitle) in [(SchemaCard.starter, nil), (fixture(10), nil), ("[1]", nil), (#"{"properties": {"a": {}}}"#, "1 field")] as [(String, String?)] {
            let id = editor.add(card(text))
            let header = try require(editor.detailPanel?.layout(for: try require(editor.document[id])).header(as: TitleHeader.self))
            expectEqual(header.subtitle, subtitle, text)
        }
    },
    test("while the text isn't a JSON object, the header shows the card's last name and count at full strength, and can't rename it") {
        let editor = try schemaEditor()
        let id = editor.add(card(fixture(6)))
        @MainActor func header() throws -> TitleHeader {
            try require(editor.detailPanel?.layout(for: try require(editor.document[id])).header(as: TitleHeader.self))
        }
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(String(fixture(6).dropLast(3))) } }
        let broken = try header()
        expectEqual([broken.title, broken.subtitle], ["Order", "6 fields"])
        expectEqual([broken.isEnabled, broken.isRenamable], [true, false], "not dimmed, not a field")
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(fixture(6)) } }
        expectEqual(try header().isRenamable, true)
    },
    test("the header renames the schema: only its title member changes, the rest byte for byte") {
        let panel = try SchemaPanelWindow()
        let written = "{ \"type\":\"object\",\n\t\"properties\" : { \"a\" : {} } }"
        let id = panel.show(card(written))
        let field = try require(panel.headerField)
        expectEqual(field.placeholderString, "Untitled")
        panel.window.focus(field)
        panel.window.type("Pet")
        expectEqual(panel.card(id)?.schema, "{ \"title\": \"Pet\", \"type\":\"object\",\n\t\"properties\" : { \"a\" : {} } }")
        panel.window.type("s")
        expectEqual(panel.card(id)?.schema, "{ \"title\": \"Pets\", \"type\":\"object\",\n\t\"properties\" : { \"a\" : {} } }")
        expectEqual(panel.editor.registry.title(of: try require(panel.editor.document[id])), "Pets")
    },
    test("the header can't rename a schema that isn't a JSON object: its name is text, not a field") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(card(fixture(10)))
        expect(panel.headerField == nil, "no field to type in")
        expect(try hasInk(panel.snapshot(), in: CGRect(x: 40, y: 8, width: 60, height: 20)), "Invoice, in ink")
        panel.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(fixture(6)) } }
        panel.window.spin { panel.headerField != nil }
        expectEqual(panel.headerField?.stringValue, "Order")
    },
    test("Return in the description asks for the schema at once; ⇧↩ is a new line") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(blankCard)
        let prompt = try require(panel.prompt)
        panel.focus(prompt)
        panel.window.type("a pet")
        panel.window.press("\r", code: 36, modifiers: .shift)
        panel.window.type("in my household")
        expectEqual(panel.card(id)?.prompt, "a pet\nin my household")
        panel.window.settle()
        expectEqual(panel.model.requests.count, 0)
        panel.model.queue(petSchema)
        panel.window.pressReturn()
        expectEqual(prompt.string, "a pet\nin my household", "Return isn't a new line")
        panel.window.spin { panel.card(id)?.schema == petSchema && panel.code?.string == petSchema }
        expectEqual(panel.model.requests.count, 1)
        expect(panel.window.firstResponder === prompt, "the description keeps the keyboard")
    },
    test("⌘↩ in the JSON Schema asks for the description; Return is a new line, indented, a pair of brackets opened") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(blankCard)
        let code = try require(panel.code)
        panel.focus(code, caret: (SchemaCard.starter as NSString).range(of: "{}").location + 1)
        panel.window.pressReturn()
        expectEqual(code.string, "{\n  \"type\": \"object\",\n  \"properties\": {\n    \n  }\n}")
        panel.window.type(#""name": {"type": "string"}"#)
        let typed = "{\n  \"type\": \"object\",\n  \"properties\": {\n    \"name\": {\"type\": \"string\"}\n  }\n}"
        code.checkTextInDocument(nil)       // what AppKit does a moment after typing, where substitutions are on
        expectEqual(code.string, typed, "straight quotes, as typed")
        expectEqual(panel.card(id)?.schema, typed, "written as typed")
        panel.window.settle()
        expectEqual(panel.model.requests.count, 0)
        panel.model.queue("A thing with a name.")
        panel.window.press("\r", code: 36, modifiers: .command)
        panel.window.spin { panel.card(id)?.prompt == "A thing with a name." && panel.prompt?.string == "A thing with a name." }
        expectEqual(panel.model.lastRequest?.system, SchemaPrompts.toPromptSystem)
        expectEqual(code.string, typed, "⌘↩ isn't a new line")
    },
    test("the keyboard leaving either side commits it") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(blankCard)
        panel.focus(try require(panel.prompt))
        panel.window.type("a pet in my household")
        panel.model.queue(petSchema)
        panel.window.makeFirstResponder(panel.canvas)
        panel.window.spin { panel.card(id)?.schema == petSchema }
        let code = try require(panel.code)
        panel.focus(code, caret: (petSchema as NSString).range(of: "\"integer\"").location + 1)
        panel.window.type("n")       // "ninteger": not a type, but JSON
        panel.model.queue("a pet in my household, its birth year oddly typed")
        panel.window.focus(try require(panel.headerField))
        panel.window.spin { panel.card(id)?.prompt == "a pet in my household, its birth year oddly typed" }
        expectEqual(panel.model.requests.count, 2)
    },
    test("while the model writes the schema it's read-only, and a busy line under the description says so; the description stays editable") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(blankCard)
        panel.model.holdsAnswers = true
        panel.model.queue(petSchema)
        let prompt = try require(panel.prompt)
        panel.focus(prompt)
        panel.window.type("a pet in my household")
        expect(panel.spinners.isEmpty)
        panel.window.pressReturn()
        spinRunLoop(until: { panel.model.waiting == 1 })
        panel.window.spin { panel.code?.isEditable == false }
        expect(prompt.isEditable)
        expectEqual(panel.headerField?.isEnabled, false, "renaming writes the schema too")
        expectEqual(panel.spinners.count, 1, "one line says so, and nothing covers the text")
        expect(try panel.busyLine(under: try require(panel.promptBox), above: try require(panel.codeBox)), "under the description, where the person is")
        panel.render("updating")
        panel.model.release()
        panel.window.spin { panel.code?.isEditable == true && panel.code?.string == petSchema }
        expectEqual(panel.headerField?.isEnabled, true)
        expectEqual(panel.card(id)?.schema, petSchema)
        panel.window.spin { panel.spinners.isEmpty }
        panel.render("synced")
    },
    test("while the model writes the description it's read-only, and a busy line under the JSON Schema says so") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(card(petSchema))
        panel.model.holdsAnswers = true
        panel.model.queue("A pet: name, species, birth year.")
        let code = try require(panel.code)
        panel.focus(code, caret: (petSchema as NSString).range(of: "\"integer\"").location + 1)
        panel.window.type("n")
        panel.window.press("\r", code: 36, modifiers: .command)
        spinRunLoop(until: { panel.model.waiting == 1 })
        panel.window.spin { panel.prompt?.isEditable == false }
        expect(code.isEditable)
        expectEqual(panel.spinners.count, 1)
        expect(try panel.busyLine(under: try require(panel.codeBox)), "under the JSON Schema, where the person is")
        panel.render("updating-description")
        panel.model.release()
        panel.window.spin { panel.prompt?.isEditable == true && panel.prompt?.string == "A pet: name, species, birth year." }
        expectEqual(panel.card(id)?.prompt, "A pet: name, species, birth year.")
    },
    test("with the description collapsed, a failure from the JSON side shows under the JSON Schema, with what to do") {
        let panel = try SchemaPanelWindow()
        let first = panel.show(card(petSchema))
        let description = try require(panel.editor.detailPanel?.layout(for: try require(panel.editor.document[first])).sections(in: .of(SchemaTab.self)).first)
        expectEqual(description.section, "Description")
        try require(panel.editor.detailPanel).setCollapsed(description, true)
        // Collapsing is per kind: another card's is collapsed too.
        let id = panel.editor.add(card(petSchema, at: CGPoint(x: 400, y: 40)))
        panel.editor.selection = id
        panel.window.spin { panel.prompt == nil && panel.code != nil }
        let code = try require(panel.code)
        panel.focus(code, caret: (petSchema as NSString).range(of: "\"integer\"").location + 1)
        panel.window.type("n")
        panel.model.queue(.overloaded)
        panel.window.press("\r", code: 36, modifiers: .command)
        panel.window.spin { panel.buttons.count == 1 }
        let box = try require(panel.codeBox)
        expect(panel.buttons.allSatisfy { panel.frame(of: $0).minY >= box.maxY }, "Retry, under the JSON")
        expectEqual(panel.editor.schemaSync?.status(of: id), .failed(SchemaSyncFailure(writing: .prompt, "Anthropic overloaded")))
        // "ninteger" isn't a type (Validation's warning), then the failure: both in the warning's tone,
        // since red is only the schema's own errors.
        expectEqual(try panel.statusMarks(), [.orange, .orange])
    },
    test("closing the board while a box has the keyboard commits nothing after the board's gone") {
        weak var weakEditor: CanvasEditor?
        weak var weakSync: SchemaSync?
        try autoreleasepool {
            let editor = try schemaEditor(scheduler: TaskScheduler(), model: ScriptedLanguageModel())
            weakEditor = editor
            weakSync = editor.schemaSync
            let hosting = NSHostingView(rootView: DetailPanelView(editor: editor))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: DetailStyle.idealWidth, height: 800), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            editor.selection = editor.add(blankCard)
            window.spin { hosting.descendants(NSTextView.self).contains { $0.font?.isFixedPitch == true } }
            let code = try require(hosting.descendants(NSTextView.self).first { $0.font?.isFixedPitch == true })
            window.makeFirstResponder(code)
            window.settle()
            window.type(" ")
            // The text view leaves the window with the keyboard, which commits a turn later.
            window.close()
        }
        for _ in 0..<20 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        expect(weakEditor == nil, "the board's editor went, before the commit ran")
        expect(weakSync == nil, "and its sync with it: the commit didn't keep it")
    },
    test("the JSON Schema never wraps, and is as tall as its lines until the panel's full") {
        let panel = try SchemaPanelWindow()
        _ = panel.show(card(fixture(2)))
        let code = try require(panel.code)
        let layout = try require(code.layoutManager), container = try require(code.textContainer)
        layout.ensureLayout(for: container)
        var rows = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in rows += 1 }
        let lines = fixture(2).split(separator: "\n", omittingEmptySubsequences: false).count
        expectEqual(rows, lines, "a row a line, so line N of an error is the Nth on screen")
        expect(layout.usedRect(for: container).width > code.enclosingScrollView?.contentSize.width ?? 0, "a long line runs past the box, and scrolls sideways")
        expect(try require(panel.codeBox).height > DetailStyle.codeEditorHeight, "a dozen lines: taller than the least")
        panel.editor.transact { $0.update(try! require(panel.editor.selection), as: SchemaCard.self) { $0.props.setSchema(#"{"type": "object"}"#) } }
        panel.window.spin { code.string == #"{"type": "object"}"# }
        panel.window.settle()
        expectEqual(panel.codeBox?.height, DetailStyle.codeEditorHeight - 8, "a short schema: the least height, a text area's")
        expectEqual(DetailStyle.codeEditorHeight, DetailStyle.textAreaHeight)
        panel.editor.transact { $0.update(try! require(panel.editor.selection), as: SchemaCard.self) { $0.props.setSchema(fixture(5)) } }
        panel.window.spin { code.string == fixture(5) }
        panel.window.settle()
        layout.ensureLayout(for: container)
        let text = layout.usedRect(for: container).height
        let box = try require(panel.codeBox)
        expect(box.height > DetailStyle.codeEditorHeight, "twenty fields: taller than the least")
        expect(box.height >= text, "every line in view: \(box.height) for \(text)")
        let long = (0..<200).map { "  \"field\($0)\": {}" }.joined(separator: ",\n")
        panel.editor.transact { $0.update(try! require(panel.editor.selection), as: SchemaCard.self) { $0.props.setSchema("{\"properties\": {\n\(long)\n}}") } }
        panel.window.spin { code.string.hasSuffix("}}") && code.string.count > 1000 }
        panel.window.settle()
        let full = try require(panel.codeBox)
        layout.ensureLayout(for: container)
        let panelScroll = try require(panel.hosting.descendants(NSScrollView.self).first { code.isDescendant(of: $0) && $0 !== code.enclosingScrollView })
        expect(full.height < panelScroll.frame.height, "never taller than the panel shows (\(full.height) of \(panelScroll.frame.height)), so its top and bottom can both be in view")
        expect(full.height < layout.usedRect(for: container).height, "past that it scrolls")
    },
    test("with no key, the status says so, and Open Settings… (its one button) asks the app for Settings; a key saved there tries again") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(blankCard)
        panel.model.queue(.noKey)
        panel.focus(try require(panel.prompt))
        panel.window.type("a pet")
        panel.window.pressReturn()
        panel.window.spin { panel.buttons.count == 1 }
        expectEqual(panel.editor.schemaSync?.status(of: id), .failed(SchemaSyncFailure(writing: .schema, "No API key", remedy: .key)))
        panel.render("no-key")
        // The responder chain ends at the app's delegate: stand in for it.
        let catcher = SettingsCatcher(), delegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = catcher
        defer { NSApplication.shared.delegate = delegate }
        panel.buttons[0].performClick(nil)       // Open Settings…
        expectEqual(catcher.shown, 1)
        panel.model.queue(petSchema)
        NotificationCenter.default.post(name: .languageModelKeyDidChange, object: nil)       // what Settings' Save says
        panel.window.spin { panel.card(id)?.schema != SchemaCard.starter }
        expectEqual(panel.model.requests.count, 2)
        panel.window.spin { panel.buttons.isEmpty }
    },
    test("the description's placeholder, an example, only while the schema is an object with no fields") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(blankCard)
        let box = try require(panel.promptBox).insetBy(dx: 2, dy: 2)
        expect(hasInk(try panel.snapshot(), in: box, below: 220), "e.g. a pet in my household")
        panel.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(petSchema) } }
        panel.window.spin { panel.code?.string == petSchema }
        panel.window.settle()
        expect(!hasInk(try panel.snapshot(), in: try require(panel.promptBox).insetBy(dx: 2, dy: 2), below: 220),
               "fields: the description is written from them, and says nothing till then")
        // Never an object this session: nothing syncs from the description, and an invoice isn't a pet.
        for text in [fixture(10), "[1]"] {
            _ = panel.show(card(text))
            panel.window.spin { panel.code?.string == text }
            panel.window.settle()
            expect(!hasInk(try panel.snapshot(), in: try require(panel.promptBox).insetBy(dx: 2, dy: 2), below: 220), text)
        }
    },
    test("the JSON Schema is colored: names alike, values by kind, punctuation plain, past text that isn't ASCII") {
        let panel = try SchemaPanelWindow()
        let text = #"{"title": "Café ☕️", "type": "object", "minimum": 2, "x": true, "y": nul}"#
        _ = panel.show(card(text))
        let code = try require(panel.code)
        let units = text as NSString
        @MainActor func color(_ part: String, _ occurrence: Int = 0) -> NSColor? {
            var range = units.range(of: part)
            for _ in 0..<occurrence { range = units.range(of: part, range: NSRange(location: NSMaxRange(range), length: units.length - NSMaxRange(range))) }
            return code.textStorage?.attribute(.foregroundColor, at: range.location + range.length / 2, effectiveRange: nil) as? NSColor
        }
        let name = try require(color("\"title\""))
        expectEqual([color("\"type\""), color("\"minimum\""), color("\"y\"")], [name, name, name])
        let string = try require(color("\"object\""))
        expectEqual(color("\"Café ☕️\""), string)
        expect(Set([name, string, try require(color("2")), try require(color("true"))]).count == 4, "names, strings, numbers and literals apart")
        expectEqual([color("{"), color(":"), color(",")], [.labelColor, .labelColor, .labelColor])
        let invalid = try require(code.textStorage).attribute(.underlineStyle, at: units.range(of: "nul").location, effectiveRange: nil) as? Int
        expect((invalid ?? 0) != 0, "a word that isn't JSON's is underlined")
    },
    test("the JSON Schema marks where it stops being JSON: the token after a stray comma, not the end of a text still being typed") {
        let panel = try SchemaPanelWindow()
        let text = "{\n  \"type\": \"object\",\n  \"properties\": {},\n}"
        _ = panel.show(card(text))
        let code = try require(panel.code)
        @MainActor func underlined(_ offset: Int) -> Bool {
            ((code.textStorage?.attribute(.underlineStyle, at: offset, effectiveRange: nil) as? Int) ?? 0) != 0
        }
        let units = text as NSString
        expect(underlined(units.length - 1), "the closing brace, where a property name should be: line 4, as the line under it says")
        expect(!underlined(units.range(of: ",\n}").location), "the comma itself reads as JSON")
        panel.editor.transact { $0.update(try! require(panel.editor.selection), as: SchemaCard.self) { $0.props.setSchema("{\"type\": ") } }
        panel.window.spin { code.string == "{\"type\": " }
        expect(!(0..<(code.string as NSString).length).contains { underlined($0) }, "a text cut short is being typed: nothing to mark")
    },
    test("under the JSON: what Validation finds, a line each in its tone (the words are Validation's, from one reading); nothing once it's fixed") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(card(fixture(10)))
        panel.render("invalid")
        expectEqual(try panel.statusMarks(), [.red], "Invalid JSON: expected a property name at line 6, column 35.")
        expectEqual(panel.editor.issues(id).map(\.severity), [.error])
        let warned = #"{"properties": {"a": {"type": "ninteger"}}, "required": ["fax"]}"#
        panel.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(warned) } }
        panel.window.spin { panel.code?.string == warned }
        panel.window.settle()
        expectEqual(panel.editor.issues(id).map(\.message), ["“fax” is required, but isn’t a property.", "“ninteger” in a isn’t a JSON Schema type."])
        expectEqual(try panel.statusMarks(), [.orange, .orange], "both warnings, each a line")
        panel.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(fixture(6)) } }
        panel.window.spin { (try? panel.statusMarks()) == [] }
    },
])

/// A status line's symbol, by its tone's color.
enum StatusMark: Hashable {
    case red, orange

    init?(_ color: NSColor) {
        guard color.alphaComponent > 0.5, color.redComponent > 0.7, color.blueComponent < 0.45 else { return nil }
        if color.greenComponent < 0.45 { self = .red } else if color.greenComponent < 0.8 { self = .orange } else { return nil }
    }
}

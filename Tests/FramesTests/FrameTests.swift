import Adornments
import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Frames
import Keyboard
import Mentions
import Selection
import SwiftUI
import TableOfContents
import TestKit
import Titles

@MainActor let frameTests = Suite("Frames", [
    test("its schema is its frame and the title Titles adds; it holds shapes, and owns no board") {
        let registry = try Registry(plugins: framePlugins())
        let schema = try require(registry.schema(for: Frame.kind)).json
        expectEqual(schema["title"]?.stringValue, "Frame")
        expectEqual(Set(schema["properties"]?.objectValue?.keys.map { $0 } ?? []), ["frame", "title", "frozen"])
        expectEqual(schema["required"], ["frame"])
        expectEqual(schema["properties"]?["title"]?["x-canvas-owner"]?.stringValue, "titles")
        expectEqual(schema["x-canvas-board"], nil, "its shapes are on its own board")
        expectEqual(registry.containingKinds, [Frame.kind])
        expect(!registry.boardOwningKinds.contains(Frame.kind))
    },
    // What Fixtures/kinds/frame.v0.json holds (CompositionTests holds shipped kinds to their fixtures).
    test("its props write only its frame") {
        let codec = BoardCodec(registry: try Registry(plugins: framePlugins()))
        let json = String(decoding: try codec.encodeProps(Frame(frame: CGRect(origin: .zero, size: Frame.defaultSize))), as: UTF8.self)
        expectEqual(json.filter { !$0.isWhitespace }, #"{"frame":[[0,0],[640,400]]}"#)
    },
    test("the Frame tool is F, called Frame, with its symbol; its placement is a frame of 640 × 400, for what makes shapes without the pointer") {
        let registry = try Registry(plugins: framePlugins())
        let tool = try require(registry.tools.first { $0.id == ToolID(placing: Frame.kind) })
        expectEqual(tool.label, "Frame")
        expectEqual(tool.systemImage, "rectangle.dashed")
        expectEqual(registry.help(for: tool), "Frame (F)")
        expectEqual(registry.label(of: Frame.kind), KindLabel(name: "Frame", systemImage: "rectangle.dashed", tint: .systemGray))
        let placement = try require(registry.placement(for: Frame.kind), "drawable by canvas draw")
        expectEqual(placement.size, CGSize(width: 640, height: 400))
        expectEqual(placement.shape(at: CGPoint(x: 500, y: 300)).box, CGRect(x: 180, y: 100, width: 640, height: 400))
    },
    test("its row is its symbol, in its gray, and \"Untitled Frame\", named by its title once it has one") {
        let h = try frameHarness()
        let frame = h.addFrame()
        let contents = try require(h.editor.tableOfContents)
        var label = try require(contents.entries.first { $0.id == frame }?.label)
        expectEqual(label.text, "Untitled Frame")
        expect(label.isPlaceholder)
        expectEqual(label.systemImage, "rectangle.dashed")
        expectEqual(label.color, Color(nsColor: .systemGray))
        h.editor.transact("Rename") { $0.update(frame) { $0[TitleProperty.self] = "Sprint 3" } }
        label = try require(contents.entries.first { $0.id == frame }?.label)
        expectEqual(label.text, "Sprint 3")
        expect(!label.isPlaceholder)
    },
    test("its panel's header is a TitleHeader with its placeholder and symbol, and it has no tabs of its own") {
        let h = try frameHarness()
        let frame = h.addFrame(title: "Sprint 3")
        let layout = try require(h.editor.detailPanel?.layout(for: try require(h.editor.document[frame])))
        let header = try require(layout.header(as: TitleHeader.self))
        expectEqual(header.title, "Sprint 3")
        expectEqual(header.placeholder, "Untitled Frame")
        expectEqual(header.systemImage, "rectangle.dashed")
        expectEqual(layout.tabs.map(\.title), [])
    },
    test("it's mentioned by its title, in its gray, and gone to when followed; untitled, the picker leaves it out") {
        let h = try frameHarness()
        let frame = h.addFrame()
        let other = h.addBox(CGRect(x: 600, y: 100, width: 100, height: 100))
        let mentions = try require(h.editor.mentions)
        var looks = try require(mentions.resolve(frame).appearance)
        expectEqual(looks.label, "Untitled Frame")
        expect(looks.isPlaceholder, "the @ picker offers none")
        expectEqual(looks.systemImage, "rectangle.dashed")
        expectEqual(looks.tint, .systemGray)
        h.editor.transact("Rename") { $0.update(frame) { $0[TitleProperty.self] = "Sprint 3" } }
        looks = try require(mentions.resolve(frame).appearance)
        expectEqual(looks.label, "Sprint 3")
        expect(!looks.isPlaceholder)
        h.editor.selection = other
        mentions.follow(frame)
        h.wait(0)
        expectEqual(h.editor.selection, frame, "gone to: selected")
        expectEqual(h.editor.board, .root, "and nothing opened")
        h.editor.goBack()
        expectEqual(h.editor.selection, other, "one step back")
    },
    test("an untitled frame's pill says Frame, dimmed: the placeholder, never its title; titled, its title, with no symbol") {
        let h = try frameHarness()
        let frame = h.addFrame()
        expectEqual(h.editor.adornmentFrames(of: frame).map(\.label), [AdornmentLabel(placeholder: "Frame")])
        expectEqual(h.editor.registry.title(of: try require(h.editor.document[frame])), nil, "untitled")
        h.editor.transact("Rename") { $0.update(frame) { $0[TitleProperty.self] = "Sprint 3" } }
        expectEqual(h.editor.adornmentFrames(of: frame).map(\.label), [AdornmentLabel("Sprint 3")])
        let pill = try require(h.editor.adornmentFrames(of: frame).first?.rect)
        expectEqual(pill.minX, frameRect.minX, "above its top-left corner")
        expect(pill.maxY < frameRect.minY)
    },
    test("selected, it has eight handles; resized, it's never smaller than 96 × 64") {
        let h = try frameHarness()
        let frame = h.addFrame()
        h.editor.selection = frame
        for handle in ResizeHandle.allCases {
            expectEqual(h.editor.handle(atViewPoint: point(of: handle, on: frameRect)), AnyHashable(handle), "\(handle)")
        }
        let corner = CGPoint(x: frameRect.maxX, y: frameRect.maxY)
        h.move(to: corner)
        h.press(at: corner)
        h.drag(to: CGPoint(x: 300, y: 300))
        h.drag(to: CGPoint(x: 0, y: 0))
        h.release()
        expectEqual(h.editor.box(frame), CGRect(origin: frameRect.origin, size: CGSize(width: 96, height: 64)))
        expectEqual(h.editor.undoHistory.undoName, "Resize")
    },
])

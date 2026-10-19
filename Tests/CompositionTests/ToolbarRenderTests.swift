import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import LanguageModels
import Selection
import ShippedTesting
import StickyNotes
import SwiftUI
import TestKit

// The toolbar's tools as the app hosts them, with the shipped tools, rendered to PNG files with the
// tool lock off and on: to be looked at, so a suite only with TOOLBAR_RENDER_DIR set (as the Gallery is
// with GALLERY_DIR); without it, none. Light only: a control drawn into a bitmap from an unshown window
// comes out the same in the dark appearance.

let toolbarRenderDirectory: URL? = ProcessInfo.processInfo.environment["TOOLBAR_RENDER_DIR"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

@MainActor let toolbarRenderTests = Suite("Toolbar renders", toolbarRenderDirectory == nil ? [] : [
    test("the toolbar's tools, lock off and on") {
        let directory = try require(toolbarRenderDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let editor = ShippedPlugins.makeEditor(scheduler: TaskScheduler(), model: ScriptedLanguageModel())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ToolPicker(editor: editor).padding(14).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        window.setContentSize(host.frame.size)
        let note = ToolID(placing: StickyNote.kind)
        let states: [(name: String, tool: ToolID, locked: Bool)] = [("off", note, false), ("on-note", note, true), ("on-select", .select, true)]
        var sheet: [(caption: String, image: NSBitmapImageRep)] = []
        for state in states {
            editor.setTool(state.tool)
            editor.isToolLocked = state.locked
            window.spin { (host.descendants(NSSegmentedControl.self).first?.selectedSegment ?? -1) >= 0 }
            window.settle()
            let rep = snapshot(host)
            let name = "toolbar-\(state.name)"
            try require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
            sheet.append((name, rep))
        }
        // One sheet of all three, each enlarged threefold and captioned.
        let scale: CGFloat = 3, caption: CGFloat = 22
        let cell = CGSize(width: sheet[0].image.size.width * scale, height: sheet[0].image.size.height * scale + caption)
        let image = NSImage(size: CGSize(width: cell.width, height: cell.height * CGFloat(sheet.count)))
        image.lockFocus()
        NSColor.white.setFill()
        CGRect(origin: .zero, size: image.size).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        for (index, entry) in sheet.enumerated() {
            let origin = CGPoint(x: 0, y: CGFloat(sheet.count - 1 - index) * cell.height)
            let picture = NSImage(size: entry.image.size)
            picture.addRepresentation(entry.image)
            picture.draw(in: CGRect(x: origin.x, y: origin.y + caption, width: cell.width, height: cell.height - caption))
            (entry.caption as NSString).draw(at: CGPoint(x: origin.x + 8, y: origin.y + 4),
                                             withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray])
        }
        image.unlockFocus()
        let tiff = try require(image.tiffRepresentation)
        try require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("toolbar-lock.png"))
    },
])

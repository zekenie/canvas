import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Find
import HostSlots
import Observation
import SwiftUI
import TableOfContents
import TestKit
import Titles

// What Boards calls a board wherever another plugin lists one: the table of contents' heading and
// Find's rows' headings, each a plugin value of its own, and the root's name, which is the editor's.

@MainActor let headingTests = Suite("Boards' names over other plugins' lists", [
    test("the root is called what the file is, as its window tells the editor, else Board") {
        let nest = Nest()
        let h = try nestHarness(nest)
        expectEqual(h.editor.name(of: .root), "Board")
        h.editor.nameRoot("Plans")
        expectEqual(h.editor.name(of: .root), "Plans")
        expectEqual(h.editor.name(of: nest.dBoard), "Untitled Drawer", "any other board is its owner's to name")
        h.editor.nameRoot("")
        expectEqual(h.editor.name(of: .root), "Board")
    },
    test("the path's root crumb is the file's name, and follows a rename") {
        let nest = Nest()
        let editor = try windowEditor(nest.file)
        let path = PathWindow(editor, rootName: "Plans")
        expect(editor.showBoard(nest.dBoard))
        path.window.spin { path.buttons.count == 1 }
        let before = snapshot(path.hosting), drawn = path.redrawn
        editor.nameRoot("Plans")
        path.window.settle()
        expectEqual(path.redrawn, drawn, "the same name redraws nothing")
        editor.nameRoot("A much longer name")
        path.window.spin { path.redrawn > drawn }
        expect(changedPixels(before, snapshot(path.hosting), in: path.hosting.bounds) > 0, "the root's crumb reads the new name")
    },
    test("BoardContentsPlugin heads the table of contents with the board shown's crumb and the way up; on the root, the file's name") {
        let nest = Nest()
        let h = try nestHarness(nest, [TableOfContentsPlugin(), BoardContentsPlugin()])
        let contents = try require(h.editor.tableOfContents)
        expectEqual(contents.heading.title, "Board")
        let renamed = Flag()
        withObservationTracking { _ = contents.heading } onChange: { renamed.set() }
        h.editor.nameRoot("Plans")
        expect(renamed.isSet, "whoever reads the heading, the list's header, hears the file renamed")
        let root = contents.heading
        expectEqual(root.title, "Plans")
        expectEqual(root.systemImage, nil)
        expectEqual(root.up, nil, "nothing above the root")
        expect(h.editor.showBoard(nest.dBoard))
        let inside = contents.heading
        expectEqual(inside.title, "Untitled Drawer")
        expectEqual(inside.systemImage, "archivebox")
        expectEqual(inside.up, .enclosingBoard)
        expectEqual(inside.upTitle, "Enclosing Board")
        expectEqual(inside.upHelp, "Enclosing Board (⌘↑)", "called as Go › Enclosing Board is, with its key")
        h.editor.transact(on: .root, "Rename") { $0.update(nest.d) { $0[TitleProperty.self] = "Kitchen" } }
        expectEqual(contents.heading.title, "Kitchen", "as the path names it, renamed from the board above")
    },
    test("BoardFindPlugin heads each board's rows in Find's list with its name and symbol, as the path has them") {
        let nest = Nest()
        let h = try nestHarness(nest, [FindPlugin(), BoardFindPlugin()])
        let find = try require(h.editor.find)
        expectEqual(find.heading(of: .root), FindHeading("Board"))
        h.editor.nameRoot("Plans")
        expectEqual(find.heading(of: .root), FindHeading("Plans"))
        expectEqual(find.heading(of: nest.dBoard), FindHeading("Untitled Drawer", systemImage: "archivebox"))
        expectEqual(find.heading(of: nest.pBoard), FindHeading("Untitled Pocket", systemImage: "tray"))
        h.name(nest.d, "Kitchen")
        expectEqual(find.heading(of: nest.dBoard), FindHeading("Kitchen", systemImage: "archivebox"))
    },
    test("the window hosts the path over the top of the canvas, clear of a fit as far as its pill reaches, and names the board shown in its subtitle") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let registry = h.editor.registry
        let path = try require(registry.hostOverlays.first)
        expectEqual(registry.hostOverlays.count, 1)
        expectEqual(path.alignment, .top)
        expectEqual(path.coveredTop(.root), 0, "nothing on the root, where it shows nothing")
        expectEqual(path.coveredTop(nest.dBoard), BoardPath.coveredHeight(on: nest.dBoard))
        expectEqual(registry.hostCoveredTop(on: nest.pBoard), BoardPath.coveredHeight(on: nest.pBoard))
        expectEqual(registry.windowSubtitle(for: h.editor), nil, "the root is the window's title's to name")
        expect(h.editor.showBoard(nest.dBoard))
        expectEqual(registry.windowSubtitle(for: h.editor), "Untitled Drawer")
        let renamed = Flag()
        withObservationTracking { _ = registry.windowSubtitle(for: h.editor) } onChange: { renamed.set() }
        h.editor.transact(on: .root, "Rename") { $0.update(nest.d) { $0[TitleProperty.self] = "Kitchen" } }
        expect(renamed.isSet, "the window hears the board renamed")
        expectEqual(registry.windowSubtitle(for: h.editor), "Kitchen")
        let line = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("board-navigation ") })
        expect(line.hasSuffix(" host overlay · window subtitle"), String(line))
    },
    test("each needs the plugin whose list it heads; Boards alone needs neither") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ContentsHeadings", owner: .tableOfContents, contributor: .boardContents)) {
            _ = try Registry(plugins: boardsPlugins([BoardContentsPlugin()]))
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "FindHeadings", owner: .findInBoards, contributor: .boardFind)) {
            _ = try Registry(plugins: boardsPlugins([BoardFindPlugin()]))
        }
        let registry = try Registry(plugins: boardsPlugins([TableOfContentsPlugin(), BoardContentsPlugin(), FindPlugin(), BoardFindPlugin()]))
        let lines = registry.report.split(separator: "\n")
        expect(lines.contains { $0.hasPrefix("board-contents ") && $0.hasSuffix(" contents heading") }, registry.report)
        expect(lines.contains { $0.hasPrefix("board-find ") && $0.hasSuffix(" find heading") }, registry.report)
    },
])

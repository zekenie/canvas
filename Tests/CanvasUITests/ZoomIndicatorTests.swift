import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Geometry
import TestKit

@MainActor let zoomIndicatorTests = Suite("Zoom indicator", [
    test("a change of zoom shows it at once, rounded, above the minimap; it stays while the zoom goes on changing, and fades out a second after the last change, announced") {
        let h = try minimapEditor()
        let (_, canvas, minimap) = try minimapped(h)
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 1000, height: 800)))
        let zoom = canvas.zoomIndicator
        expect(!zoom.isShowing && zoom.isHidden)
        h.editor.camera.zoom = 0.873
        expect(zoom.isShowing)
        expectEqual(zoom.title, "87%")
        expectEqual(zoom.alphaValue, 1)
        expectEqual(zoom.frame.minX, minimap.frame.minX, "their left edges in line")
        expectEqual(zoom.frame.maxY, minimap.frame.minY - 8)
        h.wait(900)
        h.editor.camera.zoom = 0.5
        expectEqual(zoom.title, "50%")
        h.wait(999)
        expect(zoom.isShowing, "a second from the last change")
        expect(zoom.layer?.animationKeys()?.contains("opacity") != true)
        expectEqual(h.editor.announcements, [], "not while it changes")
        h.wait(1)
        expect(!zoom.isShowing)
        expectEqual(h.editor.announcements, ["Zoom 50%"], "VoiceOver hears where it came to, once, through the editor")
        expectEqual(canvas.accessibilityPosts.last, .announcementRequested)
        expectEqual(zoom.alphaValue, 0, "to where the fade ends")
        expect(zoom.layer?.animationKeys()?.contains("opacity") == true, "fading out")
        h.wait(150)
        h.editor.camera.zoom = 0.6
        expect(zoom.isShowing, "zoomed as it fades")
        expectEqual(zoom.alphaValue, 1)
        expect(zoom.layer?.animationKeys()?.contains("opacity") != true, "at once")
        h.wait(300)
        expect(!zoom.isHidden, "its fade cut short, with what came after")
        h.wait(999)
        expect(!zoom.isHidden, "still fading")
        h.wait(1)
        expect(zoom.isHidden, "once it has faded")
        h.editor.camera.zoom = 2
        expect(zoom.isShowing && !zoom.isHidden, "again")
    },
    test("a pan doesn't show it, nor a zoom that rounds to the same percent") {
        let h = try minimapEditor()
        let (_, canvas, _) = try minimapped(h)
        h.editor.camera.pan(by: CGSize(width: 300, height: -200))
        h.editor.camera.zoom = 1.004
        expect(!canvas.zoomIndicator.isShowing)
    },
    test("a zoom command shows where the camera's headed, from its first frame") {
        let h = try minimapEditor()
        let (_, canvas, _) = try minimapped(h)
        h.editor.perform(.zoomIn)
        h.wait(16)
        expect(h.editor.camera.zoom < 1.1, "barely under way")
        expect(canvas.zoomIndicator.isShowing)
        expectEqual(canvas.zoomIndicator.title, "200%")
    },
    test("in the minimap's corner while it's off, or hidden on an empty board; it follows the minimap showing or hiding while it shows") {
        let h = try minimapEditor()
        let (_, canvas, _) = try minimapped(h)
        h.editor.camera.zoom = 0.5
        expectEqual(canvas.zoomIndicator.frame.origin, CGPoint(x: 12, y: 600 - 12 - 22), "the board is empty")
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 1000, height: 800)))
        expectEqual(canvas.zoomIndicator.frame.origin, CGPoint(x: 12, y: 438 - 8 - 22), "the first shape shows the minimap")
        canvas.showsMinimap = false
        expectEqual(canvas.zoomIndicator.frame.origin, CGPoint(x: 12, y: 600 - 12 - 22), "turned off")
        canvas.showsMinimap = true
        h.wait(1300)
        expect(canvas.zoomIndicator.isHidden)
        h.editor.camera.zoom = 0.7
        expectEqual(canvas.zoomIndicator.frame.origin, CGPoint(x: 12, y: 438 - 8 - 22))
    },
    test("another board shown hides it at once, and its own zoom doesn't show it") {
        let owner = ShapeID()
        let root = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: owner, Pocket(CGRect(x: 0, y: 0, width: 200, height: 200))))])
        let inside = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 4000, height: 3000))))])
        let h = try minimapEditor(file: CanvasFile(root: root, children: [owner: inside]))
        let (_, canvas, _) = try minimapped(h)
        let zoom = canvas.zoomIndicator
        h.editor.camera.zoom = 2
        expect(zoom.isShowing)
        expect(h.enter(owner))
        expect(h.editor.zoomPercentage < 100, "fitted, on a first visit")
        expect(!zoom.isShowing && zoom.isHidden)
        expect(zoom.layer?.animationKeys()?.contains("opacity") != true, "no fade")
        h.editor.camera.zoom = 0.5
        expect(zoom.isShowing, "zoomed there")
    },
    test("not before the canvas has a size, and it takes no clicks") {
        let h = try minimapEditor()
        let (window, canvas, _) = try minimapped(h)
        h.editor.viewportDidResize(to: .zero)
        h.editor.camera.zoom = 0.5
        expect(!canvas.zoomIndicator.isShowing)
        h.editor.viewportDidResize(to: canvas.bounds.size)
        h.editor.camera.zoom = 0.6
        expect(canvas.zoomIndicator.isShowing)
        let frame = canvas.zoomIndicator.frame
        let middle = canvas.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        expect(window.contentView?.superview?.hitTest(middle) === canvas, "the canvas under it")
    },
])

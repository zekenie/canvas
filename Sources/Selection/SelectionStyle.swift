import AppKit
import Keyboard
import Palette

/// The selection's UI constants. Sizes are view points. The values follow tldraw.
@MainActor
enum SelectionStyle {
    static let accent = NSColor.controlAccentColor
    /// The selection's outline while the canvas hasn't the keyboard (`editor.hasKeyboard`), as a list's selected
    /// rows go gray while another view has it: where keys go shows in the accent alone.
    static let secondary = NSColor.secondaryLabelColor
    /// The halo around a hovered or pressed handle.
    static let accentFill = NSColor(name: nil) {
        NSColor.controlAccentColor.withAlphaComponent($0.isDark ? 0.2 : 0.24)
    }
    static let handleStrokeWidth: CGFloat = 1.5
    static let handleRadius: CGFloat = 4
    /// Also the radius of the halo.
    static let handleHitRadius: CGFloat = 12
    /// Below this zoom the handles shrink with the shapes.
    static let handleFullSizeZoom: CGFloat = 0.25
    /// Resize handles leave their shape room to be pressed itself: none show on a box under this on
    /// screen either way (its corners' reach would cover its middle), and a side's only on a side
    /// at least twice this long (its reach clear of the corners').
    static let resizeHandleRoom: CGFloat = 2 * handleHitRadius
    /// A press this far inside a resizable box's side, or as far past the outline drawn off it, takes that side
    /// anywhere along it (`ResizeHandle.side`): tldraw's 6 either side of its edges, which its outline lies on.
    static let resizeSideReach: CGFloat = 6
    /// The marquee: tldraw's hsl(0, 0%, 56%), in light and dark alike.
    static let brushFill = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.56, alpha: 0.102)
    static let brushStroke = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.56, alpha: 0.251)
    static let brushStrokeWidth: CGFloat = 1
    // The shake a shape gives when something tries to change it and it can't be (`RefusalShake`).
    /// The farthest it goes to either side, in view points.
    static let shakeAmplitude: CGFloat = 5
    /// How many times it goes right and left.
    static let shakeCycles: Double = 3
    static let shakeDuration: Duration = .milliseconds(360)
    /// A frame of a shake.
    static let shakeFrame: Duration = .milliseconds(16)
    /// What VoiceOver hears as shapes that can't change refuse a try: "Locked", or "3 shapes locked".
    static func refused(_ count: Int) -> String { count == 1 ? "Locked" : "\(count) shapes locked" }
    /// Tries that keep coming (a held arrow key's refused nudges) are said once: the same shapes refused again are
    /// said again only after this long with no try.
    static let refusalQuiet: Duration = .seconds(1)
    /// Going back moves the camera this long (data-canvas's).
    static let goBackDuration: Duration = .milliseconds(200)
    /// Bringing shapes into view (`reveal`), as selecting a row of data-canvas's table of contents
    /// does (its zoom config, and tldraw's zoomToBounds): 100 points of margin in all, no closer
    /// than 120%, over 200 ms.
    static let revealInset: CGFloat = 100
    static let revealMaxZoom = ReadableZoom.maximum
    static let revealDuration: Duration = .milliseconds(200)
    /// Going to shapes (`goTo`) leaves the camera where it is when they're all in view at this zoom
    /// or closer. Text on the canvas is set for 100%, a note's at 16 points: at 70% that's 11.2
    /// points on screen, just over the 11 of `NSFont.smallSystemFontSize`, the smallest size macOS
    /// sets text to be read at. Further out the shapes are there but can't be read, so going to them
    /// brings them closer.
    static let readableZoom: CGFloat = 0.7
    /// The box around the group the selection is inside (`GroupFocusOverlay`): dashed, as tldraw
    /// draws a focused group, in the accent, standing off what it holds past their outlines (which
    /// stand off 4).
    static let groupFocusStroke = NSColor.controlAccentColor.withAlphaComponent(0.7)
    static let groupFocusStrokeWidth: CGFloat = 1
    static let groupFocusDash: [CGFloat] = [4, 3]
    static let groupFocusStandoff: CGFloat = 10
    /// The ring around a shape's focused part (⌥Tab, `PartFocusOverlay`): this wide, in the accent, stood off
    /// the part's rect by this much.
    static let partRingWidth: CGFloat = 2
    static let partRingStandoff: CGFloat = 3
    /// How far an arrow key nudges the selection, and with ⇧, in world units (tldraw's 1 and 10).
    static let nudge: CGFloat = 1
    static let shiftNudge: CGFloat = 10
    /// What the Keyboard Shortcuts window calls the arrow keys: they nudge the selection, or with none pan the view.
    static let nudgeOrPan = "Nudge or Pan"
    // Stepping from shape to shape (`StopOrder`), with tldraw's numbers (`Editor.selectAdjacentShape`).
    /// Reading order: a shape joins a row when its center is less than this far, in world units, above or
    /// below the row's last.
    static let readingRowRange: CGFloat = 100
    /// Within a row the next two shapes swap when the one after next is closer to the shape, by under
    /// this fraction of the squared distance, and at most this many degrees off the horizontal.
    static let readingSwapCloseness: CGFloat = 0.9
    static let readingSwapAngle: CGFloat = 20
    /// The nearest shape in a direction is among those across the way no farther than this many times as far
    /// as along it, and scores the distance plus each of these times its measure: how far off the line it
    /// is, how much farther than straight ahead, how many degrees off the direction.
    static let stepWedge: CGFloat = 2
    static let stepAcrossWeight: CGFloat = 2
    static let stepDiagonalWeight: CGFloat = 1.5
    static let stepAngleWeight: CGFloat = 0.5
    /// The arrow keys, and which way each steps to the nearest shape (with ⌥⌘).
    static let steps: [(KeyChord, AdjacentDirection)] = [
        (.leftArrow, .left), (.rightArrow, .right), (.upArrow, .up), (.downArrow, .down),
    ]
    /// The arrow keys, and which way each nudges.
    static let nudges: [(KeyChord, CGPoint)] = [
        (.leftArrow, CGPoint(x: -1, y: 0)), (.rightArrow, CGPoint(x: 1, y: 0)),
        (.upArrow, CGPoint(x: 0, y: -1)), (.downArrow, CGPoint(x: 0, y: 1)),
    ]
}

import AppKit
import SwiftUI

/// The window's title bar's row as a pane's sheet hands it to what it holds: the sheets run the window's full height, so a
/// pane's first line (its header) sits in the row, beside the window's own buttons, rather than under an empty band. How tall
/// the row is, and how far in from the sheet's leading and trailing edges a line there may start and must end, clear of the
/// traffic lights and the toolbar's buttons over that sheet (and a header's inset where nothing is in the way).
public struct PaneTitleRow: Equatable, Sendable {
    public var height: CGFloat
    public var leading: CGFloat
    public var trailing: CGFloat

    public init(height: CGFloat, leading: CGFloat, trailing: CGFloat) {
        self.height = height
        self.leading = leading
        self.trailing = trailing
    }
}

extension EnvironmentValues {
    /// The title bar's row, while the view is in a pane's sheet that runs under one (the window sets it); nil elsewhere (a pane
    /// hosted on its own, a sheet in a window with no title bar), where a header keeps its own height and insets.
    public var paneTitleRow: PaneTitleRow? {
        get { self[PaneTitleRowKey.self] }
        set { self[PaneTitleRowKey.self] = newValue }
    }
}

struct PaneTitleRowKey: EnvironmentKey {
    static let defaultValue: PaneTitleRow? = nil
}

/// What a press in the window's title bar's row does where the app draws, under its own things (a pane's header, the board):
/// the window's, as a press on a title bar is. It drags the window, and a double-click does what the person chose (System
/// Settings › Desktop & Dock: zoom, minimize or nothing), except where the window's toolbar has a view under the press, which
/// answers a double-click itself (a click it doesn't use goes on to what is under it).
@MainActor
public enum TitleRow {
    public enum Action: Equatable, Sendable { case drag, zoom, miniaturize, nothing }

    /// What a press does: the event's `clickCount`, whether the toolbar has a view under it, and the person's setting
    /// (`AppleActionOnDoubleClick`, unset reading as zoom).
    public static func action(clickCount: Int, underToolbar: Bool, setting: String?) -> Action {
        guard clickCount == 2 else { return .drag }
        if underToolbar { return .nothing }
        switch setting {
        case "Minimize": return .miniaturize
        case "None": return .nothing
        default: return .zoom
        }
    }

    /// A press in the row, in its window: dragged, or a double-click answered.
    public static func press(_ event: NSEvent, in window: NSWindow) {
        let underToolbar = isUnderToolbar(event.locationInWindow, in: window)
        perform(action(clickCount: event.clickCount, underToolbar: underToolbar,
                       setting: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")), event, window)
    }

    /// Whether one of the title bar's views is over a point of the window (in its coordinates): what the window's frame finds
    /// there is outside its content.
    public static func isUnderToolbar(_ point: NSPoint, in window: NSWindow) -> Bool {
        guard let content = window.contentView, let frame = content.superview,
              let hit = frame.hitTest(frame.convert(point, from: nil)) else { return false }
        return hit !== content && !hit.isDescendant(of: content)
    }

    /// What carries an action out. A test puts its own: a drag of an unshown window would wait for a release.
    public static var perform: @MainActor (Action, NSEvent, NSWindow) -> Void = { action, event, window in
        switch action {
        case .drag: window.performDrag(with: event)
        case .zoom: window.performZoom(nil)
        case .miniaturize: window.performMiniaturize(nil)
        case .nothing: break
        }
    }
}

/// Behind what a pane puts in the title bar's row: where nothing over it takes the press (its controls do; its words and
/// symbols let it through), the press is the window's (`TitleRow`). Hidden from assistive apps, which move a window their own
/// way.
public struct TitleRowDragArea: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> TitleRowDragView { TitleRowDragView() }
    public func updateNSView(_ view: TitleRowDragView, context: Context) {}
}

/// `TitleRowDragArea`'s view. A click in a window that isn't key drags it at once, as its title bar does.
public final class TitleRowDragView: NSView {
    public override func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        TitleRow.press(event, in: window)
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func isAccessibilityElement() -> Bool { false }
}

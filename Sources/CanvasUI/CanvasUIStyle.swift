import Foundation

/// The canvas view's own constants, beside those of the views it hosts (`MinimapStyle`,
/// `ZoomIndicatorStyle`, `CardStyle`, `PopoverStyle`).
@MainActor
enum CanvasUIStyle {
    /// The most shapes VoiceOver is given as the canvas's children at once (`ShapeElement`s): those
    /// nearest the selection, the selection always among them.
    static let accessibleShapesLimit = 500
    /// What VoiceOver calls the board while the host hasn't named it (a window not yet titled).
    static let unnamedBoard = "Canvas"
    /// What VoiceOver hears as several shapes are selected.
    static func selected(_ count: Int) -> String { "\(count) selected" }
}

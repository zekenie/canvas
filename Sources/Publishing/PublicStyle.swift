import AppKit

/// Publishing's words and symbols, in one place.
@MainActor
enum PublicStyle {
    /// A private shape's chip and row mark: the eye crossed out, as a reference pill trails it for a
    /// shape that isn't public.
    static let privateSymbol = "eye.slash"
    /// The chip a shape shows for a moment after it went public: the eye open, fading.
    static let publicSymbol = "eye"
    /// What VoiceOver calls the chip (asked off the main actor too: `ClickableAdornment.partTitle`), and the row
    /// mark's tooltip.
    nonisolated static let privateWord = "Private"
    static let makePublic = "Make Public"
    static let makePrivate = "Make Private"
}

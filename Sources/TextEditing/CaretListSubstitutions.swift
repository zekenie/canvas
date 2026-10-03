import AppKit

/// The substitutions that could rewrite what's typed for a list at the caret (Mentions' `@query`, a
/// slash command's `/name`): spelling correction, text replacement, smart quotes and smart dashes.
/// A list's owner takes them as the list opens (`init(of:)`), turns them off (`off`) while it's
/// open, and puts them back as they were once it closes (`apply(to:)`).
@MainActor
public struct CaretListSubstitutions {
    public let spelling: Bool
    public let replacement: Bool
    public let quotes: Bool
    public let dashes: Bool

    /// All four off.
    public static let off = CaretListSubstitutions(spelling: false, replacement: false, quotes: false, dashes: false)

    public init(spelling: Bool, replacement: Bool, quotes: Bool, dashes: Bool) {
        self.spelling = spelling
        self.replacement = replacement
        self.quotes = quotes
        self.dashes = dashes
    }

    /// The view's, as they are now.
    public init(of view: NSTextView) {
        spelling = view.isAutomaticSpellingCorrectionEnabled
        replacement = view.isAutomaticTextReplacementEnabled
        quotes = view.isAutomaticQuoteSubstitutionEnabled
        dashes = view.isAutomaticDashSubstitutionEnabled
    }

    /// Sets the view's to these.
    public func apply(to view: NSTextView) {
        view.isAutomaticSpellingCorrectionEnabled = spelling
        view.isAutomaticTextReplacementEnabled = replacement
        view.isAutomaticQuoteSubstitutionEnabled = quotes
        view.isAutomaticDashSubstitutionEnabled = dashes
    }
}

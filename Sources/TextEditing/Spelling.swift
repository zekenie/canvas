import AppKit

/// How words typed in the app are checked, the same for every text that checks them
/// (`EditingTextView.spelling`: a note's, a schema card's description, an arrow's label, a title, the
/// panel's boxes of words) and kept between launches: Edit › Spelling and Grammar's Check Spelling
/// While Typing (on until it's turned off), Check Grammar With Spelling (off until it's turned on) and
/// Correct Spelling Automatically (as System Settings has it, until it's turned on or off here). A
/// text's own toggles for them (the menu bar's, its context menu's) change them here, and every text
/// that follows them changes at once. The words a text is told to ignore (Ignore Spelling) are one
/// list for all of them, until the app quits: an editor on the canvas is made for one editing, so a
/// list of its own would go with it. AppKit checks a text against a spell document of the view's
/// own, which an override of `spellCheckerDocumentTag` doesn't change for its checking, so the list
/// goes into each follower's document as it starts following, before its text is checked, and what
/// a follower was told to ignore comes back as the keyboard leaves it, or it leaves its window.
@MainActor
public final class Spelling {
    /// The app's, kept in the standard user defaults.
    public static let app = Spelling(defaults: .standard)

    private let defaults: UserDefaults
    /// The texts that follow these: each is set again as one changes.
    private let followers = NSHashTable<EditingTextView>.weakObjects()

    /// The words the followers were told to ignore, every follower's from then on.
    public private(set) var ignoredWords: Set<String> = []

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Check Spelling While Typing: a word misspelled is marked as it's typed. On until it's turned off.
    public var checksWhileTyping: Bool {
        get { defaults.object(forKey: Self.whileTypingKey) as? Bool ?? true }
        set { change(Self.whileTypingKey, to: newValue) { $0.isContinuousSpellCheckingEnabled = $1 } }
    }

    /// Check Grammar With Spelling: grammar is marked too, while spelling is. Off until it's turned on.
    public var checksGrammar: Bool {
        get { defaults.object(forKey: Self.grammarKey) as? Bool ?? false }
        set { change(Self.grammarKey, to: newValue) { $0.isGrammarCheckingEnabled = $1 } }
    }

    /// Correct Spelling Automatically: a word misspelled is corrected as it's typed. As System
    /// Settings has it (Keyboard › Text Input), until it's turned on or off here.
    public var correctsAutomatically: Bool {
        get { defaults.object(forKey: Self.correctionKey) as? Bool ?? NSSpellChecker.isAutomaticSpellingCorrectionEnabled }
        set { change(Self.correctionKey, to: newValue) { $0.isAutomaticSpellingCorrectionEnabled = $1 } }
    }

    static let whileTypingKey = "CheckSpellingWhileTyping"
    static let grammarKey = "CheckGrammarWithSpelling"
    static let correctionKey = "CorrectSpellingAutomatically"

    /// A text follows these from now on, set to them at once, the words to ignore in its document.
    func follow(_ view: EditingTextView) {
        followers.add(view)
        apply(to: view)
        if !ignoredWords.isEmpty {
            NSSpellChecker.shared.setIgnoredWords(Array(ignoredWords), inSpellDocumentWithTag: view.spellCheckerDocumentTag)
        }
    }

    /// Takes in the words a follower was told to ignore, for every follower: those made from now on,
    /// and those there now, for their words not yet checked.
    func keepIgnoredWords(of view: EditingTextView) {
        let told = Set(NSSpellChecker.shared.ignoredWords(inSpellDocumentWithTag: view.spellCheckerDocumentTag) ?? [])
        let new = told.subtracting(ignoredWords)
        guard !new.isEmpty else { return }
        ignoredWords.formUnion(new)
        for other in followers.allObjects where other !== view {
            for word in new { NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: other.spellCheckerDocumentTag) }
        }
    }

    func unfollow(_ view: EditingTextView) {
        followers.remove(view)
    }

    /// Keeps a setting, and sets every follower's to it, that one alone: a list at a caret may have
    /// turned another off for a while (`CaretListSubstitutions`).
    private func change(_ key: String, to value: Bool, _ set: (NSTextView, Bool) -> Void) {
        defaults.set(value, forKey: key)
        for view in followers.allObjects { set(view, value) }
    }

    private func apply(to view: NSTextView) {
        view.isContinuousSpellCheckingEnabled = checksWhileTyping
        view.isGrammarCheckingEnabled = checksGrammar
        view.isAutomaticSpellingCorrectionEnabled = correctsAutomatically
    }
}

import AppKit
import TestKit
import TextEditing

// `Spelling` and `EditingTextView.spelling`: how the app checks the words typed, one setting for
// every text that's words, kept in the user defaults, its toggles any such text's. Each test keeps
// its settings in a defaults suite of its own, never the app's (`Spelling.app`).

/// Settings of their own, in a defaults suite `body` has for itself.
@MainActor private func withSpelling(_ body: (Spelling, UserDefaults) throws -> Void) throws {
    let suite = "SpellingTests-\(UUID().uuidString)"
    let defaults = try require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(Spelling(defaults: defaults), defaults)
}

/// A text view that checks its words as `spelling` says.
@MainActor private func words(_ spelling: Spelling?) -> EditingTextView {
    let view = EditingTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
    view.spelling = spelling
    return view
}

/// What a text shows of the three settings: spelling while typing, grammar, correction.
@MainActor private func shown(_ view: NSTextView) -> [Bool] {
    [view.isContinuousSpellCheckingEnabled, view.isGrammarCheckingEnabled, view.isAutomaticSpellingCorrectionEnabled]
}

/// An item of Edit › Spelling and Grammar, as the text with the keyboard validates it.
@MainActor private func item(_ action: String) -> NSMenuItem {
    NSMenuItem(title: "", action: NSSelectorFromString(action), keyEquivalent: "")
}

@MainActor let spellingTests = Suite("Spelling", [
    test("words are checked as they're typed, grammar isn't, and correction is as System Settings has it, until each is set") {
        try withSpelling { spelling, _ in
            expect(spelling.checksWhileTyping)
            expect(!spelling.checksGrammar)
            expectEqual(spelling.correctsAutomatically, NSSpellChecker.isAutomaticSpellingCorrectionEnabled)
            expectEqual(shown(words(spelling)), [true, false, NSSpellChecker.isAutomaticSpellingCorrectionEnabled])
        }
    },
    test("a text without settings checks as AppKit has a text view check, no words marked as they're typed, and its toggles are its own") {
        try withSpelling { spelling, _ in
            let plain = words(nil), other = words(nil), note = words(spelling)
            expect(!plain.isContinuousSpellCheckingEnabled)
            plain.toggleContinuousSpellChecking(nil)
            plain.toggleGrammarChecking(nil)
            expect(plain.isContinuousSpellCheckingEnabled)
            expect(!other.isContinuousSpellCheckingEnabled, "another's are as they were")
            expectEqual([spelling.checksWhileTyping, spelling.checksGrammar], [true, false], "and so are the settings")
            expectEqual(shown(note), [true, false, spelling.correctsAutomatically])
        }
    },
    test("a text's toggles change the settings, for every text that follows them, and they're kept") {
        try withSpelling { spelling, defaults in
            let note = words(spelling), title = words(spelling)
            let correcting = spelling.correctsAutomatically
            note.toggleContinuousSpellChecking(nil)
            expect(!spelling.checksWhileTyping)
            expectEqual(shown(note), [false, false, correcting])
            expectEqual(shown(title), [false, false, correcting], "every text that follows them, at once")
            title.toggleGrammarChecking(nil)
            title.toggleAutomaticSpellingCorrection(nil)
            expectEqual(shown(note), [false, true, !correcting])
            note.toggleContinuousSpellChecking(nil)
            expectEqual(shown(title), [true, true, !correcting])

            let again = Spelling(defaults: defaults)
            expectEqual([again.checksWhileTyping, again.checksGrammar, again.correctsAutomatically], [true, true, !correcting],
                        "kept in the defaults: the next launch's")
            expectEqual(shown(words(again)), [true, true, !correcting])
        }
    },
    test("a setting changed sets that one alone in every follower: correction a list at the caret turned off stays off") {
        try withSpelling { spelling, _ in
            let note = words(spelling)
            spelling.correctsAutomatically = true
            CaretListSubstitutions.off.apply(to: note)        // an @ picker open over its text
            spelling.checksGrammar = true
            spelling.checksWhileTyping = false
            expectEqual(shown(note), [false, true, false])
        }
    },
    test("Edit › Spelling and Grammar's items are marked as the settings are") {
        try withSpelling { spelling, _ in
            let note = words(spelling)
            spelling.checksGrammar = true
            spelling.correctsAutomatically = false
            let marks = ["toggleContinuousSpellChecking:", "toggleGrammarChecking:", "toggleAutomaticSpellingCorrection:"].map { action in
                let item = item(action)
                expect(note.validateMenuItem(item), action)
                return item.state
            }
            expectEqual(marks, [.on, .on, .off])
        }
    },
    test("a text that stops following the settings keeps what it shows, and changes no more with them") {
        try withSpelling { spelling, _ in
            let note = words(spelling), other = words(spelling)
            note.spelling = nil
            other.toggleContinuousSpellChecking(nil)
            expect(note.isContinuousSpellCheckingEnabled, "as it was")
            expect(!other.isContinuousSpellCheckingEnabled)
            note.toggleContinuousSpellChecking(nil)
            expect(!spelling.checksWhileTyping && !note.isContinuousSpellCheckingEnabled, "its own toggle again")
            other.toggleContinuousSpellChecking(nil)
            expect(spelling.checksWhileTyping && !note.isContinuousSpellCheckingEnabled)
        }
    },
    test("a word a text is told to ignore is ignored in every text that follows the settings, there already or made after, once the keyboard leaves it") {
        try withSpelling { spelling, _ in
            @MainActor func ignored(_ view: NSTextView) -> [String] {
                NSSpellChecker.shared.ignoredWords(inSpellDocumentWithTag: view.spellCheckerDocumentTag) ?? []
            }
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let open = words(spelling), note = words(spelling)
            window.contentView = note
            window.makeFirstResponder(note)
            NSSpellChecker.shared.ignoreWord("wrod", inSpellDocumentWithTag: note.spellCheckerDocumentTag)     // its Ignore Spelling
            expectEqual(ignored(open), [], "not while it has the keyboard")
            window.makeFirstResponder(nil)
            expectEqual(spelling.ignoredWords, ["wrod"])
            expectEqual(ignored(open), ["wrod"], "a text there already")
            expectEqual(ignored(words(spelling)), ["wrod"], "a text made after")
            expectEqual(ignored(words(nil)), [], "not a text without settings")
            try withSpelling { other, _ in expectEqual(ignored(words(other)), [], "nor one following other settings") }

            let label = words(spelling)
            window.contentView = label
            NSSpellChecker.shared.ignoreWord("teh", inSpellDocumentWithTag: label.spellCheckerDocumentTag)
            window.contentView = nil                                                                   // its editing over
            expectEqual(spelling.ignoredWords, ["wrod", "teh"], "taken in as it leaves its window too")
            expectEqual(Set(ignored(words(spelling))), ["wrod", "teh"])
        }
    },
])

import AppKit
import Canvas
import DetailPanel
import Mentions
import Queries
import QueryTranslation
import SwiftUI
import TextEditing

// A rule's box and the lines under it. The box is a box of the panel's (`DetailTextBox`) over a `MentionTextView` with
// no owner (so no `/` list), its sentence plain text: `@` lists shapes and then the words typed (Mentions' words row);
// a shape picked puts its name in as a chip, exact, nothing asked; the words taken make a chip of them, asked of the
// model. A chip is drawn as one (TextEditing's highlights, derived from the text: a magnifier on a tint, cyan once it
// has a query, gray while its words are asked about, orange where they're no query). Tab walks the sentence and then
// each chip, selected, VoiceOver told which, before leaving the box; ⇧Tab is its way back, entering from below on the
// last chip. Under the rule, a line for each chip says what it found (`QueryPreview`).

/// A rule's sentence, with its chips.
struct RuleTextArea: View {
    let box: RuleBox
    let stored: Rule?
    let label: String
    let placeholder: String?
    let chips: RuleChips?
    let mentions: MentionState?

    var body: some View {
        let says = chips?.rule(in: box, stored: stored).says ?? stored?.says ?? ""
        let box = box, stored = stored, chips = chips, mentions = mentions
        let text = Binding<MentionText>(get: { MentionText(plain: says) }, set: { chips?.typed(Self.plain($0), in: box, stored: stored) })
        DetailTextBox(text, height: RuleBoxStyle.height, placeholder: placeholder, label: label, onCommit: { chips?.commit(box) }) {
            let view = MentionTextView<AnyMentionable>(frame: .zero, text: MentionText(plain: says), style: .panel, owner: nil, mentions: mentions)
            view.usesRuler = false
            view.usesFontPanel = false
            view.spelling = .app
            view.onWords = { [weak view] words, range in
                guard let view else { return }
                view.insertText(words, replacementRange: range)
                chips?.chip(words: words, in: box, text: view.string, stored: stored)
            }
            view.onShape = { [weak view] candidate, range in
                guard let view else { return }
                let name = candidate.appearance.label
                view.insertText(name, replacementRange: range)
                chips?.chip(shape: candidate.id, named: name, in: box, text: view.string, stored: stored)
            }
            view.highlighting = { text in chips?.highlights(in: text, box: box) ?? [] }
            view.onKeyDown = { [weak view] event in
                guard let view, let reading = KeyMeaning.Reading(event: event) else { return false }
                return Self.step(view, reading: reading, chips: chips, box: box)
            }
            view.onEnter = { [weak view] direction in
                // Entered from below: on the last chip, with no caret of its own to come back to.
                guard let view, direction == .selectingPrevious, let last = Self.chipRanges(in: view).last else { return }
                chips?.caretBeforeChips[box] = nil
                Self.select(last, in: view, chips: chips, box: box)
            }
            chips?.hold(view, for: box)
            return view
        }
    }

    /// The text as the sentence says it: a pill pasted in is its name.
    static func plain(_ text: MentionText) -> String {
        text.runs.map { run -> String in
            switch run {
            case .text(let words): words
            case .mention(_, let label): label
            }
        }.joined()
    }

    /// Where the chips are in the view's text.
    static func chipRanges(in view: EditingTextView) -> [NSRange] { view.highlights.map(\.range) }

    /// Tab: from the sentence the first chip (the caret kept), then each chip in order, then out of the box; ⇧Tab the
    /// exact way back: the chip before, from the first the caret where it was, from the sentence out.
    static func step(_ view: EditingTextView, reading: KeyMeaning.Reading, chips: RuleChips?, box: RuleBox) -> Bool {
        let ranges = chipRanges(in: view)
        guard !ranges.isEmpty else { return false }
        let selection = view.selectedRange()
        let on = ranges.firstIndex { $0 == selection }
        switch (reading.meaning, reading.modifiers) {
        case (.next, []):
            guard let on else {
                chips?.caretBeforeChips[box] = selection
                select(ranges[0], in: view, chips: chips, box: box)
                return true
            }
            guard ranges.indices.contains(on + 1) else { return false }
            select(ranges[on + 1], in: view, chips: chips, box: box)
            return true
        case (.previous, .shift), (.previous, []):
            guard let on else { return false }
            if on > 0 {
                select(ranges[on - 1], in: view, chips: chips, box: box)
            } else {
                let caret = chips?.caretBeforeChips.removeValue(forKey: box) ?? NSRange(location: ranges[0].location, length: 0)
                view.setSelectedRange(NSMaxRange(caret) <= (view.string as NSString).length ? caret : NSRange(location: ranges[0].location, length: 0))
            }
            return true
        default:
            return false
        }
    }

    /// A chip selected, shown and said.
    static func select(_ range: NSRange, in view: EditingTextView, chips: RuleChips?, box: RuleBox) {
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        let phrase = (view.string as NSString).substring(with: range)
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: RulesStyle.chipSpoken(phrase), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Under a rule, a line for each of its chips: what it found for a sample shape of the type (`QueryPreview`), lit on the
/// canvas while the pointer is over it.
struct RuleChipLines: View {
    let rule: Rule
    let type: ShapeID
    let chips: RuleChips?
    let lights: RuleLights?
    let editor: CanvasEditor?

    var body: some View {
        ForEach(rule.chipRanges.map(\.chip), id: \.phrase) { chip in
            if let chips {
                QueryPreview(chips.preview(of: chip, type: type), editor: editor, actions: actions(for: chip, chips: chips))
                    .padding(.leading, RuleBoxStyle.lineIndent)
                    .onHover { inside in
                        lights?.light(inside ? chips.foundShapes(of: chip, type: type) : nil, by: RulesStyle.chipLight)
                    }
                    .onDisappear { lights?.light(nil, by: RulesStyle.chipLight) }
            }
        }
    }

    private func actions(for chip: RuleChip, chips: RuleChips) -> QueryPreview.Actions {
        let type = type, says = rule.says, phrase = chip.phrase
        return QueryPreview.Actions(
            follow: { [weak lights] id in lights?.go(to: [id]) },
            step: { [weak chips] delta in chips?.step(type, by: delta) },
            editWords: { [weak chips] in chips?.editWords(phrase, of: says, type: type) },
            writeQuery: { [weak chips] text in chips?.write(text, forChip: phrase, of: says, type: type) },
            retry: { [weak chips] in chips?.retry(phrase, type: type) },
            interpret: { [weak chips] in chips?.interpret(phrase, type: type) },
            completions: editor?.queries.map { RuleChipCompletions.completer(for: $0.vocabulary) })
    }
}

/// What can be typed in a chip's query: the words (but those that read what the person has selected or looks at, and
/// with the shape checked's), after a `:`, else the kinds.
enum RuleChipCompletions {
    @MainActor static func completer(for vocabulary: QueryVocabulary) -> DetailCodeCompleting {
        // A word is listed without its colon (`edge-to`), and the range a pick replaces starts at the colon.
        let words = vocabulary.words.filter { !$0.readsEditor }.map { DetailCodeCompletion(label: ":" + $0.word, detail: $0.summary, insert: ":" + $0.word) }
            + RulesStyle.scopeWords.map { DetailCodeCompletion(label: $0.word, detail: $0.summary, insert: $0.word) }
        let kinds = vocabulary.kinds.map { DetailCodeCompletion(label: $0.kind.rawValue, detail: $0.label, insert: $0.kind.rawValue) }
        return { text, caret in
            let units = Array(text.utf16)
            guard caret <= units.count else { return nil }
            var start = caret
            while start > 0, let scalar = Unicode.Scalar(units[start - 1]),
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == ":" {
                start -= 1
                if scalar == ":" { break }
            }
            let token = String(utf16CodeUnits: Array(units[start..<caret]), count: caret - start)
            let range = NSRange(location: start, length: caret - start)
            if token.hasPrefix(":") { return DetailCodeCompletions(range: range, query: token, items: words) }
            guard !token.isEmpty else { return nil }
            return DetailCodeCompletions(range: range, query: token, items: kinds)
        }
    }
}

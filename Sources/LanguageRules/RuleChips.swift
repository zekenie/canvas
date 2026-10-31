import AppKit
import Canvas
import Mentions
import Observation
import Queries
import QueryLanguage
import QueryTranslation
import TextEditing
import Titles
import Topology
import Types

// A type's rules' chips: phrases of a rule that find shapes. A chip is made in the rule's box with `@`: a shape picked
// is a chip whose query is that shape, and nothing is asked; words taken go to the model through the lifecycle every
// host of words shares (`editor.interpretations`), this service its host, the words keyed by the type and the phrase,
// asked as a stored query bound to the shape checked (`TranslationContext.stored(binding:sentence:)`). While a rule's
// box is typed into, its rule is a draft here (the sentence and its chips), and a chip's answer is a draft too, written
// with the rule as the box commits; an answer that comes after lands as a step of its own, "Interpret". The line under a
// rule shows what each chip's query finds for a sample shape of the type, one at a time in file order, ‹ › between them.

/// A rule's box in a type's Rules tab: a rule by its place in the type's list, or the box that adds one.
public struct RuleBox: Hashable, Sendable {
    public let type: ShapeID
    /// Its rule's place in the type's list; nil for the box that adds one.
    public let index: Int?

    public init(type: ShapeID, index: Int?) {
        self.type = type
        self.index = index
    }
}

/// What a chip is, as its box draws it: found (it has a query), being asked about (words with none yet), or words that
/// are no query.
public enum ChipLook: Equatable, Sendable {
    case found, asking, failed
}

@MainActor
@Observable
public final class RuleChips {
    @ObservationIgnored private weak var editor: CanvasEditor?
    /// The rules being typed, by their box: the sentence and its chips as they are.
    @ObservationIgnored private var drafts: [RuleBox: Rule] = [:]
    /// The sentence each draft started from (nil for the box that adds one): the rule a commit replaces, wherever it is
    /// by then (a rule above it gone, an undo), so a draft never writes over another rule.
    @ObservationIgnored private var bases: [RuleBox: String?] = [:]
    /// Where each box's caret was as Tab went from its sentence to its first chip: where ⇧Tab from that chip puts it back.
    @ObservationIgnored var caretBeforeChips: [RuleBox: NSRange] = [:]
    /// The boxes' text views, weakly: Edit Words puts the keyboard in one, on a chip's phrase.
    @ObservationIgnored private var views: [RuleBox: WeakText] = [:]
    /// The sample each type's lines show, by its place among the type's shapes in file order.
    @ObservationIgnored private var sampleIndex: [ShapeID: Int] = [:]
    @ObservationIgnored private var sampled: [ShapeID: [ShapeID]] = [:]
    /// What each query found for each sample, kept until a commit that writes anything; and those being asked.
    @ObservationIgnored private var found: [Asked: Found] = [:]
    @ObservationIgnored private var finding: Set<Asked> = []
    @ObservationIgnored private var generation = 0
    /// The words this host has asked about, by their key.
    @ObservationIgnored private var asked: Set<InterpretationKey> = []
    @ObservationIgnored private var revisions: [ShapeID: Int] = [:]

    init(editor: CanvasEditor) { self.editor = editor }

    /// The editor, for the views of the Rules tab that go to and light shapes.
    var editorLent: CanvasEditor? { editor }

    /// A query asked for a sample.
    private struct Asked: Hashable {
        let query: String
        let sample: ShapeID?
    }

    /// What a query found: its matches, or the engine's refusal in its words.
    private enum Found {
        case shapes(QueryMatches)
        case refused(String)
    }

    private struct WeakText {
        weak var view: EditingTextView?
    }

    // MARK: Observing

    /// Observed by a type's tab: told as a draft, an answer or what a chip found changes.
    private subscript(observed type: ShapeID) -> Int { revisions[type, default: 0] }

    private func observe(_ type: ShapeID) { access(keyPath: \.[observed: type]) }

    private func tell(_ type: ShapeID) {
        withMutation(keyPath: \.[observed: type]) { revisions[type, default: 0] += 1 }
        // The boxes draw their chips as they are now.
        for (box, held) in views where box.type == type { held.view?.refreshHighlights() }
    }

    // MARK: Drafts

    /// The rule a box shows: its draft while it's typed into, else what the type holds there.
    public func rule(in box: RuleBox, stored: Rule?) -> Rule {
        observe(box.type)
        return drafts[box] ?? stored ?? Rule(says: "")
    }

    /// A box's draft, begun from what the type holds there if it has none yet.
    private func draft(_ box: RuleBox, stored: Rule?) -> Rule {
        if let draft = drafts[box] { return draft }
        bases[box] = .some(stored?.says)
        return stored ?? Rule(says: "")
    }

    /// The box's text changed: the draft says it, keeping the chips whose phrase is still in it.
    public func typed(_ text: String, in box: RuleBox, stored: Rule?) {
        let rule = draft(box, stored: stored).saying(text)
        guard drafts[box] != rule else { return }
        drafts[box] = rule
        tell(box.type)
    }

    /// Whether a box is being typed into.
    public func isDrafting(_ box: RuleBox) -> Bool { drafts[box] != nil }

    /// A chip made of words taken from the `@` list, now in the box's `text`: words that read as a query bound to the
    /// shape checked are that query, with no model asked; else the model is asked, at once.
    public func chip(words: String, in box: RuleBox, text: String, stored: Rule?) {
        guard let editor else { return }
        var rule = draft(box, stored: stored).saying(text)
        let query = try? editor.queries?.checkStored(words, binding: .scope).canonical
        add(RuleChip(phrase: words, query: query), to: &rule)
        drafts[box] = rule
        if query == nil {
            let key = Self.key(box.type, words)
            asked.insert(key)
            editor.interpretations?.interpret(words, at: key, host: self)
        }
        tell(box.type)
    }

    /// A chip made of a shape picked from the `@` list, its name now in the box's `text`: exact, nothing asked. Its query
    /// is its title, in quotes, where no other shape has it, else its id.
    public func chip(shape: ShapeID, named name: String, in box: RuleBox, text: String, stored: Rule?) {
        var rule = draft(box, stored: stored).saying(text)
        add(RuleChip(phrase: name, query: query(naming: shape)), to: &rule)
        drafts[box] = rule
        tell(box.type)
    }

    /// Puts a chip among a rule's, in the order their phrases are written; one with its phrase already there is replaced.
    private func add(_ chip: RuleChip, to rule: inout Rule) {
        rule.find.removeAll { $0.phrase == chip.phrase }
        rule.find.append(chip)
        let says = rule.says
        func place(_ chip: RuleChip) -> String.Index { Rule.range(of: chip.phrase, in: says)?.lowerBound ?? says.endIndex }
        rule.find.sort { place($0) < place($1) }
    }

    /// The query of a shape picked: its title, quoted, where it names that shape alone, else its id.
    private func query(naming id: ShapeID) -> String {
        guard let editor, let snapshot = editor.topology?.snapshot(), let title = TitleProperty.folded(snapshot.shape(id)?[TitleProperty.self]) else {
            return "#" + id.description
        }
        var others = 0
        snapshot.forEachShape(inFileOrder: { other, _ in
            if other.id != id, TitleProperty.folded(other[TitleProperty.self]) == title { others += 1 }
        })
        return others == 0 ? Self.quoted(title) : "#" + id.description
    }

    /// Writes a box's draft as its rule (emptied, the rule goes): its chips' answers that came while it was typed go with
    /// it, in the same step, "Change Rules"; words still asked about land later, as "Interpret".
    public func commit(_ box: RuleBox) {
        guard let editor, var rule = drafts.removeValue(forKey: box) else { return }
        let base = bases.removeValue(forKey: box) ?? nil
        defer { tell(box.type) }
        rule.says = rule.says.trimmingCharacters(in: .whitespacesAndNewlines)
        rule = rule.saying(rule.says)
        for i in rule.find.indices {
            let key = Self.key(box.type, rule.find[i].phrase)
            if rule.find[i].query == nil, let query = editor.interpretations?.draftQuery(at: key, words: rule.find[i].phrase) {
                rule.find[i].query = query
            }
            if rule.find[i].query != nil { forget(key) }
        }
        var rules = RuleBook.rules(of: box.type, in: editor)
        // The rule the draft began from, where it is now: its place if it's still there, else wherever it went; one gone
        // (or the box that adds one) is added, so what was typed is never lost nor written over another rule.
        let at: Int? = if let i = box.index, let base, rules.indices.contains(i), rules[i].says == base { i }
            else if let base { rules.firstIndex { $0.says == base } } else { nil }
        if let at {
            guard rule != rules[at] else { return }
            if rule.says.isEmpty { rules.remove(at: at) } else { rules[at] = rule }
        } else {
            guard !rule.says.isEmpty else { return }
            rules.append(rule)
        }
        editor.ruleWriter?.setRules(rules, of: box.type)
        // What's still asked about lands once it comes: the words aren't typed now.
        for chip in rule.find where chip.query == nil { editor.interpretations?.editingEnded(at: Self.key(box.type, chip.phrase)) }
    }

    /// A box's text view, as it's made: what Edit Words puts the keyboard in, and what's told to draw its chips again.
    func hold(_ view: EditingTextView, for box: RuleBox) {
        views = views.filter { $0.value.view != nil }
        views[box] = WeakText(view: view)
    }

    /// The chips of the rule a box shows, where they are in `text`, each drawn as its look says.
    func highlights(in text: String, box: RuleBox) -> [TextHighlight] {
        guard let editor else { return [] }
        let stored = box.index.flatMap { RuleBook.rules(of: box.type, in: editor).dropFirst($0).first }
        let rule = Rule(says: text, find: (drafts[box] ?? stored)?.find ?? [])
        return rule.chipRanges.map { chip, range in
            TextHighlight(range: NSRange(range, in: text), fill: RulesStyle.chipFill(look(of: chip, type: box.type)), symbol: RulesStyle.chipSymbol)
        }
    }

    /// Edit Words: the keyboard in the box of the rule that says `says`, the chip's phrase selected, so typing over it
    /// (or `@` and other words) makes the chip again.
    public func editWords(_ phrase: String, of says: String, type: ShapeID) {
        guard let editor else { return }
        let index = RuleBook.rules(of: type, in: editor).firstIndex { $0.says == says }
        guard let view = views[RuleBox(type: type, index: index)]?.view ?? views.first(where: { $0.key.type == type && ($0.value.view?.string.contains(phrase) ?? false) })?.value.view,
              let range = view.string.range(of: phrase) else { return }
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(range, in: view.string))
        view.scrollRangeToVisible(NSRange(range, in: view.string))
    }

    // MARK: What a chip is, and finds

    static let slot = "rule chip: "

    /// The key of a chip's words: its type and its phrase.
    static func key(_ type: ShapeID, _ phrase: String) -> InterpretationKey { InterpretationKey(shape: type, slot: slot + phrase) }

    /// How a chip is drawn in its box.
    public func look(of chip: RuleChip, type: ShapeID) -> ChipLook {
        if chip.query != nil { return .found }
        switch editor?.interpretations?.state(at: Self.key(type, chip.phrase)) {
        case .failed?: return .failed
        case .drafted?: return .found
        default: return .asking
        }
    }

    /// What the line under a chip says: its query (the draft's while its words are typed), the words' state, the sample
    /// and what it found for it. Asks for what it found, once, when that isn't known.
    public func preview(of chip: RuleChip, type: ShapeID) -> QueryPreview.Content {
        observe(type)
        guard let editor else { return QueryPreview.Content(query: chip.query) }
        let key = Self.key(type, chip.phrase)
        var status: InterpretationStatus?
        var query = chip.query
        switch editor.interpretations?.state(at: key) {
        case .interpreting?: status = .interpreting
        case .failed(let failure)?: status = failure
        case .drafted(let draft, _)? where query == nil: query = draft
        default: break
        }
        guard let query else {
            // Words nobody is asking about (asked before the file was last opened, or never: no translator then) offer
            // Interpret, as a pill's do; with nothing to ask with, they say so.
            if status == nil, editor.queryTranslator == nil { status = .unavailable }
            return QueryPreview.Content(query: nil, status: status, offersInterpret: status == nil)
        }
        let bound = (try? editor.queries?.check(query, binding: .scope).usesScope) ?? false
        let samples = bound ? samples(of: type) : []
        let sample = samples.isEmpty ? nil : samples[min(sampleIndex[type] ?? 0, samples.count - 1)]
        var content = QueryPreview.Content(query: query, status: status, sample: sample.map(name(of:)), samples: samples.count)
        guard !bound || sample != nil else {
            content.rows = []
            return content
        }
        let asking = Asked(query: query, sample: sample)
        switch found[asking] {
        case .shapes(let matches)?:
            (content.rows, content.more) = rows(of: matches)
        case .refused(let message)?:
            content.refusal = message
        case nil:
            ask(asking, type: type)
        }
        return content
    }

    /// The shapes a chip's line found for its sample, as the light shows them: what lights while the line is highlighted.
    public func foundShapes(of chip: RuleChip, type: ShapeID) -> [ShapeID] {
        guard let editor, let query = chip.query ?? editor.interpretations?.draftQuery(at: Self.key(type, chip.phrase), words: chip.phrase) else { return [] }
        let samples = samples(of: type)
        let sample = samples.isEmpty ? nil : samples[min(sampleIndex[type] ?? 0, samples.count - 1)]
        guard case .shapes(let matches)? = found[Asked(query: query, sample: sample)] ?? found[Asked(query: query, sample: nil)] else { return [] }
        return matches.ids
    }

    /// Steps a type's lines to the sample before or after (round the ends).
    public func step(_ type: ShapeID, by delta: Int) {
        let count = samples(of: type).count
        guard count > 1 else { return }
        sampleIndex[type] = ((sampleIndex[type] ?? 0) + delta + count) % count
        tell(type)
    }

    /// The type's shapes in file order: the samples its lines step through. Kept until a commit that writes anything, so
    /// drawing the tab again sorts nothing.
    private func samples(of type: ShapeID) -> [ShapeID] {
        if let kept = sampled[type] { return kept }
        guard let editor, let types = editor.types, let snapshot = editor.topology?.snapshot() else { return [] }
        let instances = types.allInstances(of: type)
        let sorted = instances.sorted { (snapshot.fileOrderKey(of: $0) ?? []).lexicographicallyPrecedes(snapshot.fileOrderKey(of: $1) ?? []) }
        sampled[type] = sorted
        return sorted
    }

    /// A sample by name: an arrow by its ends ("Lloyd Smucker → Limit, Save, Grow Act"), else as Mentions names it.
    private func name(of id: ShapeID) -> String {
        guard let editor else { return "" }
        if let snapshot = editor.topology?.snapshot(), let edge = snapshot.edges(carriedBy: id).first(where: { $0.slot.isEmpty }) {
            return label(of: edge.source) + " → " + label(of: edge.target)
        }
        return label(of: id)
    }

    private func label(of id: ShapeID) -> String {
        guard let editor, let record = editor.shape(inFile: id) else { return RulesStyle.untitled }
        return editor.mentionAppearance(of: record)?.label ?? TitleProperty.folded(record[TitleProperty.self]) ?? RulesStyle.untitled
    }

    /// What a query found, a row each, each container followed by what it holds, at most `RulesStyle.foundRows` rows;
    /// how many more.
    private func rows(of matches: QueryMatches) -> ([FoundRow], Int) {
        guard let editor else { return ([], 0) }
        let snapshot = editor.topology?.snapshot()
        var rows: [FoundRow] = [], more = 0
        func row(_ id: ShapeID, depth: Int, held: Int) -> FoundRow? {
            guard let record = editor.shape(inFile: id) else { return nil }
            let appearance = editor.mentionAppearance(of: record)
            let detail = held > 0 ? RulesStyle.inside(held) : editor.mentions?.place(ofShape: id)?.text
            return FoundRow(id: id, symbol: appearance?.systemImage ?? RulesStyle.shapeSymbol, tint: appearance?.tint, name: appearance?.label ?? label(of: id),
                            place: detail, dimmed: false, depth: depth)
        }
        for id in matches.ids {
            let held = snapshot?.children(of: id) ?? []
            if rows.count < RulesStyle.foundRows, let line = row(id, depth: 0, held: held.count) { rows.append(line) } else { more += 1 }
            for child in held {
                if rows.count < RulesStyle.foundRows, let line = row(child, depth: 1, held: 0) { rows.append(line) } else { more += 1 }
            }
        }
        return (rows, more + matches.count - matches.ids.count)
    }

    /// Asks what a query finds for a sample: one request, the sample bound to `:scope`, providing nothing.
    private func ask(_ asking: Asked, type: ShapeID) {
        guard let queries = editor?.queries, finding.insert(asking).inserted else { return }
        let number = generation
        Task { [weak self] in
            let result = await queries.matches([QueryMatchRequest(asking.query, scope: asking.sample, limit: RulesStyle.foundRows)]).first
            guard let self, self.generation == number else { return }
            self.finding.remove(asking)
            switch result {
            case .success(let matches)?: self.found[asking] = .shapes(matches)
            case .failure(let error)? where error.reason == .cancelled || error.reason == .boardClosed: return
            case .failure(let error)?: self.found[asking] = .refused(error.message)
            case nil: return
            }
            self.tell(type)
        }
    }

    /// Writes a query typed by hand for a chip, if the engine takes it bound to the shape checked: nil once written, else
    /// the engine's refusal. One step, "Change Rules".
    public func write(_ text: String, forChip phrase: String, of says: String, type: ShapeID) -> String? {
        guard let editor, let queries = editor.queries else { return nil }
        do throws(QueryError) {
            let plan = try queries.checkStored(text, binding: .scope)
            forget(Self.key(type, phrase))
            let held = RuleBook.rules(of: type, in: editor).first { $0.says == says }?.find.first { $0.phrase == phrase }?.query
            guard held == plan.canonical || editor.ruleWriter?.setQuery(plan.canonical, ofChip: phrase, in: says, of: type) == true else {
                return RulesStyle.notWritten
            }
            return nil
        } catch {
            return error.message
        }
    }

    /// Asks about a chip's words that nobody is asking about: what the line's Interpret does.
    public func interpret(_ phrase: String, type: ShapeID) {
        let key = Self.key(type, phrase)
        asked.insert(key)
        editor?.interpretations?.interpret(phrase, at: key, host: self)
    }

    /// Asks again about a chip's words that failed.
    public func retry(_ phrase: String, type: ShapeID) {
        editor?.interpretations?.retry(at: Self.key(type, phrase))
    }

    private func forget(_ key: InterpretationKey) {
        guard asked.remove(key) != nil else { return }
        editor?.interpretations?.drop(key)
    }

    /// The phrase a key is for.
    private static func phrase(of key: InterpretationKey) -> String { String(key.slot.dropFirst(slot.count)) }

    /// A title as a query writes it: in double quotes.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The rule a chip's words are in, as the type has it or a box has it typed.
    private func rule(holding phrase: String, of type: ShapeID) -> Rule? {
        if let draft = drafts.first(where: { $0.key.type == type && $0.value.find.contains { $0.phrase == phrase } })?.value { return draft }
        guard let editor else { return nil }
        return RuleBook.rules(of: type, in: editor).first { $0.find.contains { $0.phrase == phrase } }
    }
}

extension RuleChips: InterpretationHost {
    /// A stored query bound to the type's shapes, each the shape checked, with the rule's sentence, its phrases in
    /// brackets.
    public func context(of key: InterpretationKey) -> TranslationContext {
        guard let editor, let types = editor.types else { return .stored() }
        let connections = types.graph.relationshipTypes.contains(key.shape)
        // What the type's shapes are, by their kind's name: the first one's.
        let kind = samples(of: key.shape).first.flatMap { editor.shape(inFile: $0)?.kind }
        let noun = kind.flatMap { RuleChecks.readings(of: editor.registry)[$0]?.noun }.map(RulesStyle.plural) ?? RulesStyle.shapes
        let binding = StoredBinding(type: types.name(of: key.shape) ?? RulesStyle.untitled, shapes: noun, connections: connections)
        return .stored(binding: binding, sentence: rule(holding: Self.phrase(of: key), of: key.shape)?.bracketed)
    }

    /// Whether a rule of the type (typed or held) still has a chip of these words with no query.
    public func holdsWords(_ words: String, at key: InterpretationKey) -> Bool {
        rule(holding: words, of: key.shape)?.find.contains { $0.phrase == words && $0.query == nil } ?? false
    }

    /// What a draft finds is the line's to ask, for its sample: nothing here.
    public func request(for _: String, at _: InterpretationKey) -> QueryMatchRequest? { nil }

    /// Writes the query of words that came once the box was done with, as its own step, "Interpret".
    public func land(_ query: String, words: String, at key: InterpretationKey) {
        guard let editor, let rule = RuleBook.rules(of: key.shape, in: editor).first(where: { $0.find.contains { $0.phrase == words && $0.query == nil } }) else { return }
        asked.remove(key)
        editor.ruleWriter?.setQuery(query, ofChip: words, in: rule.says, of: key.shape, step: RulesStyle.interpret)
    }

    public func interpretAgain(at key: InterpretationKey) {
        let words = Self.phrase(of: key)
        asked.insert(key)
        editor?.interpretations?.interpret(words, at: key, host: self)
    }

    public func interpretationDidChange(at key: InterpretationKey) { tell(key.shape) }

    /// Typed while a box of the type holds a draft with these words.
    public func isEditing(at key: InterpretationKey) -> Bool? {
        let words = Self.phrase(of: key)
        return drafts.contains { $0.key.type == key.shape && $0.value.find.contains { $0.phrase == words } }
    }
}

extension RuleChips: EditorService {
    /// A commit that wrote anything: what each query finds may have changed (asked again as the lines are drawn), and
    /// words asked about whose chip went (an undo, a sentence edited elsewhere) are let go of. A file put in place: every
    /// draft and answer.
    public func documentDidChange(_ changes: ChangeSet, in _: CanvasEditor) {
        if changes.replacedDocument {
            drafts = [:]
            bases = [:]
            for key in asked { editor?.interpretations?.drop(key) }
            asked = []
        }
        let touched = changes.added.union(changes.removed).union(changes.changed.subtracting(changes.moved)).union(changes.elsewhere)
        guard !touched.isEmpty || changes.replacedDocument else { return }
        sampled = [:]
        generation += 1
        finding = []
        let types: Set<ShapeID> = found.isEmpty ? [] : Set(revisions.keys)
        found = [:]
        for key in asked where touched.contains(key.shape) && !holdsWords(Self.phrase(of: key), at: key) && isEditing(at: key) != true {
            asked.remove(key)
            editor?.interpretations?.drop(key)
        }
        for type in types { tell(type) }
    }
}

extension CanvasEditor {
    /// A type's rules' chips: nil without `LanguageRulesPlugin`.
    public var ruleChips: RuleChips? { service(RuleChips.self) }
}

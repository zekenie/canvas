import Canvas
import Foundation
import LanguageModels
import Observation

/// Each editor's prose maps (`editor.proseMaps`, `context.proseMaps` in a render): what a shape's
/// words say of its target, read where the words are drawn (`map`), and asked of the model
/// (`ProseMapPrompt`) for a pair of texts nothing has been said of. It asks for a pair:
///
/// - read with no answer, and while the reader says it may be asked about (`askingIf`: a schema
///   card's two texts in step, so what's linked is what both say), handed over as the frame that
///   read it ends (`ProseMapFrames`), so a shape is asked about only once it's drawn in full, not
///   while it's out of view or drawn as a skeleton, which read nothing;
/// - with prose that isn't blank, while its shape isn't being edited (its words aren't done), is on
///   the board shown, and the editor has a model;
/// - nothing has been said of this session (by its texts, whatever shape: undo, a copy and a file
///   opened twice ask nothing again), not being asked already, and not failed;
/// - at most `concurrentCalls` at once, the rest waiting their turn in the order they came; another
///   board shown drops the ones waiting for shapes not on it.
///
/// An answer is kept for its pair whatever the shape says by the time it lands (`ProseMapAnswers`,
/// process-wide), and is the shape's last for its target unless one asked after it has landed, as is
/// an answer a shape reads for its pair (a copy's, one undo brought back); a map read for a pair with
/// no answer is the shape's last answer placed on the texts as they are, so words being typed keep
/// the links still there. The canvas redraws as one lands, and
/// `revision(of:)` changes for its shape. A failure keeps nothing, and its pair isn't asked about
/// again this session, but after a key is saved in Settings; one that may well work later (too many
/// requests, overloaded, the network, a timeout: `LanguageModelError.isTransient`) is asked again once
/// `retryDelay` has passed and the shape is next drawn. Nothing is written to the document.
@MainActor
@Observable
public final class ProseMapService {
    /// The most calls out at once.
    public static let concurrentCalls = 4
    /// How long a pair whose call failed for a reason that may pass waits before it is asked about again.
    public static let retryDelay: Duration = .seconds(30)

    @ObservationIgnored private weak var editor: CanvasEditor?
    /// What each shape shows of each target it's read with, by the target's type.
    @ObservationIgnored private var slots: [ShapeID: [ObjectIdentifier: Slot]] = [:]
    /// The pairs read since the frame before with no answer that may be asked about, by shape and
    /// target.
    @ObservationIgnored private var wanted: [Want.Place: Want] = [:]
    /// The pairs being asked about. A call isn't cancelled: whatever the shape says by the time it
    /// lands, its answer is kept for its pair.
    @ObservationIgnored private var asking: Set<ProseMapAnswers.Key> = []
    @ObservationIgnored private var waiting: [Want] = []
    @ObservationIgnored private var failed: Set<ProseMapAnswers.Key> = []
    /// Pairs whose call failed in a way that may pass (`isTransient`): not asked about until `retryDelay` has gone.
    @ObservationIgnored private var cooling: Set<ProseMapAnswers.Key> = []
    @ObservationIgnored private var revisions: [ShapeID: Int] = [:]
    /// Counts the asks and the answers shapes read, in order: what a shape was said last is its last.
    @ObservationIgnored private var clock = 0
    @ObservationIgnored nonisolated(unsafe) private var keyObserver: (any NSObjectProtocol)?

    /// What a shape shows of a target: what it read last and the map it made, and the answer it last
    /// had for any of its pairs.
    private struct Slot {
        var shown: Shown?
        var latest: (links: [ProseLink<String>], number: Int)?
        /// Where the last answer placed was found in the target, by the addresses as written: a pair
        /// whose prose alone changed (its words typed) places its links without finding them again.
        var located: (target: String, addresses: [String], ranges: [Range<String.Index>?])?
    }

    /// A map as it was read: the texts, the answers there were then, and what it showed.
    private struct Shown {
        let prose: String
        let target: String
        let context: String
        /// `ProseMapAnswers.revision` and the shape's last answer's number as it was made.
        let answers: Int
        let latest: Int?
        /// The answer it was placed from, or nil for none.
        let source: Source?
        let map: AnyObject?
        /// Its pair, if it has no answer.
        let want: Want?
    }

    /// Which answer a map was placed from: its pair's own (by the number `ProseMapAnswers` keeps it
    /// under), or the shape's last (by `clock`'s number for it).
    private enum Source: Equatable {
        case answer(Int), latest(Int)
    }

    /// A pair to ask about, and the shape that read it: the request is made only as it's asked.
    struct Want {
        struct Place: Hashable {
            let shape: ShapeID
            let target: ObjectIdentifier
        }
        let place: Place
        let key: ProseMapAnswers.Key
        let type: any ProseTarget.Type
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        keyObserver = NotificationCenter.default.addObserver(forName: .languageModelKeyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyDidChange() }
        }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    // MARK: Reading

    /// What `shape`'s words, `prose`, say of `target`: its pair's answer placed on the two texts,
    /// else the shape's last answer for this target placed on them, else nil. Give the texts as the
    /// model reads them (a mention as a word the model can copy): the links are found in them, and a
    /// reader that draws other text moves them onto it. `context` is what this pair needs said beyond
    /// the target's guide (`ProseMapPrompt.system`), and is part of what its answer is kept by.
    ///
    /// A pair with no answer is asked about once the frame ends, if `askingIf` says it may be: called
    /// only then, so a reader can say "while its two texts are in step" for nothing on every frame.
    /// The same map, the same object, while nothing it's placed from changes, so reading one on every
    /// frame costs a lookup when the texts are the same strings as last time.
    public func map<T: ProseTarget>(_ type: T.Type, of shape: ShapeID, prose: String, target: String, context: String = "",
                                    askingIf ready: () -> Bool = { true }) -> ProseMap<T>? {
        let kind = ObjectIdentifier(type)
        let slot = slots[shape]?[kind]
        if let kept = slot?.shown, Self.same(kept.prose, prose), Self.same(kept.target, target), Self.same(kept.context, context),
           kept.answers == ProseMapAnswers.revision, kept.latest == slot?.latest?.number {
            if let want = kept.want, mayAsk(want.key), ready() { wanted[want.place] = want }
            return kept.map as? ProseMap<T>
        }
        var next = slot ?? Slot()
        let key = ProseMapAnswers.Key(type, prose: prose, target: target, context: context)
        let answer = ProseMapAnswers.answer(for: key)
        // An answer read is the shape's last, as one it asked for is: a copy's words, or those undo
        // brought back, keep their links as they're typed.
        if let answer, next.latest?.links != answer.links {
            clock += 1
            next.latest = (answer.links, clock)
        }
        let source = answer.map { Source.answer($0.number) } ?? next.latest.map { Source.latest($0.number) }
        let map: ProseMap<T>?
        if let kept = next.shown, kept.source == source, Self.same(kept.prose, prose), Self.same(kept.target, target) {
            map = kept.map as? ProseMap<T>
        } else if let links = answer?.links ?? next.latest?.links {
            map = place(links, prose: prose, target: target, in: &next)
        } else {
            map = nil
        }
        let want = answer == nil && !key.prose.isEmpty ? Want(place: Want.Place(shape: shape, target: kind), key: key, type: type) : nil
        next.shown = Shown(prose: prose, target: target, context: context, answers: ProseMapAnswers.revision, latest: next.latest?.number,
                           source: source, map: map, want: want)
        slots[shape, default: [:]][kind] = next
        if let want, mayAsk(want.key), ready() { wanted[want.place] = want }
        return map
    }

    /// The same text, as a range in one is a range in the other: equal, and as long in UTF-8
    /// (strings `==` calls equal may be written differently, an accent as one scalar or two). The
    /// same string costs no more than a look at its storage.
    private static func same(_ a: String, _ b: String) -> Bool { a == b && a.utf8.count == b.utf8.count }

    /// Whether a pair may be asked about now, as far as what's kept here says: not failed, and not
    /// out already. Looked at before the reader is asked whether it may be.
    private func mayAsk(_ key: ProseMapAnswers.Key) -> Bool { !failed.contains(key) && !cooling.contains(key) && !asking.contains(key) }

    /// The links placed on the texts, found in the target again only if it, or what they lead to,
    /// changed since the last placed.
    private func place<T: ProseTarget>(_ links: [ProseLink<String>], prose: String, target: String, in slot: inout Slot) -> ProseMap<T> {
        let written = links.map(\.address)
        let addresses = written.map { T.Address($0) }
        let located: [Range<String.Index>?]
        if let kept = slot.located, Self.same(kept.target, target), kept.addresses == written {
            located = kept.ranges
        } else {
            var found = T.locate(addresses.compactMap { $0 }, in: target).makeIterator()
            located = addresses.map { $0 == nil ? nil : found.next() ?? nil }
            slot.located = (target, written, located)
        }
        #if DEBUG
        placed += 1
        #endif
        return ProseMap(prose: prose, target: target, quotes: links.map(\.quote), addresses: addresses, located: located)
    }

    /// Changes as the shape's maps do: an answer asked for it landed. Observing it hears only this
    /// shape's.
    public func revision(of shape: ShapeID) -> Int {
        access(keyPath: \.[revision: shape])
        return revisions[shape] ?? 0
    }

    /// Only a key: one key path per shape, under which Observation keeps the observers of that
    /// shape's maps apart from every other shape's.
    private subscript(revision shape: ShapeID) -> Int { revisions[shape] ?? 0 }

    /// How many calls are out, and how many wait their turn.
    public var callsOut: Int { asking.count }
    public var callsWaiting: Int { waiting.count }

    #if DEBUG
    /// How many maps have been placed, debug builds only: reading a map whose texts and answer
    /// didn't change places none.
    @ObservationIgnored public private(set) var placed = 0

    /// Every answer forgotten, process-wide, for tests that need none kept from one before.
    public static func forgetEveryAnswer() { ProseMapAnswers.forgetEverything() }
    #endif

    // MARK: Asking

    /// The frame that read the pairs ended: those that may be asked about are, or wait their turn.
    func frameEnded() {
        guard !wanted.isEmpty else { return }
        let wants = wanted.values
        wanted = [:]
        for want in wants { ask(want) }
        askNext()
    }

    private func ask(_ want: Want) {
        guard let editor, editor.languageModel != nil, editor.editingShapeID != want.place.shape, editor.document[want.place.shape] != nil,
              ProseMapAnswers.answer(for: want.key) == nil, mayAsk(want.key), !waiting.contains(where: { $0.key == want.key }) else { return }
        waiting.append(want)
    }

    private func askNext() {
        guard let model = editor?.languageModel else { return }
        while asking.count < Self.concurrentCalls, !waiting.isEmpty {
            let want = waiting.removeFirst()
            clock += 1
            let number = clock
            asking.insert(want.key)
            let request = ProseMapPrompt.request(want.type, prose: want.key.prose, target: want.key.text, context: want.key.context)
            Task { [weak self] in
                let result: Result<ModelResponse, LanguageModelError>
                do throws(LanguageModelError) {
                    result = .success(try await model.respond(to: request))
                } catch {
                    result = .failure(error)
                }
                self?.land(want, asked: number, result)
            }
        }
    }

    private func land(_ want: Want, asked number: Int, _ result: Result<ModelResponse, LanguageModelError>) {
        asking.remove(want.key)
        if case .success(let response) = result, let links = ProseMapPrompt.links(from: response) {
            ProseMapAnswers.remember(links, for: want.key)
            let shape = want.place.shape
            // A shape that went since keeps nothing; one still here keeps its last answer.
            if var slot = slots[shape]?[want.place.target] {
                if (slot.latest?.number ?? -1) < number {
                    slot.latest = (links, number)
                    slots[shape]?[want.place.target] = slot
                }
                withMutation(keyPath: \.[revision: shape]) { revisions[shape, default: 0] += 1 }
            }
            editor?.setNeedsDisplay()
        } else if case .failure(.cancelled) = result {
            // Nothing said: asked again when it's next read.
        } else if case .failure(let error) = result, error.isTransient {
            // A burst of calls meets a rate limit, a network drops: not for the whole session, but not at once.
            cooling.insert(want.key)
            let key = want.key
            _ = editor?.scheduler.schedule(after: Self.retryDelay) { [weak self] in
                guard let self, cooling.remove(key) != nil else { return }
                editor?.setNeedsDisplay()
            }
        } else {
            failed.insert(want.key)
        }
        askNext()
    }

    /// A key was saved or removed in Settings: what failed may not now, so the canvas draws again
    /// and what it reads with no answer is asked about.
    private func keyDidChange() {
        failed = []
        cooling = []
        editor?.setNeedsDisplay()
    }

    /// The shape went: nothing kept of it stays but its answers, by their texts.
    private func forget(_ shape: ShapeID) {
        slots[shape] = nil
        revisions[shape] = nil
        waiting.removeAll { $0.place.shape == shape }
    }
}

extension ProseMapService: EditorService {
    /// Forgets what's kept of the shapes a commit took out of the file, from the board shown or any
    /// other; one moved to another board keeps its last answer, as its texts did.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard !changes.removed.isEmpty || !changes.elsewhere.isEmpty, !slots.isEmpty || !waiting.isEmpty else { return }
        let file = editor.file
        for shape in changes.removed where file.record(shape) == nil { forget(shape) }
        for shape in changes.elsewhere where file.record(shape) == nil { forget(shape) }
    }

    /// Another board is shown: what a shape on the board left showed is kept (its answers are its
    /// texts'), but nothing waits to be asked for it; a whole file put in place takes every shape
    /// afresh.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        wanted = [:]
        waiting.removeAll { editor.document[$0.place.shape] == nil }
        if change.isFileReplaced { slots = [:] }
    }
}

/// What the model said of each pair of texts, process-wide, as a type's readings are kept:
/// by the target, the prose (trimmed), the target's text and the context, so undo, a copy or a file
/// opened twice finds what it said.
@MainActor
enum ProseMapAnswers {
    struct Key: Hashable, Sendable {
        let target: ObjectIdentifier
        let prose: String
        let text: String
        let context: String
        /// The key hashed once, as it's made: a pair with no answer is looked up on every frame that
        /// draws its shape, and its texts may run to thousands of characters.
        private let hashed: Int

        init<T: ProseTarget>(_ type: T.Type, prose: String, target: String, context: String) {
            self.target = ObjectIdentifier(type)
            self.prose = prose.trimmingCharacters(in: .whitespacesAndNewlines)
            text = target
            self.context = context
            var hasher = Hasher()
            hasher.combine(self.target)
            hasher.combine(self.prose)
            hasher.combine(text)
            hasher.combine(context)
            hashed = hasher.finalize()
        }

        static func == (a: Key, b: Key) -> Bool {
            a.hashed == b.hashed && a.target == b.target && a.prose == b.prose && a.text == b.text && a.context == b.context
        }

        func hash(into hasher: inout Hasher) { hasher.combine(hashed) }
    }

    /// At most this many answers are kept: past it, the quarter kept longest goes.
    static let capacity = 1024
    /// Changes whenever an answer is kept or let go.
    private(set) static var revision = 0
    private static var answers: [Key: (links: [ProseLink<String>], number: Int)] = [:]

    static func answer(for key: Key) -> (links: [ProseLink<String>], number: Int)? { answers[key] }

    static func remember(_ links: [ProseLink<String>], for key: Key) {
        revision += 1
        answers[key] = (links, revision)
        if answers.count > capacity {
            let old = answers.sorted { $0.value.number < $1.value.number }.prefix(capacity / 4).map(\.key)
            for key in old { answers[key] = nil }
        }
    }

    #if DEBUG
    static func forgetEverything() {
        answers = [:]
        revision += 1
    }
    #endif
}

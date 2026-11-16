import Canvas
import Foundation
import QueryLanguage

// What a stored query names, by identity. A query written from words names shapes by their titles (`:is-a("Task")`), and
// a title is only what a shape is called today. These two functions let a caller that keeps a query remember which shapes
// the titles named when it was written (`bindNames(in:)`) and read the query by those shapes whatever they are called
// now (`named(_:by:as:)`): the engine's, so any module that keeps a stored query (Constraints, later a rule's phrases) uses
// them, and no plugin finds title heads by hand.
//
// A title head is a compound's head that is a title, `"Task"`, or a kind and a title, `note"Task"`, at any depth: in a
// complex selector's compounds (the container side too), `:not`, `:is`, `:where`, `:inside`, `:has`, the edge words'
// anchors, and the argument of a plugin's relation (`:is-a("Task")`, read as selectors, as resolution reads it). Never a
// word's text argument (`:drawn-by("Plans")`, `:contains("…")`), an attribute's value (`[title="Task"]`) or an edge type.
// A head is keyed by what it says: a title by its text, escapes undone (`Task`), a kind and a title by the head as the
// language prints it (`note"Task"`), so one title written two ways is two keys.

/// How `named(_:by:as:)` writes the title heads it has a shape for.
public enum QueryNameForm: Sendable {
    /// By id, `#7C1E…`, while the shape is in the file, else as written: what a query is judged by.
    case ids
    /// By the shape's title now, while it is in the file and has one, else as written: what a person reads.
    case titles
}

/// The title heads of a tree, found and changed in place: the one walk the two functions share.
struct TitleHeads {
    /// The words whose argument reads as selectors (a plugin's relations), as resolution reads it.
    let relations: Set<String>

    /// A head's key, nil for a head that is no title.
    static func key(of head: Head) -> String? {
        switch head {
        case .title(let title, _): title
        case .kindTitle: head.canonical
        case .kind, .any, .id: nil
        }
    }

    /// `list` with every title head `change` gives another head for written as that one.
    func rewrite(_ list: SelectorList, _ change: (Head) -> Head?) -> SelectorList {
        var list = list
        for index in list.selectors.indices { list.selectors[index] = rewrite(list.selectors[index], change) }
        return list
    }

    func rewrite(_ selector: ComplexSelector, _ change: (Head) -> Head?) -> ComplexSelector {
        var selector = selector
        for index in selector.compounds.indices { selector.compounds[index] = rewrite(selector.compounds[index], change) }
        return selector
    }

    func rewrite(_ compound: Compound, _ change: (Head) -> Head?) -> Compound {
        var compound = compound
        if let head = compound.head, Self.key(of: head) != nil, let changed = change(head) { compound.head = changed }
        for index in compound.filters.indices {
            guard case .pseudo(var pseudo) = compound.filters[index] else { continue }
            pseudo.argument = rewrite(pseudo.argument, of: pseudo, change)
            compound.filters[index] = .pseudo(pseudo)
        }
        return compound
    }

    private func rewrite(_ argument: PseudoArgument, of pseudo: PseudoClass, _ change: (Head) -> Head?) -> PseudoArgument {
        switch argument {
        case .none, .types, .text:
            return argument
        case .selectors(let list):
            return .selectors(rewrite(list, change))
        case .has(let items):
            return .has(items.map { HasItem(child: $0.child, compound: rewrite($0.compound, change)) })
        case .anchored(let anchors, let types):
            return .anchored(anchors.map { rewrite($0, change) }, types: types)
        case .raw(_, let span):
            // A relation's argument is shapes; any other word's raw argument is text or refused, and has no title head.
            guard relations.contains(pseudo.name), let list = try? SelectorList(argumentOf: pseudo) else { return argument }
            let rewritten = rewrite(list, change)
            return rewritten == list ? argument : .raw(rewritten.canonical, span)
        }
    }
}

extension QueryState {
    /// The words whose argument is shapes: the plugins' relations, edge-based or answered from a fact of the file.
    private var titleHeads: TitleHeads {
        TitleHeads(relations: Set(vocabulary.contributedWords.values.compactMap { declared in
            switch declared.meaning {
            case .relation, .fileRelation: declared.word
            case .pseudoClass: nil
            }
        }))
    }

    /// What `text` names by title, bound now: each title head it holds (see above for where; each key once) mapped to
    /// the one shape of the file the engine matches that head to now (a head in `kept` keeps its shape). A title is folded and matched as the engine folds
    /// and matches one (the names point's `fold`, against each shape's name, named or derived, of the shapes on boards the
    /// app can show); a kind and a title is the shapes of that kind so titled. A head that names none, or several, is
    /// left out, and so is a text that doesn't read. Meant for a write: it reads the file's names once, and nothing when
    /// the text holds no title head (never per frame or per commit). On the main actor, never observing the document.
    public func bindNames(in text: String, keeping kept: [String: ShapeID] = [:]) -> [String: ShapeID] {
        guard let editor, let naming = vocabulary.naming, let list = try? SelectorList(parsing: text) else { return [:] }
        var wanted: [String: [(key: String, kind: ShapeKind?)]] = [:]
        _ = titleHeads.rewrite(list) { head in
            switch head {
            case .title(let title, _):
                wanted[naming.fold(title) ?? title, default: []].append((title, nil))
            case .kindTitle(let kind, _, let title, _):
                wanted[naming.fold(title) ?? title, default: []].append((head.canonical, ShapeKind(rawValue: kind)))
            case .kind, .any, .id:
                break
            }
            return nil
        }
        guard !wanted.isEmpty else { return [:] }
        var found: [String: ShapeID] = [:], several: Set<String> = []
        editor.withoutObservingDocument {
            let file = editor.file
            for board in file.showableBoards(boardOwningKinds: registry.boardOwningKinds) {
                for record in file[board].shapes where !record.isOpaque {
                    guard let entry = vocabulary.kind(record.kind) else { continue }
                    let name: String?
                    switch entry.names {
                    case .named: name = naming.named(record)
                    case .derived: name = naming.derived(record, registry)
                    case .none: name = nil
                    }
                    guard let name, let heads = wanted[name] else { continue }
                    for head in heads where head.kind == nil || head.kind == record.kind {
                        if let first = found[head.key], first != record.id { several.insert(head.key) } else { found[head.key] = record.id }
                    }
                }
            }
        }
        for key in several { found[key] = nil }
        // A head the caller says is the shape it named (a title the person didn't touch) stays that shape, whatever else is
        // called the same now, while the shape is in the file.
        for key in kept.keys where wanted.values.contains(where: { $0.contains { $0.key == key } }) {
            if let id = kept[key], editor.withoutObservingDocument({ visibleKind(of: id) }) != nil { found[key] = id }
        }
        return found
    }

    /// `text` with each title head `names` has a shape for written by that shape (`form`): the canonical form
    /// `checkStored` stores. A head the binding doesn't hold, or whose shape isn't in the file (gone, kept aside, on a
    /// board the app can't show), or in `.titles` has no title now, stays as written; a kind and a title bound is
    /// written `#id` alone as the language has one head, or the kind with the title now. A text that doesn't read comes
    /// back as it was. Reads the shapes named only, observing nothing (the caller that shows the text watches the shapes
    /// it names).
    public func named(_ text: String, by names: [String: ShapeID], as form: QueryNameForm) -> String {
        guard let list = try? SelectorList(parsing: text) else { return text }
        return written(list, by: names, as: form).list.canonical
    }

    /// The keys the heads of `text` that `names` binds have once written in the `.titles` form: the key a person's box shows
    /// each of them under now (a shape renamed is keyed by its new title). A head with no title now isn't there.
    public func shownKeys(in text: String, by names: [String: ShapeID]) -> [String: String] {
        guard let list = try? SelectorList(parsing: text) else { return [:] }
        return written(list, by: names, as: .titles).keys
    }

    private func written(_ list: SelectorList, by names: [String: ShapeID], as form: QueryNameForm) -> (list: SelectorList, keys: [String: String]) {
        guard let editor else { return (list, [:]) }
        let naming = vocabulary.naming
        var keys: [String: String] = [:]
        let written = titleHeads.rewrite(list) { head in
            guard let key = TitleHeads.key(of: head), let id = names[key] else { return nil }
            switch form {
            case .ids:
                guard editor.withoutObservingDocument({ visibleKind(of: id) }) != nil else { return nil }
                return .id(id.rawValue, headSpan(head))
            case .titles:
                // Reads the file without observing it: a caller that must follow a rename observes the shapes it names itself.
                guard let title = editor.withoutObservingDocument({ () -> String? in
                    guard let kind = visibleKind(of: id), let naming, let title = Self.title(of: id, kind: kind, editor: editor, naming: naming, vocabulary: vocabulary, registry: registry) else { return nil }
                    return title
                }) else { return nil }
                let changed: Head
                switch head {
                case .kindTitle(let kind, let kindSpan, _, let titleSpan): changed = .kindTitle(kind, kindSpan, title: title, titleSpan)
                default: changed = .title(title, headSpan(head))
                }
                keys[key] = TitleHeads.key(of: changed)
                return changed
            }
        }
        return (written, keys)
    }

    private func headSpan(_ head: Head) -> QuerySpan {
        switch head {
        case .title(_, let span), .id(_, let span), .kind(_, let span): span
        case .kindTitle(_, let span, _, _): span
        case .any: QuerySpan(offset: 0, length: 0)
        }
    }

    /// The kind of a shape the engine ranges over, by id; nil for one it doesn't.
    private func visibleKind(of id: ShapeID) -> ShapeKind? {
        guard let editor else { return nil }
        let file = editor.file
        guard let board = file.board(containing: id), editor.canShow(board), let record = file.record(id), !record.isOpaque,
              vocabulary.kind(record.kind) != nil else { return nil }
        return record.kind
    }

    /// A shape's name as the names point has it; nil for none.
    private static func title(of id: ShapeID, kind: ShapeKind, editor: CanvasEditor, naming: QueryNaming, vocabulary: QueryVocabulary,
                              registry: Registry) -> String? {
        guard let record = editor.file.record(id), let entry = vocabulary.kind(kind) else { return nil }
        switch entry.names {
        case .named: return naming.named(record)
        case .derived: return naming.derived(record, registry)
        case .none: return nil
        }
    }
}

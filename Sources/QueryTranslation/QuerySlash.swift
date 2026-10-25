import Canvas
import Queries
import QueryLanguage
import Selection
import SlashCommands

// `/query`: a question in English typed in the command bar, and the shapes it finds selected. The question
// becomes a query as `canvas query --ask`'s does (`QueryTranslator.translate`, the person's: the prompt, the
// vocabulary, where the person is and what they selected, the titles, the file's types), and the shapes that
// query matches are selected, so the next command acts on them. A face of the translator's in the window,
// so a plugin value of its own: a list with the translator need not have the bar.

extension PluginID {
    public static let querySlash: PluginID = "query-slash"
}

/// `/query <question>` in the command bar (`SelectionSlashCommand`): with several shapes selected it narrows
/// them to those the question finds; with nothing selected it asks the whole file, and selects what it finds
/// on the board shown, or, with none there, on the first board that has some, shown as following a mention
/// shows it (one step back). Never on one shape, nor in a shape's text. The bar waits for the model, says
/// "No matches" or the model's failure in its own words where it would, and closes once something is selected.
/// Every plugin list with it needs `SlashCommandsPlugin` (whose point it fills) and, to answer,
/// `QueryTranslationPlugin`, `QueriesPlugin`, a language model and `SelectionPlugin`.
public struct QuerySlashPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .querySlash }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.selectionSlashCommand(SelectionSlashCommand(QuerySlash.name, argument: QuerySlashStyle.argument, waiting: QuerySlashStyle.asking,
                                                              when: { target, editor in QuerySlash.offers(target, in: editor) },
                                                              answer: { target, arguments, editor in QuerySlash.answer(target, arguments, in: editor) }))
    }
}

/// What `/query` does.
@MainActor
enum QuerySlash {
    static let name = "query"

    /// Several shapes selected, or nothing selected while the file has a shape (the whole file is asked,
    /// whatever the board shown holds); never one shape, nor a line of a shape's text.
    static func offers(_ target: SlashTarget, in editor: CanvasEditor) -> Bool {
        switch target {
        case .text: false
        case .selection(let ids): ids.count > 1
        case .everything: editor.file.shapeCount > 0
        }
    }

    /// The question as the translator is asked it: what was typed, a pill as the name it shows in quotes, as
    /// the language writes a title.
    static func question(_ arguments: SlashArguments) -> String {
        arguments.runs.map { run in
            switch run {
            case .text(let text): text
            case .shape(_, let label): AskRequest.quoted(label)
            }
        }.joined()
    }

    /// The task the bar waits for: the question translated (the person's: with nothing selected as `--ask` asks it, on a
    /// selection told that only what it picks out of the selection is kept), the query's matches found, narrowed to the
    /// selection for a selection, and selected (`select`). It holds the
    /// translator and the engine, which hold the editor weakly, and the editor weakly, so a file closed while
    /// it waits goes. Cancelled (the bar closed, the line changed), it says nothing more.
    static func answer(_ target: SlashTarget, _ arguments: SlashArguments, in editor: CanvasEditor) -> Task<SlashAnswer, Never> {
        let question = question(arguments)
        let translator = editor.queryTranslator, queries = editor.queries
        let selection: Set<ShapeID>? = if case .selection(let ids) = target { Set(ids) } else { nil }
        return Task { @MainActor [weak editor] in
            guard let queries else { return .failed(QueryTranslationError.noQueries.message) }
            guard let translator else { return .failed(QueryTranslationError.noModel.message) }
            let query: String
            do throws(QueryTranslationError) {
                query = try await translator.translate(question, about: selection == nil ? .person : .selection).query
            } catch {
                return error == .cancelled ? .done : .failed(QuerySlashStyle.failure(error))
            }
            // Stopped, or the file closed, while the model answered: nothing to find or select.
            guard !Task.isCancelled, editor != nil else { return .done }
            let request = QueryMatchRequest(query, limit: QueryMatchRequest.every, admitting: { selection?.contains($0.id) ?? true })
            let found: QueryMatches
            switch await queries.matches([request]).first {
            case .success(let matches)?: found = matches
            case .failure(let error)?: return error.reason == .cancelled ? .done : .failed(error.message)
            case nil: return .done
            }
            guard !Task.isCancelled, let editor else { return .done }
            guard !found.ids.isEmpty else { return .failed(QuerySlashStyle.noMatches) }
            return select(found.ids, in: editor) ? .done : .failed(QuerySlashStyle.notSelectable)
        }
    }

    /// Selects what the question found (`editor.goTo`): the matches on the board shown, if any are; else those
    /// on the first board in the file's order that has some, which it shows. VoiceOver hears how many were
    /// selected, and how many more are on other boards. False when none of them could be selected (a kind that
    /// can't be), which the bar says.
    static func select(_ ids: [ShapeID], in editor: CanvasEditor) -> Bool {
        let file = editor.file, shown = editor.board
        let here = ids.filter { file.board(containing: $0) == shown }
        editor.goTo(here.isEmpty ? ids : here)
        let board = editor.board
        let selected = Set(editor.selectedShapeIDs).intersection(ids).count
        guard selected > 0 else { return false }
        let elsewhere = ids.count(where: { file.board(containing: $0) != board })
        editor.announce(QuerySlashStyle.selected(selected, elsewhere: elsewhere))
        return true
    }
}

/// `/query`'s words.
@MainActor
enum QuerySlashStyle {
    /// The hint beside its name in the list.
    static let argument = "question"
    /// What VoiceOver hears while the model is asked.
    static let asking = "Asking"
    /// Nothing the query found is among the shapes it was asked of, as every list says it.
    static let noMatches = "No matches"
    /// What it found can't be selected (a kind that opted out of selection).
    static let notSelectable = "Can’t select what it found"

    /// How a translation failed, in the bar: the model's own words, a deadline's in two.
    static func failure(_ error: QueryTranslationError) -> String {
        if case .tooSlow = error { return "Too slow" }
        return error.message
    }

    /// "4 shapes selected", "1 shape selected, 3 more on other boards".
    static func selected(_ count: Int, elsewhere: Int) -> String {
        let said = count == 1 ? "1 shape selected" : "\(count) shapes selected"
        return elsewhere > 0 ? said + ", \(elsewhere) more on other boards" : said
    }
}

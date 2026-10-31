import AppKit
import Canvas
import DetailPanel
import SwiftUI

/// What words found, as the line under them says it (a rule's chip's): the query they became, colored and editable in
/// place as code (with completions; written as the keyboard leaves it or on ⌘↩, if the engine reads it, else its
/// refusal under it), the sample shape it was asked for, with ‹ › to the one before and after, when the query
/// is bound to the shape checked (`:scope`), and what it found for that sample by name, a container found followed by
/// what it holds, then how many more, or that it found nothing; while the words are asked about, or failed, what every
/// host of words says (`InterpretationStatus`), with its button.
public struct QueryPreview: View {
    /// What the line says.
    public struct Content: Equatable {
        /// The query, once there is one.
        public var query: String?
        /// The words' state while they're asked about, or why they're no query.
        public var status: InterpretationStatus?
        /// What the query was asked for, for a query bound to the shape checked: the sample's name, and how many samples
        /// there are to step through.
        public var sample: String?
        public var samples: Int
        /// What it found for the sample (nil while it's being found), how many more, and the engine's refusal of it.
        public var rows: [FoundRow]?
        public var more: Int
        public var refusal: String?
        /// Words with no query that nobody is asking about (asked before the file was last opened, say): Interpret.
        public var offersInterpret: Bool

        public init(query: String?, status: InterpretationStatus? = nil, sample: String? = nil, samples: Int = 0, rows: [FoundRow]? = nil,
                    more: Int = 0, refusal: String? = nil, offersInterpret: Bool = false) {
            self.query = query
            self.status = status
            self.sample = sample
            self.samples = samples
            self.rows = rows
            self.more = more
            self.refusal = refusal
            self.offersInterpret = offersInterpret
        }
    }

    /// What the line's buttons and keys do: a row followed, the sample stepped (by -1 or 1), the words edited, the query
    /// written by hand (the engine's refusal, or nil once it's written), the words asked again.
    public struct Actions {
        public var follow: @MainActor (ShapeID) -> Void
        public var step: @MainActor (Int) -> Void
        public var editWords: @MainActor () -> Void
        public var writeQuery: @MainActor (String) -> String?
        public var retry: @MainActor () -> Void
        public var interpret: @MainActor () -> Void
        public var completions: DetailCodeCompleting?

        public init(follow: @escaping @MainActor (ShapeID) -> Void, step: @escaping @MainActor (Int) -> Void, editWords: @escaping @MainActor () -> Void,
                    writeQuery: @escaping @MainActor (String) -> String?, retry: @escaping @MainActor () -> Void,
                    interpret: @escaping @MainActor () -> Void = {}, completions: DetailCodeCompleting? = nil) {
            self.follow = follow
            self.step = step
            self.editWords = editWords
            self.writeQuery = writeQuery
            self.retry = retry
            self.interpret = interpret
            self.completions = completions
        }
    }

    let content: Content
    let actions: Actions
    weak var editor: CanvasEditor?
    @State private var editing: String?
    @State private var refused: String?

    public init(_ content: Content, editor: CanvasEditor?, actions: Actions) {
        self.content = content
        self.editor = editor
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InterpretationStyle.previewSpacing) {
            if let query = content.query {
                DetailCodeEditor(Binding(get: { editing ?? query }, set: { editing = $0 }), height: InterpretationStyle.queryBoxHeight,
                                 coloring: QueryColoring.spans, completions: actions.completions, label: InterpretationWords.query) {
                    finishEditing(from: query)
                }
                if let refused { DetailStatusLine(DetailStatus(refused, tone: .warning)) }
            }
            if let status = content.status {
                DetailStatusLine(DetailStatus(status.words, tone: status.isBusy ? .neutral : .warning), isBusy: status.isBusy, actions: buttons(for: status))
            } else if content.query == nil, content.offersInterpret {
                Button(InterpretationWords.interpret) { actions.interpret() }
                    .buttonStyle(.link)
                    .font(.system(size: InterpretationStyle.captionSize))
            } else if content.query != nil {
                if let sample = content.sample { SampleLine(sample: sample, samples: content.samples, step: actions.step) }
                if let refusal = content.refusal {
                    DetailStatusLine(DetailStatus(refusal, tone: .warning))
                } else if let rows = content.rows {
                    if rows.isEmpty {
                        Text(InterpretationWords.findsNothing).font(.system(size: InterpretationStyle.captionSize)).foregroundStyle(.secondary)
                    } else {
                        FoundRows(rows, more: content.more, editor: editor, follow: actions.follow)
                    }
                }
                // The query is edited in its box above; the words, in theirs.
                Button(InterpretationWords.editWords) { actions.editWords() }
                    .buttonStyle(.link)
                    .font(.system(size: InterpretationStyle.captionSize))
            }
        }
    }

    /// What a status line offers: Open Settings… for a key, Edit Words where the words are no query, else Retry.
    private func buttons(for status: InterpretationStatus) -> [DetailStatusAction] {
        switch status {
        case .noQuery: [DetailStatusAction(InterpretationWords.editWords, perform: actions.editWords)]
        default: status.action.map { [$0.button(retry: actions.retry)] } ?? []
        }
    }

    private func finishEditing(from shown: String) {
        guard let text = editing else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != shown, !query.isEmpty else {
            editing = nil
            refused = nil
            return
        }
        if let refusal = actions.writeQuery(query) {
            refused = refusal
        } else {
            editing = nil
            refused = nil
        }
    }
}

/// The sample a bound query was asked for, with ‹ › to the one before and after (← → while it has the keyboard).
struct SampleLine: View {
    let sample: String
    let samples: Int
    let step: @MainActor (Int) -> Void

    var body: some View {
        HStack(spacing: InterpretationStyle.previewSpacing) {
            Text(InterpretationWords.sample(sample)).font(.system(size: InterpretationStyle.captionSize)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if samples > 1 {
                Button { step(-1) } label: { Image(systemName: InterpretationStyle.previousSample) }
                    .accessibilityLabel(InterpretationWords.previousSample)
                Button { step(1) } label: { Image(systemName: InterpretationStyle.nextSample) }
                    .accessibilityLabel(InterpretationWords.nextSample)
            }
        }
        .buttonStyle(.borderless)
        .focusable(samples > 1)
        .onMoveCommand { direction in
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(InterpretationWords.sample(sample))
    }
}

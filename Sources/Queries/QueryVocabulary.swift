import Canvas
import QueryLanguage
import Topology

/// What this app's queries can name, read off the registry once (it never changes) and kept, to be
/// read anywhere: each kind with what it's called, whether its shapes are named and how, whether
/// they hold shapes and whether a board of them (and what an untitled one's board is called), and
/// its attributes with what each takes; the edge types, as a tree; and the words, the language's and
/// the plugins'. Its `text` is the `<vocabulary>` block `--ask` sends the model, and what `canvas
/// query-vocabulary` prints.
///
/// An editor's is `queries.vocabulary`, made on its first query; the command that answers for no
/// board makes one from a registry alone.
public struct QueryVocabulary: Sendable {
    /// A kind, as queries see it.
    public struct KindEntry: Sendable {
        public let kind: ShapeKind
        /// What the app calls it (`registry.label(of:)`): "Note".
        public let label: String
        /// Whether its shapes have names, and how (the names point's).
        public let names: QueryNameSource
        /// Whether its shapes can have shapes inside them (Topology's `containerKinds`): a board of
        /// them (`holdsBoard`, a subboard), or shapes on the board they're on (a frame). What can
        /// stand where a container goes (before a space or `>`, in `:inside()`, what `:has()` is on).
        public let holdsShapes: Bool
        /// Whether they hold shapes by owning a board of them (`registry.boardOwningKinds`).
        public let holdsBoard: Bool
        /// What the board of one whose owner has no name is called: the board names point's
        /// placeholder, else the label. Nil for a kind that holds no board.
        public let boardName: String?
        /// What a query can test on its shapes, by name.
        public let attributes: [AttributeEntry]
        /// Its schema, read.
        public let schema: KindSchema

        /// Its attribute of this name, if it has one.
        public func attribute(_ name: String) -> AttributeEntry? {
            attributes.first { $0.name == name }
        }
    }

    /// An attribute of a kind: a property of its schema, or the names point's word.
    public struct AttributeEntry: Sendable {
        public let name: String
        /// What its values are.
        public let shape: KindSchema.PropertyShape
        /// What it takes, said briefly (`KindSchema.compactType`): `todo|doing|blocked|done`.
        public let compactType: String
        /// Whether it's the names point's word, read through the names point: a derived name is an
        /// attribute too.
        public let isName: Bool
        /// How its text reads, when a text format reads it ("mentions read as @Name").
        public let reads: String?
        /// The media type of its text (its items', for a list), when a text format reads it.
        public let mediaType: String?
    }

    /// An edge type, in the tree's order.
    public struct EdgeTypeEntry: Sendable {
        public let type: EdgeTypeID
        /// The type it's a kind of; nil for a root.
        public let parent: EdgeTypeID?
        public let summary: String?
        /// How deep it is: 0 for a root.
        public let depth: Int
    }

    /// A pseudo-class a query can use: the language's own, then plugins'.
    public struct WordEntry: Sendable {
        /// Without its colon: `edge-to`.
        public let word: String
        /// How it's written, with what its parentheses take: `:edge-to(S[, types])`.
        public let form: String
        /// What its parentheses take, in a few words: "nothing", "shapes".
        public let takes: String
        /// What it means, lowercase, no period.
        public let summary: String
        /// A query that uses it.
        public let example: String
        /// The plugin whose word it is (the language's own are `queries`').
        public let from: PluginID
        /// Whether its verdict reads the editor (the person's selection, the board shown, a live
        /// verdict): a query that stands alone, stored and run later, can't use it.
        public let readsEditor: Bool
    }

    /// In registry order.
    public let kinds: [KindEntry]
    /// In the tree's order: each root in plugin order, followed by the types under it.
    public let edgeTypes: [EdgeTypeEntry]
    /// The language's words, then plugins', in plugin order.
    public let words: [WordEntry]
    /// The `<vocabulary>` block: kinds, edge types and plugins' words, as `canvas query-vocabulary`
    /// prints it.
    public let text: String

    // What resolving and answering a query take from it.

    /// The names point's contribution, if one.
    let naming: QueryNaming?
    /// Text formats, by media type.
    let textFormats: [String: QueryTextFormatting]
    /// Plugins' words, by word.
    let contributedWords: [String: QueryWordDeclaration]
    /// The edge types installed plugins declare, as a tree.
    let edgeTree: EdgeTypeTree

    /// The declaration of the word a plan keeps under `key` (the word, or, for one that takes a text, the word with it).
    func declaration(forKey key: String) -> QueryWordDeclaration? { contributedWords[WordKey.word(of: key)] }
    /// The kinds whose shapes can have shapes inside them: a board of them, or shapes on theirs.
    let containerKinds: Set<ShapeKind>
    private let kindIndex: [ShapeKind: Int]

    @MainActor
    public init(registry: Registry) {
        let naming = registry.queryNaming
        let boardNaming = registry.queryBoardNaming
        let formats = Dictionary(registry.contributions(to: QueryTextFormats.self).map { ($0.value.mediaType, $0.value) },
                                 uniquingKeysWith: { first, _ in first })
        let containers = registry.containerKinds
        var kinds: [KindEntry] = []
        for kind in registry.kinds {
            let schema = KindSchema(registry.schema(for: kind) ?? JSONSchema([:]))
            let label = registry.label(of: kind).name
            let names = naming?.source(kind, registry) ?? .none
            let holdsBoard = registry.boardOwningKinds.contains(kind)
            var attributes: [AttributeEntry] = []
            for name in schema.properties.keys where !schema.holdsPlace(name) && !schema.isUnlisted(name)
                && !(names != .none && name == naming?.attribute) {
                guard let shape = schema.shape(of: name) else { continue }
                let mediaType = shape.mediaType.flatMap { formats[$0] == nil ? nil : $0 }
                attributes.append(AttributeEntry(name: name, shape: shape, compactType: schema.compactType(of: name), isName: false,
                                                 reads: mediaType.flatMap { formats[$0]?.describes }, mediaType: mediaType))
            }
            if names != .none, let naming {
                let own = schema.properties[naming.attribute] != nil
                attributes.append(AttributeEntry(name: naming.attribute, shape: .string(format: nil, mediaType: nil, choices: nil),
                                                 compactType: own ? schema.compactType(of: naming.attribute) : "text", isName: true,
                                                 reads: nil, mediaType: nil))
            }
            attributes.sort { $0.name < $1.name }
            let boardName = holdsBoard ? boardNaming?.placeholder(kind, registry) ?? label : nil
            kinds.append(KindEntry(kind: kind, label: label, names: names, holdsShapes: containers.contains(kind), holdsBoard: holdsBoard,
                                   boardName: boardName, attributes: attributes, schema: schema))
        }

        let tree = registry.edgeTypes
        var edgeTypes: [EdgeTypeEntry] = []
        func add(_ type: EdgeTypeID, depth: Int) {
            edgeTypes.append(EdgeTypeEntry(type: type, parent: tree.parent(of: type), summary: tree.summary(of: type), depth: depth))
            for child in tree.children(of: type) { add(child, depth: depth + 1) }
        }
        for type in tree.declared where tree.parent(of: type) == nil { add(type, depth: 0) }

        var contributed: [String: QueryWordDeclaration] = [:]
        var words = Word.allCases.map(\.entry)
        for declared in registry.contributions(to: QueryWords.self) {
            let value = declared.value
            contributed[value.word] = value
            words.append(WordEntry(word: value.word, form: value.form, takes: value.takes, summary: value.summary, example: value.example,
                                   from: declared.pluginID, readsEditor: value.reads.contains(.editor)))
        }

        self.kinds = kinds
        self.edgeTypes = edgeTypes
        self.words = words
        self.naming = naming
        textFormats = formats
        contributedWords = contributed
        edgeTree = tree
        containerKinds = containers
        kindIndex = Dictionary(kinds.enumerated().map { ($1.kind, $0) }, uniquingKeysWith: { first, _ in first })
        text = Self.text(kinds: kinds, edgeTypes: edgeTypes, words: words.filter { $0.from != .queries })
    }

    /// A kind, if the app has it.
    public func kind(_ kind: ShapeKind) -> KindEntry? {
        kindIndex[kind].map { kinds[$0] }
    }

    /// The word the names point tests names with (`title`); nil when nothing names shapes.
    public var nameAttribute: String? { naming?.attribute }

    // MARK: The text

    /// The `<vocabulary>` block for a query that is stored and run later by something that has no
    /// person looking, with every word that reads the editor left out (`WordEntry.readsEditor`):
    /// what translating the words of a reference is told.
    public var textForStoredQueries: String {
        Self.text(kinds: kinds, edgeTypes: edgeTypes, words: words.filter { $0.from != .queries && !$0.readsEditor })
    }

    /// The `<vocabulary>` block's text: what `--ask` tells the model this app's queries can name.
    private static func text(kinds: [KindEntry], edgeTypes: [EdgeTypeEntry], words: [WordEntry]) -> String {
        var lines = ["Kinds (the id to write; what the app calls it; its attributes and what each takes):"]
        for entry in kinds {
            var about = [entry.label, entry.names.described]
            if entry.holdsBoard {
                about.append("holds a board of shapes")
            } else if entry.holdsShapes {
                about.append("holds shapes")
            }
            let attributes = entry.attributes.map { "\($0.name) \($0.compactType)" + ($0.reads.map { " (\($0))" } ?? "") }
            lines.append("- \(entry.kind) (\(about.joined(separator: "; ")))" + (attributes.isEmpty ? "" : ": " + attributes.joined(separator: ", ")))
        }
        if !edgeTypes.isEmpty {
            lines.append("Edge types (each takes in those indented under it):")
            for entry in edgeTypes {
                lines.append(String(repeating: "  ", count: entry.depth) + "- \(entry.type)" + (entry.summary.map { " — \($0)" } ?? ""))
            }
        }
        if !words.isEmpty {
            lines.append("Pseudo-classes plugins add:")
            for entry in words {
                lines.append("- \(entry.form) — \(entry.summary). Example: \(entry.example)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension QueryNameSource {
    /// As the vocabulary says it.
    var described: String {
        switch self {
        case .none: "untitled"
        case .named: "titled"
        case .derived: "titled from what it holds"
        }
    }
}

extension KindSchema.PropertyShape {
    /// The media type of its text, or its items' for a list of text.
    var mediaType: String? {
        switch self {
        case .string(_, let mediaType, _): mediaType
        case .array(let items): items.mediaType
        default: nil
        }
    }
}

extension QueryWordDeclaration {
    /// `:word` for a pseudo-class, `:word(S)` for a relation.
    var form: String {
        switch meaning {
        case .pseudoClass: argument == nil ? ":\(word)" : ":\(word)(\"…\")"
        case .relation, .fileRelation: ":\(word)(S)"
        }
    }

    /// What its parentheses take, as the language says it of its own words of the same signature.
    var takes: String {
        switch meaning {
        case .pseudoClass: argument ?? Word.Signature.none.takes
        case .relation, .fileRelation: Word.Signature.selectors.takes
        }
    }
}

// MARK: The language's words

extension Word {
    /// The word as the vocabulary lists it.
    var entry: QueryVocabulary.WordEntry {
        QueryVocabulary.WordEntry(word: rawValue, form: form, takes: takes, summary: summary, example: example, from: .queries,
                                  readsEditor: self == .currentBoard)
    }

    /// How it's written: `:edge-to(S[, types])`.
    var form: String {
        switch signature {
        case .none: ":\(rawValue)"
        case .selectors: ":\(rawValue)(S)"
        case .has: ":\(rawValue)(S), :\(rawValue)(> S)"
        case .anchor: ":\(rawValue)(S[, types])"
        case .twoAnchors: ":\(rawValue)(A, B[, types])"
        case .types: ":\(rawValue)[(types)]"
        case .text: ":\(rawValue)(\"text\")"
        }
    }

    /// What it means, of the shape it's on.
    var summary: String {
        switch self {
        case .not: "not matched by S"
        case .is: "matched by S"
        case .where: "matched by S, as :is"
        case .has: "has a shape S matches inside it, at any depth; after >, directly inside it"
        case .inside: "inside a shape S matches, at any depth"
        case .topLevel: "inside nothing: on the file's top board, held by no shape"
        case .currentBoard: "on the board the file's window shows"
        case .edgeTo: "has an edge to a shape S matches"
        case .edgeFrom: "has an edge from a shape S matches"
        case .connectedTo: "has an edge to or from a shape S matches"
        case .downstreamOf: "reached from a shape S matches by edges followed forward"
        case .upstreamOf: "reaches a shape S matches by edges followed forward"
        case .componentOf: "joined to a shape S matches by edges either way, however many"
        case .startsAt: "a connection that starts at a shape S matches"
        case .endsAt: "a connection that ends at a shape S matches"
        case .startOf: "the shape a connection S matches starts at"
        case .endOf: "the shape a connection S matches ends at"
        case .between: "a connection joining a shape A matches and one B matches"
        case .dangling: "carries an edge to a shape that isn't there"
        case .contains: "its name or the text of an attribute holds the text, ignoring case"
        }
    }
}

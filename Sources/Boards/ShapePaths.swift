import Canvas
import FuzzyMatching
import Titles
import Topology

/// Where a shape is in its file, and what it is called there: the names of the containers it is
/// inside (frames, and the shapes whose boards hold it), outermost first, then its own title, as
/// "Alpha › Beta › Checkout" says it. The root board is never on it, so a shape on the root in no
/// container has its title alone for a path. Each container is named as every path names one
/// (`registry.containerName(of:)`: its title, else what its kind is called), so an untitled frame is
/// on it as "Frame". What identifies a shape to a person: two shapes may share a title, never a path
/// (`PathValidationPlugin` warns of a path two shapes share).
public struct ShapePath: Hashable, Sendable {
    /// What a path puts between its names, as Jump To's rows and the path over the canvas show it.
    public static let separator = " › "

    /// The containers the shape is inside, outermost first.
    public let containers: [ContainerName]
    /// Its own name: its title.
    public let name: String

    public init(containers: [ContainerName], name: String) {
        self.containers = containers
        self.name = name
    }

    /// "Alpha › Beta › Checkout": the containers' names (their placeholders where untitled), then the
    /// shape's.
    public var text: String { key.text }

    /// What two paths are compared by: their names as said, a placeholder like a title.
    public var key: Key { Key(containers.map(\.text) + [name]) }

    /// Whether the shape is in no container: its path is its title.
    public var isTopLevel: Bool { containers.isEmpty }

    /// A path's names as a path says them, outermost first, the shape's own last: what two shapes
    /// that share a path have equal. A container with no title is its placeholder here, so two "A"s
    /// in two untitled frames share one.
    public struct Key: Hashable, Sendable {
        /// The containers' names, then the shape's.
        public let segments: [String]
        /// Their hash, worked out once: a key is looked up several times for each shape a commit files again.
        private let hash: Int

        public init(_ segments: [String]) {
            self.segments = segments
            hash = segments.hashValue
        }

        public static func == (a: Key, b: Key) -> Bool { a.hash == b.hash && a.segments == b.segments }
        public func hash(into hasher: inout Hasher) { hasher.combine(hash) }

        /// "Alpha › Beta › Checkout".
        public var text: String { segments.joined(separator: ShapePath.separator) }
        /// The shape's own name: the last.
        public var name: String { segments.last ?? "" }
        /// Whether the shape is in no container.
        public var isTopLevel: Bool { segments.count <= 1 }
    }
}

/// The containment tree's names, read once and kept: what each container (a frame, a board's owner)
/// is directly in (Topology's `parent(of:)`), what it is called in a path
/// (`registry.containerName(of:)`) and that name folded for matching (`FuzzyMatcher.Label`, none for
/// an untitled container, which nothing matches). A value a service embeds, one for an editor's file
/// (Jump To's state, the path index): no service of its own, so a list with Jump To and no
/// `BoardsPlugin` keeps it all the same. Kept until a commit changes that container: `forget(_:)`
/// is told each commit, `forgetAll()` a file put in place, and a container is read again the next
/// time a path goes through it.
///
/// Every container's name and parent is the shape's own (its title, its container field, the board
/// it is on), so a commit that changes either names the container, and nothing else need be
/// forgotten: a rename of a frame forgets the frame alone, and what is inside it is found through it
/// as it is now. It reads Topology through `editor.topology`, which hears a commit before it answers;
/// without TopologyPlugin every shape is in no container.
@MainActor
public struct ShapePaths {
    /// A container's place and name.
    public struct Node {
        /// The shape it is directly inside: its container, else the owner of its board; nil on the
        /// root in no container.
        public let parent: ShapeID?
        /// What a path calls it.
        public let name: ContainerName
        /// Its title, folded for a matcher; nil while it has none, as a path's placeholder is never
        /// matched.
        public let label: FuzzyMatcher.Label?
    }

    private unowned let editor: CanvasEditor
    private var nodes: [ShapeID: Node] = [:]

    public init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// How many containers are kept (tests).
    public var count: Int { nodes.count }

    /// A container's place and name, read once and kept until a commit changes it. A shape that isn't
    /// in the file is a node with no parent and no name.
    public mutating func node(_ id: ShapeID) -> Node {
        if let known = nodes[id] { return known }
        let node: Node
        if let record = editor.shape(inFile: id) {
            // Called as every path calls a container (Boards' rule).
            let name = editor.registry.containerName(of: record)
            node = Node(parent: editor.topology?.parent(of: id), name: name, label: name.title.map { FuzzyMatcher.Label($0) })
        } else {
            node = Node(parent: nil, name: ContainerName(title: nil, placeholder: ""), label: nil)
        }
        nodes[id] = node
        return node
    }

    /// The containers a shape is inside, outermost first, as the table of contents' outline and the
    /// path over the canvas have them (Topology's `ancestors(of:)`, the root never one); none for a
    /// shape on the root in no container.
    public func containers(of id: ShapeID) -> [ShapeID] {
        editor.topology?.ancestors(of: id).reversed() ?? []
    }

    /// A shape's path: its containers' names, outermost first (`containers(of:)`), and its title
    /// (`registry.title(of:)`); nil for a shape with no title, or kept aside.
    public mutating func path(of record: AnyShapeRecord) -> ShapePath? {
        guard !record.isOpaque, let title = editor.registry.title(of: record) else { return nil }
        return ShapePath(containers: containers(of: record.id).map { node($0).name }, name: title)
    }

    /// Something worked out along the chain from the root down to `container` (nil: the root, which is
    /// `root` itself): each container's from its parent's through its node (`step`), made once for every
    /// container on the chain and kept in `memo`, so the shapes of one container cost one lookup and
    /// the chain is walked once for all of them. Up the chain to a container whose value is known, the
    /// root, `limit` containers or one met twice (a loop, which no showable shape has: Topology answers
    /// no parent for a shape on a board the app can't show), then down it.
    public mutating func chain<Value>(after container: ShapeID?, root: Value, memo: inout [ShapeID: Value], limit: Int = .max,
                                      _ step: (Value, Node) -> Value) -> Value {
        guard let container else { return root }
        if let known = memo[container] { return known }
        var walked: [ShapeID] = [], met: Set<ShapeID> = [], current: ShapeID? = container, value = root
        while let id = current, walked.count < limit, met.insert(id).inserted {
            if let known = memo[id] {
                value = known
                break
            }
            walked.append(id)
            current = node(id).parent
        }
        for id in walked.reversed() {
            value = step(value, node(id))
            memo[id] = value
        }
        return value
    }

    /// The names of the chain from the root down to `container`, outermost first, `container`'s last:
    /// what a shape directly in it has before its title. Kept in `memo` for the containers on the way.
    public mutating func names(through container: ShapeID?, memo: inout [ShapeID: [String]]) -> [String] {
        chain(after: container, root: [], memo: &memo) { $0 + [$1.name.text] }
    }

    /// A matcher's row after the chain from the root to `container` (nil: the root's, `root`): each
    /// container's made from its parent's through its folded name (`PathMatcher.advance`; an untitled
    /// one a skip), kept in `memo` for the query, so what a container holds is ranked by its path for
    /// one match each (Jump To's ranking of several pieces). Followed up `deepest` containers at most.
    public mutating func row(after container: ShapeID?, _ matcher: PathMatcher, root: PathMatcher.Row,
                             memo: inout [ShapeID: PathMatcher.Row]) -> PathMatcher.Row {
        chain(after: container, root: root, memo: &memo, limit: Self.deepest) { matcher.advance($0, through: $1.label) }
    }

    /// The deepest a matcher's row is followed: a path of more containers is matched by its innermost.
    public static let deepest = 64

    /// Forgets the containers a commit changed: those it removed, added or changed other than by
    /// moving them (a move changes no name and no parent), and those it reached on other boards
    /// (`elsewhere`: a deleted subboard's, a paste's), whichever is fewer to go through.
    public mutating func forget(_ changes: ChangeSet) {
        guard !nodes.isEmpty else { return }
        for id in changes.removed { nodes[id] = nil }
        for id in changes.added where !changes.moved.contains(id) { nodes[id] = nil }
        for id in changes.changed where !changes.moved.contains(id) { nodes[id] = nil }
        guard !changes.elsewhere.isEmpty else { return }
        if nodes.count < changes.elsewhere.count {
            nodes = nodes.filter { !changes.elsewhere.contains($0.key) }
        } else {
            for id in changes.elsewhere { nodes[id] = nil }
        }
    }

    /// Forgets every container: a file put in place, or a catalog made again.
    public mutating func forgetAll() {
        nodes = [:]
    }
}

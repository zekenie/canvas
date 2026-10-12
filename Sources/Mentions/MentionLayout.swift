import Canvas

/// Which kinds lay out by the names their mention text shows now (`registrar.mentionLayout`): an
/// arrow's label is measured for its geometry, which can't read what a mentioned shape is called
/// (it may be on another board), so Mentions hands it the names as a layout input
/// (`MentionLayout.names`) and tells the editor when one changes (`shapesDidChangeLayout`). One per
/// kind; a kind without it is laid out by the names its text holds, as a note's height is.
public enum MentionLayouts {}

extension MentionLayouts: KeyedExtensionPoint {
    public typealias Contribution = MentionLayoutContribution
    public static var owner: PluginID { .mentions }
    public static func uniqueKeys(of _: MentionLayoutContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: MentionLayoutContribution, for target: ShapeTarget) -> String { "mention layout → \(target)" }
}

/// What `MentionLayouts` keeps for a kind: the text its geometry measures.
@MainActor
public struct MentionLayoutContribution {
    let text: @MainActor (AnyShapeRecord) -> MentionText?

    init<P: ShapeProps>(_: P.Type, _ text: @escaping @MainActor (ShapeRecord<P>) -> MentionText) {
        self.text = { record in record.typed(as: P.self).map(text) }
    }
}

extension ShapeRegistrar {
    /// This kind's geometry is measured from its mention text (`text`), by the names the mentions
    /// show now: it reads them with `context.mentionNames(of:)` and measures with them
    /// (`MentionTextStyle.measuredString(_:width:names:)`), nil meaning the names the text holds.
    /// A rename, on this board or another, then lays the shapes that mention it out again, with no
    /// transaction, no undo step and nothing stored.
    ///
    ///     arrow.mentionLayout { $0.props.text }
    public mutating func mentionLayout(_ text: @escaping @MainActor (ShapeRecord<Definition.Props>) -> MentionText) {
        contribute(MentionLayoutContribution(Definition.Props.self, text), to: MentionLayouts.self)
    }
}

/// The layout input Mentions sets.
public enum MentionLayout {
    /// For a shape whose kind lays out by names (`mentionLayout`) and whose mentions show a name
    /// other than the one the text holds: the name each mention shows now, in text order. Absent
    /// when every name is as the text holds it.
    public static let names = LayoutInputKey<[String]>("mention-names")
}

extension ShapeContext {
    /// The names a shape's mentions show now, one for each in text order, when they aren't the
    /// names its text holds (`MentionLayout.names`); nil when they are, or without Mentions.
    public func mentionNames(of id: ShapeID) -> [String]? { layoutInput(MentionLayout.names, for: id) }
}

extension MentionState {
    /// Lays out again the shapes that lay out by names (`mentionLayout`) among `ids`, on any board,
    /// as the names their mentions show are now: a shape whose layout input changes has its
    /// geometry worked out again, nothing stored. Costs the shapes named, a lookup each for those
    /// of kinds that don't opt in.
    func refreshLayout(of ids: some Sequence<ShapeID>) {
        guard !layoutKinds.isEmpty else { return }
        for id in ids {
            guard let record = editor.document[id] ?? editor.shape(inFile: id), layoutKinds.contains(record.kind),
                  let text = registry.contributions(to: MentionLayouts.self, for: record.kind).first?.text(record) else {
                if laidOutByNames.remove(id) != nil { editor.setLayoutInput(MentionLayout.names, nil, for: id) }
                continue
            }
            var names: [String] = [], differs = false
            for run in text.runs {
                guard case .mention(let target, let held) = run else { continue }
                let live = (resolutions[target] ?? resolve(target)).appearance?.label
                names.append(live ?? held)
                if let live, live != held { differs = true }
            }
            if differs {
                laidOutByNames.insert(id)
                editor.setLayoutInput(MentionLayout.names, names, for: id)
            } else if laidOutByNames.remove(id) != nil {
                editor.setLayoutInput(MentionLayout.names, nil, for: id)
            }
        }
    }

    /// Takes back the names of shapes that are gone, or of every shape (a file put in place).
    func forgetLayout(of ids: some Sequence<ShapeID>) {
        for id in ids where laidOutByNames.remove(id) != nil { editor.setLayoutInput(MentionLayout.names, nil, for: id) }
    }
}

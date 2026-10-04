import Canvas

/// Something wrong with the mentions in a shape's text: a mention of a shape that can't be
/// mentioned, or not by that text (its scope), or text that looks like a mention but isn't one.
/// What a rule warns about (`MentionValidationPlugin`), in the words a person reads.
public struct MentionProblem: Hashable, Sendable {
    /// The property the text is in: the shape's own (`text`), or an added one.
    public let property: String
    /// One short sentence.
    public let message: String

    public init(property: String, message: String) {
        self.property = property
        self.message = message
    }
}

extension Registry {
    /// What's wrong with the mentions a shape's text holds, wherever the shape keeps it: for each
    /// text, the targets that can't be mentioned (named as the mention holds them, else by their
    /// kind) or are outside the text's scope (named as they're called now), each once, in text
    /// order, then the text that looks like a mention but isn't one (`lookalikes`). Targets are
    /// found through `lookup` alone, so a caller that keeps what a check read (Validation) knows
    /// what to check again. A target `lookup` doesn't find is nothing wrong, since a missing
    /// shape's pill says so (dashed), and neither is one kept aside, which isn't the app's to
    /// judge. None for a kind whose shapes can't hold names, or a shape kept aside; the same
    /// problem twice in one property is said once.
    public func mentionProblems(of shape: AnyShapeRecord, lookup: (ShapeID) -> AnyShapeRecord?) -> [MentionProblem] {
        guard namingKinds.contains(shape.kind), !shape.isOpaque else { return [] }
        var problems: [MentionProblem] = []
        var said: Set<MentionProblem> = []
        func say(_ message: String, in property: String) {
            let problem = MentionProblem(property: property, message: message)
            if said.insert(problem).inserted { problems.append(problem) }
        }
        shape.forEachNamingValue(in: self) { property, value in
            value.forEachNamingLeaf { leaf in
                guard let text = leaf as? any MentionTextHolding else { return }
                // `AnyMentionable` admits every shape that can be mentioned, so it needn't be asked.
                let isScoped = ObjectIdentifier(text.scope) != ObjectIdentifier(AnyMentionable.self)
                var seen: Set<ShapeID> = []
                text.forEachMentionRun { run in
                    guard case .mention(let id, let held) = run, seen.insert(id).inserted,
                          let target = lookup(id), !target.isOpaque else { return }
                    if !isMentionable(target.kind) {
                        say(MentionProblemCopy.unmentionable(oneLine(held) ?? kindName(of: target.kind)), in: property)
                    } else if isScoped, !text.scope.admits(target, in: self) {
                        say(MentionProblemCopy.outOfScope(mentionAppearance(of: target)?.label ?? held), in: property)
                    }
                }
                for lookalike in text.lookalikes { say(MentionProblemCopy.lookalike(lookalike), in: property) }
            }
        }
        return problems
    }

    /// What a kind is called ("Arrow", `label(of:)`).
    private func kindName(of kind: ShapeKind) -> String { label(of: kind).name }
}

/// The problems' words: short sentences with periods, each name in curly quotes.
enum MentionProblemCopy {
    /// How much of a look-alike a message quotes, in characters, before it's cut with "…".
    static let quoted = 30

    static func unmentionable(_ name: String) -> String { "“\(name)” can’t be mentioned." }
    static func outOfScope(_ name: String) -> String { "“\(name)” can’t be mentioned here." }
    static func lookalike(_ text: String) -> String { "“\(cut(text))” isn’t a mention." }

    /// The text as far as `quoted` characters, then "…" if there's more.
    static func cut(_ text: String) -> String {
        guard text.count > quoted else { return text }
        return text.prefix(quoted).trimmingTrailingWhitespace + "…"
    }
}

extension Substring {
    fileprivate var trimmingTrailingWhitespace: String {
        var end = endIndex
        while end > startIndex, self[index(before: end)].isWhitespace { end = index(before: end) }
        return String(self[startIndex..<end])
    }
}

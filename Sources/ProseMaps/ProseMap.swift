import Foundation

/// Words of the prose and the part of the target they say, as the model answers: the words as the
/// prose writes them, and an address in the target. Kept as it was said, and placed again on the
/// texts as they are (`ProseMap`), so it outlives edits to either that leave it true.
public struct ProseLink<Address: Hashable & Sendable>: Hashable, Sendable {
    /// The words, as the prose writes them.
    public var quote: String
    public var address: Address

    public init(quote: String, address: Address) {
        self.quote = quote
        self.address = address
    }
}

/// Links placed on one pair of texts: each one's words found in the prose (in order, never
/// overlapping: `ProseMapText.anchor`) and its address in the target (`Target.locate`), as the texts
/// are; a link that isn't found on both sides is left out. Immutable, and the same object for as long
/// as what it's placed from is the same (`ProseMapService.map`), so what a reader works out from one
/// (where its words are drawn) is kept by its identity.
public final class ProseMap<Target: ProseTarget>: Sendable {
    /// A link found in both texts.
    public struct Link: Hashable, Sendable {
        /// The words, as the prose writes them, and where they are in it.
        public let quote: String
        public let inProse: Range<String.Index>
        /// The part they say, and where it is in the target.
        public let address: Target.Address
        public let inTarget: Range<String.Index>
        /// What the words say of the target (`Target.role(of:)`).
        public let role: LinkRole
    }

    public let prose: String
    public let target: String
    /// In the prose's order, none overlapping another.
    public let links: [Link]

    /// The links placed on `prose` and `target` as they are.
    public convenience init(placing links: [ProseLink<Target.Address>], prose: String, target: String) {
        self.init(prose: prose, target: target, quotes: links.map(\.quote), addresses: links.map(\.address),
                  located: Target.locate(links.map(\.address), in: target))
    }

    /// The links whose quotes are `quotes` and whose addresses are `addresses`, nil for one the model
    /// wrote that isn't an address (it still holds its words, as the model listed them in order),
    /// and found in the target at `located`.
    init(prose: String, target: String, quotes: [String], addresses: [Target.Address?], located: [Range<String.Index>?]) {
        self.prose = prose
        self.target = target
        var links: [Link] = []
        for (index, inProse) in ProseMapText.anchor(quotes, in: prose).enumerated() {
            guard let inProse, let address = addresses[index], let inTarget = located[index] else { continue }
            links.append(Link(quote: quotes[index], inProse: inProse, address: address, inTarget: inTarget, role: Target.role(of: address)))
        }
        self.links = links.sorted { $0.inProse.lowerBound < $1.inProse.lowerBound }
    }

    /// The link whose words are at `index` in the prose, if any.
    public func link(at index: String.Index) -> Link? {
        links.first { $0.inProse.contains(index) }
    }

    /// The links whose parts hold `index` in the target, innermost first: a field's words, then the
    /// words of what it's in.
    public func links(atTarget index: String.Index) -> [Link] {
        let utf8 = target.utf8
        return links.filter { $0.inTarget.contains(index) }.sorted {
            utf8.distance(from: $0.inTarget.lowerBound, to: $0.inTarget.upperBound) < utf8.distance(from: $1.inTarget.lowerBound, to: $1.inTarget.upperBound)
        }
    }

    /// The part of the target a link says, as a person reads it (`ProseMapText.excerpt`).
    public func excerpt(of link: Link) -> String { ProseMapText.excerpt(link.inTarget, of: target) }
}

import Canvas
import TestKit

// Things a test orders, as a point's protocol makes them (`DetailTab`, `MenuGroup`, `Adornment`): each
// a type with its order, and the sugar that names another.
private protocol Tile: SendableMetatype {
    static var order: Order<Self> { get }
}

extension Tile {
    static var order: Order<Self> { .natural }
    static var orderAnchor: OrderAnchor { OrderAnchor(Self.self, name: "\(Self.self)") { order.rule } }
}

extension Order where Subject: Tile {
    static func before<T: Tile>(_: T.Type) -> Self { Self(.before(T.orderAnchor)) }
    static func after<T: Tile>(_: T.Type) -> Self { Self(.after(T.orderAnchor)) }
}

private enum A: Tile {}
private enum B: Tile {}
private enum C: Tile {}
private enum D: Tile {}
private enum First1: Tile { static var order: Order<Self> { .first } }
private enum First2: Tile { static var order: Order<Self> { .first } }
private enum Last1: Tile { static var order: Order<Self> { .last } }
private enum Last2: Tile { static var order: Order<Self> { .last } }
private enum AfterA1: Tile { static var order: Order<Self> { .after(A.self) } }
private enum AfterA2: Tile { static var order: Order<Self> { .after(A.self) } }
private enum BeforeB: Tile { static var order: Order<Self> { .before(B.self) } }
private enum AfterAfterA1: Tile { static var order: Order<Self> { .after(AfterA1.self) } }
private enum AfterLast1: Tile { static var order: Order<Self> { .after(Last1.self) } }
private enum BeforeFirst1: Tile { static var order: Order<Self> { .before(First1.self) } }
private enum AfterD: Tile { static var order: Order<Self> { .after(D.self) } }
private enum Itself: Tile { static var order: Order<Self> { .after(Itself.self) } }
private enum Ping: Tile { static var order: Order<Self> { .after(Pong.self) } }
private enum Pong: Tile { static var order: Order<Self> { .after(Ping.self) } }
private enum IntoLoop: Tile { static var order: Order<Self> { .before(Ping.self) } }

/// The names of `tiles` as `OrderRule.arranged` orders them.
private func arranged(_ tiles: [any Tile.Type]) -> [String] {
    OrderRule.arranged(tiles) { ($0.orderAnchor, $0.orderRule) }.map { "\($0)" }
}

extension Tile {
    static var orderRule: OrderRule { order.rule }
}

@MainActor let orderTests = Suite("Order", [
    test("what says nothing keeps the order it first appears in") {
        expectEqual(arranged([C.self, A.self, B.self]), ["C", "A", "B"])
        expectEqual(arranged([]), [])
        expectEqual(arranged([A.self]), ["A"])
    },
    test("the first ones go before the rest and the last ones after, each kind in the order it appears") {
        expectEqual(arranged([Last1.self, A.self, First1.self, B.self, First2.self, Last2.self]),
                    ["First1", "First2", "A", "B", "Last1", "Last2"])
    },
    test("one placed after another goes right after it, those after one in the order they appear, one before another right before it") {
        expectEqual(arranged([AfterA2.self, B.self, A.self, AfterA1.self]), ["B", "A", "AfterA2", "AfterA1"])
        expectEqual(arranged([A.self, B.self, BeforeB.self]), ["A", "BeforeB", "B"])
        expectEqual(arranged([AfterAfterA1.self, B.self, AfterA1.self, A.self]), ["B", "A", "AfterA1", "AfterAfterA1"], "and so on down")
        expectEqual(arranged([AfterLast1.self, Last1.self, A.self]), ["A", "Last1", "AfterLast1"], "beside a last one, last")
        expectEqual(arranged([A.self, First1.self, BeforeFirst1.self]), ["BeforeFirst1", "First1", "A"], "beside a first one, first")
    },
    test("one placed beside a thing that isn't there goes where that thing's own order puts it, after the things of its kind that are") {
        expectEqual(arranged([AfterLast1.self, A.self, Last2.self]), ["A", "Last2", "AfterLast1"], "Last1 is last, after Last2")
        expectEqual(arranged([AfterD.self, A.self, Last1.self]), ["A", "AfterD", "Last1"], "D says nothing: after what does, before the last")
        expectEqual(arranged([AfterAfterA1.self, B.self]), ["B", "AfterAfterA1"], "through two that aren't there")
    },
    test("one placed beside itself says nothing") {
        expectEqual(arranged([Itself.self, A.self, Last1.self]), ["Itself", "A", "Last1"])
    },
    test("two of one thing come out together, where the first appears, none dropped") {
        expectEqual(arranged([Last1.self, A.self, AfterA1.self, Last1.self, B.self]), ["A", "AfterA1", "B", "Last1", "Last1"])
    },
    test("things placed beside each other in a circle still come out once each, last, in the order they appear") {
        expectEqual(arranged([Ping.self, A.self, Pong.self]), ["A", "Ping", "Pong"])
        expectEqual(arranged([IntoLoop.self, Pong.self, A.self, Ping.self]), ["A", "IntoLoop", "Pong", "Ping"])
    },
    test("a cycle is found from anything that leads into it, and named as each one says it") {
        expectEqual(OrderRule.cycle(from: [A.orderAnchor, AfterA1.orderAnchor, AfterAfterA1.orderAnchor, Last1.orderAnchor]), nil)
        expectEqual(OrderRule.cycle(from: [Ping.orderAnchor]), "Ping after Pong, Pong after Ping")
        expectEqual(OrderRule.cycle(from: [A.orderAnchor, IntoLoop.orderAnchor]), "Ping after Pong, Pong after Ping")
        expectEqual(OrderRule.cycle(from: [Itself.orderAnchor]), "Itself after Itself")
    },
    test("an order says itself as the registry's report does") {
        expectEqual(Order<A>.natural.description, "")
        expectEqual(First1.order.description, "first")
        expectEqual(Last1.order.description, "last")
        expectEqual(AfterA1.order.description, "after A")
        expectEqual(BeforeB.order.description, "before B")
        expectEqual(AfterA1.order.rule, AfterA2.order.rule, "two orders beside one thing are equal")
        expectEqual(AfterA1.order.rule == BeforeB.order.rule, false)
    },
])

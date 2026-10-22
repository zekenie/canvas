import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import TestKit
import Types

// The key-walk harness (`KeyWalk`) for the two forms a card holds: where the keyboard is in a `FieldFormView` or a
// `DefinitionView`, named for the stop ("d0/2.0": level, line and cell; "kind:color"), and a cycle through a card's stops that
// ends where a card ends, by leaving it.

/// A stop of a form as a walk names it: its level, its line and its cell.
@MainActor func formStopName(_ form: FieldFormView, _ stop: FieldStop) -> String { "d\(form.depth)/\(stop.line).\(stop.column)" }

/// The ids of a form's stops, in reading order.
@MainActor func formStopIDs(_ form: FieldFormView) -> [String] { form.sheet.stops.map { "card/" + formStopName(form, $0) } }

/// The ids of a card that defines a relationship type, with `name` saying what an end's arrow is called.
@MainActor func definitionStopIDs(_ view: DefinitionView, ends: (ShapeID) -> String) -> [String] {
    view.stops.map { "card/" + definitionStopName($0, ends: ends) }
}

func definitionStopName(_ stop: DefinitionStop, ends: (ShapeID) -> String) -> String {
    switch stop {
    case .title: "title"
    case .fieldName(let key): "field:\(key)"
    case .fieldKind(let key): "kind:\(key)"
    case .option(let key, let place): "option:\(key):\(place)"
    case .newOption(let key): "newOption:\(key)"
    case .addField: "addField"
    case .endName(let end): "name:\(ends(end))"
    case .needed(let end): "needed:\(ends(end))"
    case .onlyOne(let end): "onlyOne:\(ends(end))"
    }
}

extension FocusReader where Self == CustomFocusReader {
    /// A form while it has the keyboard (itself or its editors): surface "card".
    static func form(_ form: @escaping @MainActor () -> FieldFormView?) -> CustomFocusReader {
        .custom("card") { window in
            guard let form = form(), let stop = form.focus,
                  window.firstResponder === form || window.firstResponder === form.cellEditor || window.firstResponder === form.jsonEditor else { return nil }
            return Focus.of(window, surface: "card", element: formStopName(form, stop))
        }
    }

    /// A card that defines a relationship type while it has the keyboard.
    static func definition(_ view: @escaping @MainActor () -> DefinitionView?, ends: @escaping (ShapeID) -> String) -> CustomFocusReader {
        .custom("definition") { window in
            guard let view = view(), let stop = view.focus, window.firstResponder === view || window.firstResponder === view.cellEditor else { return nil }
            return Focus.of(window, surface: "card", element: definitionStopName(stop, ends: ends))
        }
    }
}

extension KeyWalk {
    /// Tab visits `ids` in order and ⇧Tab undoes each step (P3, P4); Tab off the last one leaves the card, which is not a stop
    /// to come back to, so the cycle is held to the last but one and then to a step onto the last: the walk is left on the last.
    func expectCardStops(_ ids: [String], file: StaticString = #fileID, line: UInt = #line) {
        guard let last = ids.last, ids.count > 1 else { return }
        expectCycle(Array(ids.dropLast()), wraps: .leaves(to: last), file: file, line: line)
    }
}

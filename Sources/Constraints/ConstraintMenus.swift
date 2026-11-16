import Canvas
import ContextMenus
import Foundation
import Selection
import Validation

// What the panel's buttons do, in the menus too, so none of it waits on Keyboard navigation: a container's Constraints ▸ (each
// of its own constraints a submenu with its reach and Remove, then Remove All Constraints, and Show Constraints) and a
// breaker's Move Out of <place> and Show Constraint (the actions its issue offers). The Shape menu is the selection's context
// menu, so each is in the menu bar too.

extension CanvasCommand {
    /// Show Constraints: the container selected, its Rules tab chosen.
    public static let showConstraints: CanvasCommand = "showConstraints"
    /// Remove All Constraints: every constraint of the shape's own list taken away, one step.
    public static let removeAllConstraints: CanvasCommand = "removeAllConstraints"
    /// Show Board Constraints: the board's funnel clicked, its popover open and the keyboard in it.
    public static let showBoardConstraints: CanvasCommand = "showBoardConstraints"
}

@MainActor
func registerConstraintMenus(into registrar: inout PluginRegistrar) {
    // Declared once: the menu's items run them (the chip's click and the panel go to the same `showRules`).
    registrar.command(.showConstraints, title: ConstraintsStyle.showConstraints,
                      isEnabled: { subject in subject.shapes.count == 1 }) { subject in
        guard let id = subject.shapes.first else { return }
        subject.editor.constraintIndex?.showRules(of: id)
    }
    registrar.command(.removeAllConstraints, title: ConstraintsStyle.removeAll,
                      isEnabled: { subject in
                          subject.shapes.count == 1 && subject.shapes.first.map { !(subject.editor.constraintWriter?.constraints(of: .shape($0)) ?? []).isEmpty
                              && !subject.editor.isReadOnly($0) } == true
                      }) { subject in
        guard let id = subject.shapes.first else { return }
        _ = subject.editor.constraintWriter?.removeAll(from: .shape(id))
    }
    // The pill's click for the keyboard (View ▸), which a click on empty canvas's menu offers too: while the pill shows.
    registrar.command(.showBoardConstraints, title: ConstraintsStyle.showBoardConstraints, in: ViewMenu.Panels.self, runs: .betweenPresses,
                      isEnabled: { $0.editor.constraintBoard?.place != nil }) { subject in
        subject.editor.endEditing()
        subject.editor.constraintBoard?.open()
    }
    registrar.contextMenuForCanvas { MenuItem(command: .showBoardConstraints, when: { $0.shapes.isEmpty }) }
    registrar.forShapes(holding: ConstraintsProperty.self) { held in
        registerConstraintsMenu(into: &held)
    }
    // A shape that breaks a constraint, whatever its kind: the rule is on every kind with a box.
    registrar.forShapes(adopting: .box) { boxes in
        boxes.contextMenuForCanvas {
            MenuItems(in: StateMenuGroup.self, id: "constraint-breaker") { subject in
                if subject.shapes.count == 1, let id = subject.shapes.first, let index = subject.editor.constraintIndex {
                    let breaches = index.breaches(of: id)
                    // Nowhere out of the root to move a shape to.
                    let places = distinctPlaces(of: breaches.filter { $0.place != .root })
                    for (i, place) in places.enumerated() {
                        MenuItem(ConstraintsStyle.moveOutOf(index.name(of: place)), in: StateMenuGroup.self, id: "move-out-\(i)",
                                 stepName: ConstraintsStyle.moveOut) { ids, editor in
                            guard let id = ids.first else { return }
                            _ = editor.constraintIndex?.moveOut(id, of: place)
                        }
                    }
                    if breaches.count == 1, let breach = breaches.first {
                        MenuItem(ConstraintsStyle.showConstraint, in: StateMenuGroup.self, id: "show-constraint") { _, editor in
                            editor.constraintIndex?.show(breach)
                        }
                    } else if breaches.count > 1 {
                        Submenu(ConstraintsStyle.showConstraint, in: StateMenuGroup.self, id: "show-constraint") {
                            for (i, breach) in breaches.enumerated() {
                                MenuItem(ConstraintsStyle.walkLabel(index.name(of: breach.place), ConstraintsStyle.cut(breach.constraint.says)), in: StateMenuGroup.self,
                                         id: "show-constraint-\(i)") { _, editor in
                                    editor.constraintIndex?.show(breach)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The places a shape breaks constraints of, each once, the nearest first.
private func distinctPlaces(of breaches: [PlacedConstraint]) -> [ConstraintTarget] {
    var places: [ConstraintTarget] = []
    for breach in breaches where !places.contains(breach.place) { places.append(breach.place) }
    return places
}

/// Constraints ▸ in the menu of a container or a holder: where a constraint applies (or the shape keeps a list its own way).
@MainActor
func registerConstraintsMenu(into scope: inout ScopedRegistrar) {
    scope.contextMenuForCanvas {
        MenuItems(in: StateMenuGroup.self, id: "constraints") { subject in
            // The faces are ConstraintFacesPlugin's: a list without it has no menu for a holder.
            if subject.shapes.count == 1, let id = subject.shapes.first, let index = subject.editor.constraintIndex, let writer = subject.editor.constraintWriter,
               let boxes = subject.editor.constraintBoxes, let record = subject.editor.document[id] {
                let own = writer.constraints(of: .shape(id)) ?? []
                // The lists from elsewhere, each going to its holder as its pill does.
                let sources = index.sources(of: .shape(id))
                // Where a constraint applies, or a holder has a list: a bare type has no submenu (its Rules tab is the way to its first).
                if index.isHolder(record) ? !own.isEmpty || !sources.isEmpty : !index.constraints(of: .shape(id)).isEmpty {
                    Submenu(ConstraintsStyle.constraintsMenu, in: StateMenuGroup.self, id: "constraints") {
                        for (i, constraint) in own.enumerated() {
                            Submenu(ConstraintsStyle.cut(constraint.says), in: StateMenuGroup.self, id: "constraint-\(i)") {
                                for reach in ConstraintReach.allCases {
                                    MenuItem(ConstraintsStyle.menuTitle(of: reach), in: StateMenuGroup.self, id: "reach-\(i)-\(reach.rawValue)",
                                             isChecked: { _ in constraint.reach == reach }, stepName: ConstraintsStyle.changeConstraint) { _, editor in
                                        _ = editor.constraintWriter?.setReach(reach, of: constraint, in: .shape(id))
                                    }
                                }
                                if boxes.offersInterpret(ConstraintBox(holder: id, constraint: constraint)) {
                                    MenuItem(ConstraintsStyle.interpretConstraint, in: StateMenuGroup.self, id: "interpret-\(i)") { _, editor in
                                        editor.constraintBoxes?.interpret(ConstraintBox(holder: id, constraint: constraint))
                                    }
                                }
                                MenuItem(ConstraintsStyle.remove, in: StateMenuGroup.self, id: "remove-\(i)", stepName: ConstraintsStyle.removeConstraint) { _, editor in
                                    _ = editor.constraintWriter?.remove(constraint, from: .shape(id))
                                }
                            }
                        }
                        if !own.isEmpty {
                            MenuItem(command: .removeAllConstraints, in: StateMenuGroup.self, id: "remove-all", dims: true)
                        }
                        for (i, source) in sources.enumerated() {
                            MenuItem(ConstraintsStyle.goTo(subject.editor.constraintSourceName(of: source.holder)), in: StateMenuGroup.self, id: "go-to-source-\(i)") { _, editor in
                                editor.constraintBoxes?.go(to: [source.holder])
                            }
                        }
                        MenuItem(command: .showConstraints, in: StateMenuGroup.self, id: "show-constraints")
                    }
                }
            }
        }
    }
}

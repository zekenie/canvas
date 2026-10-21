import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import StickyNotes
import TestKit
import Titles
import Types

// A type built on another, in the panel: the states of one track, added to `galleryStates` (GalleryTypesLook.swift) as
// `hierarchyStates`. Car, Toyota built on Car, myCar a Toyota and yourCar a Car.

@MainActor let hierarchyStates: [GalleryState] = [
    GalleryState("hierarchy-car-connections", "Car's Connections tab: Instances, what is of it however far (myCar through Toyota, yourCar), and Subtypes, Toyota") { stage in
        .image(try stage.connectionsPicture(of: try carTypes(stage).car, size: CGSize(width: 300, height: 260)))
    },
    GalleryState("hierarchy-mycar-types", "myCar's Types tab: Toyota, then Car through Toyota, with no minus") { stage in
        .image(try stage.panelPicture(of: try carTypes(stage).myCar, size: CGSize(width: 320, height: 200)))
    },
]

/// Car and Toyota, built on it, in a row, myCar and yourCar under them. A type's id is its color: fixed, as every state's are.
@MainActor private func carTypes(_ stage: GalleryStage) throws -> (car: ShapeID, myCar: ShapeID) {
    let editor = stage.editor
    func instance(_ title: String, _ x: CGFloat, of type: ShapeID) -> ShapeID {
        var record = ShapeRecord(StickyNote(frame: CGRect(x: x, y: 300, width: 160, height: 120)))
        record[TitleProperty.self] = title
        record[IsAProperty.self] = [TypeLink(type)]
        editor.transact { $0.insert(AnyShapeRecord(record)) }
        return record.id
    }
    let car = editor.addTypeNote(TypeSchemaProperty.starter, title: "Car", frame: CGRect(x: 40, y: 40, width: 200, height: 160),
                                 id: ShapeID(UUID(uuidString: "0E5B1A71-0000-4000-8000-0000000000D1")!))
    let toyota = editor.addTypeNote(TypeSchemaProperty.starter, title: "Toyota", frame: CGRect(x: 300, y: 40, width: 200, height: 160),
                                    id: ShapeID(UUID(uuidString: "0E5B1A72-0000-4000-8000-0000000000D2")!))
    editor.transact { $0.update(toyota) { $0[IsAProperty.self] = [TypeLink(car)] } }
    let myCar = instance("myCar", 300, of: toyota)
    _ = instance("yourCar", 40, of: car)
    stage.spin()
    return (car, myCar)
}

import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import Neighbors
import TestKit
import Titles
import Types

/// A type built on another, through what ships: Car (a `vin` it needs, a `make`), Toyota built on Car (a `trim`),
/// myCar a Toyota; Person, Ann a Person, and Ownership from Person to Car, with Ann's arrow to myCar. Toyota is
/// a kind of Car and myCar is a Car: every surface says so, and none calls Toyota a Car.
@MainActor struct CarBoard {
    let board: BoardDocument
    let server: CommandServer
    let car: ShapeID, toyota: ShapeID, myCar: ShapeID, person: ShapeID, ann: ShapeID

    static let script = """
    sticky-note "Car" schema: "\(scripted(#"{"type": "object", "properties": {"vin": {"type": "string"}, "make": {"type": "string"}}, "required": ["vin"]}"#))"
    sticky-note "Toyota" right of "Car" schema: "\(scripted(#"{"type": "object", "properties": {"trim": {"type": "string"}}}"#))" is: "Car"
    sticky-note "myCar" right of "Toyota" is: "Toyota"
    sticky-note "Person" below "Car" schema: "\(scripted(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#))"
    sticky-note "Ownership" right of "Person" relationship: true schema: "\(scripted(#"{"type": "object", "properties": {"since": {"type": "string"}}}"#))"
    edge "Person" -> "Ownership"
    edge "Ownership" -> "Car"
    sticky-note "Ann" below "Person" is: "Person"
    edge "Ann" -> "myCar" is: "Ownership"
    """

    /// Draws the board through `canvas` as built; the caller closes it (`close()`).
    init() throws {
        let board = newBoard()
        let server = try startCommandServer(boards: [board], frontmost: board)
        (self.board, self.server) = (board, server)
        let drawn = try canvas(server, ["draw", Self.script])
        expectEqual(drawn.status, 0, drawn.error)
        settleRunLoop()
        func id(_ title: String) throws -> ShapeID {
            try require(board.editor.document.shapes.first { $0[TitleProperty.self] == title }?.id, title)
        }
        car = try id("Car"); toyota = try id("Toyota"); myCar = try id("myCar"); person = try id("Person"); ann = try id("Ann")
    }

    var editor: CanvasEditor { board.editor }

    func close() {
        server.stop()
        board.close()
    }

    /// The titles a query's rows have, sorted.
    func titles(_ query: String) throws -> [String] {
        let out = try canvas(server, ["query", "--fields", "title", query])
        expectEqual(out.status, 0, "\(query): \(out.error)")
        let rows = try JSON(text: out.output)["rows"]?.arrayValue ?? []
        return rows.compactMap { row in if case .string(let title)? = row["title"] { title } else { nil } }.sorted()
    }

    /// How many shapes a query finds (an arrow has no title to list it by).
    func count(_ query: String) throws -> Int {
        let out = try canvas(server, ["query", "--count", query])
        expectEqual(out.status, 0, "\(query): \(out.error)")
        return try JSON(text: out.output)["count"]?.intValue ?? -1
    }

    func name(_ id: ShapeID) -> String { editor.document[id]?[TitleProperty.self] ?? "\(id)" }
}

/// An arrow type built on another: Employment from Person (`jobs`, Only one) to Company (`staff`, Needed), and Contract,
/// a relationship type built on Employment with no ends of its own; Ann works at Acme on a Contract, and Initech has no
/// one. A Contract is an Employment: its arrow is judged by Employment's ends and counts in Employment's rows.
@MainActor struct ContractBoard {
    let board: BoardDocument
    let server: CommandServer
    let person: ShapeID, company: ShapeID, employment: ShapeID, contract: ShapeID, ann: ShapeID, acme: ShapeID, initech: ShapeID, arrow: ShapeID

    static let script = """
    sticky-note "Person" schema: "\(scripted(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#))"
    sticky-note "Employment" right of "Person" relationship: true schema: "\(scripted(#"{"type": "object", "properties": {"role": {"type": "string"}}}"#))"
    sticky-note "Company" right of "Employment" schema: "\(scripted(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#))"
    edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}
    edge "Employment" -> "Company" text: "staff" endRule: {"needed": true}
    sticky-note "Contract" below "Employment" relationship: true schema: "\(scripted(#"{"type": "object", "properties": {"until": {"type": "string"}}}"#))" is: "Employment"
    sticky-note "Ann" below "Person" is: "Person"
    sticky-note "Acme" below "Company" is: "Company"
    sticky-note "Initech" right of "Acme" is: "Company"
    edge "Ann" -> "Acme" is: "Contract"
    """

    init() throws {
        let board = newBoard()
        let server = try startCommandServer(boards: [board], frontmost: board)
        (self.board, self.server) = (board, server)
        let drawn = try canvas(server, ["draw", Self.script])
        expectEqual(drawn.status, 0, drawn.error)
        settleRunLoop()
        func id(_ title: String) throws -> ShapeID {
            try require(board.editor.document.shapes.first { $0[TitleProperty.self] == title }?.id, title)
        }
        person = try id("Person"); company = try id("Company"); employment = try id("Employment"); contract = try id("Contract")
        ann = try id("Ann"); acme = try id("Acme"); initech = try id("Initech")
        let contract = self.contract
        arrow = try require(board.editor.document.shapes.first { $0[IsAProperty.self] == [TypeLink(contract)] }?.id, "the Contract arrow")
    }

    var editor: CanvasEditor { board.editor }

    func close() {
        server.stop()
        board.close()
    }

    func titles(_ query: String) throws -> [String] {
        let out = try canvas(server, ["query", "--fields", "title", query])
        expectEqual(out.status, 0, "\(query): \(out.error)")
        let rows = try JSON(text: out.output)["rows"]?.arrayValue ?? []
        return rows.compactMap { row in if case .string(let title)? = row["title"] { title } else { nil } }.sorted()
    }

    /// How many shapes a query finds (an arrow has no title to list it by).
    func count(_ query: String) throws -> Int {
        let out = try canvas(server, ["query", "--count", query])
        expectEqual(out.status, 0, "\(query): \(out.error)")
        return try JSON(text: out.output)["count"]?.intValue ?? -1
    }

    /// The row a note of `type` gets, by its typed name.
    func row(_ name: String, of type: ShapeID) throws -> RelationshipRow {
        try require(editor.relationships?.rows(for: [type], isType: false).first { $0.key.label == .typed(name) }, name)
    }

    /// The arrows a note's row lists.
    func listed(_ note: ShapeID, in name: String, of type: ShapeID) throws -> [ShapeID] {
        try require(editor.relationships).relations(of: note, in: try row(name, of: type)).map(\.arrow)
    }
}

@MainActor let typeHierarchyTests = Suite("A type built on another", [
    test("a shape is never offered a type it is already through another: myCar is a Car through Toyota") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let b = try CarBoard()
        defer { b.close() }
        let types = try require(b.editor.types)
        expect(!types.admits(b.car, for: b.myCar), "a Car through Toyota")
        expect(!types.admits(b.toyota, for: b.myCar), "a Toyota")
        expectEqual(b.editor.typeChoices(for: b.myCar).map { b.name($0.type) }, ["Person"], "/is-a and Is a ▸ on myCar")
        expectEqual(types.menuChoices(for: [b.myCar]).map { b.name($0.type) }, ["Ownership", "Person", "Toyota"],
                    "Is a ▸ lists the type myCar has, to take it off, and not Car")
        expectEqual(b.editor.typeChoices(for: b.toyota).map { b.name($0.type) }, ["Ownership", "Person"], "Toyota builds on Car already")
        expect(types.admits(b.car, for: b.ann), "a Person may still be a Car")
        let step = b.editor.undoHistory.undoName
        b.editor.addTypeLink(b.car, to: b.myCar)
        expectEqual(b.editor.document[b.myCar]?[IsAProperty.self], [TypeLink(b.toyota)], "Car is not written on myCar again")
        expectEqual(b.editor.undoHistory.undoName, step, "and no step")
        // Toyota no longer a type: myCar is no Car through it (its rows say so), so Car is offered again.
        b.editor.removeType(b.toyota)
        expect(types.admits(b.car, for: b.myCar), "through a shape that is no type, as the chain reads it")
        b.editor.undo()
        expect(!types.admits(b.car, for: b.myCar))
    },
    test("what is of Car is myCar, through Toyota, and Toyota is a type built on Car: its lights' lists, and what is of a type however far") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let b = try CarBoard()
        defer { b.close() }
        let lights = b.editor.registry.neighborLights
        let (instances, subtypes) = (try require(lights.first { $0.title == "Instances" }), try require(lights.first { $0.title == "Subtypes" }))
        expectEqual(try b.titles(instances.query("#\(b.car)")), ["myCar"])
        expectEqual(try b.titles(subtypes.query("#\(b.car)")), ["Toyota"])
        expectEqual(try b.titles(instances.query("#\(b.toyota)")), ["myCar"])
        expectEqual(try b.titles(subtypes.query("#\(b.toyota)")), [])
        expectEqual(try b.titles(instances.query("#\(b.myCar)")), [], "myCar is no type")
        let types = try require(b.editor.types)
        expectEqual(types.allInstances(of: b.car), [b.myCar])
        expectEqual(types.allInstances(of: b.person), [b.ann])
        let ownership = try require(b.editor.document.shapes.first { $0[TitleProperty.self] == "Ownership" }?.id)
        let owning = try require(b.editor.document.shapes.first { $0[IsAProperty.self] == [TypeLink(ownership)] }?.id)
        expectEqual(types.allInstances(of: ownership), [owning], "a relationship type's arrows")
        expectEqual(try b.count(instances.query("#\(ownership)")), 1, "and its light finds the one")
        expectEqual(types.instances(of: b.car), [b.toyota], "what names Car itself is still Toyota")
    },
    test("myCar's Types tab says Toyota, then Car through Toyota; Toyota's says Car") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let b = try CarBoard()
        defer { b.close() }
        let types = try require(b.editor.types)
        expectEqual(types.builtOn(of: b.myCar).map { [b.name($0.type), b.name($0.through)] }, [["Car", "Toyota"]])
        expectEqual(types.builtOn(of: b.toyota).map { b.name($0.type) }, [], "Car is Toyota's own")
        expectEqual(types.builtOn(of: b.ann).map { b.name($0.type) }, [])
        // Toyota no longer a type: myCar is no Car through it, as its rows say.
        b.editor.removeType(b.toyota)
        expectEqual(types.builtOn(of: b.myCar).map { b.name($0.type) }, [])
        b.editor.undo()
        expectEqual(types.builtOn(of: b.myCar).map { b.name($0.type) }, ["Car"])
    },
    test("a value draw writes on myCar while Car is gone is kept and not warned of: Car's fields are unknown") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let b = try CarBoard()
        defer { b.close() }
        let typo = try canvas(b.server, ["draw", #"sticky-note "myCar" fieldValues: {"trimm": "LE"}"#])
        expectEqual(typo.status, 0, typo.error)
        expect(typo.output.contains(#"\"trimm\" isn't a field"#) || typo.output.contains(#""trimm" isn't a field"#),
               "a member no type names is warned of while the chain is whole: \(typo.output)")
        let deleted = try canvas(b.server, ["draw", #"delete "Car""#])
        expectEqual(deleted.status, 0, deleted.error)
        let drawn = try canvas(b.server, ["draw", #"sticky-note "myCar" fieldValues: {"vin": "1HGCM8"}"#])
        expectEqual(drawn.status, 0, drawn.error)
        expect(!drawn.output.contains("isn't a field"), "vin was Car's: \(drawn.output)")
        expectEqual(b.editor.document[b.myCar]?[FieldValuesProperty.self]?.values["vin"], .string("1HGCM8"), "and kept")
    },
    test("a Contract, built on Employment, is an Employment: judged by its ends, listed in its rows, counted for Needed and Only one") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let b = try ContractBoard()
        defer { b.close() }
        let relationships = try require(b.editor.relationships)
        let graph = relationships.graph
        expectEqual(graph.sides(of: b.contract).types(on: .from), [b.person], "Employment's ends, none drawn of its own")
        expectEqual(graph.sides(of: b.contract).types(on: .to), [b.company])
        expect(graph.ownSides(of: b.contract).isEmpty)
        let fit = try require(graph.fit(of: b.contract, from: .note(b.ann), to: .note(b.acme)))
        expectEqual([fit.from, fit.to], [.fits, .fits])
        expectEqual(try b.listed(b.acme, in: "staff", of: b.company), [b.arrow], "Acme's staff row lists Ann's Contract")
        expectEqual(try b.listed(b.ann, in: "jobs", of: b.person), [b.arrow])
        expectEqual(try b.titles(":incomplete"), ["Initech"], "Acme has its staff; Initech has none")
        expectEqual(try b.count("arrow:misfit"), 0)
        expectEqual(relationships.rows(for: [b.company], isType: false).count, 1, "no row of Contract's own: it counts in Employment's")
        // Only one: an Employment beside the Contract is two jobs.
        let second = try canvas(b.server, ["draw", #"edge "Ann" -> "Initech" is: "Employment""#])
        expectEqual(second.status, 0, second.error)
        expectEqual(try b.titles(":invalid"), ["Ann"], "jobs has two")
        expectEqual(try b.titles(":incomplete"), [])
        b.editor.undo()
        // A Contract drawn the wrong way round is a misfit, against Employment's ends.
        let wrong = try canvas(b.server, ["draw", #"edge "Initech" -> "Ann" is: "Contract""#])
        expectEqual(wrong.status, 0, wrong.error)
        expectEqual(try b.count("arrow:misfit"), 1)
        b.editor.undo()
        // --ask is told what it relates, through Employment.
        let told = try require(b.editor.fileFields).text(for: "who works where")
        expect(told.contains("Contract builds on Employment") && told.contains("relates Person to Company"), told)
    },
    test("a Contract that stops building on Employment stops counting as one, and the notes at its arrow's ends are checked again") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let b = try ContractBoard()
        defer { b.close() }
        expectEqual(try b.titles(":incomplete"), ["Initech"])
        b.editor.removeTypeLink(b.employment, from: b.contract)
        expectEqual(try b.listed(b.acme, in: "staff", of: b.company), [])
        expectEqual(try b.titles(":incomplete"), ["Acme", "Initech"], "Acme's staff is a Contract, no Employment now")
        expectEqual(try require(b.editor.relationships).graph.fit(of: b.contract, from: .note(b.ann), to: .note(b.acme))?.from, .open,
                    "and it has no ends: anything")
        b.editor.undo()
        expectEqual(try b.listed(b.acme, in: "staff", of: b.company), [b.arrow])
        expectEqual(try b.titles(":incomplete"), ["Initech"])
        // Employment unmarked: Contract reads no ends from it, and Acme has no row to need.
        b.editor.makePlainType(b.employment)
        expectEqual(try require(b.editor.relationships).graph.sides(of: b.contract).isEmpty, true)
        expectEqual(try b.titles(":incomplete"), [])
        b.editor.undo()
        expectEqual(try b.titles(":incomplete"), ["Initech"])
    },
    test("a Contract that draws an end of its own is judged by its own ends alone, and its arrows still count as Employment's") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let b = try ContractBoard()
        defer { b.close() }
        // Its first end of its own makes it its own definition: a Contract from a Company judges Ann's arrow so, and undone, as
        // an Employment again.
        let fromCompany = try canvas(b.server, ["draw", #"edge "Company" -> "Contract""#])
        expectEqual(fromCompany.status, 0, fromCompany.error)
        expectEqual(try b.count("arrow:misfit"), 1, "Ann is no Company")
        b.editor.undo()
        expectEqual(try b.count("arrow:misfit"), 0)
        let own = try canvas(b.server, ["draw", #"edge "Person" -> "Contract" text: "contracts""#])
        expectEqual(own.status, 0, own.error)
        let graph = try require(b.editor.relationships).graph
        expectEqual(graph.sides(of: b.contract).types(on: .from), [b.person])
        expectEqual(graph.sides(of: b.contract).types(on: .to), [], "its own: a side it draws nothing on takes anything")
        let fit = try require(graph.fit(of: b.contract, from: .note(b.ann), to: .note(b.acme)))
        expectEqual([fit.from, fit.to], [.fits, .open])
        let contracts = try b.row("contracts", of: b.person)
        expectEqual(contracts.others, [], "and its row says the same: anything at the other end")
        expectEqual(try b.listed(b.ann, in: "contracts", of: b.person), [b.arrow])
        expectEqual(try b.listed(b.acme, in: "staff", of: b.company), [b.arrow], "still an Employment")
        let told = try require(b.editor.fileFields).text(for: "contracts")
        let line = try require(told.split(separator: "\n").first { $0.hasPrefix("Contract") })
        expect(line.contains(#"rows: Person "contracts""#) && !line.contains("staff"), "its rows are its own ends': \(line)")
    },
    test("a plain type between Contract and Employment that stops being a type takes Contract out of Employment, and the notes are checked again") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let b = try ContractBoard()
        defer { b.close() }
        let middle = try canvas(b.server, ["draw", """
            sticky-note "Agreement" below "Contract" schema: "\(scripted(#"{"type": "object", "properties": {}}"#))" is: "Employment"
            sticky-note "Contract" is: "Agreement"
            """])
        expectEqual(middle.status, 0, middle.error)
        let agreement = try require(b.editor.document.shapes.first { $0[TitleProperty.self] == "Agreement" }?.id)
        expectEqual(try b.listed(b.acme, in: "staff", of: b.company), [b.arrow], "a Contract is an Agreement is an Employment")
        expectEqual(try b.titles(":incomplete"), ["Initech"])
        b.editor.removeType(agreement)
        expectEqual(try b.listed(b.acme, in: "staff", of: b.company), [], "the chain stops at a shape that is no type")
        expectEqual(try b.titles(":incomplete"), ["Acme", "Initech"], "Acme is told")
        b.editor.undo()
        expectEqual(try b.titles(":incomplete"), ["Initech"])
    },
    test("an arrow's lists offer the relationship type its own builds on, in that one's place, and picking it replaces it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let b = try ContractBoard()
        defer { b.close() }
        expectEqual(b.editor.typeChoices(for: b.arrow).map { b.editor.document[$0.type]?[TitleProperty.self] ?? "" }, ["Employment"],
                    "a Contract arrow may be made a plain Employment")
        b.editor.setRelationshipType(b.employment, of: [b.arrow])
        expectEqual(b.editor.document[b.arrow]?[IsAProperty.self], [TypeLink(b.employment)])
        expectEqual(try b.listed(b.acme, in: "staff", of: b.company), [b.arrow])
        b.editor.undo()
        expectEqual(b.editor.document[b.arrow]?[IsAProperty.self], [TypeLink(b.contract)])
    },
])

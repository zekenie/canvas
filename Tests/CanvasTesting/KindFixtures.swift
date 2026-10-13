import Canvas
import Foundation
import TestKit

/// Holds kinds to their fixtures in `directory`: `<kind>.v<N>.json`, one shape's props at version
/// N, as the board codec writes them. Every fixture must migrate to the kind's version today and
/// read, with any member its history hands over to an added property reading as that property;
/// the one at today's version must exist, hold every property the kind lists, and write back byte
/// for byte. So a kind whose props change how they encode, or that lists a new property (even an
/// optional one, which a board leaves out when nil), fails here until it has a migration, and a
/// fixture for its new version. Fixtures are added, never edited: each one is how boards of that
/// version were written.
@MainActor
public func expectKindFixtures(_ kinds: [ShapeKind], in registry: Registry, directory: String,
                               file: StaticString = #fileID, line: UInt = #line) {
    let codec = BoardCodec(registry: registry)
    for kind in kinds {
        // The kind's own properties: its schema's, less those it opts into.
        let listed = Set(registry.schema(for: kind)?.json["properties"]?.objectValue?.keys.map { $0 } ?? [])
            .subtracting(registry.properties(for: kind).map(\.rawValue))
        let today = codec.version(of: kind)
        expectFixtures(of: "\(kind)", version: today, directory: directory, file: file, line: line) { data, version in
            if version == today {
                let written = Set((try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue?.keys.map { $0 } ?? [])
                expect(listed.isSubset(of: written), """
                    \(kind)'s fixture for its version, \(version), doesn't hold \(listed.subtracting(written).sorted()): \
                    a property it lists now isn't in any board of that version. Give it a step (PropsMigration("…")) and a \
                    fixture for the new version that sets it.
                    """, file: file, line: line)
            }
            return try codec.encodeProps(codec.decodeRecord(props: data, kind: kind, version: version).props)
        }
    }
}

/// Holds added properties to their fixtures in `directory`, as kinds are held to theirs:
/// `<key>.v<N>.json`, one shape's value at version N. Every fixture must migrate to the
/// property's version today and read, and today's must write back byte for byte.
@MainActor
public func expectPropertyFixtures(_ keys: [PropertyKey], in registry: Registry, directory: String,
                                   file: StaticString = #fileID, line: UInt = #line) {
    let codec = BoardCodec(registry: registry)
    for key in keys {
        expectFixtures(of: "\(key)", version: codec.version(ofProperty: key), directory: directory, file: file, line: line) { data, version in
            try codec.migrateValue(data, property: key, version: version)
        }
    }
}

/// Holds file properties (a plugin's value on the file as a whole, `FileProperty`) to their fixtures
/// in `directory`, as added properties are held to theirs: `<key>.v<N>.json`, the file's value at
/// version N. Every fixture must migrate to the property's version today and read, and today's must
/// write back byte for byte.
@MainActor
public func expectFilePropertyFixtures(_ keys: [PropertyKey], in registry: Registry, directory: String,
                                       file: StaticString = #fileID, line: UInt = #line) {
    let codec = BoardCodec(registry: registry)
    for key in keys {
        expectFixtures(of: "\(key)", version: codec.version(ofFileProperty: key), directory: directory, file: file, line: line) { data, version in
            try codec.migrateFileValue(data, property: key, version: version)
        }
    }
}

/// `read` takes a fixture at its version and gives it back as today's version writes it.
@MainActor
private func expectFixtures(of name: String, version: Int?, directory: String, file: StaticString, line: UInt,
                            read: (Data, Int) throws -> Data) {
    guard let version else {
        expect(false, "\(name) isn't installed", file: file, line: line)
        return
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    let prefix = "\(name).v", suffix = ".json"
    let versions = names.compactMap { name -> Int? in
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        return Int(name.dropFirst(prefix.count).dropLast(suffix.count))
    }.sorted()
    expect(versions.contains(version), "\(name) has no fixture for its version, \(version): add \(directory)/\(prefix)\(version)\(suffix)",
           file: file, line: line)
    for fixture in versions {
        let path = "\(directory)/\(prefix)\(fixture)\(suffix)"
        guard fixture <= version else {
            expect(false, "\(path) is newer than \(name)'s version, \(version): is a migration missing, or its list misspelled?", file: file, line: line)
            continue
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let written = try read(data, fixture)
            guard fixture == version else { continue }
            expect(written == data, """
                \(path) doesn't write back as it was: \(name) now encodes differently. Add a migration, and a \
                fixture for the new version. Today it writes:
                \(String(decoding: written, as: UTF8.self))
                """, file: file, line: line)
        } catch {
            expect(false, "\(path) doesn't read: \(error)", file: file, line: line)
        }
    }
}

import Canvas
import Foundation
import TestKit

/// Holds kinds to their fixtures in `directory`: `<kind>.v<N>.json`, one shape's props at version
/// N, as the board codec writes them. Every fixture must migrate to the kind's version today and
/// read; the one at today's version must exist and write back byte for byte. So a kind whose
/// props change how they encode fails here until it has a migration, and a fixture for its new
/// version. Fixtures are added, never edited: each one is how boards of that version were written.
@MainActor
public func expectKindFixtures(_ kinds: [ShapeKind], in registry: Registry, directory: String,
                               file: StaticString = #fileID, line: UInt = #line) {
    let codec = BoardCodec(registry: registry)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    for kind in kinds {
        guard let version = codec.version(of: kind) else {
            expect(false, "\(kind) isn't installed", file: file, line: line)
            continue
        }
        let prefix = "\(kind.rawValue).v", suffix = ".json"
        let versions = names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
            return Int(name.dropFirst(prefix.count).dropLast(suffix.count))
        }.sorted()
        expect(versions.contains(version), "\(kind) has no fixture for its version, \(version): add \(directory)/\(prefix)\(version)\(suffix)",
               file: file, line: line)
        for fixture in versions {
            let path = "\(directory)/\(prefix)\(fixture)\(suffix)"
            guard fixture <= version else {
                expect(false, "\(path) is newer than \(kind)'s version, \(version): is a migration missing, or its list misspelled?", file: file, line: line)
                continue
            }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let props = try codec.decodeProps(data, kind: kind, version: fixture)
                guard fixture == version else { continue }
                let written = try codec.encodeProps(props)
                expect(written == data, """
                    \(path) doesn't write back as it was: \(kind)'s props now encode differently. Add a migration, and a \
                    fixture for the new version. Today they write:
                    \(String(decoding: written, as: UTF8.self))
                    """, file: file, line: line)
            } catch {
                expect(false, "\(path) doesn't read: \(error)", file: file, line: line)
            }
        }
    }
}

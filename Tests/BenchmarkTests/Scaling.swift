import Foundation
import TestKit

// What grows with the board grows no faster than it. Every report line is kept with the size whose
// loop it was written in (`sizes` says which as it's walked), and once the suites have run, each line
// at the smallest size is paired with the same line at the largest: a timing in it (a number of ms)
// may grow at most `Scaling.slack` times as much as the board did, or the run fails naming the line.
// So `./build.sh bench` holds 1,000 against 10,000, and `BENCH_SIZES=10000,100000` holds 10,000
// against 100,000: linear work grows some 10 to 15 times there (the larger board falls out of the
// caches), a square 100.

/// The sizes the size-driven benchmarks run at, which say which one a loop over them is at
/// (`Scaling.currentSize`), so what it reports is kept with its size.
struct BenchSizes: ExpressibleByArrayLiteral {
    let values: [Int]

    init(_ values: [Int]) { self.values = values }

    init(arrayLiteral values: Int...) { self.values = values }
}

extension BenchSizes: @MainActor RandomAccessCollection {
    var startIndex: Int { values.startIndex }
    var endIndex: Int { values.endIndex }
    subscript(position: Int) -> Int { values[position] }

    func makeIterator() -> Iterator { Iterator(values: values) }

    @MainActor struct Iterator: @MainActor IteratorProtocol {
        let values: [Int]
        var position = 0

        mutating func next() -> Int? {
            guard position < values.count else { return nil }
            defer { position += 1 }
            Scaling.currentSize = values[position]
            return values[position]
        }
    }
}

@MainActor enum Scaling {
    /// How many times the board's growth a timing may grow: twice, room for the caches and the noise
    /// of a busy machine, never for a square.
    static let slack = 2.0
    /// The lines held to a slack of their own, each named by the start of its template (`template(of:)`),
    /// with why. A hover on one of a type's instances: the reach walks every light from it, at a cost in
    /// proportion to the board though it reaches nothing (some 1.2 µs a shape from 3,000 shapes to
    /// 100,000), which at 1,000 shapes stays in the caches (some 0.4 µs), so from 1,000 to 10,000 it grows
    /// some 30 times; four holds that and still refuses a square.
    static let slacks: [(line: String, slack: Double)] = [("# shapes, a hover on one of its instances:", 4)]
    /// A timing under this at the larger size is too small to judge.
    static let floor = 1.0
    /// The size the loop over `sizes` is at, nil outside one (each test starts with none).
    static var currentSize: Int?
    /// Every line reported, with the size it was reported at.
    static var lines: [(size: Int?, text: String)] = []

    /// A line as its sizes write it alike: its numbers taken out, its spaces one each and none at its ends (a size
    /// padded to six places has a space before it at 10,000 and none at 100,000).
    static func template(of line: String) -> String {
        line.replacing(#/-?\d[\d,]*\.?\d*(?:e[-+]?\d+)?/#, with: "#").replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The slack a line is held to: its own (`slacks`), else `slack`.
    static func slack(for line: String) -> Double {
        let template = template(of: line)
        return slacks.first { template.hasPrefix($0.line) }?.slack ?? slack
    }

    /// The timings in a line, in order: each number followed by ms.
    static func timings(in line: String) -> [Double] {
        line.matches(of: #/(-?\d[\d,]*\.?\d*)\s*ms/#).compactMap { Double($0.output.1.replacing(",", with: "")) }
    }

    /// Each line at `small` beside the same line at `large`: the k-th of a template at one with the
    /// k-th at the other.
    static func pairs(_ small: Int, _ large: Int) -> [(small: String, large: String)] {
        var at: [Int: [String: [String]]] = [:]
        for (size, text) in lines { if let size { at[size, default: [:]][template(of: text), default: []].append(text) } }
        var pairs: [(small: String, large: String)] = []
        for (template, smalls) in at[small] ?? [:] {
            for (one, other) in zip(smalls, at[large]?[template] ?? []) { pairs.append((one, other)) }
        }
        return pairs
    }
}

@MainActor let scalingBenchmarks = Suite("Scaling", [
    test("what grows with the board grows no faster than it: each timing at the largest size within twice the board's growth over the smallest, or its line's own slack") {
        guard let small = sizes.values.min(), let large = sizes.values.max(), small < large else { return }
        let boardGrew = Double(large) / Double(small)
        var worst: [(growth: Double, limit: Double, small: String, large: String)] = []
        for (one, other) in Scaling.pairs(small, large) {
            let limit = Scaling.slack(for: one) * boardGrew
            for (before, after) in zip(Scaling.timings(in: one), Scaling.timings(in: other)) where before > 0 && after >= Scaling.floor {
                worst.append((after / before, limit, one, other))
            }
        }
        worst.sort { $0.growth > $1.growth }
        let kept = Dictionary(grouping: Scaling.lines.compactMap(\.size), by: { $0 }).mapValues(\.count)
        report("\(worst.count) timings compared, from \(kept[small] ?? 0) lines at \(small) shapes and \(kept[large] ?? 0) at \(large)")
        for (growth, limit, one, other) in worst.prefix(5) {
            report(String(format: "grew %.1f times (limit %.0f): %@  →  %@", growth, limit, one, other))
        }
        for (growth, limit, one, other) in worst where growth > limit {
            expect(false, String(format: "grew %.1f times from %d to %d shapes, more than %.0f: \"%@\" became \"%@\"", growth, small, large, limit, one, other))
        }
    },
])

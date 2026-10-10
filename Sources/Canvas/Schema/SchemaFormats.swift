import Foundation

/// The formats a validator checks, by name. Every other `format`, and every format with none, stays an
/// annotation, as 2020-12 has it. Opt in per validator: the core's own kind schemas write `uuid` and
/// `date-time`, and checking them would change what the schema rule says of every shape.
public struct SchemaFormats: Sendable {
    /// One format: what a value that fits it is called in a message ("an email address"), and the test.
    public struct Format: Sendable {
        /// What a fitting value is, mid-sentence: "should be an email address, not …".
        public let reads: String
        let fits: @Sendable (String) -> Bool

        public init(_ reads: String, fits: @escaping @Sendable (String) -> Bool) {
            self.reads = reads
            self.fits = fits
        }
    }

    private let formats: [String: Format]

    public init(_ formats: [String: Format]) { self.formats = formats }

    public subscript(_ name: String) -> Format? { formats[name] }

    /// Checks nothing: every `format` an annotation.
    public static let none = SchemaFormats([:])

    /// `email`, `date`, `date-time`, `time`, `uri` and `uuid`, by the RFCs (5322's addr-spec less its
    /// quoted forms and literals, 3339, 3986 and 4122), each a scan of the characters.
    public static let standard = SchemaFormats([
        "email": Format("an email address") { Standard.email($0) },
        "date": Format("a date like 2026-03-03") { Standard.date(Array($0.utf8)[...]) },
        "date-time": Format("a date and time like 2026-03-03T09:30:00Z") { Standard.dateTime($0) },
        "time": Format("a time like 09:30:00Z") { Standard.time(Array($0.utf8)[...]) },
        "uri": Format("a link with a scheme, like https://acme.com") { Standard.uri($0) },
        "uuid": Format("a UUID") { Standard.uuid($0) },
    ])
}

private enum Standard {
    private typealias Bytes = ArraySlice<UInt8>

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private static func isLetter(_ byte: UInt8) -> Bool { (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A }
    private static func isHex(_ byte: UInt8) -> Bool { isDigit(byte) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x66) }

    /// The number the digits read as; nil unless they are all digits.
    private static func number(_ digits: Bytes) -> Int? {
        var result = 0
        for byte in digits {
            guard isDigit(byte) else { return nil }
            result = result * 10 + Int(byte - 0x30)
        }
        return result
    }

    // MARK: date and time (RFC 3339)

    static func date(_ bytes: ArraySlice<UInt8>) -> Bool {
        let b = Array(bytes)
        guard b.count == 10, b[4] == 0x2D, b[7] == 0x2D,
              let year = number(b[0..<4]), let month = number(b[5..<7]), let day = number(b[8..<10]),
              (1...12).contains(month), day >= 1 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= days[month - 1]
    }

    /// `hh:mm:ss`, a fraction, and the offset RFC 3339's full-time requires.
    static func time(_ bytes: ArraySlice<UInt8>) -> Bool {
        let b = Array(bytes)
        guard b.count >= 9, b[2] == 0x3A, b[5] == 0x3A,
              let hours = number(b[0..<2]), let minutes = number(b[3..<5]), let seconds = number(b[6..<8]),
              hours <= 23, minutes <= 59, seconds <= 60 else { return false }
        var at = 8
        if b[at] == 0x2E {
            at += 1
            let start = at
            while at < b.count, isDigit(b[at]) { at += 1 }
            guard at > start else { return false }
        }
        guard at < b.count else { return false }
        if b[at] == 0x5A || b[at] == 0x7A { return at == b.count - 1 }
        guard b[at] == 0x2B || b[at] == 0x2D, b.count - at == 6, b[at + 3] == 0x3A,
              let offsetHours = number(b[(at + 1)..<(at + 3)]), let offsetMinutes = number(b[(at + 4)..<(at + 6)]) else { return false }
        return offsetHours <= 23 && offsetMinutes <= 59
    }

    static func dateTime(_ string: String) -> Bool {
        let b = Array(string.utf8)
        guard b.count > 11, b[10] == 0x54 || b[10] == 0x74 else { return false }
        return date(b[0..<10]) && time(b[11...])
    }

    // MARK: uuid

    static func uuid(_ string: String) -> Bool {
        let b = Array(string.utf8)
        guard b.count == 36 else { return false }
        for (offset, byte) in b.enumerated() {
            if [8, 13, 18, 23].contains(offset) {
                if byte != 0x2D { return false }
            } else if !isHex(byte) {
                return false
            }
        }
        return true
    }

    // MARK: email (RFC 5322 addr-spec, dot-atoms only)

    private static let atext: Set<UInt8> = Set("!#$%&'*+/=?^_`{|}~-".utf8)

    static func email(_ string: String) -> Bool {
        let b = Array(string.utf8)
        guard let at = b.firstIndex(of: 0x40), !b[(at + 1)...].contains(0x40) else { return false }
        let local = b[..<at], domain = b[(at + 1)...]
        guard (1...64).contains(local.count), (1...255).contains(domain.count) else { return false }
        for atom in local.split(separator: 0x2E, omittingEmptySubsequences: false) {
            guard !atom.isEmpty, atom.allSatisfy({ isLetter($0) || isDigit($0) || atext.contains($0) }) else { return false }
        }
        for label in domain.split(separator: 0x2E, omittingEmptySubsequences: false) {
            guard (1...63).contains(label.count), label.first != 0x2D, label.last != 0x2D,
                  label.allSatisfy({ isLetter($0) || isDigit($0) || $0 == 0x2D }) else { return false }
        }
        return true
    }

    // MARK: uri (RFC 3986, with a scheme)

    private static let uriMarks: Set<UInt8> = Set("-._~:/?#[]@!$&'()*+,;=".utf8)

    static func uri(_ string: String) -> Bool {
        let b = Array(string.utf8)
        guard let first = b.first, isLetter(first) else { return false }
        var at = 1
        while at < b.count, isLetter(b[at]) || isDigit(b[at]) || b[at] == 0x2B || b[at] == 0x2D || b[at] == 0x2E { at += 1 }
        guard at < b.count - 1, b[at] == 0x3A else { return false }
        var hashes = 0
        var i = at + 1
        while i < b.count {
            let byte = b[i]
            if byte == 0x25 {
                guard i + 2 < b.count, isHex(b[i + 1]), isHex(b[i + 2]) else { return false }
                i += 3
                continue
            }
            if byte == 0x23 { hashes += 1 }
            guard isLetter(byte) || isDigit(byte) || uriMarks.contains(byte) else { return false }
            i += 1
        }
        return hashes <= 1
    }
}

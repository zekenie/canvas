import Canvas
import CanvasRPC
import Foundation
import Titles

// The title from a field, as a rule over values: a note's real title is a copy of one field's value as
// the row shows it, kept in step while it still matches. Pure; holds no state, so the writer, `/is-a`
// and the pill's look all read one rule.

/// What a title does when a value changes. The locale is the one the row shows in.
public enum FieldTitling {
    /// The field's value as its row shows it, on one line (`TitleProperty.folded`); nil when there is none,
    /// and for a list or an object under the key (wrong for a plain field: the check says so).
    public static func shown(_ values: FieldValues, _ source: TitleSource, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let value = values.value(at: FieldPath(field: source.key)) else { return nil }
        switch value {
        case .array, .object, .null: return nil
        default: return TitleProperty.folded(FieldText.shown(value, as: source.kind, locale: locale))
        }
    }

    /// Whether text can be a title: 80 code points or fewer (`TitleProperty.maxLength`, counted as
    /// Validation counts).
    public static func fits(_ text: String) -> Bool {
        text.unicodeScalars.count <= TitleProperty.maxLength
    }

    /// The title to hold after the values went from `old` to `new`, given the title held now (folded, nil
    /// for none). nil: leave it. `.some(nil)`: take it off. `.some(text)`: write it.
    ///
    /// 1. The field's own value did not change: leave (a write to another field never titles).
    /// 2. No title held: the new value, if there is one and it fits.
    /// 3. The title held is the old value as shown: the new value if it fits, else take the title off, so
    ///    a title never outlives the value it was copied from.
    /// 4. Anything else is a title set by hand: leave.
    public static func retitle(held: String?, old: FieldValues, new: FieldValues, _ source: TitleSource, locale: Locale = .autoupdatingCurrent) -> String?? {
        let path = FieldPath(field: source.key)
        guard old.value(at: path) != new.value(at: path) else { return nil }
        let next = shown(new, source, locale: locale).flatMap { fits($0) ? $0 : nil }
        guard let held else {
            guard let next else { return nil }
            return .some(next)
        }
        guard held == shown(old, source, locale: locale) else { return nil }
        return .some(next)
    }

    /// For a note with no title: the value it holds, if that can be a title.
    public static func firstTitle(values: FieldValues, _ source: TitleSource, locale: Locale = .autoupdatingCurrent) -> String? {
        shown(values, source, locale: locale).flatMap { fits($0) ? $0 : nil }
    }
}

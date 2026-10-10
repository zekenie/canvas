import MachO

/// A text file of the product's: one of `Shipped/*.txt`, which the build puts in every executable
/// that is the product (the app, its Quick Look extension, and the tests of what ships) and in no
/// other, as a section of the binary. So what the product says in a file reaches the code that
/// uses it with no path to look under, no bundle and no module that holds it: a plugin made with
/// no arguments reads its own (`--ask`'s prompt, QueryTranslation's).
///
/// The core knows no file: a name is whatever the folder holds.
public enum ShippedText {
    /// The text of `Shipped/<name>.txt`, as written, or nil: in an executable that isn't the
    /// product, or for a name the folder has no file of.
    public static func named(_ name: String) -> String? {
        // The process's own executable: dyld's first image.
        guard let executable = _dyld_get_image_header(0) else { return nil }
        var size: UInt = 0
        let header = UnsafeRawPointer(executable).assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(header, segment, section(for: name), &size) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(size)), as: UTF8.self)
    }

    /// Where the build puts them (`build.sh`, an executable's link): the text segment, each file a
    /// section named for it, `__` then its name with `-` as `_` (a section's name is at most 16
    /// characters, which the build holds the folder's names to).
    static let segment = "__TEXT"
    static func section(for name: String) -> String { "__" + String(name.map { $0 == "-" ? "_" : $0 }) }
}

import Foundation

/// Reading and writing the document, byte-faithfully.
///
/// mdship stores checksums of managed content inside the file. A save that
/// changed anything the user did not -- a line ending, a byte order mark, the
/// encoding -- would break those checksums behind the user's back, so text
/// goes back out exactly as it came in apart from the edits.
enum TextFile {

    struct Contents: Equatable {
        let text: String
        let encoding: String.Encoding
        /// A UTF-8 file that started with a byte order mark. Decoding drops the
        /// mark, so it has to be remembered to be written back.
        var utf8ByteOrderMark = false
    }

    private static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    static func read(_ url: URL) throws -> Contents {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            return Contents(text: text, encoding: .utf8, utf8ByteOrderMark: data.starts(with: utf8BOM))
        }
        // Not UTF-8: let Foundation look for a byte order mark and guess.
        var encoding: String.Encoding = .utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) {
            return Contents(text: text, encoding: encoding)
        }
        // Latin-1 maps every byte to a character, so this always succeeds and
        // a save writes the same bytes back.
        return Contents(text: String(data: data, encoding: .isoLatin1) ?? "", encoding: .isoLatin1)
    }

    /// Writes `text` to `url`.
    ///
    /// An existing file is replaced by a finished copy rather than written in
    /// place, so a failure half way leaves the old file intact -- and replaced
    /// with `replaceItemAt`, which keeps the original's permissions, extended
    /// attributes and creation date, where a plain atomic write would not.
    static func write(_ text: String, to url: URL, encoding: String.Encoding, utf8ByteOrderMark: Bool = false) throws {
        guard var data = text.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if utf8ByteOrderMark && encoding == .utf8 && !data.starts(with: utf8BOM) {
            data = utf8BOM + data
        }
        let fileManager = FileManager.default
        // Replace what a symbolic link points to, not the link.
        let target = url.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: target.path) else {
            try data.write(to: target, options: .atomic)
            return
        }
        let scratch = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: target, create: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent(target.lastPathComponent)
        try data.write(to: copy)
        do {
            _ = try fileManager.replaceItemAt(target, withItemAt: copy)
        } catch {
            // replaceItemAt swaps the content first and only afterwards tries
            // to carry the original's permissions, extended attributes and
            // creation date over to the replacement -- a permission problem
            // in that second step throws even though the swap already
            // landed. Trust what is actually on disk over the error.
            guard let onDisk = try? Data(contentsOf: target), onDisk == data else { throw error }
        }
    }

    static func modificationDate(of url: URL) -> Date? {
        try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

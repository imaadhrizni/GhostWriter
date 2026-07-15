import Foundation

// MARK: - Text-file reading
//
// One place for the `try? String(contentsOf:encoding:.utf8)` boilerplate that
// was repeated at ~28 sites (note scanning, front-matter parsing, transcripts,
// exports). Reading a note as UTF-8 text is the app's single most common file
// operation — this keeps every call site short and consistent.

extension URL {
    /// The file's contents as a UTF-8 string, or `nil` if it can't be read.
    func readText() -> String? {
        try? String(contentsOf: self, encoding: .utf8)
    }
}

import Foundation

/// Mirrors epub2tts-edge's own `get_book()` chapter/paragraph split exactly, so the
/// resulting per-chapter paragraph counts line up 1:1, in order, with the chapters
/// `read_book()` actually iterates and runs a tqdm progress bar over. That lets us
/// translate its per-chapter "N/M" progress into a whole-book fraction, since
/// epub2tts-edge itself has no concept of overall-book progress.
enum BookProgressEstimator {
    static func chapterParagraphCounts(bookText: String) -> [Int] {
        var counts: [Int] = []
        var current = 0
        var linesSkipped = 0

        for rawLine in bookText.components(separatedBy: "\n") {
            if linesSkipped < 2, rawLine.hasPrefix("Title") || rawLine.hasPrefix("Author") {
                linesSkipped += 1
                continue
            }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if current > 0 {
                    counts.append(current)
                    current = 0
                }
            } else if !line.isEmpty, line.contains(where: { $0.isLetter || $0.isNumber }) {
                current += 1
            }
        }
        if current > 0 {
            counts.append(current)
        }
        return counts
    }
}

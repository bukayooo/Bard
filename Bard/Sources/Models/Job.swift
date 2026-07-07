import Foundation

enum SourceKind: String, Codable {
    case epub
    case pdf
    case txt

    static func from(url: URL) -> SourceKind? {
        switch url.pathExtension.lowercased() {
        case "epub": return .epub
        case "pdf": return .pdf
        case "txt": return .txt
        default: return nil
        }
    }
}

@MainActor
@Observable
final class Job: Identifiable {
    let id: UUID
    let kind: SourceKind
    let originalURL: URL
    let workDir: URL

    var title: String = ""
    var author: String = ""
    var coverURL: URL?
    var txtURL: URL?
    var outputURL: URL?

    var state: JobState = .idle
    var log: [String] = []

    init(kind: SourceKind, originalURL: URL, workDir: URL) {
        self.id = UUID()
        self.kind = kind
        self.originalURL = originalURL
        self.workDir = workDir
        self.title = originalURL.deletingPathExtension().lastPathComponent
    }

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > 4000 {
            log.removeFirst(log.count - 4000)
        }
    }
}

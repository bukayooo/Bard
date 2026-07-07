import Foundation

enum JobFileManagerError: Error, LocalizedError {
    case cannotCreateDirectory(String)
    case cannotCopyFile(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let msg): return "Could not create working directory: \(msg)"
        case .cannotCopyFile(let msg): return "Could not copy file: \(msg)"
        }
    }
}

enum JobFileManager {
    static func createJob(for sourceURL: URL) throws -> (workDir: URL, copiedSource: URL) {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let bardDir = appSupport.appendingPathComponent("Bard/Jobs", isDirectory: true)
        let jobDir = bardDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: jobDir, withIntermediateDirectories: true)
        } catch {
            throw JobFileManagerError.cannotCreateDirectory(error.localizedDescription)
        }
        let dest = jobDir.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: sourceURL, to: dest)
        } catch {
            throw JobFileManagerError.cannotCopyFile(error.localizedDescription)
        }
        return (jobDir, dest)
    }

    static func sanitizedFilename(from title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "audiobook" : trimmed
    }

    @discardableResult
    static func exportOutput(_ producedURL: URL, title: String, to folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = sanitizedFilename(from: title)
        var dest = folder.appendingPathComponent("\(base).m4b")
        var counter = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base) \(counter).m4b")
            counter += 1
        }
        try fm.copyItem(at: producedURL, to: dest)
        return dest
    }
}

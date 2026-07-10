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
    private static let metadataFilename = ".bard-job.json"

    /// Persists a job's identity into its working directory so it can be recognized
    /// and restored on the next launch if Bard quits before the job finishes.
    static func saveMetadata(_ metadata: JobMetadata, in workDir: URL) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: workDir.appendingPathComponent(metadataFilename))
    }

    static func loadMetadata(from workDir: URL) -> JobMetadata? {
        let url = workDir.appendingPathComponent(metadataFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JobMetadata.self, from: data)
    }

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

    /// Lists entries under Application Support/Bard/Jobs that aren't in `activePaths`
    /// — i.e. leftover job folders Bard has no other way to reach, since it doesn't
    /// persist job history across launches (from a previous session, or a crash).
    static func orphanedJobDirs(excluding activePaths: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard
            let appSupport = try? fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return [] }
        let jobsDir = appSupport.appendingPathComponent("Bard/Jobs", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: jobsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.filter { !activePaths.contains($0.standardizedFileURL.path) }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    static func deleteJobDirs(_ dirs: [URL]) {
        for dir in dirs {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

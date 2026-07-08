import Foundation

/// Tracks which job working directories currently back a job in the sidebar.
/// Settings lives in its own SwiftUI Scene with no direct access to ContentView's
/// job list, but its "Clean Up Old Files" action still needs to know which
/// folders under Application Support/Bard/Jobs are still in use so it doesn't
/// delete out from under an open job — this is the shared source of truth for that.
final class ActiveJobsRegistry: @unchecked Sendable {
    static let shared = ActiveJobsRegistry()

    private let lock = NSLock()
    private var paths: Set<String> = []

    private init() {}

    func register(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        paths.insert(url.standardizedFileURL.path)
    }

    func unregister(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        paths.remove(url.standardizedFileURL.path)
    }

    func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

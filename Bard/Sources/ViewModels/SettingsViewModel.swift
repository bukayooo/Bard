import Foundation

@MainActor
@Observable
final class SettingsViewModel {
    var apiKey: String {
        didSet { KeychainStore.save(apiKey: apiKey) }
    }
    var repoPath: String {
        didSet {
            AppSettings.shared.epub2ttsRepoPath = repoPath
            repoConfigured = AppSettings.shared.isRepoConfigured()
        }
    }
    var outputFolderPath: String {
        didSet { AppSettings.shared.outputFolderPath = outputFolderPath }
    }
    var defaultSpeaker: String {
        didSet { AppSettings.shared.speaker = defaultSpeaker }
    }
    var sentencePauseMs: Int {
        didSet { AppSettings.shared.sentencePauseMs = sentencePauseMs }
    }
    var paragraphPauseMs: Int {
        didSet { AppSettings.shared.paragraphPauseMs = paragraphPauseMs }
    }
    var externalEditorPath: String {
        didSet { AppSettings.shared.externalEditorPath = externalEditorPath }
    }

    var voices: [String] = AppSettings.fallbackVoices
    var repoConfigured: Bool = false

    var orphanedJobDirsCount: Int = 0
    var orphanedJobsSize: Int64 = 0
    private var orphanedJobDirs: [URL] = []

    init() {
        apiKey = KeychainStore.load() ?? ""
        repoPath = AppSettings.shared.epub2ttsRepoPath
        outputFolderPath = AppSettings.shared.outputFolderPath
        defaultSpeaker = AppSettings.shared.speaker
        sentencePauseMs = AppSettings.shared.sentencePauseMs
        paragraphPauseMs = AppSettings.shared.paragraphPauseMs
        externalEditorPath = AppSettings.shared.externalEditorPath
        repoConfigured = AppSettings.shared.isRepoConfigured()
    }

    func refreshVoices() async {
        let list = await Epub2TTSRunner.shared.listVoices()
        voices = list
    }

    func chooseRepoFolder(url: URL) {
        repoPath = url.path
    }

    func chooseOutputFolder(url: URL) {
        outputFolderPath = url.path
    }

    func chooseExternalEditor(url: URL) {
        externalEditorPath = url.path
    }

    func clearExternalEditor() {
        externalEditorPath = ""
    }

    /// Bard doesn't persist job history across launches, so a job's working
    /// directory under Application Support/Bard/Jobs only ever gets cleaned up by
    /// deleting it from the sidebar in the session that created it. Anything left
    /// over from a previous launch (or a crash) needs this instead.
    func scanForOrphanedJobDirs() {
        let dirs = JobFileManager.orphanedJobDirs(excluding: ActiveJobsRegistry.shared.snapshot())
        orphanedJobDirs = dirs
        orphanedJobDirsCount = dirs.count
        orphanedJobsSize = dirs.reduce(0) { $0 + JobFileManager.directorySize($1) }
    }

    func deleteOrphanedJobDirs() {
        JobFileManager.deleteJobDirs(orphanedJobDirs)
        orphanedJobDirs = []
        orphanedJobDirsCount = 0
        orphanedJobsSize = 0
    }
}

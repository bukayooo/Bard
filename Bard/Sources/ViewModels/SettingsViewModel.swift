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

    var voices: [String] = AppSettings.fallbackVoices
    var repoConfigured: Bool = false

    init() {
        apiKey = KeychainStore.load() ?? ""
        repoPath = AppSettings.shared.epub2ttsRepoPath
        outputFolderPath = AppSettings.shared.outputFolderPath
        defaultSpeaker = AppSettings.shared.speaker
        sentencePauseMs = AppSettings.shared.sentencePauseMs
        paragraphPauseMs = AppSettings.shared.paragraphPauseMs
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
}

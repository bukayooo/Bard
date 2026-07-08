import Foundation

// Read from both MainActor (UI) and the Epub2TTSRunner actor (path resolution);
// storage is plain value types (String/Int) via UserDefaults, so unsynchronized
// reads are benign (worst case a momentarily stale value), hence @unchecked Sendable.
@Observable
final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()

    static let fallbackVoices = [
        "en-US-AndrewNeural", "en-US-AnaNeural", "en-US-AndrewMultilingualNeural",
        "en-US-AriaNeural", "en-US-AvaMultilingualNeural", "en-US-AvaNeural",
        "en-US-BrianMultilingualNeural", "en-US-BrianNeural", "en-US-ChristopherNeural",
        "en-US-EmmaMultilingualNeural", "en-US-EmmaNeural", "en-US-EricNeural",
        "en-US-GuyNeural", "en-US-JennyNeural", "en-US-MichelleNeural",
        "en-US-RogerNeural", "en-US-SteffanNeural",
    ]

    private let defaults = UserDefaults.standard

    var epub2ttsRepoPath: String {
        didSet { defaults.set(epub2ttsRepoPath, forKey: "epub2ttsRepoPath") }
    }

    var speaker: String {
        didSet { defaults.set(speaker, forKey: "speaker") }
    }

    var sentencePauseMs: Int {
        didSet { defaults.set(sentencePauseMs, forKey: "sentencePauseMs") }
    }

    var paragraphPauseMs: Int {
        didSet { defaults.set(paragraphPauseMs, forKey: "paragraphPauseMs") }
    }

    var outputFolderPath: String {
        didSet { defaults.set(outputFolderPath, forKey: "outputFolderPath") }
    }

    /// Path to a preferred external text editor .app bundle (e.g. BBEdit, Sublime Text).
    /// Empty means "no external editor configured" — the built-in text view is used only.
    var externalEditorPath: String {
        didSet { defaults.set(externalEditorPath, forKey: "externalEditorPath") }
    }

    var availableVoices: [String] = AppSettings.fallbackVoices

    private init() {
        epub2ttsRepoPath = defaults.string(forKey: "epub2ttsRepoPath")
            ?? ("~/epub2tts-edge" as NSString).expandingTildeInPath
        speaker = defaults.string(forKey: "speaker") ?? "en-US-GuyNeural"
        sentencePauseMs = defaults.object(forKey: "sentencePauseMs") as? Int ?? 1200
        paragraphPauseMs = defaults.object(forKey: "paragraphPauseMs") as? Int ?? 1200
        outputFolderPath = defaults.string(forKey: "outputFolderPath")
            ?? ("~/Documents/Audiobooks" as NSString).expandingTildeInPath
        externalEditorPath = defaults.string(forKey: "externalEditorPath") ?? ""
    }

    var epub2ttsRepoURL: URL { URL(fileURLWithPath: epub2ttsRepoPath) }
    var outputFolderURL: URL { URL(fileURLWithPath: outputFolderPath) }

    var epub2ttsBinaryURL: URL {
        epub2ttsRepoURL.appendingPathComponent(".venv/bin/epub2tts-edge")
    }

    var edgeTTSBinaryURL: URL {
        epub2ttsRepoURL.appendingPathComponent(".venv/bin/edge-tts")
    }

    func isRepoConfigured() -> Bool {
        FileManager.default.isExecutableFile(atPath: epub2ttsBinaryURL.path)
    }

    var externalEditorURL: URL? {
        externalEditorPath.isEmpty ? nil : URL(fileURLWithPath: externalEditorPath)
    }

    var hasExternalEditor: Bool { externalEditorURL != nil }

    var externalEditorName: String {
        externalEditorURL?.deletingPathExtension().lastPathComponent ?? "External Editor"
    }
}

import Foundation

enum JobState: Equatable {
    case idle
    case extracting(detail: String)
    case readyForReview
    case synthesizing(detail: String, fraction: Double?)
    case done
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

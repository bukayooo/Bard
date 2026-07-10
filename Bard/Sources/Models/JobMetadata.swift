import Foundation

/// Minimal on-disk record of a job's identity, written into its working directory
/// so an interrupted job (Bard quit or crashed mid-run) can be identified and
/// restored to the sidebar on the next launch. Completed jobs have their working
/// directory deleted once exported (see JobViewModel.startSynthesis), so metadata
/// never outlives its usefulness — anything found on disk at launch is by
/// definition an incomplete job.
struct JobMetadata: Codable {
    let kind: SourceKind
    let originalFilename: String
    var title: String
    var author: String
}

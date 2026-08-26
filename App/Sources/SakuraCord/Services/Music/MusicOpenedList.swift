import Foundation

/// A playlist or album the listener opened, and what is in it.
nonisolated struct MusicOpenedList: Equatable, Sendable {
    /// The page's id for this collection, kept so a late reply for one the
    /// listener has already left can be told apart and dropped.
    let browseId: String

    let title: String
    let subtitle: String
    let artwork: String?
    var items: [MusicSearchResult]
    var isLoading: Bool

    var artworkURL: URL? {
        artwork.flatMap { MusicArtworkURL.upscaled(from: $0, size: 240) }
    }
}

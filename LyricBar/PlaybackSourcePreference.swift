nonisolated enum PreferredNowPlayingSource: Equatable {
    case spotify
    case appleMusic
}

nonisolated func preferredNowPlayingSource(
    spotifyState: PlaybackState?,
    appleMusicState: PlaybackState?,
    previouslySelected: PreferredNowPlayingSource?,
    hasPreviousSnapshot: Bool = false
) -> PreferredNowPlayingSource? {
    if spotifyState == .playing, appleMusicState != .playing { return .spotify }
    if appleMusicState == .playing, spotifyState != .playing { return .appleMusic }
    if spotifyState == .playing, appleMusicState == .playing { return .spotify }

    if spotifyState == .paused, appleMusicState == .paused {
        if previouslySelected == .spotify { return .spotify }
        if previouslySelected == .appleMusic { return .appleMusic }
        return .spotify
    }
    if hasPreviousSnapshot {
        if previouslySelected == .spotify,
           spotifyState == nil,
           appleMusicState == .paused {
            return .spotify
        }
        if previouslySelected == .appleMusic,
           appleMusicState == nil,
           spotifyState == .paused {
            return .appleMusic
        }
    }
    if spotifyState == .paused { return .spotify }
    if appleMusicState == .paused { return .appleMusic }
    return nil
}

nonisolated func shouldRetainNowPlayingSnapshot(hasTrack: Bool, state: PlaybackState) -> Bool {
    hasTrack && state != .idle
}

nonisolated struct NowPlayingPollGate: Sendable {
    private var nextToken: UInt64 = 0
    private var activeToken: UInt64?

    mutating func begin() -> UInt64? {
        guard activeToken == nil else { return nil }
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }

    mutating func finish(_ token: UInt64) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        return true
    }

    mutating func invalidate() {
        activeToken = nil
        nextToken &+= 1
    }
}

import Foundation

/// Capture order and the "trip so far" filter behind the time slider, replay and swipe viewer.
///
/// Photos with a capture time (`takenAt`) come first, oldest to newest. Photos without one
/// can't be placed on the timeline, so they sort after every dated photo (by upload time)
/// and only appear once the slider reaches the end of the trip, i.e. "the whole trip".
/// Using the upload time instead would put them wherever the uploader happened to sync,
/// often days after the trip, and stretch the slider's range.
struct CaptureTimeline: Sendable {
    /// Every photo in capture order (dated first, then undated).
    let ordered: [Photo]
    /// Number of leading photos in `ordered` that have a `takenAt`.
    let datedCount: Int

    init(_ photos: [Photo]) {
        ordered = photos.sorted(by: Self.captureOrder)
        datedCount = ordered.prefix { $0.takenAt != nil }.count
    }

    var dated: ArraySlice<Photo> { ordered.prefix(datedCount) }
    var undatedCount: Int { ordered.count - datedCount }

    /// First to last capture time, or nil when no photo has one.
    var range: ClosedRange<Date>? {
        guard let first = dated.first?.takenAt, let last = dated.last?.takenAt else { return nil }
        return first...last
    }

    /// Replay needs at least two distinct capture times to be meaningful.
    var supportsReplay: Bool {
        guard let range else { return false }
        return range.lowerBound < range.upperBound
    }

    /// Photos visible at `cutoff`, in capture order. `nil`, or a cutoff at or past the end of
    /// the range, means the whole trip, including undated photos.
    func visible(upTo cutoff: Date?) -> [Photo] {
        guard let cutoff, let range, cutoff < range.upperBound else { return ordered }
        return Array(dated.prefix { $0.takenAt! <= cutoff })
    }

    /// Whether `cutoff` shows the whole trip.
    func isAtEnd(_ cutoff: Date?) -> Bool {
        guard let cutoff, let range else { return true }
        return cutoff >= range.upperBound
    }

    /// Strict weak order: dated by capture time, undated after them by upload time; ties by id
    /// so the order is stable across refreshes.
    static func captureOrder(_ a: Photo, _ b: Photo) -> Bool {
        switch (a.takenAt, b.takenAt) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default:
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id < b.id
        }
    }
}

/// Position of the time slider as a 0...1 fraction of the capture range.
extension ClosedRange where Bound == Date {
    func fraction(of date: Date) -> Double {
        let span = upperBound.timeIntervalSince(lowerBound)
        guard span > 0 else { return 1 }
        return Swift.min(Swift.max(date.timeIntervalSince(lowerBound) / span, 0), 1)
    }

    func date(atFraction fraction: Double) -> Date {
        lowerBound.addingTimeInterval(upperBound.timeIntervalSince(lowerBound) * Swift.min(Swift.max(fraction, 0), 1))
    }
}

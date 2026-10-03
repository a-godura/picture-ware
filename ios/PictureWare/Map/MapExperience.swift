import MapKit
import Observation
import SwiftUI

/// State behind the map screen: which photos are visible (uploader filter + time slider),
/// how they cluster at the current zoom, replay, and the swipe viewer.
///
/// Everything is derived on device from `photos`; nothing here refetches.
@MainActor
@Observable
final class MapExperience {
    /// Minimum on-screen distance between pin centres before they merge (pins are 48pt).
    static let pinSpacing: Double = 64

    /// A request to open the swipe viewer on `photos` at `startID`.
    struct Browse: Identifiable {
        let id = UUID()
        let photos: [Photo]
        let startID: Photo.ID
    }

    // MARK: Inputs

    var photos: [Photo] = [] { didSet { if photos != oldValue { rebuildTimeline() } } }
    var uploaderFilter = UploaderFilter<String>() { didSet { if uploaderFilter != oldValue { rebuildFiltered() } } }
    /// Selected time; `nil` shows the whole trip.
    var cutoff: Date? { didSet { if cutoff != oldValue { rebuildVisible() } } }
    var isTimelineOpen = false {
        didSet { if !isTimelineOpen { stop(); cutoff = nil } }
    }
    var browsing: Browse?

    @ObservationIgnored let uploaderKey: (Photo) -> String?
    @ObservationIgnored let uploaderName: (String) -> String

    // MARK: Derived

    private(set) var timeline = CaptureTimeline([])
    private(set) var uploaderOptions: [UploaderFilter<String>.Option] = []
    /// Uploader-filtered photos in capture order.
    private(set) var filtered: [Photo] = []
    /// Filtered photos visible at `cutoff`, in capture order.
    private(set) var visible: [Photo] = []
    private(set) var clusters: [MapCluster<Photo>] = []
    private(set) var isPlaying = false

    @ObservationIgnored private var viewport: (rect: MKMapRect, pointsPerScreenPoint: Double)?
    @ObservationIgnored private var clusterRadius: Double = -1
    @ObservationIgnored private var playback: Task<Void, Never>?

    init(uploaderKey: @escaping (Photo) -> String? = { _ in nil },
         uploaderName: @escaping (String) -> String = { $0 }) {
        self.uploaderKey = uploaderKey
        self.uploaderName = uploaderName
    }

    var showsUploaderFilter: Bool { uploaderOptions.count > 1 }
    var supportsReplay: Bool { timeline.supportsReplay }

    func name(of option: UploaderFilter<String>.Option) -> String {
        switch option {
        case .uploader(let key): uploaderName(key)
        case .unknown: "Unknown"
        }
    }

    // MARK: Viewport

    /// Call when the camera settles. `viewWidth` is the map's width in points.
    func cameraChanged(rect: MKMapRect, viewWidth: Double) {
        guard viewWidth > 0, rect.width > 0 else { return }
        viewport = (rect, rect.width / viewWidth)
        recluster()
    }

    // MARK: Taps

    func tap(_ cluster: MapCluster<Photo>) -> MKMapRect? {
        if cluster.isSingle {
            browsing = Browse(photos: visible, startID: cluster.representative.id)
            return nil
        }
        // Same spot (or close enough that zooming won't separate them): show the group.
        let coordinates = cluster.members.map(\.coordinate)
        if PhotoClusterer.spanInMeters(of: coordinates) < 30 {
            browsing = Browse(photos: cluster.members, startID: cluster.members[0].id)
            return nil
        }
        return PhotoClusterer.zoomRect(for: coordinates)
    }

    // MARK: Replay

    /// Capture times the replay steps through (filtered, dated photos).
    var playbackTimes: [Date] { filtered.compactMap(\.takenAt) }

    func togglePlayback() { isPlaying ? stop() : play() }

    func play() {
        let times = playbackTimes
        guard times.count > 1 else { return }
        stop()
        isTimelineOpen = true
        var start = 0
        if let cutoff, !timeline.isAtEnd(cutoff) {
            start = (times.firstIndex { $0 > cutoff } ?? 0)
        }
        // About 15 s for a whole trip, but not slower than 0.7 s or faster than 0.05 s a photo.
        let step = min(max(15 / Double(times.count), 0.05), 0.7)
        isPlaying = true
        playback = Task { [weak self] in
            for i in start..<times.count {
                guard let self, !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: min(step, 0.3))) { self.cutoff = times[i] }
                try? await Task.sleep(for: .seconds(step))
            }
            guard let self, !Task.isCancelled else { return }
            withAnimation { self.cutoff = nil }  // finish on the whole trip, undated photos too
            self.isPlaying = false
        }
    }

    func stop() {
        playback?.cancel()
        playback = nil
        isPlaying = false
    }

    // MARK: Rebuilding

    private func rebuildTimeline() {
        timeline = CaptureTimeline(photos)
        uploaderOptions = UploaderFilter.options(in: photos, key: uploaderKey)
        var pruned = uploaderFilter
        pruned.prune(to: uploaderOptions)
        if pruned != uploaderFilter { uploaderFilter = pruned } else { rebuildFiltered() }
    }

    private func rebuildFiltered() {
        filtered = uploaderFilter.apply(to: timeline.ordered, key: uploaderKey)
        rebuildVisible()
    }

    private func rebuildVisible() {
        if let cutoff, !timeline.isAtEnd(cutoff) {
            visible = Array(filtered.prefix { $0.takenAt.map { $0 <= cutoff } ?? false })
        } else {
            visible = filtered
        }
        clusterRadius = -1
        recluster()
    }

    private func recluster() {
        let pointsPerScreenPoint = viewport?.pointsPerScreenPoint ?? fallbackPointsPerScreenPoint()
        let radius = PhotoClusterer.radius(pinSpacing: Self.pinSpacing, mapPointsPerScreenPoint: pointsPerScreenPoint)
        let all = radius == clusterRadius ? lastAll : PhotoClusterer.cluster(visible, radius: radius, coordinate: \.coordinate)
        clusterRadius = radius
        lastAll = all
        clusters = onScreen(all)
    }

    @ObservationIgnored private var lastAll: [MapCluster<Photo>] = []

    /// Only clusters in (a generous margin around) the viewport get annotation views.
    private func onScreen(_ all: [MapCluster<Photo>]) -> [MapCluster<Photo>] {
        guard let rect = viewport?.rect else { return all }
        let margin = rect.insetBy(dx: -rect.width * 0.5, dy: -rect.height * 0.5)
        return all.filter { margin.contains(MKMapPoint($0.coordinate)) }
    }

    /// Before the map reports its camera, assume all photos fit a phone-width screen.
    private func fallbackPointsPerScreenPoint() -> Double {
        guard let rect = MapFit.rect(for: visible.map(\.coordinate)) else { return 0 }
        return rect.width / 390
    }
}

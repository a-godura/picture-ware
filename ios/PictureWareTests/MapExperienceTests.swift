import CoreLocation
import Foundation
import MapKit
import Testing
@testable import PictureWare

/// Timing budget for the 1,000-photo checks. Locally (Debug, simulator)
/// clustering takes ~4–6 ms and a scrub step ~2 ms; CI's shared macOS
/// runners are several times slower and noisy (one run measured 18.5 ms).
/// The budget is loose enough not to flake there but still catches an
/// order-of-magnitude regression (e.g. an accidental O(n²) clusterer).
private let perfBudget = Duration.milliseconds(60)

private func photo(_ id: String, lat: Double = 38.7, lng: Double = -9.1,
                   taken: TimeInterval?, created: TimeInterval = 0) -> Photo {
    Photo(id: id, lat: lat, lng: lng,
          takenAt: taken.map { Date(timeIntervalSince1970: $0) },
          createdAt: Date(timeIntervalSince1970: created),
          imageUrl: URL(string: "https://example.invalid/\(id).jpg")!)
}

/// Map points per metre around Lisbon, to express radii in metres.
private let perMeter = MKMapPointsPerMeterAtLatitude(38.7)

@Suite("Clustering")
struct ClustererTests {
    @Test func zeroRadiusKeepsEveryPhotoSeparate() {
        let photos = (0..<5).map { photo("p\($0)", taken: Double($0)) }
        let clusters = PhotoClusterer.cluster(photos, radius: 0, coordinate: \.coordinate)
        #expect(clusters.count == 5)
        #expect(clusters.allSatisfy { $0.isSingle })
    }

    @Test func nearbyPhotosMergeAndFarOnesDont() throws {
        let photos = [
            photo("a", lat: 38.7000, lng: -9.1000, taken: 1),
            photo("b", lat: 38.7001, lng: -9.1001, taken: 2),  // ~14 m from a
            photo("c", lat: 38.7500, lng: -9.1000, taken: 3),  // ~5.5 km away
        ]
        let clusters = PhotoClusterer.cluster(photos, radius: 100 * perMeter, coordinate: \.coordinate)
        #expect(clusters.count == 2)
        let pair = try #require(clusters.first { $0.count == 2 })
        #expect(pair.members.map(\.id) == ["a", "b"])
        #expect(pair.id == "a", "identity is the earliest member")
        #expect(pair.representative.id == "b", "thumbnail is the newest member")
        #expect(abs(pair.coordinate.latitude - 38.70005) < 1e-6, "positioned at the centroid")
    }

    @Test func mergesAcrossGridCellBoundaries() {
        // Two points 10 map points apart straddling a cell edge of a 1000-point grid.
        let radius = 1000.0
        let left = MKMapPoint(x: 134_217_000 - 5, y: 100_000_000).coordinate
        let right = MKMapPoint(x: 134_217_000 + 5, y: 100_000_000).coordinate
        let photos = [photo("l", lat: left.latitude, lng: left.longitude, taken: 1),
                      photo("r", lat: right.latitude, lng: right.longitude, taken: 2)]
        #expect(PhotoClusterer.cluster(photos, radius: radius, coordinate: \.coordinate).count == 1)
    }

    @Test func zoomingInSplitsClusters() {
        let photos = SampleTrip.photos(count: 200)
        let counts = [10_000.0, 1_000, 100, 10].map { meters in
            PhotoClusterer.cluster(photos, radius: meters * perMeter, coordinate: \.coordinate).count
        }
        #expect(counts == counts.sorted(), "\(counts)")
        #expect(counts.first! <= 5, "10 km radius: a few bubbles per city")
        #expect(counts.last! > 13, "street zoom: more pins than sample spots")
    }

    @Test func everyPhotoLandsInExactlyOneCluster() {
        let photos = SampleTrip.photos(count: 300)
        let clusters = PhotoClusterer.cluster(photos, radius: 500 * perMeter, coordinate: \.coordinate)
        let ids = clusters.flatMap { $0.members.map(\.id) }
        #expect(ids.count == photos.count)
        #expect(Set(ids) == Set(photos.map(\.id)))
    }

    @Test func radiusIsQuantizedToHalfZoomLevels() {
        let a = PhotoClusterer.radius(pinSpacing: 50, mapPointsPerScreenPoint: 100)
        let b = PhotoClusterer.radius(pinSpacing: 50, mapPointsPerScreenPoint: 103)
        let c = PhotoClusterer.radius(pinSpacing: 50, mapPointsPerScreenPoint: 200)
        #expect(a == b, "small camera nudges keep the same clusters")
        #expect(c > a)
        #expect(PhotoClusterer.radius(pinSpacing: 50, mapPointsPerScreenPoint: 0) == 0)
    }

    @Test func spanAndZoomRect() throws {
        let same = [CLLocationCoordinate2D(latitude: 38.7, longitude: -9.1),
                    CLLocationCoordinate2D(latitude: 38.7, longitude: -9.1)]
        #expect(PhotoClusterer.spanInMeters(of: same) == 0)
        let rect = try #require(PhotoClusterer.zoomRect(for: same, minimumMeters: 150))
        #expect(rect.width / perMeter > 150)
        #expect(rect.width / perMeter < 300, "zooms much closer than Fit All's 2 km minimum")
        #expect(rect.contains(MKMapPoint(same[0])))
    }


    /// ~1,000 photos must re-cluster quickly on every zoom change.
    @Test func performanceWithAThousandPhotos() {
        let photos = SampleTrip.photos(count: 1000)
        let clock = ContinuousClock()
        var worst = Duration.zero
        for meters in [50_000.0, 5_000, 500, 50, 5] {
            let elapsed = clock.measure {
                _ = PhotoClusterer.cluster(photos, radius: meters * perMeter, coordinate: \.coordinate)
            }
            worst = max(worst, elapsed)
        }
        print("PERF cluster 1000 photos, worst of 5 zoom levels: \(worst)")
        #expect(worst < perfBudget)
    }
}

@Suite("Capture timeline")
struct CaptureTimelineTests {
    let photos = [
        photo("late", taken: 300, created: 1),
        photo("undated-new", taken: nil, created: 900),
        photo("early", taken: 100, created: 2),
        photo("undated-old", taken: nil, created: 800),
        photo("mid-b", taken: 200, created: 5),
        photo("mid-a", taken: 200, created: 5),
    ]

    @Test func capturesOrderDatedFirstThenUndatedByUploadTime() {
        let timeline = CaptureTimeline(photos)
        #expect(timeline.ordered.map(\.id) == ["early", "mid-a", "mid-b", "late", "undated-old", "undated-new"])
        #expect(timeline.datedCount == 4)
        #expect(timeline.undatedCount == 2)
        #expect(timeline.range == Date(timeIntervalSince1970: 100)...Date(timeIntervalSince1970: 300))
    }

    @Test func orderIsStableRegardlessOfInputOrder() {
        #expect(CaptureTimeline(photos.reversed()).ordered == CaptureTimeline(photos).ordered)
    }

    @Test func visibleUpToCutoff() {
        let timeline = CaptureTimeline(photos)
        func ids(_ t: TimeInterval?) -> [String] { timeline.visible(upTo: t.map(Date.init(timeIntervalSince1970:))).map(\.id) }
        #expect(ids(nil).count == 6, "no cutoff: whole trip")
        #expect(ids(50) == [], "before the first photo")
        #expect(ids(100) == ["early"], "inclusive")
        #expect(ids(250) == ["early", "mid-a", "mid-b"], "undated photos are hidden mid-trip")
        #expect(ids(300).count == 6, "end of the slider: whole trip, undated included")
        #expect(ids(10_000).count == 6)
    }

    @Test func replayNeedsTwoDistinctCaptureTimes() {
        #expect(!CaptureTimeline([]).supportsReplay)
        #expect(CaptureTimeline([photo("u", taken: nil)]).range == nil)
        #expect(!CaptureTimeline([photo("a", taken: 5), photo("b", taken: 5)]).supportsReplay)
        #expect(CaptureTimeline(photos).supportsReplay)
    }

    @Test func sliderFractionRoundTrips() {
        let range = Date(timeIntervalSince1970: 100)...Date(timeIntervalSince1970: 300)
        #expect(range.fraction(of: Date(timeIntervalSince1970: 150)) == 0.25)
        #expect(range.date(atFraction: 0.25) == Date(timeIntervalSince1970: 150))
        #expect(range.fraction(of: .distantPast) == 0)
        #expect(range.date(atFraction: 7) == range.upperBound)
    }
}

@Suite("Uploader filter")
struct UploaderFilterTests {
    typealias Filter = UploaderFilter<String>
    struct Item { let name: String; let by: String? }
    let key: (Item) -> String? = { $0.by }

    @Test func optionsAreSortedWithUnknownLast() {
        let items = [Item(name: "1", by: "zoe"), Item(name: "2", by: nil), Item(name: "3", by: "ana"), Item(name: "4", by: "zoe")]
        #expect(Filter.options(in: items, key: key) == [.uploader("ana"), .uploader("zoe"), .unknown])
    }

    @Test func hiddenWithOnlyOneUploader() {
        #expect(!Filter.isUseful(for: [Item(name: "1", by: "ana"), Item(name: "2", by: "ana")], key: key))
        #expect(!Filter.isUseful(for: [Item(name: "legacy", by: nil)], key: key), "legacy photos only")
        #expect(!Filter.isUseful(for: [Item](), key: key))
        #expect(Filter.isUseful(for: [Item(name: "1", by: "ana"), Item(name: "2", by: nil)], key: key))
    }

    @Test func applyHidesSelectedUploaders() {
        let items = [Item(name: "1", by: "ana"), Item(name: "2", by: "ben"), Item(name: "3", by: nil)]
        var filter = Filter()
        #expect(filter.apply(to: items, key: key).count == 3)
        filter.hidden = [.uploader("ben"), .unknown]
        #expect(filter.apply(to: items, key: key).map(\.name) == ["1"])
    }

    @Test func toggleNeverHidesEveryone() {
        let options: [Filter.Option] = [.uploader("ana"), .uploader("ben")]
        var filter = Filter()
        filter.toggle(.uploader("ana"), among: options)
        #expect(filter.hidden == [.uploader("ana")])
        filter.toggle(.uploader("ben"), among: options)
        #expect(filter.hidden == [.uploader("ana")], "the last shown uploader stays shown")
        filter.toggle(.uploader("ana"), among: options)
        #expect(filter.hidden.isEmpty)
        filter.showOnly(.uploader("ben"), among: options)
        #expect(filter.hidden == [.uploader("ana")])
    }

    @Test func pruneDropsStaleState() {
        var filter = Filter(hidden: [.uploader("gone"), .uploader("ana")])
        filter.prune(to: [.uploader("ana"), .uploader("ben")])
        #expect(filter.hidden == [.uploader("ana")])
        filter.prune(to: [.uploader("ana")])
        #expect(filter.hidden.isEmpty, "never ends up hiding everything")
    }

    @Test func worksWithAnyComparableKey() {
        let items = [(1, "a"), (2, "b"), (1, "c")]
        let filter = UploaderFilter<Int>(hidden: [.uploader(2)])
        #expect(filter.apply(to: items) { $0.0 }.map(\.1) == ["a", "c"])
    }
}

@Suite("Map experience")
@MainActor
struct MapExperienceTests {
    @Test func legacyPhotosShowNoUploaderFilter() {
        let experience = MapExperience()
        experience.photos = SampleTrip.photos(count: 20)
        #expect(!experience.showsUploaderFilter)
        #expect(experience.visible.count == 20)
    }

    @Test func uploaderFilterAndTimeCombine() throws {
        let experience = MapExperience(uploaderKey: SampleTrip.uploader(of:))
        let photos = SampleTrip.photos(count: 60)
        experience.photos = photos
        #expect(experience.showsUploaderFilter)
        experience.uploaderFilter.hidden = [.uploader("ben")]
        #expect(experience.visible.allSatisfy { SampleTrip.uploader(of: $0) != "ben" })
        let range = try #require(experience.timeline.range)
        experience.cutoff = range.date(atFraction: 0.5)
        #expect(experience.visible.allSatisfy { $0.takenAt! <= experience.cutoff! })
        #expect(experience.visible.count < experience.filtered.count)
        #expect(experience.clusters.reduce(0) { $0 + $1.count } == experience.visible.count)
        #expect(experience.visible == experience.visible.sorted(by: CaptureTimeline.captureOrder))
    }

    @Test func closingReplayShowsTheWholeTrip() throws {
        let experience = MapExperience()
        experience.photos = SampleTrip.photos(count: 30)
        experience.isTimelineOpen = true
        experience.cutoff = try #require(experience.timeline.range).lowerBound
        #expect(experience.visible.count == 1)
        experience.isTimelineOpen = false
        #expect(experience.cutoff == nil)
        #expect(experience.visible.count == 30)
    }

    @Test func tappingAPinOpensTheSwipeViewerInCaptureOrder() throws {
        let experience = MapExperience()
        experience.photos = SampleTrip.photos(count: 30).shuffled()
        // The whole world in view, but at sub-metre zoom: only exact duplicates cluster.
        experience.cameraChanged(rect: .world, viewWidth: MKMapRect.world.width * 10)
        let single = try #require(experience.clusters.first { $0.isSingle })
        #expect(experience.tap(single) == nil)
        let browse = try #require(experience.browsing)
        #expect(browse.startID == single.representative.id)
        #expect(browse.photos == CaptureTimeline(experience.photos).ordered)
    }

    @Test func tappingASameSpotClusterShowsTheGroup() throws {
        let experience = MapExperience()
        experience.photos = [photo("a", taken: 1), photo("b", taken: 2), photo("c", taken: 3),
                             photo("far", lat: 41.1, taken: 4)]
        let cluster = try #require(experience.clusters.first { $0.count == 3 })
        #expect(experience.tap(cluster) == nil)
        #expect(experience.browsing?.photos.map(\.id) == ["a", "b", "c"])
    }

    @Test func tappingASpreadClusterZoomsIn() throws {
        let experience = MapExperience()
        experience.photos = [photo("a", lat: 38.700, taken: 1), photo("b", lat: 38.701, taken: 2),
                             photo("far", lat: 41.1, taken: 4)]
        let cluster = try #require(experience.clusters.first { $0.count == 2 })
        let rect = try #require(experience.tap(cluster))
        #expect(experience.browsing?.id == nil)
        #expect(cluster.members.allSatisfy { rect.contains(MKMapPoint($0.coordinate)) })
    }

    /// Scrubbing re-filters and re-clusters on every slider change.
    @Test func scrubbingAThousandPhotosIsFast() throws {
        let experience = MapExperience(uploaderKey: SampleTrip.uploader(of:))
        let clock = ContinuousClock()
        let load = clock.measure { experience.photos = SampleTrip.photos(count: 1000) }
        let range = try #require(experience.timeline.range)
        let steps = 100
        let scrub = clock.measure {
            for i in 0...steps { experience.cutoff = range.date(atFraction: Double(i) / Double(steps)) }
        }
        let perStep = scrub / (steps + 1)
        print("PERF 1000 photos: load+cluster \(load), scrub step (filter+cluster) \(perStep)")
        #expect(load < perfBudget * 4)
        #expect(perStep < perfBudget)
    }
}

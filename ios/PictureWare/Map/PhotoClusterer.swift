import CoreLocation
import MapKit

/// A group of nearby items shown as one pin.
struct MapCluster<Item: Identifiable>: Identifiable where Item.ID == String {
    /// The earliest member's id, so a cluster keeps its identity (and SwiftUI animates it)
    /// while a replay adds later photos to it.
    let id: String
    /// Centroid of the members.
    let coordinate: CLLocationCoordinate2D
    /// Members in input order (capture order).
    let members: [Item]

    var count: Int { members.count }
    /// The newest member, so the thumbnail follows a replay.
    var representative: Item { members[members.count - 1] }
    var isSingle: Bool { members.count == 1 }
}

/// Screen-distance clustering, computed on device for the current zoom.
///
/// SwiftUI's `Map` has no clustering on iOS 18 (`MKClusterAnnotation` is UIKit-only), so this
/// is a greedy grid clusterer: items are visited in order, and each joins the nearest existing
/// cluster whose seed is within `radius`, else seeds a new one. A grid with cell size `radius`
/// limits the search to the 3x3 neighbouring cells, so it's O(n). Distances are in Web
/// Mercator map points, which makes the result depend only on the zoom (not on panning).
enum PhotoClusterer {
    private struct Cell: Hashable { let x: Int, y: Int }
    private struct Building { let seed: MKMapPoint; var sumX: Double; var sumY: Double; var members: [Int] }

    /// - Parameters:
    ///   - items: in the order clusters should be seeded (capture order).
    ///   - radius: merge distance in `MKMapPoint` units; ≤ 0 disables clustering.
    static func cluster<Item: Identifiable>(
        _ items: [Item],
        radius: Double,
        coordinate: (Item) -> CLLocationCoordinate2D
    ) -> [MapCluster<Item>] where Item.ID == String {
        let points = items.map { MKMapPoint(coordinate($0)) }
        var clusters: [Building] = []
        guard radius > 0 else {
            return items.indices.map { i in
                MapCluster(id: items[i].id, coordinate: coordinate(items[i]), members: [items[i]])
            }
        }

        var grid: [Cell: [Int]] = [:]  // cell -> indices into `clusters` seeded there
        let radiusSquared = radius * radius
        for (i, p) in points.enumerated() {
            let cx = Int((p.x / radius).rounded(.down)), cy = Int((p.y / radius).rounded(.down))
            var best: (index: Int, distance: Double)?
            for dx in -1...1 {
                for dy in -1...1 {
                    for c in grid[Cell(x: cx + dx, y: cy + dy), default: []] {
                        let s = clusters[c].seed
                        let ex: Double = s.x - p.x, ey: Double = s.y - p.y
                        let d: Double = ex * ex + ey * ey
                        if d <= radiusSquared && d < (best?.distance ?? .infinity) { best = (c, d) }
                    }
                }
            }
            if let best {
                clusters[best.index].sumX += p.x
                clusters[best.index].sumY += p.y
                clusters[best.index].members.append(i)
            } else {
                grid[Cell(x: cx, y: cy), default: []].append(clusters.count)
                clusters.append(Building(seed: p, sumX: p.x, sumY: p.y, members: [i]))
            }
        }

        return clusters.map { b in
            let n = Double(b.members.count)
            let center = b.members.count == 1
                ? coordinate(items[b.members[0]])
                : MKMapPoint(x: b.sumX / n, y: b.sumY / n).coordinate
            return MapCluster(id: items[b.members[0]].id, coordinate: center, members: b.members.map { items[$0] })
        }
    }

    /// Merge radius for a viewport, quantized to half zoom levels so tiny camera nudges don't
    /// reshuffle the pins.
    static func radius(pinSpacing: Double, mapPointsPerScreenPoint: Double) -> Double {
        guard mapPointsPerScreenPoint > 0 else { return 0 }
        let quantized = pow(2, (log2(mapPointsPerScreenPoint) * 2).rounded() / 2)
        return pinSpacing * quantized
    }

    /// Size of the members' bounding box in metres (its longer side).
    static func spanInMeters(of coordinates: [CLLocationCoordinate2D]) -> Double {
        guard let first = coordinates.first else { return 0 }
        let points = coordinates.map(MKMapPoint.init)
        let xs = points.map(\.x), ys = points.map(\.y)
        let side = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        return side / MKMapPointsPerMeterAtLatitude(first.latitude)
    }

    /// Region to zoom into a cluster: its members with padding, at least `minimumMeters` wide.
    static func zoomRect(for coordinates: [CLLocationCoordinate2D], minimumMeters: Double = 150) -> MKMapRect? {
        guard let first = coordinates.first else { return nil }
        let points = coordinates.map(MKMapPoint.init)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let minSide = minimumMeters * MKMapPointsPerMeterAtLatitude(first.latitude)
        let width = max(maxX - minX, minSide), height = max(maxY - minY, minSide)
        return MKMapRect(x: (minX + maxX - width) / 2, y: (minY + maxY - height) / 2, width: width, height: height)
            .insetBy(dx: -width * 0.2, dy: -height * 0.2)
    }
}

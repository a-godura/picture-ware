import CoreLocation
import MapKit

enum MapFit {
    /// A map rect containing every coordinate with some padding, at least ~2 km wide.
    static func rect(for coordinates: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard !coordinates.isEmpty else { return nil }
        let points = coordinates.map(MKMapPoint.init)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let minSide = 2000 * MKMapPointsPerMeterAtLatitude(coordinates[0].latitude)
        let width = max(maxX - minX, minSide), height = max(maxY - minY, minSide)
        let rect = MKMapRect(x: (minX + maxX - width) / 2, y: (minY + maxY - height) / 2, width: width, height: height)
        return rect.insetBy(dx: -width * 0.25, dy: -height * 0.25)
    }
}

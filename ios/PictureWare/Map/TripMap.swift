import MapKit
import SwiftUI

/// Full-screen map of a trip's photos: clustered pins, the replay and uploader controls
/// (top leading), and the swipe viewer. Put `TimelineBar` wherever the screen's bottom
/// controls are.
struct TripMap: View {
    let experience: MapExperience
    @Binding var position: MapCameraPosition
    let onDelete: @MainActor (Photo) async throws -> Void
    @State private var mapWidth: Double = 0

    var body: some View {
        @Bindable var experience = experience
        Map(position: $position) {
            ForEach(experience.clusters) { cluster in
                Annotation("", coordinate: cluster.coordinate, anchor: .bottom) {
                    Button { tap(cluster) } label: { ClusterPin(cluster: cluster) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.accessibilityLabel(for: cluster))
                }
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { mapWidth = $0 }
        .onMapCameraChange(frequency: .onEnd) { context in
            withAnimation(.snappy) { experience.cameraChanged(rect: context.rect, viewWidth: mapWidth) }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) { controls }
        .sheet(item: $experience.browsing) { browse in
            PhotoBrowser(photos: browse.photos, startID: browse.startID, onDelete: onDelete)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if experience.supportsReplay && !experience.isTimelineOpen {
                Button { withAnimation { experience.isTimelineOpen = true } } label: {
                    Label("Replay", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(MapChipStyle())
            }
            if experience.showsUploaderFilter {
                UploaderFilterMenu(experience: experience)
            }
        }
        .padding()
    }

    private func tap(_ cluster: MapCluster<Photo>) {
        if let rect = experience.tap(cluster) {
            withAnimation { position = .rect(rect) }
        }
    }

    static func accessibilityLabel(for cluster: MapCluster<Photo>) -> String {
        if cluster.isSingle {
            return cluster.representative.takenAt
                .map { "Photo taken \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Photo"
        }
        return "\(cluster.count) photos"
    }
}

/// A round photo thumbnail, with a count badge when it stands for several photos.
struct ClusterPin: View {
    let cluster: MapCluster<Photo>

    var body: some View {
        PhotoThumbnail(url: cluster.representative.imageUrl)
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .overlay(alignment: .topTrailing) {
                if !cluster.isSingle {
                    Text(cluster.count, format: .number)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Color.accentColor, in: Capsule())
                        .overlay(Capsule().stroke(.white, lineWidth: 2))
                        .offset(x: 8, y: -8)
                }
            }
            .shadow(radius: 3, y: 1)
    }
}

struct PhotoThumbnail: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else if phase.error != nil {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct UploaderFilterMenu: View {
    let experience: MapExperience

    var body: some View {
        let options = experience.uploaderOptions
        let filter = experience.uploaderFilter
        Menu {
            Toggle("Everyone", isOn: Binding(
                get: { filter.hidden.isEmpty },
                set: { _ in experience.uploaderFilter.hidden = [] }
            ))
            Divider()
            ForEach(options, id: \.self) { option in
                Toggle(experience.name(of: option), isOn: Binding(
                    get: { filter.isShown(option) },
                    set: { _ in experience.uploaderFilter.toggle(option, among: options) }
                ))
            }
        } label: {
            Label(filter.hidden.isEmpty ? "Everyone" : "\(options.count - filter.hidden.count) of \(options.count)",
                  systemImage: filter.hidden.isEmpty ? "person.2" : "person.2.fill")
        }
        .menuActionDismissBehavior(.disabled)
        .buttonStyle(MapChipStyle())
        .accessibilityLabel("Filter by uploader")
    }
}

/// Capsule button on a material background, matching the map's other floating controls.
struct MapChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(.regularMaterial, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

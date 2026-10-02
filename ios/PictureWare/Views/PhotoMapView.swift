import MapKit
import PhotosUI
import SwiftUI

/// Signed-in main screen: every uploaded photo as a pin on a full-screen map.
struct PhotoMapView: View {
    let auth: AuthService
    @State private var model: PhotosModel
    @State private var position: MapCameraPosition = .automatic
    @State private var pickerItem: PhotosPickerItem?
    @State private var selected: Photo?
    @Environment(\.scenePhase) private var scenePhase

    init(auth: AuthService) {
        self.auth = auth
        _model = State(initialValue: PhotosModel(api: APIClient(baseURL: auth.config.apiURL, tokens: auth)))
    }

    var body: some View {
        Map(position: $position) {
            ForEach(model.photos) { photo in
                Annotation("", coordinate: photo.coordinate, anchor: .bottom) {
                    Button { selected = photo } label: { PhotoPin(url: photo.imageUrl) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(photo.takenAt.map { "Photo taken \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Photo")
                }
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) { menu }
        .overlay(alignment: .bottom) { bottomBar }
        .sheet(item: $selected) { photo in
            PhotoDetailView(photo: photo) { try await model.delete(photo) }
        }
        .task { await model.load() }
        .onChange(of: model.fitGeneration) { fitToPins() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await model.upload(item) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Image URLs are only valid for an hour; refresh when coming back.
            if phase == .active { Task { await model.load() } }
        }
    }

    private var menu: some View {
        Menu {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
            Button("Fit All Photos", systemImage: "arrow.up.left.and.arrow.down.right") { fitToPins() }
                .disabled(model.photos.isEmpty)
            Divider()
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task { await auth.signOut() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Menu")
        .padding()
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            StatusBanner(model: model)
            Spacer(minLength: 0)
            PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current,
                         photoLibrary: .shared()) {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(Color.accentColor, in: Circle())
                    .shadow(radius: 4, y: 2)
            }
            .disabled(model.uploadState.isBusy)
            .accessibilityLabel("Add photo")
        }
        .padding()
    }

    private func fitToPins() {
        guard let rect = MapFit.rect(for: model.photos.map(\.coordinate)) else { return }
        withAnimation { position = .rect(rect) }
    }
}

private struct PhotoPin: View {
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
        .frame(width: 48, height: 48)
        .background(.background)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: 3))
        .shadow(radius: 3, y: 1)
    }
}

/// Upload progress / errors and list-loading errors.
private struct StatusBanner: View {
    let model: PhotosModel

    var body: some View {
        Group {
            switch model.uploadState {
            case .preparing:
                banner { ProgressView(); Text("Reading photo…") }
            case .uploading(let fraction):
                banner {
                    ProgressView(value: fraction).frame(width: 80)
                    Text("Uploading \(Int(fraction * 100))%")
                }
            case .processing:
                banner { ProgressView(); Text("Processing…") }
            case .failed(let message):
                banner {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message)
                    Button("Dismiss", systemImage: "xmark") { model.uploadState = .idle }
                        .labelStyle(.iconOnly)
                }
            case .idle:
                if let error = model.loadError {
                    banner {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error)
                        Button("Retry", systemImage: "arrow.clockwise") { Task { await model.load() } }
                            .labelStyle(.iconOnly)
                    }
                } else if model.photos.isEmpty && !model.isLoading {
                    banner { Text("No photos yet. Tap + to add one.") }
                }
            }
        }
        .animation(.default, value: model.uploadState)
    }

    private func banner(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8, content: content)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

extension PhotosModel.UploadState {
    var isBusy: Bool {
        switch self {
        case .preparing, .uploading, .processing: true
        case .idle, .failed: false
        }
    }
}

import MapKit
import SwiftUI

/// Signed-in main screen: every uploaded photo as a pin on a full-screen map.
struct PhotoMapView: View {
    let auth: AuthService
    @State private var model: PhotosModel
    private let uploads = UploadCenter.shared
    private let api: APIClient
    @State private var position: MapCameraPosition = .automatic
    @State private var experience = MapExperience()
    @Environment(\.scenePhase) private var scenePhase

    init(auth: AuthService) {
        self.auth = auth
        api = APIClient(baseURL: auth.config.apiURL, tokens: auth)
        _model = State(initialValue: PhotosModel(api: api))
    }

    var body: some View {
        // Clustering, replay, uploader filter and the swipe viewer live in Map/.
        TripMap(experience: experience, position: $position) { photo in
            try await model.delete(photo)
            uploads.forget(photoID: photo.id)
        }
        .overlay(alignment: .topTrailing) { menu }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                TimelineBar(experience: experience).padding([.horizontal, .top])
                bottomBar
            }
        }
        .onChange(of: model.photos, initial: true) { experience.photos = model.photos }
        .task {
            uploads.activate(backend: APIUploadBackend(api: api))
            await model.load()
        }
        .task(id: uploads.completedGeneration) {
            // The backend lists a photo shortly after storage receives it.
            guard uploads.completedGeneration > 0 else { return }
            for delay in [1.5, 4.0] {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                await model.load()
            }
        }
        .onChange(of: model.fitGeneration) { fitToPins() }
        .onChange(of: scenePhase) { _, phase in
            // Image URLs are only valid for an hour; refresh when coming back.
            if phase == .active {
                Task { await model.load() }
                uploads.retryWaitingNow()
            }
        }
    }

    private var menu: some View {
        Menu {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
            Button("Fit All Photos", systemImage: "arrow.up.left.and.arrow.down.right") { fitToPins() }
                .disabled(model.photos.isEmpty)
            Divider()
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task {
                    await uploads.signOut()
                    await auth.signOut()
                }
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
            if uploads.isVisible {
                UploadPanel(uploads: uploads)
            } else {
                StatusBanner(model: model)
            }
            Spacer(minLength: 0)
            AddPhotosButton(uploads: uploads)
        }
        .padding()
    }

    private func fitToPins() {
        guard let rect = MapFit.rect(for: model.photos.map(\.coordinate)) else { return }
        withAnimation { position = .rect(rect) }
    }
}

/// List-loading errors and the empty state. (Upload status is `UploadPanel`.)
private struct StatusBanner: View {
    let model: PhotosModel

    var body: some View {
        if let error = model.loadError {
            banner {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error)
                Button("Retry", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .labelStyle(.iconOnly)
            }
        } else if model.photos.isEmpty && !model.isLoading {
            banner { Text("No photos yet. Tap + to add some.") }
        }
    }

    private func banner(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8, content: content)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

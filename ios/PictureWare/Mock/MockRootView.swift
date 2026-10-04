#if DEBUG
import SwiftUI

/// Mock mode: the signed-in UI backed by `MockAPI`, with no backend and no sign-in.
/// Launch with `-MockAPI YES` (the "PictureWare (Mock)" scheme does). Debug builds only.
///
/// Uploads go through the real upload queue, with its own store and `MockUploadTransport`,
/// so nothing touches a signed-in user's queue. "Sign Out" starts over with a freshly
/// seeded mock.
struct MockRootView: View {
    private struct Session {
        let api: MockAPI
        let uploads: UploadCenter

        @MainActor static func make() throws -> Session {
            let api = try MockAPI.contractSeeded(ContractDocument.bundled())
            let store = UploadStore(directory: FileManager.default.temporaryDirectory
                .appending(path: "MockUploads", directoryHint: .isDirectory))
            return Session(api: api, uploads: UploadCenter(transport: MockUploadTransport(api: api), store: store))
        }
    }

    @State private var current: Session?
    @State private var error: String?
    @State private var generation = 0

    init() {
        do {
            _current = State(initialValue: try Session.make())
        } catch {
            _error = State(initialValue: error.localizedDescription)
        }
    }

    var body: some View {
        Group {
            if let current {
                PhotoMapView(api: current.api, uploads: current.uploads) { reset() }
                    .id(generation)
            } else if let error {
                ContentUnavailableView("Mock mode unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            }
        }
        .overlay(alignment: .topLeading) {
            Text("MOCK API")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.yellow, in: Capsule())
                .padding()
                .accessibilityIdentifier("mock-mode-badge")
        }
    }

    private func reset() {
        do {
            current = try Session.make()
            generation += 1
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum LaunchOptions {
    /// `-MockAPI YES` on the command line lands in the argument domain of `UserDefaults`.
    static var useMockAPI: Bool { UserDefaults.standard.bool(forKey: "MockAPI") }
}
#endif

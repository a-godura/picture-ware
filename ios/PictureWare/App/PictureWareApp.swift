import SwiftUI

@main
struct PictureWareApp: App {
    @State private var auth = AuthService(config: AppConfig.load())

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth)
        }
    }
}

struct RootView: View {
    let auth: AuthService

    var body: some View {
        switch auth.state {
        case .signedOut:
            SignedOutView(auth: auth)
        case .signedIn:
            PhotoMapView(auth: auth)
        }
    }
}

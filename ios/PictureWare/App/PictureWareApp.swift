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
        #if DEBUG
        // `-PWSampleMap YES`: the map on offline sample data, no backend or sign-in.
        if UserDefaults.standard.bool(forKey: "PWSampleMap") {
            SampleTripMapScreen()
        } else {
            signedInOrOut
        }
        #else
        signedInOrOut
        #endif
    }

    @ViewBuilder private var signedInOrOut: some View {
        switch auth.state {
        case .signedOut:
            SignedOutView(auth: auth)
        case .signedIn:
            PhotoMapView(auth: auth)
        }
    }
}

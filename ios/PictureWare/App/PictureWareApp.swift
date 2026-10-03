import SwiftUI

@main
struct PictureWareApp: App {
    @UIApplicationDelegateAdaptor(UploadAppDelegate.self) private var uploadDelegate
    @State private var auth = AuthService(config: AppConfig.load())

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if LaunchOptions.useMockAPI {
                MockRootView() // `-MockAPI YES`: signed-in UI on MockAPI (contract examples), no backend
            } else if UploadDemo.isEnabled {
                UploadDemoView()
            } else if ExportDemo.isEnabled {
                ExportDemoView() // `-PWExportDemo YES`: Save to Photos / Files on sample files
            } else {
                RootView(auth: auth)
            }
            #else
            RootView(auth: auth)
            #endif
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
            PhotoMapView(api: APIClient(baseURL: auth.config.apiURL, tokens: auth)) { await auth.signOut() }
        }
    }
}

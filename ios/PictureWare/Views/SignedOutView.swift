import SwiftUI

struct SignedOutView: View {
    let auth: AuthService

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Picture Ware")
                    .font(.largeTitle.bold())
                Text("Upload a photo and see where it was taken on a map.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            if let message = auth.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await auth.signIn() }
            } label: {
                Group {
                    if auth.isWorking {
                        ProgressView()
                    } else {
                        Text("Sign in")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(auth.isWorking)
            .accessibilityIdentifier("signInButton")
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }
}

import SwiftUI

struct PermissionsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Full Disk Access Required")
                .font(.title)
                .fontWeight(.bold)

            VStack(spacing: 12) {
                Text("iMessage Search needs Full Disk Access to read your message history.")
                    .multilineTextAlignment(.center)

                Text("This app only opens your Messages and Contacts databases in **read-only** mode. It never modifies any data.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 450)

            Button("Open Full Disk Access Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            VStack(spacing: 6) {
                Text("Click the **+** button, find **iMessage Search.app**, and toggle it on.")
                    .multilineTextAlignment(.center)
                Text("Then quit (Cmd+Q) and relaunch.")
                    .multilineTextAlignment(.center)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 400)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

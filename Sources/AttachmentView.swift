import SwiftUI
import AppKit

struct AttachmentView: View {
    let attachment: AttachmentInfo

    var body: some View {
        if !attachment.exists {
            Text("\(attachment.filename) (unavailable)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let mimeType = attachment.mimeType, mimeType.hasPrefix("image/") {
            if let nsImage = NSImage(contentsOfFile: attachment.fullPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture {
                        NSWorkspace.shared.open(URL(fileURLWithPath: attachment.fullPath))
                    }
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
            }
        } else {
            Button(action: {
                NSWorkspace.shared.open(URL(fileURLWithPath: attachment.fullPath))
            }) {
                Label(attachment.filename, systemImage: "doc")
                    .font(.caption)
            }
            .buttonStyle(.link)
        }
    }
}

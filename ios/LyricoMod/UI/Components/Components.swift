import SwiftUI
import UIKit

/// Async cover thumbnail backed by CoverCache.
struct CoverThumbnail: View {
    let song: SongRecord
    var size: CGFloat = 44
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(Color(.secondarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
        .task(id: "\(song.uri)|\(song.fileSize)|\(song.fileLastModified)|\(song.dbUpdateTime)") {
            image = CoverCache.shared.cachedImage(for: song)
            if image == nil { image = await CoverCache.shared.image(for: song) }
        }
    }
}

/// UIActivityViewController wrapper (batch share, cover/lyrics export).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareItems: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// Folder picker (UIDocumentPickerViewController for public.folder).
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

/// Small toast-like banner.
struct BannerMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var isError = false
}

struct BannerView: View {
    let message: BannerMessage

    var body: some View {
        Text(message.text)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .foregroundStyle(message.isError ? Color.red : Color.primary)
            .shadow(radius: 4)
            .padding(.bottom, 24)
    }
}

extension View {
    func banner(_ message: Binding<BannerMessage?>) -> some View {
        overlay(alignment: .bottom) {
            if let m = message.wrappedValue {
                BannerView(message: m)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: m.id) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { message.wrappedValue = nil }
                    }
            }
        }
        .animation(.easeInOut, value: message.wrappedValue)
    }
}

/// Label + value row used in info sections.
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

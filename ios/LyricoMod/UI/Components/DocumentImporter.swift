import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// File picker that copies the picked files into the app's temp folder (`asCopy: true`).
///
/// SwiftUI's `.fileImporter` opens files in place, which needs a sandbox extension from the
/// document picker. In apps installed with TrollStore or re-signed builds this can fail
/// silently: the picker stays open and "Open" does nothing. Copy mode avoids that.
struct DocumentImporterSheet: UIViewControllerRepresentable {
    let types: [UTType]
    let allowsMultipleSelection: Bool
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void
        private var done = false

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !done else { return }
            done = true
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !done else { return }
            done = true
            onCancel()
        }
    }
}

extension View {
    /// Drop-in replacement for `.fileImporter` that copies the picked files.
    func documentImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool = false,
        onPick: @escaping ([URL]) -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            DocumentImporterSheet(
                types: allowedContentTypes,
                allowsMultipleSelection: allowsMultipleSelection,
                onPick: { urls in
                    isPresented.wrappedValue = false
                    // Let the sheet finish dismissing before the caller presents alerts or sheets.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onPick(urls) }
                },
                onCancel: { isPresented.wrappedValue = false }
            )
            .ignoresSafeArea()
        }
    }
}

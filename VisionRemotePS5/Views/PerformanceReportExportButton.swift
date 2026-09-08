import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Prepare one immutable report only when the user requests an export. The
/// system file picker owns destination selection and writing authorization.
@MainActor
struct PerformanceReportExportButton: View {
    let compact: Bool
    let onDismiss: () -> Void

    @State private var isPreparing = false
    @State private var isExportPresented = false
    @State private var document: PerformanceReportDocument?
    @State private var showError = false
    @State private var errorMessage = ""

    init(compact: Bool = false, onDismiss: @escaping () -> Void = {}) {
        self.compact = compact
        self.onDismiss = onDismiss
    }

    var body: some View {
        Button(action: prepareReport) {
            HStack {
                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
                Text(compact ? "Export Report" : "Export Performance Report")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(compact ? .small : .regular)
        .disabled(isPreparing || isExportPresented)
        .fileExporter(isPresented: $isExportPresented,
                      document: document,
                      contentTypes: [.plainText],
                      defaultFilename: "VisionRemotePS5-Performance.txt",
                      onCompletion: { result in
            Task { @MainActor in finishExport(result) }
        }, onCancellation: {
            Task { @MainActor in
                document = nil
                onDismiss()
            }
        })
        .alert("Performance Report", isPresented: $showError) {
            Button("OK") { onDismiss() }
        } message: {
            Text(errorMessage)
        }
    }

    private func prepareReport() {
        guard !isPreparing, !isExportPresented else { return }
        isPreparing = true
        Task { @MainActor in
            do {
                let text = try await StreamingService.shared.makePerformanceReport()
                document = PerformanceReportDocument(text: text)
                isPreparing = false
                isExportPresented = true
            } catch PerformanceReportError.collectionDisabled {
                isPreparing = false
                errorMessage = "Performance collection is disabled in this comparison build."
                showError = true
            } catch is CancellationError {
                isPreparing = false
                onDismiss()
            } catch {
                isPreparing = false
                errorMessage = "The report could not be prepared. Start a streaming session, then try again."
                showError = true
            }
        }
    }

    private func finishExport(_ result: Result<URL, Error>) {
        document = nil
        switch result {
        case .success:
            onDismiss()
        case .failure(let error):
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError {
                onDismiss()
            } else {
                // Avoid exposing provider paths or unfiltered diagnostic text.
                errorMessage = "The report could not be saved. Please try again."
                showError = true
            }
        }
    }
}

private struct PerformanceReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let contents: Data

    init(text: String) { contents = Data(text.utf8) }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              String(data: data, encoding: .utf8) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        contents = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: contents)
    }
}

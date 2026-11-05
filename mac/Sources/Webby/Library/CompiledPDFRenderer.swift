import AppKit
import WebKit

/// Renders Compiled HTML to PDF through the same locked-down WebKit host used for the
/// on-screen view: nonpersistent storage, JavaScript off, HTTP(S) blocked before load,
/// `baseURL: nil`, and navigation cancelled after the initial document.
///
/// This production renderer is exercised by the app, not the unit suite. Manual
/// checks still cover multipage pagination and 200-note output.
@MainActor
enum CompiledPDFRenderer {
    enum RenderError: LocalizedError {
        case printFailed

        var errorDescription: String? {
            "The compiled view could not be printed to PDF."
        }
    }

    static func render(html: String, to url: URL) async throws {
        let controller = CompiledWebViewController()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controller.onFinish = {
                continuation.resume()
            }
            controller.onFailure = { error in
                continuation.resume(throwing: error)
            }
            controller.load(html: html)
        }

        let printInfo = NSPrintInfo()
        printInfo.orientation = .portrait
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let operation = controller.webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw RenderError.printFailed }
    }
}

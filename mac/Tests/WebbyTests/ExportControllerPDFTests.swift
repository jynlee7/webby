import Foundation
import Testing
@testable import Webby
import WebbyCore

private let pdfNow = Date(timeIntervalSince1970: 1_800_000_000)

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyPDFExport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeNote(text: String) -> Note {
    Note(
        text: text,
        frame: NoteFrame(),
        placement: .screen,
        createdAt: pdfNow,
        updatedAt: pdfNow
    )
}

@MainActor
private func makeController(_ store: NoteStore) -> NotesController {
    let permission = AccessibilityPermission()
    let monitor = ContextMonitor(permission: permission)
    return NotesController(
        store: store,
        monitor: monitor,
        permission: permission,
        themes: .fallback,
        now: { pdfNow }
    )
}

@MainActor
@Suite struct ExportControllerPDFTests {
    @Test func pdfExportRendersToASiblingThenWritesTheAdvertisedPDF() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        #expect(store.add(makeNote(text: "PDF heading\nBody text")))
        let model = LibraryModel(controller: makeController(store), clock: { pdfNow })
        let destination = directory.appendingPathComponent("webby-all-notes.pdf")

        var renderedHTML = ""
        var renderedURL: URL?
        var written: (data: Data, url: URL, allowOverwrite: Bool)?

        let export = ExportController(
            model: model,
            savePanel: { _, _ in nil },
            pdfSavePanel: { filename in
                #expect(filename == "webby-all-notes.pdf")
                return destination
            },
            pdfRenderer: { html, url in
                renderedHTML = html
                renderedURL = url
                #expect(url.pathExtension == "pdf")
                #expect(url.lastPathComponent.hasSuffix(".pdf"))
                #expect(url.deletingLastPathComponent() == directory)
                try Data("%PDF-1.7\nfixture\n".utf8).write(to: url)
            },
            writer: { data, url, allowOverwrite in
                written = (data, url, allowOverwrite)
                try data.write(to: url)
            }
        )

        let result = try await export.exportPDF(selection: .all)

        #expect(result == destination)
        #expect(renderedHTML.contains("PDF heading"))
        #expect(renderedURL != nil)
        #expect(written?.data.starts(with: Data("%PDF".utf8)) == true)
        #expect(written?.url == destination)
        #expect(written?.allowOverwrite == false)
        #expect(model.exportStatus == "Exported webby-all-notes.pdf")
        #expect(try Data(contentsOf: destination).starts(with: Data("%PDF".utf8)))
    }

    @Test func makePDFDocumentUsesTheCompiledHTMLAndPDFFilename() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        #expect(store.add(makeNote(text: "Deterministic heading")))
        let model = LibraryModel(controller: makeController(store), clock: { pdfNow })
        let export = ExportController(model: model, pdfRenderer: nil)

        let document = try export.makePDFDocument(selection: .all)

        #expect(document.filename == "webby-all-notes.pdf")
        #expect(document.html.contains("Deterministic heading"))
    }

    @Test func pdfExportRejectsAnUnavailableRendererWithoutOpeningThePanel() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        #expect(store.add(makeNote(text: "No renderer")))
        let model = LibraryModel(controller: makeController(store), clock: { pdfNow })
        var panelOpened = false
        let export = ExportController(
            model: model,
            pdfSavePanel: { _ in
                panelOpened = true
                return directory.appendingPathComponent("unused.pdf")
            },
            pdfRenderer: nil
        )

        do {
            _ = try await export.exportPDF(selection: .all)
            Issue.record("Expected the unavailable renderer to fail the export")
        } catch let error as ExportController.PDFExportError {
            #expect(error == .rendererUnavailable)
        }

        #expect(panelOpened == false)
        #expect(model.exportStatus == nil)
    }

    @Test func pdfExportRejectsRendererOutputThatIsNotPDF() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        #expect(store.add(makeNote(text: "Broken renderer")))
        let model = LibraryModel(controller: makeController(store), clock: { pdfNow })
        var wroteDestination = false
        let export = ExportController(
            model: model,
            pdfSavePanel: { _ in directory.appendingPathComponent("broken.pdf") },
            pdfRenderer: { _, url in
                try Data("not a pdf".utf8).write(to: url)
            },
            writer: { _, _, _ in
                wroteDestination = true
            }
        )

        do {
            _ = try await export.exportPDF(selection: .all)
            Issue.record("Expected non-PDF renderer output to fail the export")
        } catch let error as ExportController.PDFExportError {
            #expect(error == .invalidPDF)
        }

        #expect(wroteDestination == false)
    }
}

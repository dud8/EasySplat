#if canImport(XCTest)
import XCTest
import UniformTypeIdentifiers
@testable import EasySplatApp

final class DropZoneStateTextTests: XCTestCase {
    @MainActor
    private final class DeliveryRecorder {
        private(set) var batches: [DropURLLoadBatch] = []

        func receive(_ batch: DropURLLoadBatch) {
            MainActor.assertIsolated()
            batches.append(batch)
        }
    }

    func testDropZoneCopySwitchesWhileTargeted() {
        XCTAssertEqual(
            DropZoneView.displayTitle(restingTitle: "Drop input", isTargeted: false),
            "Drop input"
        )
        XCTAssertEqual(
            DropZoneView.displaySubtitle(restingSubtitle: "Videos or photos", isTargeted: false),
            "Videos or photos"
        )
        XCTAssertEqual(
            DropZoneView.displayTitle(restingTitle: "Drop input", isTargeted: true),
            "Release to add"
        )
        XCTAssertEqual(
            DropZoneView.displaySubtitle(restingSubtitle: "Videos or photos", isTargeted: true),
            "Videos, photos, folders, or datasets"
        )
    }

    func testImporterRequestsKeepFileAndFolderSelectionSeparate() {
        XCTAssertEqual(InputImporterRequest.addFiles.selectionMode, .append)
        XCTAssertEqual(InputImporterRequest.addFolders.selectionMode, .append)
        XCTAssertEqual(InputImporterRequest.replaceFiles.selectionMode, .replace)
        XCTAssertEqual(InputImporterRequest.replaceFolders.selectionMode, .replace)

        XCTAssertFalse(InputImporterRequest.addFiles.allowedContentTypes.contains(.folder))
        XCTAssertEqual(InputImporterRequest.addFolders.allowedContentTypes, [.folder])
        XCTAssertEqual(InputImporterRequest.replaceFolders.allowedContentTypes, [.folder])
        XCTAssertEqual(InputImporterRequest.replaceFiles.failureMessage, "Couldn’t choose input")
        XCTAssertEqual(InputImporterRequest.replaceFolders.failureMessage, "Couldn’t choose folder.")
    }

    func testImporterCancellationClearsStateBeforeAlternatingFileAndFolderRequests() {
        var presentation = InputImporterPresentation()
        let actions: [(InputImporterRequest, [UTType])] = [
            (.addFiles, [.image, .movie, .video, .mpeg4Movie, .quickTimeMovie, .zip]),
            (.addFolders, [.folder]),
            (.replaceFiles, [.image, .movie, .video, .mpeg4Movie, .quickTimeMovie, .zip]),
            (.replaceFolders, [.folder]),
            (.addFiles, [.image, .movie, .video, .mpeg4Movie, .quickTimeMovie, .zip]),
            (.addFolders, [.folder]),
        ]

        for (request, allowedTypes) in actions {
            presentation.present(request)
            XCTAssertTrue(presentation.isPresented)
            XCTAssertEqual(presentation.request, request)
            XCTAssertEqual(presentation.request?.allowedContentTypes, allowedTypes)

            // SwiftUI may lower the binding before invoking onCancellation.
            presentation.presentationChanged(false)
            XCTAssertFalse(presentation.isPresented)
            XCTAssertEqual(presentation.request, request)

            presentation.cancel()
            XCTAssertFalse(presentation.isPresented)
            XCTAssertNil(presentation.request)
        }
    }

    func testPendingImporterRequestCannotBeReclassifiedBeforeItsCallback() {
        var presentation = InputImporterPresentation()
        presentation.present(.addFiles)

        // SwiftUI may lower the binding a turn before delivering completion.
        presentation.presentationChanged(false)
        presentation.present(.replaceFolders)

        XCTAssertEqual(presentation.request, .addFiles)
        XCTAssertFalse(presentation.isPresented)
        XCTAssertEqual(presentation.finish(), .addFiles)
    }

    func testRootImporterSourceMapsCancellationToThePresentationStateOwner() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let homeView = repository.appendingPathComponent("EasySplatApp/UI/Home/HomeView.swift")
        let source = try String(contentsOf: homeView, encoding: .utf8)

        XCTAssertEqual(source.components(separatedBy: ".fileImporter(").count - 1, 1)
        XCTAssertTrue(source.contains("set: { inputImporter.presentationChanged($0) }"))
        XCTAssertTrue(source.contains("onCancellation: { inputImporter.cancel() }"))
    }

    func testDropURLResultsFinishOnceAndKeepProviderOrderAndFailures() async {
        let first = URL(fileURLWithPath: "/tmp/first.jpg")
        let third = URL(fileURLWithPath: "/tmp/third.jpg")
        let recorder = await MainActor.run { DeliveryRecorder() }
        let accumulator = DropURLLoadAccumulator(
            expectedResultCount: 3,
            onCompletion: { batch in recorder.receive(batch) }
        )

        let thirdProvider = await accumulator.append(DropURLLoadResult(index: 2, url: third))
        let failedProvider = await accumulator.append(DropURLLoadResult(index: 1, url: nil))
        let firstProvider = await accumulator.append(DropURLLoadResult(index: 0, url: first))
        let duplicateProvider = await accumulator.append(DropURLLoadResult(index: 0, url: first))

        XCTAssertNil(thirdProvider)
        XCTAssertNil(failedProvider)
        XCTAssertEqual(firstProvider?.urls, [first, third])
        XCTAssertEqual(firstProvider?.failedProviderCount, 1)
        XCTAssertNil(duplicateProvider)
        let delivered = await MainActor.run { recorder.batches }
        XCTAssertEqual(delivered, [DropURLLoadBatch(urls: [first, third], failedProviderCount: 1)])
    }

    func testDropURLResultsReportAllProviderFailures() async {
        let accumulator = DropURLLoadAccumulator(expectedResultCount: 3)

        _ = await accumulator.append(DropURLLoadResult(index: 2, url: nil))
        _ = await accumulator.append(DropURLLoadResult(index: 0, url: nil))
        let batch = await accumulator.append(DropURLLoadResult(index: 1, url: nil))

        XCTAssertEqual(batch?.urls, [])
        XCTAssertEqual(batch?.failedProviderCount, 3)
    }

    func testProviderErrorWinsOverAnUnexpectedURLPayload() async {
        let accumulator = DropURLLoadAccumulator(expectedResultCount: 1)
        let unexpectedURL = URL(fileURLWithPath: "/tmp/unexpected.jpg")

        let batch = await accumulator.append(
            DropURLLoadResult(
                index: 0,
                url: unexpectedURL,
                providerFailed: true
            )
        )

        XCTAssertEqual(batch?.urls, [])
        XCTAssertEqual(batch?.failedProviderCount, 1)
    }
}
#endif

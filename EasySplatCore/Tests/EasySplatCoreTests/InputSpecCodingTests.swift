import XCTest
@testable import EasySplatCore

final class InputSpecCodingTests: XCTestCase {
    func testInputSpecVideoCoding() throws {
        let spec = InputSpec.video(files: ["/tmp/video.mov"])
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(InputSpec.self, from: data)
        guard case let .video(files) = decoded else {
            return XCTFail("Expected video input spec")
        }
        XCTAssertEqual(files, ["/tmp/video.mov"])
    }

    func testInputSpecPhotosCoding() throws {
        let spec = InputSpec.photos(folder: "/tmp/photos")
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(InputSpec.self, from: data)
        guard case let .photos(folder) = decoded else {
            return XCTFail("Expected photos input spec")
        }
        XCTAssertEqual(folder, "/tmp/photos")
    }

    func testInputSpecMixedCoding() throws {
        let spec = InputSpec.mixed(videos: ["/tmp/a.mp4", "/tmp/b.mov"], photosFolder: "/tmp/photos")
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(InputSpec.self, from: data)
        guard case let .mixed(videos, photosFolder) = decoded else {
            return XCTFail("Expected mixed input spec")
        }
        XCTAssertEqual(videos, ["/tmp/a.mp4", "/tmp/b.mov"])
        XCTAssertEqual(photosFolder, "/tmp/photos")
    }

    func testInputSpecDatasetCoding() throws {
        let spec = InputSpec.dataset(kind: .nerfstudio, imagesFolder: "Originals/Photos")
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(InputSpec.self, from: data)
        guard case let .dataset(kind, imagesFolder) = decoded else {
            return XCTFail("Expected dataset input spec")
        }
        XCTAssertEqual(kind, .nerfstudio)
        XCTAssertEqual(imagesFolder, "Originals/Photos")
        // The wire key is the case name; renaming it would strand projects.
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Array(object.keys), ["dataset"])
    }

    // Adding the dataset case must not disturb how the three original cases
    // encode: these byte-level shapes are what format-31 projects contain.
    func testLegacyCaseEncodingsAreByteStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let video = String(
            data: try encoder.encode(InputSpec.video(files: ["a.mov"])), encoding: .utf8
        )
        XCTAssertEqual(video, #"{"video":{"files":["a.mov"]}}"#)
        let photos = String(
            data: try encoder.encode(InputSpec.photos(folder: "p")), encoding: .utf8
        )
        XCTAssertEqual(photos, #"{"photos":{"folder":"p"}}"#)
        let mixed = String(
            data: try encoder.encode(InputSpec.mixed(videos: ["a.mov"], photosFolder: "p")),
            encoding: .utf8
        )
        XCTAssertEqual(mixed, #"{"mixed":{"photosFolder":"p","videos":["a.mov"]}}"#)
    }

    func testDatasetAccessorsRouteThroughPhotoMachinery() {
        let spec = InputSpec.dataset(kind: .colmap, imagesFolder: "Originals/Photos")
        XCTAssertTrue(spec.isDataset)
        XCTAssertEqual(spec.datasetKind, .colmap)
        XCTAssertEqual(spec.photosFolder, "Originals/Photos")
        XCTAssertTrue(spec.hasPhotos)
        XCTAssertFalse(spec.hasVideos)
        XCTAssertEqual(spec.videoFiles, [])
        XCTAssertFalse(InputSpec.photos(folder: "p").isDataset)
        XCTAssertNil(InputSpec.photos(folder: "p").datasetKind)
    }
}

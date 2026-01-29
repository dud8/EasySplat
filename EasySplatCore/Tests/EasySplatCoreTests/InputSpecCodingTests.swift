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
}

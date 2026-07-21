import CryptoKit
import Darwin
import Foundation
import Testing

@testable import EasySplatMeasurementRunnerCore

@Suite("Canonical cameras measurement evidence")
struct MeasurementCanonicalCamerasEvidenceTests {
  @Test("runtime manifest capture binds the exact worker and geometry bytes")
  func runtimeManifestCaptureBindsExactBytes() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let workerURL = fixture.root.appendingPathComponent("worker_execution.json")
    let geometryURL = fixture.root.appendingPathComponent("geometry_manifest.json")
    let worker = Data("{\"worker\":1}\n".utf8)
    let geometry = Data("{\"geometry\":1}\n".utf8)
    try worker.write(to: workerURL)
    try geometry.write(to: geometryURL)

    let evidence = try MeasurementRuntimeManifestEvidence.capture(
      workerURL: workerURL,
      geometryURL: geometryURL
    )

    #expect(evidence.worker.data == worker)
    #expect(evidence.geometry.data == geometry)
    #expect(evidence.worker.sha256 == SHA256.hash(data: worker).hexDigest)
    #expect(evidence.geometry.sha256 == SHA256.hash(data: geometry).hexDigest)
  }

  @Test("runtime manifest capture rejects worker replacement during collection")
  func runtimeManifestCaptureRejectsWorkerReplacement() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let workerURL = fixture.root.appendingPathComponent("worker_execution.json")
    let geometryURL = fixture.root.appendingPathComponent("geometry_manifest.json")
    try Data("{\"worker\":1}\n".utf8).write(to: workerURL)
    try Data("{\"geometry\":1}\n".utf8).write(to: geometryURL)

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementRuntimeManifestEvidence.capture(
        workerURL: workerURL,
        geometryURL: geometryURL,
        hooks: .init(afterWorkerRead: {
          let replacement = fixture.root.appendingPathComponent("replacement.json")
          try Data("{\"worker\":2}\n".utf8).write(to: replacement)
          _ = try FileManager.default.replaceItemAt(workerURL, withItemAt: replacement)
        })
      )
    }
  }

  @Test("runtime manifest capture rejects geometry mutation during collection")
  func runtimeManifestCaptureRejectsGeometryMutation() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let workerURL = fixture.root.appendingPathComponent("worker_execution.json")
    let geometryURL = fixture.root.appendingPathComponent("geometry_manifest.json")
    try Data("{\"worker\":1}\n".utf8).write(to: workerURL)
    try Data("{\"geometry\":1}\n".utf8).write(to: geometryURL)

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementRuntimeManifestEvidence.capture(
        workerURL: workerURL,
        geometryURL: geometryURL,
        hooks: .init(afterGeometryRead: {
          let descriptor = open(geometryURL.path, O_WRONLY | O_APPEND)
          guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
          defer { close(descriptor) }
          var byte: UInt8 = 0x20
          guard write(descriptor, &byte, 1) == 1 else {
            throw CocoaError(.fileWriteUnknown)
          }
        })
      )
    }
  }

  @Test("binds a bounded stable canonical cameras file")
  func bindsHealthyFile() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let bytes = Data("1 OPENCV_FISHEYE 512 512 190 190 255 256 0 0 0 0\n".utf8)
    try bytes.write(to: fixture.cameras)

    let evidence = try MeasurementStableFileEvidence.read(
      fixture.cameras,
      maximumBytes: 1_048_576
    )

    #expect(evidence.byteCount == bytes.count)
    #expect(evidence.sha256 == SHA256.hash(data: bytes).hexDigest)
  }

  @Test("rejects missing and symbolic-link files")
  func rejectsMissingAndSymlink() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementStableFileEvidence.read(fixture.cameras, maximumBytes: 1_048_576)
    }
    let target = fixture.root.appendingPathComponent("outside.txt")
    try Data("camera".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: fixture.cameras, withDestinationURL: target)
    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementStableFileEvidence.read(fixture.cameras, maximumBytes: 1_048_576)
    }
  }

  @Test("rejects multiply linked cameras files")
  func rejectsHardlink() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try Data("camera".utf8).write(to: fixture.cameras)
    try FileManager.default.linkItem(
      at: fixture.cameras,
      to: fixture.root.appendingPathComponent("second-name.txt")
    )

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementStableFileEvidence.read(fixture.cameras, maximumBytes: 1_048_576)
    }
  }

  @Test("rejects a file replaced while it is read")
  func rejectsReplacementDuringRead() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try Data("original".utf8).write(to: fixture.cameras)

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementStableFileEvidence.readForTesting(
        fixture.cameras,
        maximumBytes: 1_048_576
      ) {
        let replacement = fixture.root.appendingPathComponent("replacement.txt")
        try Data("replacement".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(fixture.cameras, withItemAt: replacement)
      }
    }
  }

  @Test("rejects a file changed after bytes are read")
  func rejectsMutationDuringRead() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try Data("original".utf8).write(to: fixture.cameras)

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementStableFileEvidence.readForTesting(
        fixture.cameras,
        maximumBytes: 1_048_576
      ) {
        let descriptor = open(fixture.cameras.path, O_WRONLY | O_APPEND)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        var byte: UInt8 = 0x0A
        guard write(descriptor, &byte, 1) == 1 else { throw CocoaError(.fileWriteUnknown) }
      }
    }
  }

  @Test("rejects an oversized cameras file")
  func rejectsOversizedFile() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try Data(repeating: 0x20, count: 65).write(to: fixture.cameras)

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementStableFileEvidence.read(fixture.cameras, maximumBytes: 64)
    }
  }

  @Test("rejects a cameras digest that differs from published geometry")
  func rejectsDigestMismatch() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try Data("camera".utf8).write(to: fixture.cameras)

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementStableFileEvidence.read(fixture.cameras, maximumBytes: 1_048_576)
        .requiringSHA256(String(repeating: "0", count: 64), label: "canonical cameras")
    }
  }

  private struct Fixture {
    let root: URL
    var cameras: URL { root.appendingPathComponent("cameras.txt") }

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}

private extension Digest {
  var hexDigest: String { map { String(format: "%02x", $0) }.joined() }
}

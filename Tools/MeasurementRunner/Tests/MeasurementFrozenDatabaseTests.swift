import Darwin
import Foundation
import Testing

@testable import EasySplatMeasurementAdapterSupport

@Suite("Frozen mapper database")
struct MeasurementFrozenDatabaseTests {
  @Test("mapper cadence alternates one immutable option set in the fixed release order")
  func mapperCadenceScheduleIsFixed() throws {
    let fixed = try MeasurementMapperFixedOptions(
      localMaxRefinements: 2,
      globalMaxRefinements: 5,
      globalMaxNumIterations: 75,
      localMaxNumIterations: 10,
      localFunctionTolerance: 0.001,
      globalFunctionTolerance: 0.000_001,
      localImageCount: 6,
      randomSeed: 42,
      refineFocalLength: true
    )

    let schedule = MeasurementMapperCadenceSchedule(fixedOptions: fixed)

    #expect(MeasurementMapperCadenceTrial.warmup.ordinal == 0)
    #expect(MeasurementMapperCadenceTrial.warmup.name == "mapper-cadence-warmup-1p4")
    #expect(MeasurementMapperCadenceTrial.warmup.ratio == 1.4)
    #expect(schedule.fixedOptions == fixed)
    #expect(schedule.trials.map(\.ordinal) == [1, 2, 3, 4, 5, 6, 7, 8])
    #expect(schedule.trials.map(\.name) == [
      "mapper-cadence-01-1p1",
      "mapper-cadence-02-1p4",
      "mapper-cadence-03-1p4",
      "mapper-cadence-04-1p1",
      "mapper-cadence-05-1p1",
      "mapper-cadence-06-1p4",
      "mapper-cadence-07-1p4",
      "mapper-cadence-08-1p1",
    ])
    let ratios = schedule.trials.map(\.ratio)
    #expect(ratios == [1.1, 1.4, 1.4, 1.1, 1.1, 1.4, 1.4, 1.1])
    #expect(ratios.count { $0 == 1.1 } == 4)
    #expect(ratios.count { $0 == 1.4 } == 4)
    #expect(ratios == Array(ratios.reversed()))
    let adjacentPairs: [[Double]] = stride(from: 0, to: ratios.count, by: 2).map {
      [ratios[$0], ratios[$0 + 1]]
    }
    let expectedPairs: [[Double]] = [
      [1.1, 1.4],
      [1.4, 1.1],
      [1.1, 1.4],
      [1.4, 1.1],
    ]
    #expect(adjacentPairs == expectedPairs)

    for trial in schedule.trials {
      let options = try schedule.mapperOptions(for: trial)
      #expect(options.globalFramesRatio == trial.ratio)
      #expect(options.globalPointsRatio == trial.ratio)
      #expect(options.localMaxRefinements == fixed.localMaxRefinements)
      #expect(options.globalMaxRefinements == fixed.globalMaxRefinements)
      #expect(options.globalMaxNumIterations == fixed.globalMaxNumIterations)
      #expect(options.localMaxNumIterations == fixed.localMaxNumIterations)
      #expect(options.localFunctionTolerance == fixed.localFunctionTolerance)
      #expect(options.globalFunctionTolerance == fixed.globalFunctionTolerance)
      #expect(options.localImageCount == fixed.localImageCount)
      #expect(options.randomSeed == fixed.randomSeed)
      #expect(options.refineFocalLength == fixed.refineFocalLength)
    }
    let warmupOptions = try schedule.mapperOptions(for: .warmup)
    #expect(warmupOptions.globalFramesRatio == 1.4)
    #expect(warmupOptions.globalPointsRatio == 1.4)
  }

  @Test("cadence JSON stores fixed mapper options once and ratios only per trial")
  func mapperCadenceEncodingDoesNotDuplicateFixedOptions() throws {
    let data = try JSONEncoder().encode(makeSchedule())
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let fixed = try #require(object["fixed_options"] as? [String: Any])
    let trials = try #require(object["trials"] as? [[String: Any]])

    #expect(Set(fixed.keys) == [
      "global_function_tolerance",
      "global_max_num_iterations",
      "global_max_refinements",
      "local_function_tolerance",
      "local_image_count",
      "local_max_num_iterations",
      "local_max_refinements",
      "random_seed",
      "refine_focal_length",
    ])
    #expect(trials.count == 8)
    #expect(trials.allSatisfy { Set($0.keys) == ["name", "ordinal", "ratio"] })
    #expect(trials.compactMap { $0["ratio"] as? Double }
      == [1.1, 1.4, 1.4, 1.1, 1.1, 1.4, 1.4, 1.1])
  }

  @Test("fixed mapper options validate without relying on the current Core API")
  func fixedMapperOptionsValidateScalarsLocally() {
    #expect(throws: MeasurementMapperFixedOptionsValidationError.nonPositiveValue(
      "Local refinement limit"
    )) {
      try MeasurementMapperFixedOptions(
        localMaxRefinements: 0,
        globalMaxRefinements: 5,
        globalMaxNumIterations: 75,
        localMaxNumIterations: 10,
        localFunctionTolerance: 0.001,
        globalFunctionTolerance: 0.000_001,
        localImageCount: 6,
        randomSeed: 42,
        refineFocalLength: true
      )
    }
    #expect(throws: MeasurementMapperFixedOptionsValidationError.invalidTolerance(
      "Global function tolerance"
    )) {
      try MeasurementMapperFixedOptions(
        localMaxRefinements: 2,
        globalMaxRefinements: 5,
        globalMaxNumIterations: 75,
        localMaxNumIterations: 10,
        localFunctionTolerance: 0.001,
        globalFunctionTolerance: .nan,
        localImageCount: 6,
        randomSeed: 42,
        refineFocalLength: true
      )
    }
    #expect(throws: MeasurementMapperFixedOptionsValidationError.randomSeedOutOfRange) {
      try MeasurementMapperFixedOptions(
        localMaxRefinements: 2,
        globalMaxRefinements: 5,
        globalMaxNumIterations: 75,
        localMaxNumIterations: 10,
        localFunctionTolerance: 0.001,
        globalFunctionTolerance: 0.000_001,
        localImageCount: 6,
        randomSeed: UInt64(Int32.max) + 1,
        refineFocalLength: true
      )
    }
  }

  @Test("fixed mapper options use the canonical cross-language binding digest")
  func fixedMapperOptionsBindingDigestIsCanonical() throws {
    let baseline = try makeFixedOptions()
    let expected = "b62c0ec3cc6d36e410fd99d021f4c710c8fc3b786f3293cd6ceae3eeb85b5a89"

    #expect(try baseline.bindingSHA256(minimumPairInlierCount: 15) == expected)

    let mutations = [
      try makeFixedOptions(localMaxRefinements: 3)
        .bindingSHA256(minimumPairInlierCount: 15),
      try makeFixedOptions(globalMaxRefinements: 4)
        .bindingSHA256(minimumPairInlierCount: 15),
      try makeFixedOptions(globalMaxNumIterations: 101)
        .bindingSHA256(minimumPairInlierCount: 15),
      try makeFixedOptions(localMaxNumIterations: 11)
        .bindingSHA256(minimumPairInlierCount: 15),
      try makeFixedOptions(localFunctionTolerance: 0.002)
        .bindingSHA256(minimumPairInlierCount: 15),
      try makeFixedOptions(globalFunctionTolerance: 0.000_002)
        .bindingSHA256(minimumPairInlierCount: 15),
      try makeFixedOptions(localImageCount: 7)
        .bindingSHA256(minimumPairInlierCount: 15),
      try makeFixedOptions(randomSeed: 43)
        .bindingSHA256(minimumPairInlierCount: 15),
      try makeFixedOptions(refineFocalLength: false)
        .bindingSHA256(minimumPairInlierCount: 15),
      try baseline.bindingSHA256(minimumPairInlierCount: 16),
    ]
    #expect(!mutations.contains(expected))
    #expect(Set(mutations).count == mutations.count)
    #expect(throws: MeasurementMapperFixedOptionsValidationError.invalidMinimumPairInlierCount) {
      try baseline.bindingSHA256(minimumPairInlierCount: 0)
    }
    #expect(throws: MeasurementMapperFixedOptionsValidationError.invalidMinimumPairInlierCount) {
      try baseline.bindingSHA256(minimumPairInlierCount: -1)
    }
  }

  @Test("APFS trial clones preserve bytes and metadata without sharing an inode")
  func apfsTrialClonePreservesFrozenSource() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let database = try MeasurementFrozenCOLMAPDatabase(
      sourceParent: fixture.sourceParent,
      sourceName: fixture.sourceName,
      destinationParent: fixture.destinationParent
    )
    let trial = try #require(makeSchedule().trials.first)

    let clone = try database.makeTrialClone(for: trial, destinationName: "trial-01.db")

    #expect(clone.strategy == .apfsClone)
    #expect(clone.trialOrdinal == 1)
    #expect(clone.trialName == "mapper-cadence-01-1p1")
    #expect(clone.destinationName == "trial-01.db")
    #expect(clone.destinationDeviceID == database.sourceEvidence.deviceID)
    #expect(clone.destinationInode != database.sourceEvidence.inode)
    #expect(clone.destinationLinkCount == 1)
    #expect(clone.destinationByteCount == database.sourceEvidence.byteCount)
    #expect(database.sourceEvidence.mode & UInt32(0o7777) == UInt32(0o400))
    #expect(clone.destinationMode & UInt32(0o7777) == UInt32(0o600))
    #expect(clone.destinationOwnerUID == database.sourceEvidence.ownerUID)
    #expect(clone.destinationOwnerGID == database.sourceEvidence.ownerGID)
    #expect(clone.destinationSHA256 == database.sourceEvidence.sha256)
    #expect(try Data(contentsOf: fixture.destinationParent.appendingPathComponent("trial-01.db"))
      == fixture.sourceBytes)
    #expect(try database.revalidateSourceStatOnly() == database.sourceEvidence)
    #expect(try database.finalizeSourceRehash() == database.sourceEvidence)
  }

  @Test("capture freezes the master read-only and stat-only validation rejects re-enabling writes")
  func captureFreezesMasterReadOnly() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }

    let database = try fixture.open()

    var status = stat()
    #expect(Darwin.lstat(fixture.sourceURL.path, &status) == 0)
    #expect(UInt32(status.st_mode) & UInt32(0o7777) == UInt32(0o400))
    #expect(Darwin.chmod(fixture.sourceURL.path, 0o600) == 0)
    #expect(throws: MeasurementFrozenDatabaseError.sourceChanged) {
      try database.revalidateSourceStatOnly()
    }
  }

  @Test("recapturing one frozen master preserves exact source evidence")
  func repeatedCaptureDoesNotAdvanceFrozenSourceTimestamps() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let first = try fixture.open()
    let firstEvidence = first.sourceEvidence

    let second = try fixture.open()

    #expect(second.sourceEvidence == firstEvidence)
    #expect(try first.finalizeSourceRehash() == firstEvidence)
    #expect(try second.finalizeSourceRehash() == firstEvidence)
    var status = stat()
    #expect(Darwin.lstat(fixture.sourceURL.path, &status) == 0)
    #expect(UInt32(status.st_mode) == UInt32(S_IFREG | S_IRUSR))
  }

  @Test("source and trial databases may share one private directory")
  func supportsOnePrivateDatabaseDirectory() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let database = try MeasurementFrozenCOLMAPDatabase(
      sourceParent: fixture.sourceParent,
      sourceName: fixture.sourceName,
      destinationParent: fixture.sourceParent
    )
    let trial = try #require(makeSchedule().trials.first)

    let evidence = try database.makeTrialClone(
      for: trial,
      destinationName: "trial.db"
    )

    #expect(evidence.strategy == .apfsClone)
    #expect(evidence.destinationParentDeviceID == database.sourceEvidence.parentDeviceID)
    #expect(evidence.destinationParentInode == database.sourceEvidence.parentInode)
    #expect(evidence.destinationMode & UInt32(0o7777) == UInt32(0o600))
    #expect(throws: MeasurementFrozenDatabaseError.destinationExists(fixture.sourceName)) {
      try database.makeTrialClone(for: trial, destinationName: fixture.sourceName)
    }
    #expect(try database.finalizeSourceRehash() == database.sourceEvidence)
  }

  @Test("trial lease survives source release and revalidates through held descriptors")
  func trialLeaseRevalidatesUnchanged() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    var source: MeasurementFrozenCOLMAPDatabase? = try fixture.open()
    let lease = try #require(source).makeTrialCloneLease(
      for: try #require(makeSchedule().trials.first),
      destinationName: "leased.db"
    )
    source = nil

    #expect(lease.databaseURL.path.hasPrefix("/"))
    #expect(lease.databaseURL == fixture.destinationParent.appendingPathComponent("leased.db"))
    #expect(lease.evidence.destinationName == "leased.db")
    #expect(lease.evidence.destinationMode & UInt32(0o7777) == UInt32(0o600))
    #expect(try lease.revalidatePreRunUnchanged() == lease.evidence)
    let finalEvidence = try lease.finalizePostRun()
    #expect(finalEvidence.destinationName == lease.evidence.destinationName)
    #expect(finalEvidence.destinationInode == lease.evidence.destinationInode)
    #expect(finalEvidence.destinationByteCount == lease.evidence.destinationByteCount)
    #expect(finalEvidence.destinationSHA256 == lease.evidence.destinationSHA256)
  }

  @Test("trial lease records mapper mutations while preserving the bound inode")
  func trialLeaseRecordsBoundMapperMutation() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let source = try fixture.open()
    let lease = try source.makeTrialCloneLease(
      for: try #require(makeSchedule().trials.first),
      destinationName: "mutated.db"
    )
    let descriptor = Darwin.open(
      lease.databaseURL.path,
      O_WRONLY | O_NOFOLLOW | O_CLOEXEC
    )
    #expect(descriptor >= 0)
    var byte: UInt8 = 0xA5
    let written = withUnsafeBytes(of: &byte) {
      Darwin.pwrite(descriptor, $0.baseAddress, 1, 0)
    }
    #expect(written == 1)
    #expect(Darwin.ftruncate(descriptor, off_t(fixture.sourceBytes.count + 257)) == 0)
    #expect(Darwin.fsync(descriptor) == 0)
    Darwin.close(descriptor)

    #expect(throws: MeasurementFrozenDatabaseError.self) {
      try lease.revalidatePreRunUnchanged()
    }
    let finalEvidence = try lease.finalizePostRun()
    #expect(finalEvidence.destinationDeviceID == lease.evidence.destinationDeviceID)
    #expect(finalEvidence.destinationInode == lease.evidence.destinationInode)
    #expect(finalEvidence.destinationLinkCount == 1)
    #expect(finalEvidence.destinationByteCount == Int64(fixture.sourceBytes.count + 257))
    #expect(finalEvidence.destinationMode & UInt32(0o7777) == UInt32(0o600))
    #expect(finalEvidence.destinationSHA256 != lease.evidence.destinationSHA256)
    #expect(try source.finalizeSourceRehash() == source.sourceEvidence)
  }

  @Test("trial lease rejects permission changes")
  func trialLeaseRejectsChmod() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let source = try fixture.open()
    let lease = try source.makeTrialCloneLease(
      for: try #require(makeSchedule().trials.first),
      destinationName: "chmod.db"
    )

    #expect(Darwin.chmod(lease.databaseURL.path, 0o400) == 0)
    #expect(throws: MeasurementFrozenDatabaseError.self) {
      try lease.revalidatePreRunUnchanged()
    }
    #expect(throws: MeasurementFrozenDatabaseError.self) {
      try lease.finalizePostRun()
    }
  }

  @Test("trial lease rejects pathname replacement while retaining the original inode")
  func trialLeaseRejectsPathReplacement() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let source = try fixture.open()
    let lease = try source.makeTrialCloneLease(
      for: try #require(makeSchedule().trials.first),
      destinationName: "replaced.db"
    )
    let replacement = fixture.destinationParent.appendingPathComponent("replacement.db")
    try fixture.sourceBytes.write(to: replacement)
    #expect(Darwin.chmod(replacement.path, 0o600) == 0)
    try FileManager.default.removeItem(at: lease.databaseURL)
    try FileManager.default.moveItem(at: replacement, to: lease.databaseURL)

    #expect(throws: MeasurementFrozenDatabaseError.self) {
      try lease.revalidatePreRunUnchanged()
    }
    #expect(throws: MeasurementFrozenDatabaseError.self) {
      try lease.finalizePostRun()
    }
  }

  @Test("trial lease rejects transient pathname replacement after the original is restored")
  func trialLeaseRejectsTransientPathReplacement() throws {
    for validation in ["pre-run", "post-run"] {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      let source = try fixture.open()
      let lease = try source.makeTrialCloneLease(
        for: try #require(makeSchedule().trials.first),
        destinationName: "transient-\(validation).db"
      )
      if validation == "post-run" {
        try lease.revalidatePreRunUnchanged()
      }

      let parked = fixture.destinationParent.appendingPathComponent("parked-\(validation).db")
      let replacement = fixture.destinationParent.appendingPathComponent(
        "replacement-\(validation).db"
      )
      try Data(repeating: 0xA5, count: fixture.sourceBytes.count).write(to: replacement)
      #expect(Darwin.chmod(replacement.path, 0o600) == 0)
      try FileManager.default.moveItem(at: lease.databaseURL, to: parked)
      try FileManager.default.moveItem(at: replacement, to: lease.databaseURL)
      try FileManager.default.moveItem(at: lease.databaseURL, to: replacement)
      try FileManager.default.moveItem(at: parked, to: lease.databaseURL)

      if validation == "pre-run" {
        #expect(throws: MeasurementFrozenDatabaseError.trialPathMutation(
          UInt32(NOTE_RENAME)
        )) {
          try lease.revalidatePreRunUnchanged()
        }
      } else {
        #expect(throws: MeasurementFrozenDatabaseError.trialPathMutation(
          UInt32(NOTE_RENAME)
        )) {
          try lease.finalizePostRun()
        }
      }
    }
  }

  @Test("trial lease rejects transient atomic pathname swaps where supported")
  func trialLeaseRejectsTransientAtomicSwap() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let source = try fixture.open()
    let lease = try source.makeTrialCloneLease(
      for: try #require(makeSchedule().trials.first),
      destinationName: "swap.db"
    )
    let replacement = fixture.destinationParent.appendingPathComponent("swap-replacement.db")
    try Data(repeating: 0x5A, count: fixture.sourceBytes.count).write(to: replacement)
    #expect(Darwin.chmod(replacement.path, 0o600) == 0)

    let first = Darwin.renameatx_np(
      AT_FDCWD,
      lease.databaseURL.path,
      AT_FDCWD,
      replacement.path,
      UInt32(RENAME_SWAP)
    )
    if first != 0, [ENOTSUP, EINVAL].contains(errno) {
      return
    }
    #expect(first == 0)
    #expect(Darwin.renameatx_np(
      AT_FDCWD,
      lease.databaseURL.path,
      AT_FDCWD,
      replacement.path,
      UInt32(RENAME_SWAP)
    ) == 0)

    #expect(throws: MeasurementFrozenDatabaseError.trialPathMutation(
      UInt32(NOTE_RENAME | NOTE_DELETE)
    )) {
      try lease.revalidatePreRunUnchanged()
    }
    #expect(throws: MeasurementFrozenDatabaseError.trialPathMutation(
      UInt32(NOTE_RENAME | NOTE_DELETE)
    )) {
      try lease.finalizePostRun()
    }
  }

  @Test("trial watcher ignores ordinary writes and restored attributes")
  func trialLeaseWatcherIgnoresWritesAndRestoredAttributes() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let source = try fixture.open()
    let lease = try source.makeTrialCloneLease(
      for: try #require(makeSchedule().trials.first),
      destinationName: "ordinary-mutation.db"
    )
    try lease.revalidatePreRunUnchanged()

    let descriptor = Darwin.open(
      lease.databaseURL.path,
      O_WRONLY | O_NOFOLLOW | O_CLOEXEC
    )
    #expect(descriptor >= 0)
    var replacementByte: UInt8 = 0xA5
    #expect(withUnsafeBytes(of: &replacementByte) {
      Darwin.pwrite(descriptor, $0.baseAddress, 1, 0)
    } == 1)
    var originalByte = try #require(fixture.sourceBytes.first)
    #expect(withUnsafeBytes(of: &originalByte) {
      Darwin.pwrite(descriptor, $0.baseAddress, 1, 0)
    } == 1)
    #expect(Darwin.fsync(descriptor) == 0)
    Darwin.close(descriptor)
    #expect(Darwin.chmod(lease.databaseURL.path, 0o400) == 0)
    #expect(Darwin.chmod(lease.databaseURL.path, 0o600) == 0)

    let finalEvidence = try lease.finalizePostRun()
    #expect(finalEvidence.destinationSHA256 == lease.evidence.destinationSHA256)
  }

  @Test("watcher setup failure preserves the published private trial clone")
  func trialWatcherSetupFailurePreservesPublishedClone() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let source = try fixture.open(trialWatcherOperation: { _ in
      throw MeasurementFrozenDatabaseError.trialWatcherUnavailable(
        "injected trial database watcher",
        EMFILE
      )
    })
    let destination = fixture.destinationParent.appendingPathComponent("watcher-failure.db")

    #expect(throws: MeasurementFrozenDatabaseError.trialWatcherUnavailable(
      "injected trial database watcher",
      EMFILE
    )) {
      try source.makeTrialCloneLease(
        for: try #require(makeSchedule().trials.first),
        destinationName: destination.lastPathComponent
      )
    }
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(try Data(contentsOf: destination) == fixture.sourceBytes)
    var status = stat()
    #expect(Darwin.lstat(destination.path, &status) == 0)
    #expect(status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
    #expect(status.st_mode & mode_t(0o7777) == mode_t(0o600))
  }

  @Test("trial lease rejects WAL, SHM, and unknown companions regardless of type")
  func trialLeaseRejectsEveryCompanionType() throws {
    enum CompanionKind {
      case file
      case directory
      case symbolicLink
    }
    for (suffix, kind) in [
      ("-wal", CompanionKind.file),
      ("-shm", CompanionKind.directory),
      ("-future", CompanionKind.symbolicLink),
    ] {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      let source = try fixture.open()
      let lease = try source.makeTrialCloneLease(
        for: try #require(makeSchedule().trials.first),
        destinationName: "companions.db"
      )
      let companion = fixture.destinationParent.appendingPathComponent(
        "companions.db" + suffix
      )
      switch kind {
      case .file:
        try Data("wal".utf8).write(to: companion)
      case .directory:
        try FileManager.default.createDirectory(at: companion, withIntermediateDirectories: false)
      case .symbolicLink:
        try FileManager.default.createSymbolicLink(
          at: companion,
          withDestinationURL: fixture.sourceURL
        )
      }

      #expect(throws: MeasurementFrozenDatabaseError.sourceCompanion(companion.lastPathComponent)) {
        try lease.revalidatePreRunUnchanged()
      }
      #expect(throws: MeasurementFrozenDatabaseError.sourceCompanion(companion.lastPathComponent)) {
        try lease.finalizePostRun()
      }
    }
  }

  @Test("trial lease rejects destination-parent rebinding")
  func trialLeaseRejectsParentRebinding() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let source = try fixture.open()
    let lease = try source.makeTrialCloneLease(
      for: try #require(makeSchedule().trials.first),
      destinationName: "parent.db"
    )
    let displaced = fixture.root.appendingPathComponent("displaced-lease-parent", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.destinationParent, to: displaced)
    try FileManager.default.createDirectory(
      at: fixture.destinationParent,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    #expect(Darwin.chmod(fixture.destinationParent.path, 0o700) == 0)

    #expect(throws: MeasurementFrozenDatabaseError.self) {
      try lease.revalidatePreRunUnchanged()
    }
    #expect(throws: MeasurementFrozenDatabaseError.self) {
      try lease.finalizePostRun()
    }
  }

  @Test("releasing a successful trial lease never deletes its database")
  func trialLeaseReleasePreservesDatabase() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let source = try fixture.open()
    var lease: MeasurementFrozenDatabaseTrialLease? = try source.makeTrialCloneLease(
      for: try #require(makeSchedule().trials.first),
      destinationName: "preserved.db"
    )
    let databaseURL = try #require(lease).databaseURL
    let evidence = try #require(lease).evidence

    lease = nil

    #expect(FileManager.default.fileExists(atPath: databaseURL.path))
    #expect(try Data(contentsOf: databaseURL) == fixture.sourceBytes)
    var status = stat()
    #expect(Darwin.lstat(databaseURL.path, &status) == 0)
    #expect(UInt64(status.st_ino) == evidence.destinationInode)
  }

  @Test(
    "every SQLite companion blocks freezing",
    arguments: ["database.db-wal", "database.db-shm", "database.db-journal", "database.db-future"]
  )
  func rejectsEverySourceCompanion(_ companion: String) throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    try Data("companion".utf8).write(
      to: fixture.sourceParent.appendingPathComponent(companion)
    )

    #expect(throws: MeasurementFrozenDatabaseError.sourceCompanion(companion)) {
      try MeasurementFrozenCOLMAPDatabase(
        sourceParent: fixture.sourceParent,
        sourceName: fixture.sourceName,
        destinationParent: fixture.destinationParent
      )
    }
  }

  @Test("a companion created after capture invalidates stat-only revalidation")
  func revalidationRejectsLateCompanion() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let database = try fixture.open()
    let companion = fixture.sourceName + "-wal"
    try Data("late".utf8).write(to: fixture.sourceParent.appendingPathComponent(companion))

    #expect(throws: MeasurementFrozenDatabaseError.sourceCompanion(companion)) {
      try database.revalidateSourceStatOnly()
    }
  }

  @Test("a companion created during freezing prevents evidence publication")
  func captureRejectsCompanionCreatedDuringFreeze() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let companionName = fixture.sourceName + "-wal"
    let companionURL = fixture.sourceParent.appendingPathComponent(companionName)

    #expect(throws: MeasurementFrozenDatabaseError.sourceCompanion(companionName)) {
      try fixture.open(captureCheckpoint: {
        try Data("late-during-freeze".utf8).write(to: companionURL)
      })
    }
  }

  @Test("source symlinks, hardlinks, and empty files are rejected")
  func rejectsUnsafeSources() throws {
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      let target = fixture.sourceParent.appendingPathComponent("target.db")
      try FileManager.default.moveItem(at: fixture.sourceURL, to: target)
      try FileManager.default.createSymbolicLink(at: fixture.sourceURL, withDestinationURL: target)
      #expect(throws: MeasurementFrozenDatabaseError.self) { try fixture.open() }
    }
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      let link = fixture.sourceParent.appendingPathComponent("database-copy.db")
      #expect(Darwin.link(fixture.sourceURL.path, link.path) == 0)
      #expect(throws: MeasurementFrozenDatabaseError.self) { try fixture.open() }
    }
    do {
      let fixture = try FrozenDatabaseFixture(sourceBytes: Data())
      defer { fixture.remove() }
      #expect(throws: MeasurementFrozenDatabaseError.self) { try fixture.open() }
    }
  }

  @Test("source and destination parent leaves must be private real directories")
  func rejectsUnsafeParentDirectories() throws {
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      #expect(Darwin.chmod(fixture.sourceParent.path, 0o750) == 0)
      #expect(throws: MeasurementFrozenDatabaseError.self) { try fixture.open() }
    }
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      #expect(Darwin.chmod(fixture.destinationParent.path, 0o500) == 0)
      #expect(throws: MeasurementFrozenDatabaseError.self) { try fixture.open() }
    }
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      let alias = fixture.root.appendingPathComponent("source-alias", isDirectory: true)
      try FileManager.default.createSymbolicLink(
        at: alias,
        withDestinationURL: fixture.sourceParent
      )
      #expect(throws: MeasurementFrozenDatabaseError.self) {
        try MeasurementFrozenCOLMAPDatabase(
          sourceParent: alias,
          sourceName: fixture.sourceName,
          destinationParent: fixture.destinationParent
        )
      }
    }
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      let alias = fixture.root.appendingPathComponent("destination-alias", isDirectory: true)
      try FileManager.default.createSymbolicLink(
        at: alias,
        withDestinationURL: fixture.destinationParent
      )
      #expect(throws: MeasurementFrozenDatabaseError.self) {
        try MeasurementFrozenCOLMAPDatabase(
          sourceParent: fixture.sourceParent,
          sourceName: fixture.sourceName,
          destinationParent: alias
        )
      }
    }
  }

  @Test("source and destination names must be normalized single components")
  func rejectsUnsafeNames() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let invalidNames = ["", ".", "..", "folder/name", "folder\\name", "e\u{301}.db"]
    for name in invalidNames {
      #expect(throws: MeasurementFrozenDatabaseError.invalidLeafName(name)) {
        try MeasurementFrozenCOLMAPDatabase(
          sourceParent: fixture.sourceParent,
          sourceName: name,
          destinationParent: fixture.destinationParent
        )
      }
    }

    let database = try fixture.open()
    let trial = try #require(makeSchedule().trials.first)
    for name in invalidNames {
      #expect(throws: MeasurementFrozenDatabaseError.invalidLeafName(name)) {
        try database.makeTrialClone(for: trial, destinationName: name)
      }
    }
  }

  @Test("existing destination entries are never replaced or removed")
  func preservesExistingDestination() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let database = try fixture.open()
    let trial = try #require(makeSchedule().trials.first)
    let destination = fixture.destinationParent.appendingPathComponent("existing.db")
    let original = Data("keep this exact destination".utf8)
    try original.write(to: destination)

    #expect(throws: MeasurementFrozenDatabaseError.destinationExists("existing.db")) {
      try database.makeTrialClone(for: trial, destinationName: "existing.db")
    }
    #expect(try Data(contentsOf: destination) == original)
  }

  @Test("an existing destination symlink is preserved")
  func preservesExistingDestinationSymlink() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let database = try fixture.open()
    let trial = try #require(makeSchedule().trials.first)
    let target = fixture.root.appendingPathComponent("outside.db")
    let original = Data("outside".utf8)
    try original.write(to: target)
    let destination = fixture.destinationParent.appendingPathComponent("existing.db")
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

    #expect(throws: MeasurementFrozenDatabaseError.destinationExists("existing.db")) {
      try database.makeTrialClone(for: trial, destinationName: "existing.db")
    }
    #expect(try Data(contentsOf: target) == original)
    #expect(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
  }

  @Test("source byte mutation and source-leaf replacement invalidate the lease")
  func detectsSourceMutationAndReplacement() throws {
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      let database = try fixture.open()
      #expect(Darwin.chmod(fixture.sourceURL.path, 0o600) == 0)
      try Data(repeating: 0x5A, count: fixture.sourceBytes.count).write(to: fixture.sourceURL)
      #expect(throws: MeasurementFrozenDatabaseError.sourceChanged) {
        try database.revalidateSourceStatOnly()
      }
      #expect(throws: MeasurementFrozenDatabaseError.sourceChanged) {
        try database.finalizeSourceRehash()
      }
    }
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      let database = try fixture.open()
      let replacement = fixture.sourceParent.appendingPathComponent("replacement.db")
      try fixture.sourceBytes.write(to: replacement)
      #expect(Darwin.chmod(replacement.path, 0o640) == 0)
      try FileManager.default.removeItem(at: fixture.sourceURL)
      try FileManager.default.moveItem(at: replacement, to: fixture.sourceURL)
      #expect(throws: MeasurementFrozenDatabaseError.sourceChanged) {
        try database.revalidateSourceStatOnly()
      }
    }
  }

  @Test("source and destination parent rebinding invalidate the lease")
  func detectsParentRebinding() throws {
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      let database = try fixture.open()
      let displaced = fixture.root.appendingPathComponent("displaced-source", isDirectory: true)
      try FileManager.default.moveItem(at: fixture.sourceParent, to: displaced)
      try FileManager.default.createDirectory(
        at: fixture.sourceParent,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      #expect(Darwin.chmod(fixture.sourceParent.path, 0o700) == 0)

      #expect(throws: MeasurementFrozenDatabaseError.self) {
        try database.revalidateSourceStatOnly()
      }
    }
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      let database = try fixture.open()
      let displaced = fixture.root.appendingPathComponent("displaced-trials", isDirectory: true)
      try FileManager.default.moveItem(at: fixture.destinationParent, to: displaced)
      try FileManager.default.createDirectory(
        at: fixture.destinationParent,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      #expect(Darwin.chmod(fixture.destinationParent.path, 0o700) == 0)

      #expect(throws: MeasurementFrozenDatabaseError.self) {
        try database.makeTrialClone(
          for: try #require(makeSchedule().trials.first),
          destinationName: "rebound.db"
        )
      }
      #expect(try FileManager.default.contentsOfDirectory(
        atPath: fixture.destinationParent.path
      ).isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: displaced.path).isEmpty)
    }
  }

  @Test("clone EINTR is retried and unsupported cloning has explicit copy evidence")
  func retriesInterruptedCloneAndReportsCopyFallback() throws {
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      var attempts = 0
      let database = try fixture.open { source, parent, leaf, flags in
        attempts += 1
        if attempts == 1 { return EINTR }
        let result = leaf.withCString { fclonefileat(source, parent, $0, flags) }
        return result == 0 ? 0 : errno
      }
      let evidence = try database.makeTrialClone(
        for: try #require(makeSchedule().trials.first),
        destinationName: "eintr.db"
      )
      #expect(attempts == 2)
      #expect(evidence.strategy == .apfsClone)
    }
    do {
      let fixture = try FrozenDatabaseFixture()
      defer { fixture.remove() }
      let database = try fixture.open { _, _, _, _ in ENOTSUP }
      let evidence = try database.makeTrialClone(
        for: try #require(makeSchedule().trials.first),
        destinationName: "copied.db"
      )
      #expect(evidence.strategy == .descriptorCopy)
      #expect(evidence.destinationMode & UInt32(0o7777) == UInt32(0o600))
      #expect(evidence.destinationSHA256 == database.sourceEvidence.sha256)
    }
  }

  @Test(
    "only unsupported clone errors permit an explicit descriptor-copy fallback",
    arguments: [EXDEV, ENOTSUP, ENOSYS]
  )
  func permittedCopyFallbacks(_ code: Int32) throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let database = try fixture.open { _, _, _, _ in code }
    let evidence = try database.makeTrialClone(
      for: try #require(makeSchedule().trials.first),
      destinationName: "fallback.db"
    )

    #expect(evidence.strategy == .descriptorCopy)
    #expect(evidence.destinationMode & UInt32(0o7777) == UInt32(0o600))
  }

  @Test("unexpected clone errors fail closed without creating a copy")
  func unexpectedCloneErrorDoesNotFallBack() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let database = try fixture.open { _, _, _, _ in EIO }

    #expect(throws: MeasurementFrozenDatabaseError.cloneFailed(EIO)) {
      try database.makeTrialClone(
        for: try #require(makeSchedule().trials.first),
        destinationName: "must-not-exist.db"
      )
    }
    #expect(try FileManager.default.contentsOfDirectory(
      atPath: fixture.destinationParent.path
    ).isEmpty)
  }

  @Test("validation failure never unlinks an unpublished staging pathname")
  func validationFailurePreservesStagingWithoutTouchingOtherEntries() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let sentinel = fixture.destinationParent.appendingPathComponent("sentinel.txt")
    let sentinelBytes = Data("preserve".utf8)
    try sentinelBytes.write(to: sentinel)
    let database = try fixture.open { source, parent, leaf, flags in
      let result = leaf.withCString { fclonefileat(source, parent, $0, flags) }
      guard result == 0 else { return errno }
      let descriptor = leaf.withCString {
        openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard descriptor >= 0 else { return errno }
      guard fchmod(descriptor, 0o600) == 0 else {
        let code = errno
        Darwin.close(descriptor)
        return code
      }
      Darwin.close(descriptor)
      let writable = leaf.withCString {
        openat(parent, $0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      }
      guard writable >= 0 else { return errno }
      defer { Darwin.close(writable) }
      var byte: UInt8 = 0xFF
      let written = withUnsafeBytes(of: &byte) {
        pwrite(writable, $0.baseAddress, 1, 0)
      }
      return written == 1 ? 0 : errno
    }

    #expect(throws: MeasurementFrozenDatabaseError.self) {
      try database.makeTrialClone(
        for: try #require(makeSchedule().trials.first),
        destinationName: "invalid.db"
      )
    }
    #expect(!FileManager.default.fileExists(
      atPath: fixture.destinationParent.appendingPathComponent("invalid.db").path
    ))
    #expect(try Data(contentsOf: sentinel) == sentinelBytes)
    let leaves = try FileManager.default.contentsOfDirectory(
      atPath: fixture.destinationParent.path
    ).sorted()
    #expect(leaves.count == 2)
    #expect(leaves.contains("sentinel.txt"))
    #expect(leaves.contains { $0.hasPrefix(".") && $0.hasSuffix(".frozen-db") })
  }

  @Test("failed clone validation preserves a hostile staging replacement")
  func failedCloneValidationDoesNotDeleteReplacement() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let target = fixture.root.appendingPathComponent("hostile-target.db")
    let targetBytes = Data("must survive".utf8)
    try targetBytes.write(to: target)
    let database = try fixture.open { _, parent, leaf, _ in
      let result = target.path.withCString { destination in
        leaf.withCString { name in
          Darwin.symlinkat(destination, parent, name)
        }
      }
      return result == 0 ? 0 : errno
    }

    #expect(throws: MeasurementFrozenDatabaseError.self) {
      try database.makeTrialClone(
        for: try #require(makeSchedule().trials.first),
        destinationName: "invalid.db"
      )
    }
    let leaves = try FileManager.default.contentsOfDirectory(
      atPath: fixture.destinationParent.path
    )
    let stagingName = try #require(
      leaves.first { $0.hasPrefix(".") && $0.hasSuffix(".frozen-db") }
    )
    let staging = fixture.destinationParent.appendingPathComponent(stagingName)
    #expect(try staging.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(try Data(contentsOf: target) == targetBytes)
  }

  @Test("post-publication validation failure preserves the published destination")
  func postPublicationFailurePreservesDestination() throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let database = try fixture.open(postPublicationCheckpoint: {
      throw FrozenDatabaseInjectedError.expected
    })
    let destination = fixture.destinationParent.appendingPathComponent("published.db")

    #expect(throws: FrozenDatabaseInjectedError.expected) {
      try database.makeTrialClone(
        for: try #require(makeSchedule().trials.first),
        destinationName: destination.lastPathComponent
      )
    }
    #expect(try Data(contentsOf: destination) == fixture.sourceBytes)
    var status = stat()
    #expect(Darwin.lstat(destination.path, &status) == 0)
    #expect(UInt32(status.st_mode) & UInt32(0o7777) == UInt32(0o600))
  }

  @Test("pre-cancelled work creates no destination")
  func cancellationCreatesNoDestination() async throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let database = try fixture.open()
    let trial = try #require(makeSchedule().trials.first)
    let result = await Task<Result<MeasurementFrozenDatabaseCloneEvidence, Error>, Never> {
      withUnsafeCurrentTask { $0?.cancel() }
      return Result {
        try database.makeTrialClone(for: trial, destinationName: "cancelled.db")
      }
    }.value

    guard case .failure(let error) = result else {
      Issue.record("cancelled clone unexpectedly succeeded")
      return
    }
    #expect(error is CancellationError)
    #expect(!FileManager.default.fileExists(
      atPath: fixture.destinationParent.appendingPathComponent("cancelled.db").path
    ))
  }

  @Test("cancellation after a clone becomes writable preserves its private staging leaf")
  func cancellationAfterWritableClonePreservesStaging() async throws {
    let fixture = try FrozenDatabaseFixture()
    defer { fixture.remove() }
    let database = try fixture.open { source, parent, leaf, flags in
      let result = leaf.withCString { fclonefileat(source, parent, $0, flags) }
      guard result == 0 else { return errno }
      let descriptor = leaf.withCString {
        openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard descriptor >= 0 else { return errno }
      let chmodResult = fchmod(descriptor, 0o600)
      let chmodError = errno
      Darwin.close(descriptor)
      guard chmodResult == 0 else { return chmodError }
      withUnsafeCurrentTask { $0?.cancel() }
      return 0
    }
    let trial = try #require(makeSchedule().trials.first)
    let result = await Task<Result<MeasurementFrozenDatabaseCloneEvidence, Error>, Never> {
      Result {
        try database.makeTrialClone(for: trial, destinationName: "cancelled-after-clone.db")
      }
    }.value

    guard case .failure(let error) = result else {
      Issue.record("cancelled clone unexpectedly succeeded")
      return
    }
    #expect(error is CancellationError)
    let leaves = try FileManager.default.contentsOfDirectory(
      atPath: fixture.destinationParent.path
    )
    #expect(leaves.count == 1)
    let stagingName = try #require(leaves.first)
    #expect(stagingName.hasPrefix(".") && stagingName.hasSuffix(".frozen-db"))
    var status = stat()
    #expect(Darwin.lstat(
      fixture.destinationParent.appendingPathComponent(stagingName).path,
      &status
    ) == 0)
    #expect(UInt32(status.st_mode) & UInt32(0o7777) == UInt32(0o600))
  }

  private func makeSchedule() throws -> MeasurementMapperCadenceSchedule {
    MeasurementMapperCadenceSchedule(
      fixedOptions: try MeasurementMapperFixedOptions(
        localMaxRefinements: 2,
        globalMaxRefinements: 5,
        globalMaxNumIterations: 75,
        localMaxNumIterations: 10,
        localFunctionTolerance: 0.001,
        globalFunctionTolerance: 0.000_001,
        localImageCount: 6,
        randomSeed: 42,
        refineFocalLength: true
      )
    )
  }

  private func makeFixedOptions(
    localMaxRefinements: Int = 2,
    globalMaxRefinements: Int = 5,
    globalMaxNumIterations: Int = 100,
    localMaxNumIterations: Int = 10,
    localFunctionTolerance: Double = 0.001,
    globalFunctionTolerance: Double = 0.000_001,
    localImageCount: Int = 6,
    randomSeed: UInt64 = 42,
    refineFocalLength: Bool = true
  ) throws -> MeasurementMapperFixedOptions {
    try MeasurementMapperFixedOptions(
      localMaxRefinements: localMaxRefinements,
      globalMaxRefinements: globalMaxRefinements,
      globalMaxNumIterations: globalMaxNumIterations,
      localMaxNumIterations: localMaxNumIterations,
      localFunctionTolerance: localFunctionTolerance,
      globalFunctionTolerance: globalFunctionTolerance,
      localImageCount: localImageCount,
      randomSeed: randomSeed,
      refineFocalLength: refineFocalLength
    )
  }
}

private struct FrozenDatabaseFixture {
  let root: URL
  let sourceParent: URL
  let destinationParent: URL
  let sourceName = "database.db"
  let sourceBytes: Data

  var sourceURL: URL { sourceParent.appendingPathComponent(sourceName) }

  init(sourceBytes: Data = Data((0..<16_384).map { UInt8($0 % 251) })) throws {
    self.sourceBytes = sourceBytes
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    sourceParent = root.appendingPathComponent("source", isDirectory: true)
    destinationParent = root.appendingPathComponent("trials", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceParent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createDirectory(
      at: destinationParent,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    #expect(Darwin.chmod(sourceParent.path, 0o700) == 0)
    #expect(Darwin.chmod(destinationParent.path, 0o700) == 0)
    try sourceBytes.write(to: sourceURL)
    #expect(Darwin.chmod(sourceURL.path, 0o640) == 0)
  }

  func open(
    cloneOperation: MeasurementFrozenCOLMAPDatabase.CloneOperation? = nil,
    captureCheckpoint: @escaping () throws -> Void = {},
    postPublicationCheckpoint: @escaping () throws -> Void = {},
    trialWatcherOperation: @escaping MeasurementFrozenDatabaseTrialLease.WatcherOperation =
      MeasurementFrozenDatabaseTrialLease.makePathMutationWatcher
  ) throws -> MeasurementFrozenCOLMAPDatabase {
    try MeasurementFrozenCOLMAPDatabase(
      sourceParent: sourceParent,
      sourceName: sourceName,
      destinationParent: destinationParent,
      cloneOperation: cloneOperation ?? MeasurementFrozenCOLMAPDatabase.performClone,
      captureCheckpoint: captureCheckpoint,
      postPublicationCheckpoint: postPublicationCheckpoint,
      trialWatcherOperation: trialWatcherOperation
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private enum FrozenDatabaseInjectedError: Error {
  case expected
}

import Darwin
import CryptoKit
import Foundation

public struct MeasurementPairListAttemptSummary: Sendable, Equatable {
  public let attemptNumber: Int
  public let matcher: String
  public let exactRecoveryReason: String?
  public let recoveryLevel: String
  public let outcome: String
  public let scheduledPairCount: Int
  public let attemptedPairCount: Int
  public let rawMatchedPairCount: Int
  public let spatiallyVerifiedPairCount: Int
}

public struct MeasurementPairListBuildResult: Sendable, Equatable {
  public let pairListDigest: String
  public let attempts: [MeasurementPairListAttemptSummary]
  public let scheduledPairCount: Int
  public let attemptedPairCount: Int
  public let rawMatchedPairCount: Int
  public let spatiallyVerifiedPairCount: Int
  public let localPairCount: Int
  public let retrievalPairCount: Int
  public let loopPairCount: Int
}

public enum MeasurementPairListBuilder {
  private static let sourceSchemaVersion = 20
  private static let outputSchemaVersion = 5
  private static let maximumSourceBytes = 64 * 1_024 * 1_024
  private static let maximumExactRecoveryPairCount = 256

  static func permitsExactRecovery(scheduledPairCount: Int) -> Bool {
    (1...maximumExactRecoveryPairCount).contains(scheduledPairCount)
  }

  struct IOHooks {
    var afterSourceRead: () throws -> Void = {}
    var beforeDestinationPublish: () throws -> Void = {}
    var afterDestinationPublish: () throws -> Void = {}
  }

  public static func write(
    source: URL,
    selectedFrameCount: Int,
    to destination: URL
  ) throws -> MeasurementPairListBuildResult {
    try write(
      source: source,
      selectedFrameCount: selectedFrameCount,
      to: destination,
      hooks: IOHooks())
  }

  static func write(
    source: URL,
    selectedFrameCount: Int,
    to destination: URL,
    hooks: IOHooks
  ) throws -> MeasurementPairListBuildResult {
    let evidence = try load(source, afterRead: hooks.afterSourceRead)
    let output = try build(evidence, selectedFrameCount: selectedFrameCount)
    var data = try JSONSerialization.data(
      withJSONObject: output.document,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0A)
    try writeExclusive(data, to: destination, hooks: hooks)
    return output.result
  }

  private static func load(
    _ source: URL,
    afterRead: @escaping () throws -> Void
  ) throws -> SourceEvidence {
    let stable = try MeasurementStableFileEvidence.readForTesting(
      source,
      maximumBytes: maximumSourceBytes,
      afterRead: afterRead)
    let evidence: SourceEvidence
    do {
      evidence = try JSONDecoder().decode(SourceEvidence.self, from: stable.data)
    } catch {
      throw MeasurementRunnerError.subprocessFailed(
        "pair-graph evidence does not match schema \(sourceSchemaVersion)")
    }
    guard evidence.schemaVersion == sourceSchemaVersion else {
      throw MeasurementRunnerError.subprocessFailed(
        "pair-graph evidence does not match schema \(sourceSchemaVersion)")
    }
    return evidence
  }

  private static func writeExclusive(
    _ data: Data,
    to destination: URL,
    hooks: IOHooks
  ) throws {
    let parent = destination.deletingLastPathComponent()
    let leaf = destination.lastPathComponent
    guard destination.isFileURL,
      !leaf.isEmpty, leaf != ".", leaf != "..",
      !leaf.contains("/"), !leaf.contains("\0")
    else { throw MeasurementRunnerError.unsafePath("pair-list destination is invalid") }
    let parentDescriptor = Darwin.open(
      parent.path,
      O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard parentDescriptor >= 0 else {
      throw MeasurementRunnerError.unsafePath("pair-list destination directory is unsafe")
    }
    defer { Darwin.close(parentDescriptor) }
    var openedParent = stat()
    var parentAtPath = stat()
    guard Darwin.fstat(parentDescriptor, &openedParent) == 0,
      Darwin.lstat(parent.path, &parentAtPath) == 0,
      (openedParent.st_mode & S_IFMT) == S_IFDIR,
      openedParent.st_dev == parentAtPath.st_dev,
      openedParent.st_ino == parentAtPath.st_ino
    else {
      throw MeasurementRunnerError.unsafePath("pair-list destination directory is unstable")
    }

    func parentPathStillMatches() -> Bool {
      var current = stat()
      return Darwin.lstat(parent.path, &current) == 0
        && (current.st_mode & S_IFMT) == S_IFDIR
        && current.st_dev == openedParent.st_dev
        && current.st_ino == openedParent.st_ino
    }

    func leafStillMatches(_ candidate: String, _ identity: stat) -> Bool {
      var current = stat()
      return Darwin.fstatat(
        parentDescriptor,
        candidate,
        &current,
        AT_SYMLINK_NOFOLLOW) == 0
        && (current.st_mode & S_IFMT) == S_IFREG
        && current.st_nlink == 1
        && current.st_dev == identity.st_dev
        && current.st_ino == identity.st_ino
    }

    func removeLeafIfOwned(_ candidate: String, identity: stat) {
      if leafStillMatches(candidate, identity) {
        _ = Darwin.unlinkat(parentDescriptor, candidate, 0)
      }
    }

    let stagingLeaf = ".easysplat-pair-list-\(UUID().uuidString).tmp"
    let descriptor = Darwin.openat(
      parentDescriptor,
      stagingLeaf,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw MeasurementRunnerError.unsafePath("pair-list staging file could not be created")
    }
    var opened = stat()
    guard Darwin.fstat(descriptor, &opened) == 0,
      (opened.st_mode & S_IFMT) == S_IFREG,
      opened.st_nlink == 1
    else {
      Darwin.close(descriptor)
      throw MeasurementRunnerError.unsafePath("pair-list staging file is unsafe")
    }
    var published = false
    defer {
      Darwin.close(descriptor)
      if !published {
        removeLeafIfOwned(stagingLeaf, identity: opened)
      }
    }

    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { bytes in
        Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          data.count - offset)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw MeasurementRunnerError.unsafePath("pair-list staging file could not be written")
      }
      offset += count
    }
    var written = stat()
    guard fstat(descriptor, &written) == 0,
      written.st_dev == opened.st_dev,
      written.st_ino == opened.st_ino,
      (written.st_mode & S_IFMT) == S_IFREG,
      written.st_nlink == 1,
      written.st_size == off_t(data.count),
      Darwin.fsync(descriptor) == 0
    else {
      throw MeasurementRunnerError.unsafePath("pair-list staging file is not durable")
    }

    try hooks.beforeDestinationPublish()
    guard parentPathStillMatches(),
      leafStillMatches(stagingLeaf, written)
    else {
      throw MeasurementRunnerError.identityMismatch(
        "pair-list destination changed before publication")
    }
    var renameResult: Int32
    repeat {
      renameResult = Darwin.renameatx_np(
        parentDescriptor,
        stagingLeaf,
        parentDescriptor,
        leaf,
        UInt32(RENAME_EXCL))
    } while renameResult != 0 && errno == EINTR
    guard renameResult == 0 else {
      throw MeasurementRunnerError.unsafePath("pair-list destination already exists")
    }
    published = true

    do {
      try hooks.afterDestinationPublish()
      var publishedStatus = stat()
      guard parentPathStillMatches(),
        Darwin.fstatat(
        parentDescriptor,
        leaf,
        &publishedStatus,
        AT_SYMLINK_NOFOLLOW) == 0,
        publishedStatus.st_dev == written.st_dev,
        publishedStatus.st_ino == written.st_ino,
        publishedStatus.st_nlink == 1,
        publishedStatus.st_size == written.st_size,
        Darwin.fsync(parentDescriptor) == 0,
        parentPathStillMatches()
      else {
        throw MeasurementRunnerError.identityMismatch(
          "pair-list destination changed during publication")
      }
    } catch {
      var current = stat()
      if Darwin.fstatat(
        parentDescriptor,
        leaf,
        &current,
        AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == written.st_dev,
        current.st_ino == written.st_ino
      {
        _ = Darwin.unlinkat(parentDescriptor, leaf, 0)
        _ = Darwin.fsync(parentDescriptor)
      }
      throw error
    }
  }

  private static func build(
    _ evidence: SourceEvidence,
    selectedFrameCount: Int
  ) throws -> (document: [String: Any], result: MeasurementPairListBuildResult) {
    guard selectedFrameCount > 0,
      isSHA256(evidence.selectedFramesDigest),
      evidence.imageNames.count == selectedFrameCount,
      Set(evidence.imageNames).count == evidence.imageNames.count,
      evidence.imageNames.allSatisfy(validImageName),
      validatePlanBinding(evidence.planBinding, pairingPolicy: evidence.pairingPolicy),
      !evidence.attempts.isEmpty,
      evidence.acceptedAttemptNumber == evidence.attempts.count,
      evidence.retrievalWasScheduled
        == retrievalIsScheduled(
          pairingPolicy: evidence.pairingPolicy,
          selectedFrameCount: selectedFrameCount,
          requiresCrossClipRetrieval: evidence.planBinding.requiresCrossClipRetrieval),
      evidence.matchingDurationSeconds.isFinite,
      evidence.matchingDurationSeconds >= 0,
      Set(evidence.fallbackReasons).count == evidence.fallbackReasons.count,
      evidence.fallbackReasons.allSatisfy({ reason in
        !reason.isEmpty && reason == reason.trimmingCharacters(in: .whitespacesAndNewlines)
          && reason.utf8.count <= 512
      })
    else {
      throw invalidEvidence()
    }
    let imageIndex = Dictionary(
      uniqueKeysWithValues: evidence.imageNames.enumerated().map { ($0.element, $0.offset) }
    )
    var attemptDocuments: [[String: Any]] = []
    var acceptedSchedule: [SourcePair] = []
    var acceptedRetrieval: SourceRetrieval?
    var acceptedMatcher = ""
    var measuredDuration = 0.0
    for (offset, attempt) in evidence.attempts.enumerated() {
      let expectedNumber = offset + 1
      try validateAttempt(attempt, expectedNumber: expectedNumber, imageIndex: imageIndex)
      guard (attempt.retrieval != nil)
        == retrievalIsRequired(
          pairingPolicy: evidence.pairingPolicy,
          imageCount: selectedFrameCount,
          recoveryLevel: attempt.artifact.recoveryLevel,
          requiresCrossClipRetrieval: evidence.planBinding.requiresCrossClipRetrieval)
      else { throw invalidEvidence() }
      if let retrieval = attempt.retrieval {
        guard let limits = expectedRetrievalLimits(
          binding: evidence.planBinding,
          recoveryLevel: attempt.artifact.recoveryLevel)
        else { throw invalidEvidence() }
        guard retrieval.engine == evidence.planBinding.retrievalEngine,
          retrieval.queryStride == evidence.planBinding.retrievalQueryStride,
          retrieval.candidateCount == limits.candidates,
          retrieval.returnedNeighborCount == limits.neighbors,
          retrieval.minimumFrameSeparation
            == expectedMinimumFrameSeparation(
              pairingPolicy: evidence.pairingPolicy,
              selectedFrameCount: selectedFrameCount,
              requiresCrossClipRetrieval: evidence.planBinding.requiresCrossClipRetrieval)
        else { throw invalidEvidence() }
      }
      measuredDuration += attempt.artifact.durationSeconds
      let exportedRetrieval: [String: Any]?
      if let retrieval = attempt.retrieval {
        exportedRetrieval = try retrievalDocument(
          retrieval,
          executed: attempt.retrievalWasExecuted,
          scheduledPairs: attempt.scheduledPairs,
          imageIndex: imageIndex,
          requiresCrossClipRetrieval: evidence.planBinding.requiresCrossClipRetrieval
        )
      } else {
        exportedRetrieval = nil
      }
      attemptDocuments.append([
        "attempt_number": attempt.artifact.attemptNumber,
        "matcher_used": attempt.artifact.matcher,
        "exact_recovery_reason": attempt.artifact.exactRecoveryReason ?? NSNull(),
        "recovery_level": attempt.artifact.recoveryLevel,
        "outcome": attempt.artifact.outcome,
        "scheduled_pair_count": attempt.artifact.scheduledPairCount,
        "attempted_pair_count": attempt.artifact.attemptedPairCount,
        "raw_matched_pair_count": attempt.artifact.rawMatchedPairCount,
        "spatially_verified_pair_count": attempt.artifact.spatiallyVerifiedPairCount,
        "retrieval": exportedRetrieval ?? NSNull(),
      ])
      if expectedNumber == evidence.acceptedAttemptNumber {
        guard attempt.artifact.outcome == "completed" else { throw invalidEvidence() }
        acceptedSchedule = attempt.scheduledPairs
        acceptedRetrieval = attempt.retrieval
        acceptedMatcher = attempt.artifact.matcher
      }
    }
    try validateRecoveryHistory(
      evidence.attempts,
      selectedFrameCount: selectedFrameCount,
      pairingPolicy: evidence.pairingPolicy,
      fallbackReasons: evidence.fallbackReasons
    )
    let durationScale = max(1, abs(measuredDuration), abs(evidence.matchingDurationSeconds))
    guard measuredDuration.isFinite,
      abs(measuredDuration - evidence.matchingDurationSeconds) <= durationScale * 1e-12,
      evidence.usedLocalVocabularyRetrieval == (acceptedRetrieval != nil),
      !evidence.usedLocalVocabularyRetrieval || evidence.retrievalWasScheduled
    else { throw invalidEvidence() }
    let pairListDigest = scheduleDigest(acceptedSchedule)
    guard pairListDigest == evidence.pairListDigest,
      scheduleIsConnected(
        acceptedSchedule,
        imageCount: selectedFrameCount,
        imageIndex: imageIndex
      )
    else { throw invalidEvidence() }
    try validateInspection(
      evidence.acceptedInspection,
      schedule: acceptedSchedule,
      imageCount: selectedFrameCount,
      artifact: evidence.attempts[evidence.acceptedAttemptNumber - 1].artifact,
      pairingPolicy: evidence.pairingPolicy)

    let attempted = Set(evidence.acceptedInspection.attemptedPairs)
    let rawMatched = Set(evidence.acceptedInspection.rawMatchedPairs)
    let verified = Set(evidence.acceptedInspection.spatiallyVerifiedPairs)
    let directedQueries = try directedQueryMap(acceptedRetrieval, imageIndex: imageIndex)
    let acceptedAttempt = evidence.attempts[evidence.acceptedAttemptNumber - 1]
    let exhaustive = acceptedRetrieval == nil
      && ((evidence.pairingPolicy == "unorderedRetrieval" && selectedFrameCount <= 60)
        || (acceptedAttempt.artifact.recoveryLevel == "maximum" && selectedFrameCount <= 250))
    let pairDocuments: [[String: Any]] = try acceptedSchedule.map { pair in
      guard let first = imageIndex[pair.firstImageName],
        let second = imageIndex[pair.secondImageName], first < second
      else { throw invalidEvidence() }
      let pairType: String
      switch pair.role {
      case "local": pairType = "local"
      case "loopRevisit": pairType = "loop"
      case "retrieval": pairType = exhaustive ? "exhaustive" : "retrieval"
      default: throw invalidEvidence()
      }
      let edge = Edge(first, second)
      let query: Any
      if pairType == "retrieval" || pairType == "loop" {
        guard let queryIndex = directedQueries[edge] else { throw invalidEvidence() }
        query = queryIndex
      } else {
        query = NSNull()
      }
      var document: [String: Any] = [
        "view_a": first,
        "view_b": second,
        "pair_type": pairType,
        "query_view": query,
        "attempted": attempted.contains(pair),
        "raw_matched": rawMatched.contains(pair),
        "spatially_verified": verified.contains(pair),
      ]
      if pairType == "exhaustive" {
        document["matcher_used"] = acceptedMatcher
      }
      return document
    }
    let expectedDirectedEdges = Set(
      acceptedSchedule.compactMap { pair -> Edge? in
        guard pair.role != "local", !exhaustive,
          let first = imageIndex[pair.firstImageName], let second = imageIndex[pair.secondImageName]
        else { return nil }
        return Edge(first, second)
      }
    )
    guard Set(directedQueries.keys) == expectedDirectedEdges else { throw invalidEvidence() }
    let result = MeasurementPairListBuildResult(
      pairListDigest: pairListDigest,
      attempts: evidence.attempts.map { attempt in
        MeasurementPairListAttemptSummary(
          attemptNumber: attempt.artifact.attemptNumber,
          matcher: attempt.artifact.matcher,
          exactRecoveryReason: attempt.artifact.exactRecoveryReason,
          recoveryLevel: attempt.artifact.recoveryLevel,
          outcome: attempt.artifact.outcome,
          scheduledPairCount: attempt.artifact.scheduledPairCount,
          attemptedPairCount: attempt.artifact.attemptedPairCount,
          rawMatchedPairCount: attempt.artifact.rawMatchedPairCount,
          spatiallyVerifiedPairCount: attempt.artifact.spatiallyVerifiedPairCount
        )
      },
      scheduledPairCount: evidence.acceptedInspection.scheduledPairCount,
      attemptedPairCount: evidence.acceptedInspection.attemptedPairCount,
      rawMatchedPairCount: evidence.acceptedInspection.rawMatchedPairCount,
      spatiallyVerifiedPairCount: evidence.acceptedInspection.spatiallyVerifiedPairCount,
      localPairCount: acceptedSchedule.count { $0.role == "local" },
      retrievalPairCount: acceptedSchedule.count { $0.role == "retrieval" },
      loopPairCount: acceptedSchedule.count { $0.role == "loopRevisit" }
    )
    return ([
      "schema_version": outputSchemaVersion,
      "selected_frame_count": selectedFrameCount,
      "accepted_attempt_number": evidence.acceptedAttemptNumber,
      "pairs": pairDocuments,
      "attempts": attemptDocuments,
      "fallback_reasons": evidence.fallbackReasons,
    ], result)
  }

  private static func validateAttempt(
    _ attempt: SourceAttempt,
    expectedNumber: Int,
    imageIndex: [String: Int]
  ) throws {
    let artifact = attempt.artifact
    guard artifact.attemptNumber == expectedNumber,
      ["faiss", "exact"].contains(artifact.matcher),
      (artifact.matcher == "exact") == (artifact.exactRecoveryReason != nil),
      artifact.exactRecoveryReason.map({
        [
          "faissCrash",
          "faissUnsupportedOperation",
          "faissGeometryRejectedAfterRetries",
        ].contains($0)
      }) ?? true,
      ["normal", "expanded", "maximum"].contains(artifact.recoveryLevel),
      ["completed", "rejected", "failed"].contains(artifact.outcome),
      artifact.scheduledPairCount == attempt.scheduledPairs.count,
      artifact.scheduledPairCount >= artifact.attemptedPairCount,
      artifact.attemptedPairCount >= artifact.rawMatchedPairCount,
      artifact.rawMatchedPairCount >= artifact.spatiallyVerifiedPairCount,
      artifact.spatiallyVerifiedPairCount >= 0,
      artifact.durationSeconds.isFinite, artifact.durationSeconds >= 0,
      !attempt.retrievalWasExecuted || attempt.retrieval != nil,
      artifact.outcome == "failed"
        || (artifact.attemptedPairCount == artifact.scheduledPairCount
          && scheduleIsConnected(
            attempt.scheduledPairs,
            imageCount: imageIndex.count,
            imageIndex: imageIndex))
    else { throw invalidEvidence() }
    var previous: Edge?
    var seen: Set<Edge> = []
    for pair in attempt.scheduledPairs {
      guard ["local", "retrieval", "loopRevisit"].contains(pair.role),
        let first = imageIndex[pair.firstImageName],
        let second = imageIndex[pair.secondImageName], first < second
      else { throw invalidEvidence() }
      let edge = Edge(first, second)
      guard seen.insert(edge).inserted,
        previous.map({ $0.first < edge.first || ($0.first == edge.first && $0.second < edge.second) })
          ?? true
      else { throw invalidEvidence() }
      previous = edge
    }
  }

  private static func validateRecoveryHistory(
    _ attempts: [SourceAttempt],
    selectedFrameCount: Int,
    pairingPolicy: String,
    fallbackReasons: [String]
  ) throws {
    guard attempts.first?.artifact.matcher == "faiss",
      attempts.first?.artifact.exactRecoveryReason == nil,
      let firstLevelName = attempts.first?.artifact.recoveryLevel,
      let firstLevel = ["normal": 0, "expanded": 1, "maximum": 2][firstLevelName],
      firstLevel <= min(2, fallbackReasons.count)
    else { throw invalidEvidence() }
    let levels = ["normal": 0, "expanded": 1, "maximum": 2]
    for index in attempts.indices.dropFirst() {
      let previous = attempts[index - 1]
      let current = attempts[index]
      guard let previousLevel = levels[previous.artifact.recoveryLevel],
        let currentLevel = levels[current.artifact.recoveryLevel],
        currentLevel >= previousLevel,
        currentLevel - previousLevel <= min(2, max(1, fallbackReasons.count))
      else { throw invalidEvidence() }

      if current.artifact.matcher == "exact" {
        guard permitsExactRecovery(
          scheduledPairCount: current.artifact.scheduledPairCount),
          previous.artifact.matcher == "faiss",
          currentLevel == previousLevel,
          current.scheduledPairs == previous.scheduledPairs,
          current.retrieval == previous.retrieval,
          let reason = current.artifact.exactRecoveryReason
        else { throw invalidEvidence() }
        switch reason {
        case "faissCrash", "faissUnsupportedOperation":
          guard previous.artifact.outcome == "failed" else { throw invalidEvidence() }
        case "faissGeometryRejectedAfterRetries":
          let multiplication = selectedFrameCount.multipliedReportingOverflow(
            by: selectedFrameCount - 1)
          let isSmallUnorderedExhaustive = pairingPolicy == "unorderedRetrieval"
            && (2...60).contains(selectedFrameCount)
            && !multiplication.overflow
            && previous.artifact.recoveryLevel == "normal"
            && previous.artifact.scheduledPairCount == multiplication.partialValue / 2
          guard previous.artifact.outcome == "rejected",
            previous.artifact.recoveryLevel == "maximum" || isSmallUnorderedExhaustive
          else { throw invalidEvidence() }
        default:
          throw invalidEvidence()
        }
        continue
      }

      guard current.artifact.exactRecoveryReason == nil,
        previous.artifact.matcher == "faiss"
      else { throw invalidEvidence() }
      if currentLevel == previousLevel {
        guard current.artifact.matcher == "faiss",
          previous.artifact.outcome != "completed",
          current.scheduledPairs == previous.scheduledPairs
        else { throw invalidEvidence() }
      } else {
        let repeatedPlanningFailure = current.scheduledPairs == previous.scheduledPairs
          && current.artifact.outcome == "failed"
          && current.artifact.attemptedPairCount == 0
          && current.artifact.rawMatchedPairCount == 0
          && current.artifact.spatiallyVerifiedPairCount == 0
        guard current.artifact.matcher == "faiss",
          current.scheduledPairs != previous.scheduledPairs || repeatedPlanningFailure
        else { throw invalidEvidence() }
      }
    }
  }

  private static func validateInspection(
    _ inspection: SourceInspection,
    schedule: [SourcePair],
    imageCount: Int,
    artifact: SourceAttemptArtifact,
    pairingPolicy: String
  ) throws {
    let scheduled = Set(schedule)
    func canonicalSubset(_ pairs: [SourcePair]) -> Bool {
      let pairSet = Set(pairs)
      return pairSet.count == pairs.count && pairSet.isSubset(of: scheduled)
        && pairs == schedule.filter(pairSet.contains)
    }
    let attempted = Set(inspection.attemptedPairs)
    let raw = Set(inspection.rawMatchedPairs)
    let verified = Set(inspection.spatiallyVerifiedPairs)
    let localCount = schedule.count { $0.role == "local" }
    let retrievalCount = schedule.count { $0.role == "retrieval" }
    let loopCount = schedule.count { $0.role == "loopRevisit" }
    var componentTotal = 0
    var priorComponentCount = imageCount
    var measuredIsolatedCount = 0
    for count in inspection.componentViewCounts {
      let addition = componentTotal.addingReportingOverflow(count)
      guard count > 0, count <= priorComponentCount, count <= imageCount,
        !addition.overflow, addition.partialValue <= imageCount
      else { throw invalidEvidence() }
      componentTotal = addition.partialValue
      priorComponentCount = count
      if count == 1 { measuredIsolatedCount += 1 }
    }
    guard let dominantViewCount = inspection.componentViewCounts.first else {
      throw invalidEvidence()
    }
    let hasMinorVerifiedComponent = inspection.componentViewCounts.dropFirst().contains { $0 > 1 }
    let requiredDominantFraction = hasMinorVerifiedComponent ? 0.95 : 0.90
    let hasSingleBiconnectedBlock = inspection.biconnectedBlockCount == 1
    guard inspection.scheduledPairCount == schedule.count,
      inspection.scheduledPairCount == artifact.scheduledPairCount,
      artifact.outcome == "completed",
      inspection.attemptedPairCount == artifact.attemptedPairCount,
      inspection.rawMatchedPairCount == artifact.rawMatchedPairCount,
      inspection.spatiallyVerifiedPairCount == artifact.spatiallyVerifiedPairCount,
      inspection.attemptedPairCount == inspection.attemptedPairs.count,
      inspection.rawMatchedPairCount == inspection.rawMatchedPairs.count,
      inspection.spatiallyVerifiedPairCount == inspection.spatiallyVerifiedPairs.count,
      canonicalSubset(inspection.attemptedPairs),
      canonicalSubset(inspection.rawMatchedPairs),
      canonicalSubset(inspection.spatiallyVerifiedPairs),
      raw.isSubset(of: attempted), verified.isSubset(of: raw),
      inspection.localPairCount == localCount,
      inspection.retrievalPairCount == retrievalCount,
      inspection.loopRevisitPairCount == loopCount,
      localCount + retrievalCount + loopCount == schedule.count,
      inspection.connectedComponentCount == inspection.componentViewCounts.count,
      componentTotal == imageCount,
      measuredIsolatedCount == inspection.isolatedViewCount,
      !hasMinorVerifiedComponent
        || permitsSecondaryVerifiedComponent(
          pairingPolicy: pairingPolicy,
          recoveryLevel: artifact.recoveryLevel),
      inspection.descriptorlessViewCount >= 0,
      inspection.descriptorlessViewCount <= inspection.isolatedViewCount,
      dominantViewCount >= 2,
      inspection.componentViewCounts.dropFirst().first.map({ dominantViewCount > $0 }) ?? true,
      Double(dominantViewCount) / Double(imageCount) >= requiredDominantFraction,
      inspection.articulationViewCount >= 0,
      inspection.articulationViewCount <= dominantViewCount - 2,
      inspection.biconnectedBlockCount >= 1,
      inspection.biconnectedBlockCount
        <= min(inspection.spatiallyVerifiedPairCount, dominantViewCount - 1),
      inspection.articulationViewCount < inspection.biconnectedBlockCount,
      inspection.largestBiconnectedBlockViewCount >= 2,
      inspection.largestBiconnectedBlockViewCount <= dominantViewCount,
      inspection.secondLargestBiconnectedBlockViewCount >= 0,
      inspection.secondLargestBiconnectedBlockViewCount
        <= inspection.largestBiconnectedBlockViewCount,
      hasSingleBiconnectedBlock
        ? inspection.articulationViewCount == 0
          && inspection.largestBiconnectedBlockViewCount == dominantViewCount
          && inspection.secondLargestBiconnectedBlockViewCount == 0
        : inspection.articulationViewCount > 0
          && inspection.largestBiconnectedBlockViewCount < dominantViewCount
          && inspection.secondLargestBiconnectedBlockViewCount >= 2,
      inspection.degreeP10 >= 0,
      inspection.degreeP10 <= inspection.degreeMedian,
      inspection.degreeMedian <= inspection.degreeP90,
      inspection.degreeP90 < imageCount,
      inspection.spatiallyVerifiedPairCount >= dominantViewCount - 1,
      inspection.degreeP90
        <= min(dominantViewCount - 1, inspection.spatiallyVerifiedPairCount),
      isSHA256(inspection.featureDatabaseDigest),
      isSHA256(inspection.matchingDatabaseDigest)
    else { throw invalidEvidence() }
  }

  static func permitsSecondaryVerifiedComponent(
    pairingPolicy: String,
    recoveryLevel: String
  ) -> Bool {
    let orderedPolicies = [
      "orderedContinuous", "orderedOrbit", "orderedWalkthrough", "orderedLargeArea",
    ]
    return orderedPolicies.contains(pairingPolicy) && recoveryLevel != "normal"
  }

  private static func retrievalDocument(
    _ retrieval: SourceRetrieval,
    executed: Bool,
    scheduledPairs: [SourcePair],
    imageIndex: [String: Int],
    requiresCrossClipRetrieval: Bool
  ) throws -> [String: Any] {
    guard retrieval.engine == "localSiftVocabularyV2",
      retrieval.queryStride > 0, retrieval.candidateCount > 0,
      retrieval.returnedNeighborCount > 0,
      retrieval.returnedNeighborCount <= retrieval.candidateCount,
      retrieval.minimumFrameSeparation >= 0,
      !retrieval.queryImageNames.isEmpty,
      Set(retrieval.queryImageNames).count == retrieval.queryImageNames.count,
      retrieval.queryOutcomes.count == retrieval.queryImageNames.count,
      retrieval.queryOutcomes.map(\.queryImageName) == retrieval.queryImageNames
    else { throw invalidEvidence() }
    let groupIndexByImageName = try validatedImageGroupIndices(
      retrieval,
      imageIndex: imageIndex,
      requiresCrossClipRetrieval: requiresCrossClipRetrieval)
    let queryViews = try retrieval.queryImageNames.map { name -> Int in
      guard let index = imageIndex[name] else { throw invalidEvidence() }
      return index
    }
    var directedDocuments: [[String: Any]] = []
    var directedLines: [String] = []
    var seen: Set<DirectedEdge> = []
    var queryOutcomeDocuments: [[String: Any]] = []
    var expectedDirectedLines: [String] = []
    var expectedEdges: Set<Edge> = []
    let baseEdges = Set(try scheduledPairs.compactMap { pair -> Edge? in
      guard pair.role == "local" else { return nil }
      guard let first = imageIndex[pair.firstImageName],
        let second = imageIndex[pair.secondImageName]
      else { throw invalidEvidence() }
      return Edge(first, second)
    })
    for outcome in retrieval.queryOutcomes {
      let neighbors = outcome.rankedNeighborImageNames
      let statusMatchesNeighbors = (outcome.status == "ranked" && !neighbors.isEmpty)
        || (outcome.status == "noRankedNeighbors" && neighbors.isEmpty)
      guard statusMatchesNeighbors,
        imageIndex[outcome.queryImageName] != nil,
        Set(outcome.rankedNeighborImageNames).count
          == outcome.rankedNeighborImageNames.count,
        outcome.rankedNeighborImageNames
          == outcome.rankedNeighborImageNames.sorted(by: canonicalUTF8Less),
        outcome.rankedNeighborImageNames.allSatisfy({ neighbor in
          imageIndex[neighbor] != nil && neighbor != outcome.queryImageName
        })
      else { throw invalidEvidence() }
      guard let queryView = imageIndex[outcome.queryImageName] else {
        throw invalidEvidence()
      }
      let neighborViews = try neighbors.map { neighbor -> Int in
        guard let view = imageIndex[neighbor] else { throw invalidEvidence() }
        return view
      }
      queryOutcomeDocuments.append([
        "query_view": queryView,
        "status": outcome.status,
        "ranked_neighbor_views": neighborViews,
      ])
      var retainedNeighborCount = 0
      for (neighbor, targetView) in zip(neighbors, neighborViews) {
        let edge = Edge(queryView, targetView)
        guard !baseEdges.contains(edge),
          groupIndexByImageName.map({ groups in
            groups[outcome.queryImageName] != groups[neighbor]
          }) != false
        else { throw invalidEvidence() }
        guard abs(queryView - targetView) >= retrieval.minimumFrameSeparation else {
          throw invalidEvidence()
        }
        retainedNeighborCount += 1
        guard retainedNeighborCount <= retrieval.returnedNeighborCount else {
          throw invalidEvidence()
        }
        if expectedEdges.insert(edge).inserted {
          expectedDirectedLines.append("\(outcome.queryImageName) \(neighbor)")
        }
      }
    }
    expectedDirectedLines.sort(by: canonicalUTF8Less)
    guard Set(retrieval.directedPairLines).count == retrieval.directedPairLines.count,
      retrieval.directedPairLines == retrieval.directedPairLines.sorted(by: canonicalUTF8Less),
      retrieval.directedPairLines == expectedDirectedLines
    else { throw invalidEvidence() }
    for line in retrieval.directedPairLines {
      let fields = line.split(whereSeparator: \Character.isWhitespace)
      guard fields.count == 2,
        let query = imageIndex[String(fields[0])],
        let target = imageIndex[String(fields[1])], query != target,
        queryViews.contains(query), seen.insert(DirectedEdge(query, target)).inserted
      else { throw invalidEvidence() }
      directedLines.append("\(fields[0]) \(fields[1])")
      directedDocuments.append(["query_view": query, "target_view": target])
    }
    let scheduledRetrievalEdges = Set(try scheduledPairs.compactMap { pair -> Edge? in
      guard pair.role != "local" else { return nil }
      guard let first = imageIndex[pair.firstImageName],
        let second = imageIndex[pair.secondImageName]
      else { throw invalidEvidence() }
      return Edge(first, second)
    })
    guard scheduledRetrievalEdges == expectedEdges else { throw invalidEvidence() }
    var requestFields = [
      retrieval.engine,
      String(retrieval.queryStride),
      String(retrieval.candidateCount),
      String(retrieval.returnedNeighborCount),
      String(retrieval.minimumFrameSeparation),
    ]
    if let candidatePolicy = retrieval.candidatePolicy,
      let imageGroupListDigest = retrieval.imageGroupListDigest
    {
      requestFields.append(candidatePolicy)
      requestFields.append(imageGroupListDigest)
    }
    let requestDigest = receiptDigest(requestFields + retrieval.queryImageNames)
    var headerFields = [
      groupIndexByImageName == nil
        ? "EASYSPLAT_RETRIEVAL_OUTCOMES_V2"
        : "EASYSPLAT_RETRIEVAL_OUTCOMES_V3",
      retrieval.engine,
      String(retrieval.queryStride),
      String(retrieval.candidateCount),
      String(retrieval.returnedNeighborCount),
      String(retrieval.minimumFrameSeparation),
    ]
    if let candidatePolicy = retrieval.candidatePolicy,
      let imageGroupListDigest = retrieval.imageGroupListDigest
    {
      headerFields.append(candidatePolicy)
      headerFields.append(imageGroupListDigest)
    }
    headerFields.append(String(retrieval.queryImageNames.count))
    headerFields.append(requestDigest)
    let contractLines = [
      headerFields.joined(separator: " "),
    ] + retrieval.queryOutcomes.map { outcome in
      ([
        "Q",
        outcome.status,
        outcome.queryImageName,
        String(outcome.rankedNeighborImageNames.count),
      ] + outcome.rankedNeighborImageNames).joined(separator: " ")
    } + directedLines.map { "P \($0)" }
    guard isSHA256(retrieval.outputDigest),
      retrieval.outputDigest == receiptDigest(contractLines)
    else { throw invalidEvidence() }
    return [
      "engine": retrieval.engine,
      "query_views": queryViews,
      "query_stride": retrieval.queryStride,
      "candidate_count": retrieval.candidateCount,
      "returned_neighbor_count": retrieval.returnedNeighborCount,
      "minimum_frame_separation": retrieval.minimumFrameSeparation,
      "candidate_policy": retrieval.candidatePolicy as Any? ?? NSNull(),
      "image_group_list_digest": (
        retrieval.imageGroupListDigest.map { "sha256:" + $0 } as Any?
      ) ?? NSNull(),
      "executed": executed,
      "query_outcomes": queryOutcomeDocuments,
      "directed_pairs": directedDocuments,
      "request_digest": "sha256:" + requestDigest,
      "output_digest": "sha256:" + retrieval.outputDigest,
    ]
  }

  private static func validatedImageGroupIndices(
    _ retrieval: SourceRetrieval,
    imageIndex: [String: Int],
    requiresCrossClipRetrieval: Bool
  ) throws -> [String: Int]? {
    switch (
      retrieval.candidatePolicy,
      retrieval.imageGroupListDigest,
      retrieval.imageGroupLines
    ) {
    case (nil, nil, nil):
      guard !requiresCrossClipRetrieval else { throw invalidEvidence() }
      return nil
    case let ("crossGroupV1"?, digest?, lines?):
      guard requiresCrossClipRetrieval,
        isSHA256(digest),
        lines.count == imageIndex.count,
        lines == lines.sorted(by: canonicalUTF8Less)
      else { throw invalidEvidence() }
      var groups: [String: Int] = [:]
      for line in lines {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2 else { throw invalidEvidence() }
        let imageName = String(fields[0])
        let rawGroupIndex = String(fields[1])
        guard imageIndex[imageName] != nil,
          let groupIndex = Int(rawGroupIndex),
          groupIndex >= 0,
          String(groupIndex) == rawGroupIndex,
          groups.updateValue(groupIndex, forKey: imageName) == nil
        else { throw invalidEvidence() }
      }
      let groupIndices = Set(groups.values)
      guard Set(groups.keys) == Set(imageIndex.keys),
        groupIndices.count >= 2,
        groupIndices == Set(0..<groupIndices.count),
        digest == receiptDigest(["crossGroupV1"] + lines)
      else { throw invalidEvidence() }
      return groups
    default:
      throw invalidEvidence()
    }
  }

  private static func directedQueryMap(
    _ retrieval: SourceRetrieval?,
    imageIndex: [String: Int]
  ) throws -> [Edge: Int] {
    guard let retrieval else { return [:] }
    var result: [Edge: Int] = [:]
    for line in retrieval.directedPairLines {
      let fields = line.split(whereSeparator: \Character.isWhitespace)
      guard fields.count == 2,
        let query = imageIndex[String(fields[0])],
        let target = imageIndex[String(fields[1])], query != target,
        result.updateValue(query, forKey: Edge(query, target)) == nil
      else { throw invalidEvidence() }
    }
    return result
  }

  private static func scheduleDigest(_ pairs: [SourcePair]) -> String {
    guard !pairs.isEmpty else { return sha256(Data()) }
    let lines = pairs.map { "\($0.firstImageName) \($0.secondImageName)" }.joined(separator: "\n")
    return sha256(Data((lines + "\n").utf8))
  }

  private static func scheduleIsConnected(
    _ pairs: [SourcePair],
    imageCount: Int,
    imageIndex: [String: Int]
  ) -> Bool {
    guard imageCount > 0 else { return false }
    var adjacency = Array(repeating: [Int](), count: imageCount)
    for pair in pairs {
      guard let first = imageIndex[pair.firstImageName],
        let second = imageIndex[pair.secondImageName]
      else { return false }
      adjacency[first].append(second)
      adjacency[second].append(first)
    }
    var visited: Set<Int> = [0]
    var frontier = [0]
    while let current = frontier.popLast() {
      for neighbor in adjacency[current] where visited.insert(neighbor).inserted {
        frontier.append(neighbor)
      }
    }
    return visited.count == imageCount
  }

  private static func receiptDigest(_ fields: [String]) -> String {
    var data = Data()
    for field in fields {
      let bytes = Data(field.utf8)
      data.append(Data("\(bytes.count):".utf8))
      data.append(bytes)
    }
    return sha256(data)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func validatePlanBinding(
    _ binding: SourcePlanBinding,
    pairingPolicy: String
  ) -> Bool {
    let pairingPolicies = [
      "unorderedRetrieval", "segmentedMixed", "orderedContinuous",
      "orderedOrbit", "orderedWalkthrough", "orderedLargeArea",
    ]
    let temporalPairings = ["none", "linear", "multiscale"]
    let crossClipPolicies = [
      "orderedContinuous", "orderedOrbit", "orderedWalkthrough", "orderedLargeArea",
      "segmentedMixed",
    ]
    let cameraInitializationRecipes = [
      "colmapAutomatic", "sharedOpenCVFisheyeEquidistantDiagonal150V1",
    ]
    return pairingPolicies.contains(pairingPolicy)
      && binding.pairingPolicy == pairingPolicy
      && binding.geometryBackend == "colmap"
      && binding.modelIdentifier == "none"
      && temporalPairings.contains(binding.temporalPairing)
      && binding.retrievalEngine == "localSiftVocabularyV2"
      && binding.retrievalCandidateCount > 0
      && binding.retrievalNeighborCount > 0
      && binding.retrievalNeighborCount <= binding.retrievalCandidateCount
      && binding.retrievalQueryStride > 0
      && binding.normalDescriptorMatcher == "faiss"
      && cameraInitializationRecipes.contains(binding.cameraInitializationRecipe)
      && binding.runSeed <= UInt64(Int32.max)
      && binding.temporalOffsets.allSatisfy { $0 > 0 }
      && binding.temporalOffsets == binding.temporalOffsets.sorted()
      && Set(binding.temporalOffsets).count == binding.temporalOffsets.count
      && ((binding.temporalPairing == "none") == binding.temporalOffsets.isEmpty)
      && (!binding.requiresCrossClipRetrieval
        || (crossClipPolicies.contains(binding.pairingPolicy)
          && binding.temporalPairing != "none"))
  }

  private static func retrievalIsScheduled(
    pairingPolicy: String,
    selectedFrameCount: Int,
    requiresCrossClipRetrieval: Bool
  ) -> Bool {
    if requiresCrossClipRetrieval { return true }
    return switch pairingPolicy {
    case "orderedContinuous": selectedFrameCount >= 120
    case "unorderedRetrieval": selectedFrameCount > 60
    case "orderedOrbit", "orderedWalkthrough", "orderedLargeArea", "segmentedMixed": true
    default: false
    }
  }

  private static func retrievalIsRequired(
    pairingPolicy: String,
    imageCount: Int,
    recoveryLevel: String,
    requiresCrossClipRetrieval: Bool
  ) -> Bool {
    if recoveryLevel == "maximum", imageCount <= 250 { return false }
    if pairingPolicy == "unorderedRetrieval", imageCount <= 60 { return false }
    return retrievalIsScheduled(
      pairingPolicy: pairingPolicy,
      selectedFrameCount: imageCount,
      requiresCrossClipRetrieval: requiresCrossClipRetrieval)
  }

  private static func expectedRetrievalLimits(
    binding: SourcePlanBinding,
    recoveryLevel: String
  ) -> (candidates: Int, neighbors: Int)? {
    switch recoveryLevel {
    case "normal":
      return (binding.retrievalCandidateCount, binding.retrievalNeighborCount)
    case "expanded":
      if ["unorderedRetrieval", "segmentedMixed"].contains(binding.pairingPolicy) {
        return (40, 16)
      }
      return (binding.retrievalCandidateCount, binding.retrievalNeighborCount)
    case "maximum":
      return (80, 32)
    default:
      return nil
    }
  }

  private static func expectedMinimumFrameSeparation(
    pairingPolicy: String,
    selectedFrameCount: Int,
    requiresCrossClipRetrieval: Bool
  ) -> Int {
    if requiresCrossClipRetrieval { return 0 }
    switch pairingPolicy {
    case "orderedContinuous", "orderedOrbit", "orderedWalkthrough", "orderedLargeArea":
      return max(12, selectedFrameCount / 10)
    default:
      return 0
    }
  }

  private static func validImageName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".."
      && !name.contains("/") && !name.contains("\\")
      && !name.contains(where: \Character.isWhitespace)
      && !name.utf8.contains(0)
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (97...102).contains(byte)
    }
  }

  private static func canonicalUTF8Less(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }

  private static func invalidEvidence() -> MeasurementRunnerError {
    .subprocessFailed("pair-graph evidence is incomplete or inconsistent")
  }
}

private struct SourceEvidence: Decodable {
  let schemaVersion: Int
  let selectedFramesDigest: String
  let imageNames: [String]
  let pairingPolicy: String
  let planBinding: SourcePlanBinding
  let attempts: [SourceAttempt]
  let acceptedAttemptNumber: Int
  let acceptedInspection: SourceInspection
  let retrievalWasScheduled: Bool
  let usedLocalVocabularyRetrieval: Bool
  let pairListDigest: String
  let matchingDurationSeconds: Double
  let fallbackReasons: [String]
}

private struct SourcePlanBinding: Decodable {
  let pairingPolicy: String
  let geometryBackend: String
  let modelIdentifier: String
  let temporalPairing: String
  let temporalOffsets: [Int]
  let retrievalEngine: String
  let retrievalCandidateCount: Int
  let retrievalNeighborCount: Int
  let retrievalQueryStride: Int
  let requiresCrossClipRetrieval: Bool
  let normalDescriptorMatcher: String
  let cameraInitializationRecipe: String
  let runSeed: UInt64
}

private struct SourceAttempt: Decodable {
  let artifact: SourceAttemptArtifact
  let scheduledPairs: [SourcePair]
  let retrieval: SourceRetrieval?
  let retrievalWasExecuted: Bool
}

private struct SourceAttemptArtifact: Decodable {
  let attemptNumber: Int
  let matcher: String
  let exactRecoveryReason: String?
  let recoveryLevel: String
  let outcome: String
  let scheduledPairCount: Int
  let attemptedPairCount: Int
  let rawMatchedPairCount: Int
  let spatiallyVerifiedPairCount: Int
  let durationSeconds: Double
}

private struct SourceRetrieval: Decodable, Equatable {
  let engine: String
  let queryImageNames: [String]
  let queryStride: Int
  let candidateCount: Int
  let returnedNeighborCount: Int
  let minimumFrameSeparation: Int
  let candidatePolicy: String?
  let imageGroupListDigest: String?
  let imageGroupLines: [String]?
  let queryOutcomes: [SourceRetrievalQueryOutcome]
  let directedPairLines: [String]
  let outputDigest: String
}

private struct SourceRetrievalQueryOutcome: Decodable, Equatable {
  let queryImageName: String
  let status: String
  let rankedNeighborImageNames: [String]
}

private struct SourceInspection: Decodable {
  let scheduledPairCount: Int
  let attemptedPairCount: Int
  let rawMatchedPairCount: Int
  let spatiallyVerifiedPairCount: Int
  let localPairCount: Int
  let retrievalPairCount: Int
  let loopRevisitPairCount: Int
  let connectedComponentCount: Int
  let isolatedViewCount: Int
  let descriptorlessViewCount: Int
  let componentViewCounts: [Int]
  let articulationViewCount: Int
  let biconnectedBlockCount: Int
  let largestBiconnectedBlockViewCount: Int
  let secondLargestBiconnectedBlockViewCount: Int
  let degreeP10: Int
  let degreeMedian: Int
  let degreeP90: Int
  let featureDatabaseDigest: String
  let matchingDatabaseDigest: String
  let attemptedPairs: [SourcePair]
  let rawMatchedPairs: [SourcePair]
  let spatiallyVerifiedPairs: [SourcePair]
}

private struct SourcePair: Decodable, Hashable {
  let firstImageName: String
  let secondImageName: String
  let role: String
}

private struct Edge: Hashable {
  let first: Int
  let second: Int

  init(_ first: Int, _ second: Int) {
    self.first = min(first, second)
    self.second = max(first, second)
  }
}

private struct DirectedEdge: Hashable {
  let query: Int
  let target: Int

  init(_ query: Int, _ target: Int) {
    self.query = query
    self.target = target
  }
}

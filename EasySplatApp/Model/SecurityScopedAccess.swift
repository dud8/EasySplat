import Foundation

/// Keeps the sandbox's grant open for the files and folders the user picked.
///
/// A URL handed back by the file importer or by a drop carries a security scope,
/// and the sandbox refuses to read it — or anything below it — while that scope
/// is closed. The grant belongs to the URL the user chose, not to URLs derived
/// from it, so expanding a folder into its photos yields paths that stay readable
/// only for as long as the folder's own scope is held. Selection expands folders
/// straight away and the pipeline reads the files minutes later, which is why the
/// claim has to outlive the picker callback that produced it.
///
/// Outside the sandbox `startAccessingSecurityScopedResource()` reports false and
/// there is nothing to balance, so a claim costs nothing in the Developer ID lane.
final class SecurityScopedAccess {
    typealias Start = (URL) -> Bool
    typealias Stop = (URL) -> Void

    /// Opaque ownership for the successful starts made by one operation.
    struct ClaimBatch {
        fileprivate let claimIDs: Set<UInt64>
    }

    /// Opaque ownership for every claim held before an operation begins.
    struct ClaimSnapshot {
        fileprivate let claimIDs: Set<UInt64>
    }

    private struct HeldClaim {
        let id: UInt64
        let url: URL
    }

    private let start: Start
    private let stop: Stop
    private var held: [HeldClaim] = []
    private var nextClaimID: UInt64 = 0

    init(
        start: @escaping Start = { $0.startAccessingSecurityScopedResource() },
        stop: @escaping Stop = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.start = start
        self.stop = stop
    }

    deinit {
        for claim in held { stop(claim.url) }
    }

    /// The URLs whose scope this holder currently keeps open.
    var claimed: [URL] { held.map(\.url) }

    /// Captures claim ownership without exposing mutable holder state. A later
    /// replacement can release precisely this generation after its provisional
    /// claims have been promoted, even when both generations name the same URL.
    func snapshot() -> ClaimSnapshot {
        ClaimSnapshot(claimIDs: Set(held.map(\.id)))
    }

    /// Opens the scope of every file URL that carries one. The system counts
    /// repeated claims of the same URL, so each one taken here is balanced by
    /// exactly one release.
    @discardableResult
    func claim(_ urls: [URL]) -> ClaimBatch {
        takeClaims(urls, reusingCoverageFrom: nil, deduplicateInput: false)
    }

    /// Takes provisional claims for one selection operation. Append operations
    /// may reuse grants from their starting snapshot; replacements deliberately
    /// take a fresh claim so the complete previous generation can be released
    /// only after the new selection commits.
    func beginClaimBatch(
        _ urls: [URL],
        reusingCoverageFrom snapshot: ClaimSnapshot?
    ) -> ClaimBatch {
        takeClaims(urls, reusingCoverageFrom: snapshot, deduplicateInput: true)
    }

    /// Promotes only provisional claims whose selected roots were themselves
    /// accepted. Coverage is intentionally not used here: a rejected parent
    /// folder must not survive merely because it encloses an older selection.
    func releaseClaims(in batch: ClaimBatch, retainingExactRoots roots: [URL]) {
        let retainedPaths = Set(roots.map { $0.standardizedFileURL.path })
        guard !batch.claimIDs.isEmpty, !held.isEmpty else { return }
        var retainedClaims: [HeldClaim] = []
        for claim in held {
            if !batch.claimIDs.contains(claim.id)
                || retainedPaths.contains(claim.url.standardizedFileURL.path) {
                retainedClaims.append(claim)
            } else {
                stop(claim.url)
            }
        }
        held = retainedClaims
    }

    /// Releases only claims present in `snapshot` that do not back `selection`.
    func releaseClaims(in snapshot: ClaimSnapshot, notCovering selection: [URL]) {
        releaseClaims(snapshot.claimIDs, notCovering: selection)
    }

    private func takeClaims(
        _ urls: [URL],
        reusingCoverageFrom snapshot: ClaimSnapshot?,
        deduplicateInput: Bool
    ) -> ClaimBatch {
        var batchIDs = Set<UInt64>()
        var attemptedPaths = Set<String>()

        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            if deduplicateInput, !attemptedPaths.insert(path).inserted {
                continue
            }
            if let snapshot,
               held.contains(where: {
                   snapshot.claimIDs.contains($0.id) && Self.covers(root: $0.url, path: path)
               }) {
                continue
            }
            guard start(url) else { continue }
            let id = allocateClaimID()
            held.append(HeldClaim(id: id, url: url))
            batchIDs.insert(id)
        }
        return ClaimBatch(claimIDs: batchIDs)
    }

    private func allocateClaimID() -> UInt64 {
        precondition(nextClaimID < UInt64.max, "Security-scope claim identifier exhausted")
        defer { nextClaimID += 1 }
        return nextClaimID
    }

    /// Drops every claim that no longer backs anything in `selection`. A claim
    /// on a folder backs the files below it, which is what a selection holds
    /// after it expands a chosen folder into paths of its own.
    func releaseRootsNotCovering(_ selection: [URL]) {
        releaseClaims(Set(held.map(\.id)), notCovering: selection)
    }

    private func releaseClaims(_ claimIDs: Set<UInt64>, notCovering selection: [URL]) {
        guard !claimIDs.isEmpty, !held.isEmpty else { return }
        let selectedPaths = Set(selection.map { $0.standardizedFileURL.path })
        var retainedClaims: [HeldClaim] = []
        for claim in held {
            if !claimIDs.contains(claim.id)
                || selectedPaths.contains(where: { Self.covers(root: claim.url, path: $0) }) {
                retainedClaims.append(claim)
            } else {
                stop(claim.url)
            }
        }
        held = retainedClaims
    }

    private static func covers(root: URL, path: String) -> Bool {
        let rootPath = root.standardizedFileURL.path
        guard path != rootPath else { return true }
        let enclosing = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(enclosing)
    }

    func releaseAll() {
        for claim in held { stop(claim.url) }
        held.removeAll()
    }
}

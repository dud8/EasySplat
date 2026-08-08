import Darwin
import EasySplatCore
import Foundation
import UniformTypeIdentifiers

enum InputSelectionMode: Equatable {
    case append
    case replace
}

/// Terminal results of a single drag. URLs stay in provider order, while a
/// failed provider is retained as a count instead of being compacted away.
struct DropURLLoadBatch: Equatable, Sendable {
    let urls: [URL]
    let failedProviderCount: Int

    init(urls: [URL], failedProviderCount: Int) {
        self.urls = urls
        self.failedProviderCount = max(0, failedProviderCount)
    }
}

struct DropURLLoadResult: Sendable {
    let index: Int
    let url: URL?

    init(index: Int, url: URL?, providerFailed: Bool = false) {
        self.index = index
        self.url = providerFailed ? nil : url
    }
}

struct InputFolderResourceMetadata {
    let isRegularFile: Bool?
    let isDirectory: Bool?
    let isSymbolicLink: Bool?
    let isHidden: Bool?
    let isPackage: Bool?
    let name: String?

    init(
        isRegularFile: Bool?,
        isDirectory: Bool?,
        isSymbolicLink: Bool?,
        isHidden: Bool?,
        isPackage: Bool?,
        name: String?
    ) {
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.name = name
    }

    init(resourceValues: URLResourceValues) {
        self.init(
            isRegularFile: resourceValues.isRegularFile,
            isDirectory: resourceValues.isDirectory,
            isSymbolicLink: resourceValues.isSymbolicLink,
            isHidden: resourceValues.isHidden,
            isPackage: resourceValues.isPackage,
            name: resourceValues.name
        )
    }
}

enum InputFolderTraversalEvent {
    case entry(
        url: URL,
        level: Int,
        metadata: InputFolderResourceMetadata?,
        skipDescendants: () -> Void
    )
    case unreadable(relativePath: String?)
}

struct InputFolderTraversal {
    let rootMetadata: InputFolderResourceMetadata?
    let events: AnySequence<InputFolderTraversalEvent>
}

typealias InputFolderTraversalProvider = (URL) -> InputFolderTraversal

extension AppModel {
    private static let supportedVideoExtensions: Set<String> = [
        "3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "qt",
    ]

    private enum SelectedInputKind: Hashable {
        case regularFile
        case directory
        case unsupported
    }

    private struct SelectedInputIdentity: Hashable {
        enum Storage: Hashable {
            case fileSystem(device: UInt64, inode: UInt64)
            case resolvedPath(String)
        }

        let kind: SelectedInputKind
        let storage: Storage
    }

    private struct ClassifiedInput {
        let kind: SelectedInputKind
        let identity: SelectedInputIdentity?
    }

    private struct SelectionCandidate {
        var videos: [URL]
        var photos: [URL]
        var dataset: PendingDataset?
        var splatOpenRequests: [URL]
        var warnings: [String] = []
        var acceptedInput = false
        var acceptedClaimRoots: [URL] = []
    }

    func startWithVideo(url: URL) {
        selectInputs(urls: [url], mode: .replace)
    }

    func startWithPhotoFolder(url: URL) {
        selectInputs(urls: [url], mode: .replace)
    }

    /// Accepts any mix of photo files, video files, and folders. A folder is
    /// expanded into the compatible photos and videos it contains, so a single
    /// capture folder with both kinds of media brings all of it in. Photos and
    /// videos coming from different folders are merged into one selection.
    func addInputs(urls: [URL]) {
        selectInputs(urls: urls, mode: .append)
    }

    /// Applies an ordered drag result after every provider has replied. Provider
    /// failures are distinct from readable files that are simply unsupported,
    /// including files skipped while a folder is expanded.
    func addDroppedInputs(_ batch: DropURLLoadBatch) {
        let acceptedInput = selectInputs(urls: batch.urls, mode: .append)
        guard batch.failedProviderCount > 0 else { return }

        let providerFeedback = Self.dropProviderFailureMessage(
            count: batch.failedProviderCount,
            addedReadableInput: acceptedInput
        )
        if let selectionWarning {
            self.selectionWarning = "\(selectionWarning)\n\(providerFeedback)"
        } else {
            selectionWarning = providerFeedback
        }
    }

    /// Evaluates selected URLs while their security scopes are open, then commits
    /// the new capture only when this selection contains usable media or a
    /// dataset. Replacement therefore never erases a working capture because a
    /// picker returned nothing, was cancelled, or held unusable paths.
    @discardableResult
    func selectInputs(urls: [URL], mode: InputSelectionMode) -> Bool {
        selectInputs(
            urls: urls,
            mode: mode,
            folderTraversalProvider: Self.fileSystemFolderTraversal
        )
    }

    @discardableResult
    func selectInputs(
        urls: [URL],
        mode: InputSelectionMode,
        folderTraversalProvider: InputFolderTraversalProvider
    ) -> Bool {
        // Claim the sandbox grant before anything reads these paths. Replacements
        // always take a fresh generation, even for the same URL, so the old
        // generation can remain readable until the candidate commits. Appends can
        // reuse an existing enclosing grant and avoid stacking the same scope.
        let priorClaims = inputAccess.snapshot()
        let priorSplatOpenRequests = splatOpenRequests
        let provisionalClaims = inputAccess.beginClaimBatch(
            urls,
            reusingCoverageFrom: mode == .append ? priorClaims : nil
        )
        var committedCapture = false
        var newlyQueuedSplatOpenRequests: [URL] = []
        var acceptedProvisionalRoots: [URL] = []
        defer {
            if committedCapture {
                var selected = pendingPhotoURLs + pendingVideoURLs + splatOpenRequests
                if let pendingDataset { selected.append(pendingDataset.selectedURL) }

                // Pruning the provisional batch is its promotion point. Only once
                // those accepted roots are stable may replacement release the
                // prior generation, including an older claim for the same URL.
                inputAccess.releaseClaims(
                    in: provisionalClaims,
                    retainingExactRoots: acceptedProvisionalRoots + newlyQueuedSplatOpenRequests
                )
                let priorSelectionToKeep = mode == .replace ? priorSplatOpenRequests : selected
                inputAccess.releaseClaims(in: priorClaims, notCovering: priorSelectionToKeep)
            } else {
                // A rejected candidate cannot borrow its provisional generation
                // for the preserved capture. A newly queued splat is the sole
                // exception because its viewer has not yet taken its own grant.
                inputAccess.releaseClaims(
                    in: provisionalClaims,
                    retainingExactRoots: newlyQueuedSplatOpenRequests
                )
            }
        }

        var candidate: SelectionCandidate
        switch mode {
        case .append:
            candidate = SelectionCandidate(
                videos: pendingVideoURLs,
                photos: pendingPhotoURLs,
                dataset: pendingDataset,
                splatOpenRequests: splatOpenRequests
            )
        case .replace:
            candidate = SelectionCandidate(
                videos: [],
                photos: [],
                dataset: nil,
                splatOpenRequests: splatOpenRequests
            )
        }

        // A splat is a result rather than capture input, but dropping one here is a
        // reasonable thing to expect to work, so it opens in the viewer instead of
        // being refused. Anything else in the same drop still goes through selection.
        let openable = urls.filter { SplatFileType.isViewable($0) }
        var queuedSplatPaths = Set(
            candidate.splatOpenRequests.map { $0.standardizedFileURL.path }
        )
        for splat in openable {
            guard queuedSplatPaths.insert(splat.standardizedFileURL.path).inserted else {
                continue
            }
            candidate.splatOpenRequests.append(splat)
            newlyQueuedSplatOpenRequests.append(splat)
        }
        let urls = urls.filter { !SplatFileType.isViewable($0) }

        // A dataset is exclusive with photos and videos. Classify the drop for
        // datasets first (deterministically by path so the winner is stable),
        // then let the exclusivity rules short-circuit before the media loop.
        let sortedURLs = urls.sorted { $0.path < $1.path }
        let detectedDatasets = sortedURLs.compactMap(detectDataset(at:))

        if let existing = candidate.dataset {
            // A dataset is already selected; nothing else can join it.
            var warnings: [String] = []
            if !detectedDatasets.isEmpty {
                warnings.append(
                    "Selected more than one dataset. EasySplat uses one at a time — kept \(existing.kind.displayName)."
                )
            }
            let hasNonDatasetURLs = sortedURLs.contains { url in
                !detectedDatasets.contains { $0.selectedURL == url }
            }
            if hasNonDatasetURLs {
                warnings.append("A dataset is selected. Remove it to add photos or videos.")
            }
            splatOpenRequests = candidate.splatOpenRequests
            selectionWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            return false
        }

        if let winner = detectedDatasets.first {
            // A dataset consumes the whole drop and evicts any pending media.
            let clearedMedia = !candidate.videos.isEmpty || !candidate.photos.isEmpty
            candidate.videos = []
            candidate.photos = []
            candidate.dataset = winner
            candidate.acceptedInput = true
            candidate.acceptedClaimRoots.append(winner.selectedURL)
            var warnings: [String] = []
            if clearedMedia {
                warnings.append(
                    "Added the \(winner.kind.displayName). The photos and videos you selected were removed."
                )
            }
            if detectedDatasets.count > 1 {
                warnings.append(
                    "Selected more than one dataset. EasySplat uses one at a time — kept \(winner.kind.displayName)."
                )
            }
            candidate.warnings.append(contentsOf: warnings)
        } else {
            var videoIdentities = Set(candidate.videos.compactMap { Self.classifyInput($0).identity })
            var photoIdentities = Set(candidate.photos.compactMap { Self.classifyInput($0).identity })

            var newVideos: [URL] = []
            var newPhotos: [URL] = []
            var ignoredFileCount = 0
            var ignoredSplatCount = 0
            var skippedCaptureFileCount = 0

            func admitVideo(
                _ url: URL,
                identity preflightIdentity: SelectedInputIdentity? = nil,
                claimRoot: URL
            ) {
                guard let identity = preflightIdentity ?? Self.classifyInput(url).identity else { return }
                candidate.acceptedInput = true
                guard videoIdentities.insert(identity).inserted else { return }
                newVideos.append(url)
                candidate.acceptedClaimRoots.append(claimRoot)
            }
            func admitPhoto(
                _ url: URL,
                identity preflightIdentity: SelectedInputIdentity? = nil,
                claimRoot: URL
            ) {
                guard let identity = preflightIdentity ?? Self.classifyInput(url).identity else { return }
                candidate.acceptedInput = true
                guard photoIdentities.insert(identity).inserted else { return }
                newPhotos.append(url)
                candidate.acceptedClaimRoots.append(claimRoot)
            }
            func ignore(_ url: URL) {
                ignoredFileCount += 1
                if SplatFileType.isSplat(url) { ignoredSplatCount += 1 }
            }

            for url in urls {
                let input = Self.classifyInput(url)
                switch input.kind {
                case .directory:
                    switch Self.expandFolder(
                        url,
                        traversal: folderTraversalProvider(url.standardizedFileURL)
                    ) {
                    case let .complete(media, skippedCounts):
                        media.videos.forEach {
                            admitVideo($0.url, identity: $0.identity, claimRoot: url)
                        }
                        media.images.forEach {
                            admitPhoto($0.url, identity: $0.identity, claimRoot: url)
                        }
                        skippedCaptureFileCount += skippedCounts.total
                    case .empty:
                        candidate.warnings.append(
                            "“\(url.lastPathComponent)” contains no photos or videos EasySplat can use."
                        )
                    case .unreadable:
                        candidate.warnings.append(
                            "Couldn’t read all of “\(url.lastPathComponent)”, so nothing from that folder was added. Check its permissions and try again."
                        )
                    case .traversalLimitExceeded:
                        candidate.warnings.append(
                            "“\(url.lastPathComponent)” is too large or deeply nested to add safely. Choose a smaller folder."
                        )
                    }
                case .regularFile:
                    if Self.isSupportedVideo(url) {
                        admitVideo(url, claimRoot: url)
                    } else if Self.isSupportedImage(url) {
                        admitPhoto(url, claimRoot: url)
                    } else {
                        ignore(url)
                    }
                case .unsupported:
                    ignore(url)
                }
            }

            candidate.videos.append(contentsOf: newVideos)
            candidate.photos.append(contentsOf: newPhotos)

            if ignoredFileCount > 0, ignoredSplatCount == ignoredFileCount {
                if skippedCaptureFileCount > 0 {
                    candidate.warnings.append(
                        Self.folderSkippedFilesMessage(count: skippedCaptureFileCount)
                    )
                }
                let splatNoun = ignoredFileCount == 1 ? "splat" : "splats"
                candidate.warnings.append("Ignored \(ignoredFileCount) \(splatNoun). EasySplat opens .ply splats.")
            } else if ignoredFileCount > 0, newVideos.isEmpty, newPhotos.isEmpty,
                      skippedCaptureFileCount == 0 {
                let noun = ignoredFileCount == 1 ? "file" : "files"
                candidate.warnings.append("Ignored \(ignoredFileCount) \(noun). Add photos, a video, or a folder of them.")
            } else {
                skippedCaptureFileCount += ignoredFileCount
                if skippedCaptureFileCount > 0 {
                    candidate.warnings.append(
                        Self.folderSkippedFilesMessage(count: skippedCaptureFileCount)
                    )
                }
            }
        }

        guard candidate.acceptedInput else {
            splatOpenRequests = candidate.splatOpenRequests
            selectionWarning = candidate.warnings.isEmpty ? nil : candidate.warnings.joined(separator: "\n")
            return false
        }

        pendingVideoURLs = candidate.videos
        pendingPhotoURLs = candidate.photos
        pendingDataset = candidate.dataset
        splatOpenRequests = candidate.splatOpenRequests
        acceptedProvisionalRoots = candidate.acceptedClaimRoots

        if requestedRunOptions.inputOrdering == .continuous,
           let input = buildInputSpec(),
           !RunPlanResolver.supports(inputOrdering: .continuous, input: input) {
            requestedRunOptions.inputOrdering = .automatic
            candidate.warnings.append("Continuous sequence can't combine videos and photos. Input Order was reset to Automatic.")
        }
        if let hint = lowPhotoCountWarning() {
            candidate.warnings.append(hint)
        }
        selectionWarning = candidate.warnings.isEmpty ? nil : candidate.warnings.joined(separator: "\n")
        committedCapture = true
        return true
    }

    func handleInputImporterResult(
        _ result: Result<[URL], any Error>,
        mode: InputSelectionMode,
        failureMessage: String
    ) {
        switch result {
        case let .success(urls):
            selectInputs(urls: urls, mode: mode)
        case let .failure(error):
            guard !Self.isInputSelectionCancellation(error) else { return }
            selectionWarning = failureMessage
        }
    }

    private static func isInputSelectionCancellation(_ error: any Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.Code.userCancelled.rawValue
    }

    private static func folderSkippedFilesMessage(count: Int) -> String {
        let file = count == 1 ? "file" : "files"
        return "Skipped \(count) \(file) EasySplat can't use as capture input."
    }

    private static func dropProviderFailureMessage(count: Int, addedReadableInput: Bool) -> String {
        let item = count == 1 ? "item" : "items"
        if addedReadableInput {
            return "Added what EasySplat could read. \(count) dropped \(item) couldn’t be opened."
        }
        return "Couldn’t read \(count) dropped \(item). Try choosing them instead."
    }

    /// A short quality hint when a photo-only selection is thin. Photos beside a
    /// video are optional, so no floor applies then.
    private func lowPhotoCountWarning() -> String? {
        guard pendingVideoURLs.isEmpty else { return nil }
        let count = pendingPhotoURLs.count
        guard count > 0, count < Self.minimumRecommendedPhotos else { return nil }
        let countText = "\(count) \(count == 1 ? "photo" : "photos")"
        if count < RunPlanResolver.minimumReconstructionImageCount {
            return "Selected \(countText). Add at least \(RunPlanResolver.minimumReconstructionImageCount) from different viewpoints."
        }
        return "Selected \(countText). \(Self.minimumRecommendedPhotos) or more is recommended for reliable coverage."
    }

    /// Classifies a single selected URL as a dataset, or nil. Directories are
    /// probed on disk; regular files qualify only when they carry a `.zip`
    /// extension, whose entry names are peeked without extraction.
    private func detectDataset(at url: URL) -> PendingDataset? {
        let classifiedInput = Self.classifyInput(url)
        switch classifiedInput.kind {
        case .directory:
            guard let detection = DatasetSniffer.detect(at: url) else { return nil }
            return PendingDataset(
                kind: detection.kind,
                selectedURL: url,
                resolvedRoot: detection.root,
                isZip: false,
                imageCount: nil
            )
        case .regularFile:
            guard url.pathExtension.lowercased() == "zip",
                  let detection = DatasetSniffer.detectInZip(at: url) else {
                return nil
            }
            return PendingDataset(
                kind: detection.kind,
                selectedURL: url,
                resolvedRoot: url,
                isZip: true,
                imageCount: nil
            )
        case .unsupported:
            return nil
        }
    }

    private static func classifyInput(_ url: URL) -> ClassifiedInput {
        guard url.isFileURL else {
            return ClassifiedInput(kind: .unsupported, identity: nil)
        }
        var linkStatus = stat()
        let linkResult: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &linkStatus)
        }

        if linkResult == 0 {
            let linkKind = linkStatus.st_mode & S_IFMT
            if linkKind == S_IFLNK {
                // A Finder alias is not a POSIX symlink. Actual symlink roots
                // are never followed: accepting one would make the picker grant
                // cover a different filesystem location than the selected URL.
                return ClassifiedInput(kind: .unsupported, identity: nil)
            }
            return classifiedInput(from: linkStatus)
        }

        // A directory URL may be unreadable even after the user selected it;
        // retain that hint so folder admission can present its actionable error.
        // A missing or unreadable file, however, must never be admitted from its
        // extension alone.
        guard url.hasDirectoryPath else {
            return ClassifiedInput(kind: .unsupported, identity: nil)
        }
        let resolvedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return ClassifiedInput(
            kind: .directory,
            identity: SelectedInputIdentity(kind: .directory, storage: .resolvedPath(resolvedPath))
        )
    }

    private static func classifiedInput(from status: stat) -> ClassifiedInput {
        let fileType = status.st_mode & S_IFMT
        let kind: SelectedInputKind
        if fileType == S_IFREG {
            kind = .regularFile
        } else if fileType == S_IFDIR {
            kind = .directory
        } else {
            return ClassifiedInput(kind: .unsupported, identity: nil)
        }
        return ClassifiedInput(
            kind: kind,
            identity: SelectedInputIdentity(
                kind: kind,
                storage: .fileSystem(
                    device: UInt64(status.st_dev),
                    inode: UInt64(status.st_ino)
                )
            )
        )
    }

    private static func isSupportedVideo(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(pathExtension) {
            return true
        }
        guard let type = UTType(filenameExtension: pathExtension) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// Matches what photo admission accepts: anything conforming to `public.image`
    /// by its extension, which includes JPEG, PNG, HEIC, and camera RAW.
    static func isSupportedImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .image)
    }

    /// Enumerates a selected folder for the photos and videos it holds. Mirrors
    /// the pipeline's photo discovery: bounded depth, hidden files skipped, and a
    /// project bundle's own output directories excluded so a re-selected project
    /// doesn't ingest its generated frames. Symlinks are skipped here so photo
    /// admission's fail-closed symlink rejection is never tripped by expansion.
    private struct ExpandedFolderMediaItem {
        let url: URL
        let identity: SelectedInputIdentity
    }

    private struct ExpandedFolderMedia {
        var images: [ExpandedFolderMediaItem] = []
        var videos: [ExpandedFolderMediaItem] = []

        var isEmpty: Bool {
            images.isEmpty && videos.isEmpty
        }
    }

    private struct ExpandedFolderSkippedCounts {
        var total = 0
    }

    /// Folder enumeration is all-or-nothing. A partial prefix is not useful
    /// capture input: it can silently omit the camera views that make a run
    /// reconstructable, so every resource, depth, and count failure rejects the
    /// selected folder as a unit.
    private enum ExpandedFolder {
        case complete(media: ExpandedFolderMedia, skippedCounts: ExpandedFolderSkippedCounts)
        case empty
        case unreadable(relativePath: String?)
        case traversalLimitExceeded
    }

    private static var folderResourceKeys: Set<URLResourceKey> {
        [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .isPackageKey,
            .nameKey,
        ]
    }

    private static func fileSystemFolderTraversal(_ folder: URL) -> InputFolderTraversal {
        let root = folder.standardizedFileURL
        let resourceKeys = folderResourceKeys
        let rootMetadata: InputFolderResourceMetadata?
        do {
            rootMetadata = InputFolderResourceMetadata(
                resourceValues: try root.resourceValues(forKeys: resourceKeys)
            )
        } catch {
            rootMetadata = nil
        }

        guard rootMetadata != nil else {
            return InputFolderTraversal(
                rootMetadata: nil,
                events: AnySequence<InputFolderTraversalEvent>([])
            )
        }

        var unreadablePath: String?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                unreadablePath = relativePath(of: url, from: root)
                return false
            }
        ) else {
            return InputFolderTraversal(
                rootMetadata: rootMetadata,
                events: AnySequence([.unreadable(relativePath: nil)])
            )
        }

        let events = AnySequence<InputFolderTraversalEvent> {
            var emittedEnumerationFailure = false
            return AnyIterator<InputFolderTraversalEvent> {
                if let object = enumerator.nextObject() {
                    guard let url = object as? URL else {
                        return .unreadable(relativePath: nil)
                    }
                    let metadata: InputFolderResourceMetadata
                    do {
                        metadata = InputFolderResourceMetadata(
                            resourceValues: try url.resourceValues(forKeys: resourceKeys)
                        )
                    } catch {
                        return .unreadable(relativePath: relativePath(of: url, from: root))
                    }
                    return .entry(
                        url: url,
                        level: enumerator.level,
                        metadata: metadata,
                        skipDescendants: { enumerator.skipDescendants() }
                    )
                }

                guard !emittedEnumerationFailure, let unreadablePath else { return nil }
                emittedEnumerationFailure = true
                return .unreadable(relativePath: unreadablePath)
            }
        }

        return InputFolderTraversal(rootMetadata: rootMetadata, events: events)
    }

    private static func expandFolder(
        _ folder: URL,
        traversal: InputFolderTraversal
    ) -> ExpandedFolder {
        let fileManager = FileManager.default
        let root = folder.standardizedFileURL

        guard let rootMetadata = traversal.rootMetadata,
              let rootIsRegularFile = rootMetadata.isRegularFile,
              let rootIsDirectory = rootMetadata.isDirectory,
              let rootIsSymbolicLink = rootMetadata.isSymbolicLink,
              let rootIsHidden = rootMetadata.isHidden,
              let rootIsPackage = rootMetadata.isPackage,
              !rootIsRegularFile,
              rootIsDirectory else {
            return .unreadable(relativePath: nil)
        }
        if rootIsSymbolicLink || rootIsHidden || rootIsPackage {
            return .empty
        }

        let maximumDepth = 64
        let maximumVisitedEntries = 50_000
        let looksLikeProjectRoot = fileManager.fileExists(
            atPath: root.appendingPathComponent("project.json").path
        )
        let excludedProjectDirectories: Set<String> = looksLikeProjectRoot
            ? ["Frames", "SfM", "Training", "Output", "Logs"]
            : []

        var media = ExpandedFolderMedia()
        var skippedCounts = ExpandedFolderSkippedCounts()
        var visitedEntries = 0
        for event in traversal.events {
            guard case let .entry(url, level, metadata, skipDescendants) = event else {
                if case let .unreadable(relativePath) = event {
                    return .unreadable(relativePath: relativePath)
                }
                continue
            }
            guard visitedEntries < maximumVisitedEntries else {
                return .traversalLimitExceeded
            }
            visitedEntries += 1

            guard level <= maximumDepth else {
                skipDescendants()
                return .traversalLimitExceeded
            }

            guard let entryRelativePath = relativePath(of: url, from: root),
                  let metadata,
                  let isRegularFile = metadata.isRegularFile,
                  let isDirectory = metadata.isDirectory,
                  let isSymbolicLink = metadata.isSymbolicLink,
                  let isHidden = metadata.isHidden,
                  let isPackage = metadata.isPackage,
                  !(isRegularFile && isDirectory) else {
                return .unreadable(relativePath: relativePath(of: url, from: root))
            }

            if isHidden || isSymbolicLink || isPackage {
                if isDirectory { skipDescendants() }
                continue
            }
            if isDirectory {
                if !excludedProjectDirectories.isEmpty,
                   url.deletingLastPathComponent().standardizedFileURL == root,
                   metadata.name == nil {
                    return .unreadable(relativePath: entryRelativePath)
                }
                if let name = metadata.name,
                   !excludedProjectDirectories.isEmpty,
                   url.deletingLastPathComponent().standardizedFileURL == root,
                   excludedProjectDirectories.contains(name) {
                    skipDescendants()
                }
                continue
            }
            guard isRegularFile else { continue }
            if isSupportedVideo(url) {
                guard let identity = classifyInput(url).identity else {
                    return .unreadable(relativePath: entryRelativePath)
                }
                media.videos.append(ExpandedFolderMediaItem(url: url, identity: identity))
            } else if isSupportedImage(url) {
                guard let identity = classifyInput(url).identity else {
                    return .unreadable(relativePath: entryRelativePath)
                }
                media.images.append(ExpandedFolderMediaItem(url: url, identity: identity))
            } else {
                skippedCounts.total += 1
            }
        }

        guard !media.isEmpty else { return .empty }
        media.images.sort {
            (relativePath(of: $0.url, from: root) ?? "")
                < (relativePath(of: $1.url, from: root) ?? "")
        }
        media.videos.sort {
            (relativePath(of: $0.url, from: root) ?? "")
                < (relativePath(of: $1.url, from: root) ?? "")
        }
        return .complete(media: media, skippedCounts: skippedCounts)
    }

    private static func relativePath(of url: URL, from root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "" }
        let descendantPrefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(descendantPrefix) else { return nil }
        return String(path.dropFirst(descendantPrefix.count))
    }

    /// Recommended floor used by the pre-flight check. Phrased as a quality
    /// recommendation rather than the pipeline's three-view hard minimum.
    nonisolated static let minimumRecommendedPhotos: Int = 12

    /// Count non-hidden image files in a folder. Recurses into subdirectories
    /// to match the pipeline's photo discovery, but stops as soon as the UI's
    /// recommendation threshold is met. Returns nil when the folder cannot be enumerated.
    nonisolated static func countImageFiles(
        in folder: URL,
        maximumVisitedEntries: Int = 4_096
    ) -> Int? {
        guard maximumVisitedEntries > 0, !Task.isCancelled else { return nil }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }
        let maxDepth = 3
        var visitedEntries = 0
        var count = 0
        for case let url as URL in enumerator {
            guard !Task.isCancelled, visitedEntries < maximumVisitedEntries else {
                return nil
            }
            visitedEntries += 1
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if let declaredType = UTType(filenameExtension: url.pathExtension),
               declaredType.conforms(to: .image) {
                count += 1
                if count >= minimumRecommendedPhotos {
                    return count
                }
            }
        }
        return count
    }

    func removeVideo(at offsets: IndexSet) {
        pendingVideoURLs.remove(atOffsets: offsets)
        pruneInputAccess()
    }

    func removeDataset() {
        pendingDataset = nil
        selectionWarning = nil
        pruneInputAccess()
    }

    /// Gives up the sandbox grants that no longer back anything selected. A
    /// grant covers what the user picked; removing the last photo, video, or
    /// dataset that came from one leaves nothing for it to cover.
    func pruneInputAccess() {
        // A splat is on its way to the viewer, which takes a grant of its own
        // when the window opens. Until the request is drained, this one is what
        // keeps the file readable.
        var selected = pendingPhotoURLs + pendingVideoURLs + splatOpenRequests
        if let pendingDataset { selected.append(pendingDataset.selectedURL) }
        inputAccess.releaseRootsNotCovering(selected)
    }

    func clearPendingInputs() {
        pendingVideoURLs = []
        pendingPhotoURLs = []
        pendingDataset = nil
        selectionWarning = nil
        // Nothing pending means nothing left to read from the user's own folders.
        // A run reaches here only once its inputs are copied into the project.
        inputAccess.releaseAll()
    }

    func removeAllPhotos() {
        pendingPhotoURLs = []
        selectionWarning = nil
        pruneInputAccess()
    }

    func buildInputSpec() -> InputSpec? {
        if let pendingDataset {
            // Adoption rewrites `imagesFolder` to a project-relative path later;
            // this pre-adoption spec names the source the user picked.
            return .dataset(kind: pendingDataset.kind, imagesFolder: pendingDataset.resolvedRoot.path)
        }
        let videos = pendingVideoURLs
        let photosFolder = nominalPhotosFolderPath(for: pendingPhotoURLs)
        if !videos.isEmpty, let photosFolder {
            return .mixed(videos: videos.map(\.path), photosFolder: photosFolder)
        }
        if !videos.isEmpty {
            return .video(files: videos.map(\.path))
        }
        if let photosFolder {
            return .photos(folder: photosFolder)
        }
        return nil
    }

    /// A representative directory path for a set of selected photos, used only to
    /// label the project and satisfy the pre-adoption input shape. Adoption
    /// replaces it with the controlled `Originals/Photos` location, so this value
    /// is never persisted and never walked (the file list drives preflight).
    private func nominalPhotosFolderPath(for photos: [URL]) -> String? {
        guard let first = photos.first else { return nil }
        guard photos.count > 1 else {
            return first.deletingLastPathComponent().path
        }
        let componentLists = photos.map {
            $0.deletingLastPathComponent().standardizedFileURL.pathComponents
        }
        let shortest = componentLists.map(\.count).min() ?? 0
        var shared: [String] = []
        for index in 0..<shortest {
            let component = componentLists[0][index]
            guard componentLists.allSatisfy({ $0[index] == component }) else { break }
            shared.append(component)
        }
        guard shared.count > 1 else {
            // No meaningful common ancestor (e.g. different volumes); fall back
            // to the first photo's parent so the label stays a real directory.
            return first.deletingLastPathComponent().path
        }
        return NSString.path(withComponents: shared)
    }

    func projectTitle(for input: InputSpec) -> String {
        if input.isDataset, let source = input.photosFolder {
            return URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
        }
        if let firstVideo = input.videoFiles.first {
            return URL(fileURLWithPath: firstVideo).deletingPathExtension().lastPathComponent
        }
        if let photosFolder = input.photosFolder {
            return URL(fileURLWithPath: photosFolder).lastPathComponent
        }
        return "Project"
    }
}

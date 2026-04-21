import Foundation

extension PipelineRunner {
    func prepareBrushDataset(
        paths: ProjectPaths,
        progress: (Double, String) -> Void
    ) throws -> URL {
        let fm = FileManager.default
        let dataset = paths.trainingURL.appendingPathComponent("dataset", isDirectory: true)
        let images = dataset.appendingPathComponent("images", isDirectory: true)
        let sparse = dataset.appendingPathComponent("sparse/0", isDirectory: true)
        try resetDirectory(images)
        try resetDirectory(sparse)

        let selected = try fm.contentsOfDirectory(at: paths.framesSelectedURL, includingPropertiesForKeys: nil)
        let imageFiles = selected.filter { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
        guard !imageFiles.isEmpty else { throw PipelineError.invalidInput }
        let imageProgressScale = 0.7
        let imageTotal = max(1, imageFiles.count)
        for (index, url) in imageFiles.enumerated() {
            let dest = images.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            if index % 5 == 0 || index + 1 == imageFiles.count {
                let fraction = imageProgressScale * (Double(index + 1) / Double(imageTotal))
                progress(fraction, "Preparing training dataset (images) \(index + 1)/\(imageTotal)")
            }
        }

        let sourceSparseRoot = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let sourceSparse = try resolveSparseModelDirectory(at: sourceSparseRoot)
        guard sparseModelFilesExist(at: sourceSparse) else { throw PipelineError.outputMissing }
        try _ = ensureTextSparseModelFiles(at: sourceSparse)
        let files = try fm.contentsOfDirectory(
            at: sourceSparse,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let fileItems = files.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        }
        let sparseProgressScale = 1.0 - imageProgressScale
        let sparseTotal = max(1, fileItems.count)
        for (index, file) in fileItems.enumerated() {
            let dest = sparse.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: file, to: dest)
            let fraction = imageProgressScale + sparseProgressScale * (Double(index + 1) / Double(sparseTotal))
            progress(fraction, "Preparing training dataset (sparse) \(index + 1)/\(sparseTotal)")
        }

        progress(0.98, "Preparing training dataset (sparse): ensuring text model files.")
        let converted = try ensureTextSparseModelFiles(at: sparse)
        if converted {
            progress(0.99, "Preparing training dataset (sparse): conversion complete.")
        }

        let requiredTextFiles = ["cameras.txt", "images.txt", "points3D.txt"]
        for name in requiredTextFiles {
            let fileURL = sparse.appendingPathComponent(name)
            guard fm.fileExists(atPath: fileURL.path) else { throw PipelineError.outputMissing }
            let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw PipelineError.outputMissing }
        }
        let imagesTxt = sparse.appendingPathComponent("images.txt")
        try _ = ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(at: imagesTxt)
        return dataset
    }

    func latestBrushExport(in trainingURL: URL, minModificationDate: Date? = nil) -> (file: URL, step: Int?)? {
        let fm = FileManager.default
        let exportsDir = trainingURL.appendingPathComponent("dataset_exports", isDirectory: true)

        if fm.fileExists(atPath: exportsDir.path) {
            if let export = latestBrushExportInDirectory(exportsDir, minModificationDate: minModificationDate) {
                return export
            }
        }

        // Fallback: search recursively in case Brush is configured with a different export path.
        let enumerator = fm.enumerator(at: trainingURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var latest: (file: URL, date: Date, step: Int?)?
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "ply" else { continue }
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if let minModificationDate, date < minModificationDate { continue }
            let step = brushExportStep(from: item)
            if let best = latest {
                if date > best.date || (date == best.date && (step ?? -1) > (best.step ?? -1)) {
                    latest = (item, date, step)
                }
            } else {
                latest = (item, date, step)
            }
        }
        guard let latest else { return nil }
        return (file: latest.file, step: latest.step)
    }

    private func latestBrushExportInDirectory(
        _ directory: URL,
        minModificationDate: Date? = nil
    ) -> (file: URL, step: Int?)? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []

        var newest: (file: URL, date: Date, step: Int?)?
        for file in files where file.pathExtension.lowercased() == "ply" {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if let minModificationDate, date < minModificationDate {
                continue
            }
            let step = brushExportStep(from: file)
            if let best = newest {
                if date > best.date || (date == best.date && (step ?? -1) > (best.step ?? -1)) {
                    newest = (file, date, step)
                }
            } else {
                newest = (file, date, step)
            }
        }

        guard let newest else { return nil }
        return (file: newest.file, step: newest.step)
    }

    func brushExportStep(from url: URL) -> Int? {
        let name = url.lastPathComponent
        let stem: String
        if name.hasSuffix(".compressed.ply") {
            stem = String(name.dropLast(".compressed.ply".count))
        } else if name.hasSuffix(".ply") {
            stem = String(name.dropLast(".ply".count))
        } else {
            return nil
        }
        guard stem.hasPrefix("export_") else { return nil }
        return Int(stem.dropFirst("export_".count))
    }

    struct BrushTrainProgress: Sendable {
        let step: Int
        let total: Int
    }

    struct BrushTrainingPlan: Sendable {
        let totalSteps: Int?
        let exportEvery: Int?
    }

    final class BrushExportStepBox: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: Int?

        func update(step: Int) {
            lock.lock()
            latest = step
            lock.unlock()
        }

        func latestStep() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            return latest
        }
    }

    struct BrushSnapshotDecision: Sendable {
        let keep: Bool
        let delete: URL?
    }

    final class BrushTrainingRateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: Double?

        func update(rate: Double) {
            lock.lock()
            latest = rate
            lock.unlock()
        }

        func latestRate() -> Double? {
            lock.lock()
            defer { lock.unlock() }
            return latest
        }
    }

    final class BrushTrainingEtaEstimator: @unchecked Sendable {
        private let lock = NSLock()
        private var smoothedRate: Double?
        private var smoothedEtaSeconds: TimeInterval?
        private var lastEstimatedStep: Int?
        private var sampleCount: Int = 0
        private let minSamples = 6
        private let minStep = 50
        private let alpha: Double = 0.2
        private let etaIncreaseAlpha: Double = 0.2
        private let etaDecreaseAlpha: Double = 0.35
        private let maxEtaIncreaseFactor: Double = 1.25

        func update(rate: Double) {
            guard rate > 0 else { return }
            lock.lock()
            if let existing = smoothedRate {
                smoothedRate = alpha * rate + (1.0 - alpha) * existing
            } else {
                smoothedRate = rate
            }
            sampleCount += 1
            lock.unlock()
        }

        func estimateRemainingSeconds(step: Int, total: Int) -> TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            guard sampleCount >= minSamples else { return nil }
            guard step >= minStep else { return nil }
            guard total > step else { return nil }
            guard let rate = smoothedRate, rate > 0 else { return nil }
            if let lastEstimatedStep, step < lastEstimatedStep {
                smoothedEtaSeconds = nil
            }
            let remainingSteps = total - step
            let rawEta = Double(remainingSteps) / rate
            let boundedEta: TimeInterval
            if let existing = smoothedEtaSeconds {
                boundedEta = min(rawEta, existing * maxEtaIncreaseFactor)
            } else {
                boundedEta = rawEta
            }
            let nextEta: TimeInterval
            if let existing = smoothedEtaSeconds {
                let alpha = boundedEta > existing ? etaIncreaseAlpha : etaDecreaseAlpha
                nextEta = alpha * boundedEta + (1.0 - alpha) * existing
            } else {
                nextEta = boundedEta
            }
            smoothedEtaSeconds = nextEta
            lastEstimatedStep = step
            return nextEta
        }
    }

    final class BrushSnapshotManager: @unchecked Sendable {
        private let lock = NSLock()
        private let defaultExportEvery: Int?
        private let minSteps: Int
        private let maxSteps: Int
        private let totalSteps: Int?
        private var lastKeptStep: Int?
        private var lastKeptFile: URL?

        init(
            defaultExportEvery: Int?,
            minSteps: Int,
            maxSteps: Int,
            totalSteps: Int?
        ) {
            self.defaultExportEvery = defaultExportEvery
            self.minSteps = minSteps
            self.maxSteps = maxSteps
            self.totalSteps = totalSteps
        }

        func handleSnapshot(file: URL, step: Int, stepsPerSecond: Double?) -> BrushSnapshotDecision {
            lock.lock()
            defer { lock.unlock() }

            if let lastKeptFile, lastKeptFile.resolvingSymlinksInPath() == file.resolvingSymlinksInPath() {
                lastKeptStep = step
                return BrushSnapshotDecision(keep: true, delete: nil)
            }

            let targetStepInterval = snapshotStepInterval(stepsPerSecond: stepsPerSecond)
            let shouldKeep: Bool
            if let lastKeptStep {
                if step < lastKeptStep {
                    shouldKeep = true
                } else if let totalSteps, step >= max(0, totalSteps - targetStepInterval) {
                    shouldKeep = true
                } else {
                    shouldKeep = (step - lastKeptStep) >= targetStepInterval
                }
            } else {
                shouldKeep = true
            }

            if shouldKeep {
                let delete = lastKeptFile
                lastKeptStep = step
                lastKeptFile = file
                return BrushSnapshotDecision(keep: true, delete: delete)
            }
            return BrushSnapshotDecision(keep: false, delete: file)
        }

        private func snapshotStepInterval(stepsPerSecond: Double?) -> Int {
            let fallback = defaultExportEvery ?? minSteps
            guard let rate = stepsPerSecond, rate > 0 else {
                return clampStepCount(fallback)
            }
            let estimatedTotalSeconds: TimeInterval? = {
                guard let totalSteps else { return nil }
                return Double(totalSteps) / rate
            }()
            let targetSeconds = PipelineRunner.brushSnapshotTargetSeconds(estimatedTotalSeconds: estimatedTotalSeconds)
            let rawSteps = Int((rate * targetSeconds).rounded())
            return clampStepCount(rawSteps)
        }

        private func clampStepCount(_ value: Int) -> Int {
            let safeMin = max(1, minSteps)
            let safeMax = max(safeMin, maxSteps)
            if value < safeMin { return safeMin }
            if value > safeMax { return safeMax }
            return value
        }
    }

    final class TrainingStatusGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastEmitAt: Date = .distantPast
        private let minInterval: TimeInterval = 1.0

        func shouldEmit(now: Date) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if now.timeIntervalSince(lastEmitAt) < minInterval {
                return false
            }
            lastEmitAt = now
            return true
        }
    }

    final class BrushTrainingStepLogGate: @unchecked Sendable {
        private let lock = NSLock()
        private let stepInterval: Int
        private var lastEmittedStep: Int?

        init(stepInterval: Int) {
            self.stepInterval = max(1, stepInterval)
        }

        func shouldEmit(step: Int) -> Bool {
            guard step > 0 else { return false }
            guard step % stepInterval == 0 else { return false }
            lock.lock()
            defer { lock.unlock() }
            if lastEmittedStep == step {
                return false
            }
            lastEmittedStep = step
            return true
        }
    }

    func brushTrainingPlan(for preset: PresetSpec) -> BrushTrainingPlan {
        switch preset.quality {
        case .draft:
            return BrushTrainingPlan(totalSteps: 20_000, exportEvery: 5_000)
        case .standard:
            return BrushTrainingPlan(totalSteps: 40_000, exportEvery: 5_000)
        case .ultra:
            return BrushTrainingPlan(totalSteps: 80_000, exportEvery: 10_000)
        }
    }

    func trainingStatusMessage(
        elapsed: TimeInterval,
        progress: BrushTrainProgress?,
        latestExportStep: Int?,
        totalSteps: Int?,
        etaSeconds: TimeInterval?
    ) -> String {
        let elapsedText = formatElapsed(elapsed)
        let etaText = etaSeconds.map { " • ETA \(formatElapsed($0))" } ?? ""
        if let progress, progress.total > 0 {
            let stepText = formatStepCount(progress.step)
            let totalText = formatStepCount(progress.total)
            return "Training model - \(stepText)/\(totalText) steps\(etaText) (running \(elapsedText))"
        }
        if let totalSteps {
            let fallbackStep = max(0, latestExportStep ?? 0)
            let clamped = min(fallbackStep, totalSteps)
            let stepText = formatStepCount(clamped)
            let totalText = formatStepCount(totalSteps)
            return "Training model - \(stepText)/\(totalText) steps\(etaText) (running \(elapsedText))"
        }
        if let latestExportStep {
            let stepText = formatStepCount(latestExportStep)
            return "Training model - \(stepText) steps\(etaText) (running \(elapsedText))"
        }
        return "Training model - running \(elapsedText)"
    }

    func formatStepCount(_ value: Int) -> String {
        let raw = String(max(0, value))
        var grouped: [Character] = []
        var count = 0
        for ch in raw.reversed() {
            if count != 0 && count % 3 == 0 {
                grouped.append(",")
            }
            grouped.append(ch)
            count += 1
        }
        return String(grouped.reversed())
    }

    func formatElapsed(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%dm %02ds", mins, secs)
    }

    func brushExportEveryOverride() -> Int? {
        Self.envInt("EASYSPLAT_BRUSH_EXPORT_EVERY")
    }

    func brushAdaptiveExportEvery(plan: BrushTrainingPlan, logURL: URL) -> Int? {
        guard let totalSteps = plan.totalSteps, totalSteps > 0 else { return nil }
        let rates = brushRecentStepRates(from: logURL, maxSamples: 12)
        guard !rates.isEmpty else { return nil }
        let sorted = rates.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return nil }
        let estimatedTotalSeconds = Double(totalSteps) / median
        let targetSeconds = Self.brushSnapshotTargetSeconds(estimatedTotalSeconds: estimatedTotalSeconds)
        let rawSteps = Int((median * targetSeconds).rounded())
        let clamped = Self.clampStepCount(rawSteps, min: Self.brushSnapshotMinSteps(), max: Self.brushSnapshotMaxSteps())
        if clamped <= 0 { return nil }
        return min(clamped, totalSteps)
    }

    func clearBrushResumeSnapshot(in trainingURL: URL) {
        removeIfExists(trainingURL.appendingPathComponent("latest_snapshot.ply"))
    }

    func updateResumeSnapshotFromLatestExport(
        trainingURL: URL,
        minModificationDate: Date? = nil
    ) {
        guard let exportURL = latestBrushUncompressedExport(
            in: trainingURL,
            minModificationDate: minModificationDate
        ) else { return }
        updateBrushResumeSnapshot(from: exportURL, trainingURL: trainingURL)
    }

    func updateBrushResumeSnapshot(from exportURL: URL, trainingURL: URL) {
        guard exportURL.lastPathComponent.hasSuffix(".ply"),
              !exportURL.lastPathComponent.hasSuffix(".compressed.ply") else { return }
        let destURL = trainingURL.appendingPathComponent("latest_snapshot.ply")
        if exportURL.resolvingSymlinksInPath() == destURL.resolvingSymlinksInPath() {
            return
        }
        copyItemReplacing(source: exportURL, destination: destURL)
    }

    private func latestBrushUncompressedExport(in trainingURL: URL, minModificationDate: Date? = nil) -> URL? {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: trainingURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var latest: (URL, Date)?
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "ply" else { continue }
            if item.lastPathComponent.hasSuffix(".compressed.ply") { continue }
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if let minModificationDate, date < minModificationDate { continue }
            if let best = latest {
                if date > best.1 {
                    latest = (item, date)
                }
            } else {
                latest = (item, date)
            }
        }
        return latest?.0
    }

    private func copyItemReplacing(source: URL, destination: URL) {
        let fm = FileManager.default
        if source.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
            return
        }
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".tmp")
        try? fm.removeItem(at: tempURL)
        do {
            try fm.copyItem(at: source, to: tempURL)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tempURL, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: tempURL, to: destination)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
        }
    }

    private func brushRecentStepRates(from logURL: URL, maxSamples: Int) -> [Double] {
        guard let text = readTail(from: logURL, maxBytes: 512 * 1024) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var rates: [Double] = []
        rates.reserveCapacity(maxSamples)
        for line in lines {
            if let rate = brushTrainStepRate(from: String(line)), rate > 0 {
                rates.append(rate)
            }
        }
        if rates.count > maxSamples {
            return Array(rates.suffix(maxSamples))
        }
        return rates
    }

    private func readTail(from url: URL, maxBytes: Int) -> String? {
        guard maxBytes > 0 else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let offset = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            if data.isEmpty { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func brushSnapshotTargetSeconds(estimatedTotalSeconds: TimeInterval?) -> TimeInterval {
        let minSeconds = brushSnapshotMinSeconds()
        let maxSeconds = brushSnapshotMaxSeconds()
        let defaultSeconds = brushSnapshotDefaultSeconds()
        guard let estimatedTotalSeconds else {
            return clampSeconds(defaultSeconds, min: minSeconds, max: maxSeconds)
        }

        let target: TimeInterval
        switch estimatedTotalSeconds {
        case ..<600:
            target = minSeconds
        case ..<1800:
            target = max(minSeconds, 30)
        case ..<3600:
            target = max(minSeconds, 60)
        case ..<7200:
            target = max(minSeconds, 120)
        default:
            target = max(minSeconds, 300)
        }
        return clampSeconds(target, min: minSeconds, max: maxSeconds)
    }

    static func brushSnapshotMinSteps() -> Int {
        Self.envInt("EASYSPLAT_BRUSH_SNAPSHOT_MIN_STEPS") ?? 5
    }

    static func brushSnapshotMaxSteps() -> Int {
        Self.envInt("EASYSPLAT_BRUSH_SNAPSHOT_MAX_STEPS") ?? 5_000
    }

    private static func brushSnapshotMinSeconds() -> TimeInterval {
        Self.envDouble("EASYSPLAT_BRUSH_SNAPSHOT_MIN_SECONDS") ?? 20
    }

    private static func brushSnapshotMaxSeconds() -> TimeInterval {
        Self.envDouble("EASYSPLAT_BRUSH_SNAPSHOT_MAX_SECONDS") ?? 300
    }

    private static func brushSnapshotDefaultSeconds() -> TimeInterval {
        Self.envDouble("EASYSPLAT_BRUSH_SNAPSHOT_DEFAULT_SECONDS") ?? 120
    }

    private static func clampSeconds(_ value: TimeInterval, min minValue: TimeInterval, max maxValue: TimeInterval) -> TimeInterval {
        let safeMin = Swift.max(0, minValue)
        let safeMax = Swift.max(safeMin, maxValue)
        if value < safeMin { return safeMin }
        if value > safeMax { return safeMax }
        return value
    }

    private static func clampStepCount(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        let safeMin = Swift.max(1, minValue)
        let safeMax = Swift.max(safeMin, maxValue)
        if value < safeMin { return safeMin }
        if value > safeMax { return safeMax }
        return value
    }

    private static func envInt(_ key: String) -> Int? {
        guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Int(raw),
              value > 0 else { return nil }
        return value
    }

    private static func envDouble(_ key: String) -> Double? {
        guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Double(raw),
              value > 0 else { return nil }
        return value
    }
}

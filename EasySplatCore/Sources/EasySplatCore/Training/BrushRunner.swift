import Foundation

public final class BrushRunner {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func runTrain(
        brushPath: URL,
        datasetPath: URL,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) throws {
        let args = ["train", datasetPath.path]
        let result = try runner.run(brushPath.path, args, onStdout: { onLog($0, false) }, onStderr: { onLog($0, true) })
        guard result.exitCode == 0 else { throw NSError(domain: "BrushRunner", code: Int(result.exitCode)) }
    }

    public func findLatestPly(in directory: URL) -> URL? {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var latest: (URL, Date)?
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "ply" else { continue }
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if latest == nil || date > latest!.1 {
                latest = (item, date)
            }
        }
        return latest?.0
    }
}

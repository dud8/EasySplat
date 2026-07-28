import Foundation

public protocol SplatSceneReaderDelegate: AnyObject {
    func didStartReading(withPointCount pointCount: UInt32)
    func didRead(points: [SplatScenePoint])
    func didFinishReading()
    func didFailReading(withError error: Error?)
}

public protocol SplatSceneReader {
    func read(to delegate: SplatSceneReaderDelegate)
    func read(
        to delegate: SplatSceneReaderDelegate,
        shouldCancel: @escaping @Sendable () -> Bool
    )
}

public extension SplatSceneReader {
    /// Readers that cannot interrupt themselves still satisfy the cancellable form.
    func read(
        to delegate: SplatSceneReaderDelegate,
        shouldCancel: @escaping @Sendable () -> Bool
    ) {
        read(to: delegate)
    }
}

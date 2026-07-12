import Foundation

#if DEBUG
extension AppModel {
    func test_loadPipelineLogTail(projectURL: URL, maxLines: Int = 200, maxBytes: Int = 64 * 1024) -> [String] {
        loadPipelineLogTail(projectURL: projectURL, maxLines: maxLines, maxBytes: maxBytes)
    }

    func test_applyToolchainProgress(fraction: Double, message: String) {
        handleToolchainProgress(fraction: fraction, message: message)
    }

    func test_validatedShareItems() -> [Any]? {
        validatedShareItems()
    }

    func test_activateShareSession() {
        activeShareSession = ShareSession(model: self)
        isShareSheetActive = true
    }
}
#endif

import EasySplatCore
import Foundation

#if DEBUG
extension AppModel {
    func test_loadPipelineLogTail(projectURL: URL, maxLines: Int = 200, maxBytes: Int = 64 * 1024) -> [String] {
        loadPipelineLogTail(projectURL: projectURL, maxLines: maxLines, maxBytes: maxBytes)
    }

    func test_applyToolchainProgress(fraction: Double, message: String) {
        handleToolchainProgress(fraction: fraction, message: message)
    }

    @discardableResult
    func test_recordShareClicked(projectURL: URL) -> ShareMetrics {
        recordShareClicked(projectURL: projectURL)
    }

    func test_recordShareCompleted(projectURL: URL, serviceName: String) {
        let session = ShareSession(model: self, projectURL: projectURL)
        activeShareSession = session
        isShareSheetActive = true
        shareDidComplete(from: session, serviceName: serviceName, projectURL: projectURL)
        clearShareSession(session)
    }

    func test_recordShareCompletedFromInactiveSession(projectURL: URL, serviceName: String) {
        let session = ShareSession(model: self, projectURL: projectURL)
        shareDidComplete(from: session, serviceName: serviceName, projectURL: projectURL)
    }

    func test_shareEventsText(projectURL: URL) -> String {
        let url = ProjectPaths(root: projectURL).appEventsLogURL
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func test_activateShareSession(projectURL: URL) {
        activeShareSession = ShareSession(model: self, projectURL: projectURL)
        isShareSheetActive = true
    }

    func test_deactivateShareSession() {
        activeShareSession = nil
        isShareSheetActive = false
    }
}
#endif

import Foundation

public struct LearnedMpsProbeResult: Codable, Sendable {
    public let pythonMachine: String
    public let platform: String
    public let torchVersion: String
    public let mpsBuilt: Bool
    public let mpsAvailable: Bool
    public let mpsAllocOK: Bool
    public let failure: String?

    public var isMpsUsable: Bool {
        mpsBuilt && mpsAvailable && mpsAllocOK
    }
}

public enum LearnedMpsProbeError: Error, LocalizedError {
    case commandFailed(String)
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        case .invalidOutput:
            return "Learned MPS probe produced invalid output."
        }
    }
}

public enum LearnedMpsProbe {
    public static func run(
        python: URL,
        runner: SubprocessRunning = SubprocessRunner()
    ) async throws -> LearnedMpsProbeResult {
        let script = """
        import json, platform, sys
        try:
            import torch
        except Exception as exc:
            payload = {
                "pythonMachine": platform.machine(),
                "platform": platform.platform(),
                "torchVersion": "missing",
                "mpsBuilt": False,
                "mpsAvailable": False,
                "mpsAllocOK": False,
                "failure": f"torch import failed: {exc}",
            }
            print(json.dumps(payload))
            sys.exit(1)
        mps_built = bool(torch.backends.mps.is_built())
        mps_available = bool(torch.backends.mps.is_available())
        mps_alloc_ok = False
        failure = None
        if mps_available:
            try:
                torch.empty((1,), device="mps")
                mps_alloc_ok = True
            except Exception as exc:
                failure = f"mps alloc failed: {exc}"
        payload = {
            "pythonMachine": platform.machine(),
            "platform": platform.platform(),
            "torchVersion": torch.__version__,
            "mpsBuilt": mps_built,
            "mpsAvailable": mps_available,
            "mpsAllocOK": mps_alloc_ok,
            "failure": failure,
        }
        print(json.dumps(payload))
        """

        let result = try await runner.runAsync(
            python.path,
            ["-c", script]
        )
        guard result.exitCode == 0 || !result.stdout.isEmpty else {
            throw LearnedMpsProbeError.commandFailed(result.stderr)
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LearnedMpsProbeResult.self, from: data) else {
            throw LearnedMpsProbeError.invalidOutput
        }
        if result.exitCode != 0 {
            throw LearnedMpsProbeError.commandFailed(decoded.failure ?? result.stderr)
        }
        return decoded
    }
}

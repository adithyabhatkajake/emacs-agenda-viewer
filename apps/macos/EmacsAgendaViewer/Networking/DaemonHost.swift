import Foundation

/// Launches the bundled `eavd` helper process and tears it down on app exit.
///
/// The helper-process pattern (Apple's recommendation for app-bundled
/// services) keeps the daemon's lifecycle tied to the app: closing the app
/// stops `eavd` and frees the socket. Compare with the deprecated
/// launchd-managed Express server, which would persist after the app died.
///
/// Lookup order for the binary, in priority:
///   1. `EAV_DAEMON_BIN` env var (developer override).
///   2. `Contents/Resources/eavd` inside the running `.app` bundle.
///   3. `daemon/target/release/eavd` relative to the repo (dev convenience).
@MainActor
final class DaemonHost {
    private(set) var process: Process?
    private(set) var port: UInt16 = 3002
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    var endpointURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func start() throws {
        guard !isRunning else { return }

        let bin = try locateBinary()
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["--http-port", String(port)]
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.terminationHandler = { _ in
            // Logged on the main actor only; Process delivers this on a
            // background thread. The next launch attempt happens via a UI
            // action; we don't auto-restart here to avoid spin loops on
            // configuration errors.
        }
        try proc.run()
        process = proc
    }

    /// Poll `/api/debug` until it responds 200 OK, with a hard timeout.
    /// Returns true if the daemon is healthy, false otherwise. The first
    /// launch path on a cold install can take ~1–2 s while eavd loads
    /// `eav-bridge.el` into Emacs and re-indexes.
    func waitForReady(timeout: TimeInterval = 8) async -> Bool {
        let probe = endpointURL.appendingPathComponent("api/debug")
        let started = Date()
        while -started.timeIntervalSinceNow < timeout {
            var req = URLRequest(url: probe)
            req.timeoutInterval = 1
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return true
                }
            } catch {
                // connection refused / timeout → keep polling
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }
        proc.interrupt()
        // Give it 2 s to shut down gracefully; SIGKILL if it hangs.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak proc] in
            if let p = proc, p.isRunning { p.terminate() }
        }
        process = nil
    }

    private func locateBinary() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["EAV_DAEMON_BIN"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("eavd")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        // Dev fallback: walk up looking for `daemon/target/release/eavd`.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()       // Networking
            .deletingLastPathComponent()       // EmacsAgendaViewer
            .deletingLastPathComponent()       // EmacsAgendaViewer (app)
            .deletingLastPathComponent()       // macos
            .deletingLastPathComponent()       // apps
            .appendingPathComponent("daemon/target/release/eavd")
        if FileManager.default.isExecutableFile(atPath: dev.path) {
            return dev
        }
        throw DaemonHostError.binaryNotFound
    }
}

enum DaemonHostError: LocalizedError {
    case binaryNotFound

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "eavd binary not found. Expected it in the app bundle's Resources/, in EAV_DAEMON_BIN, or at daemon/target/release/eavd."
        }
    }
}

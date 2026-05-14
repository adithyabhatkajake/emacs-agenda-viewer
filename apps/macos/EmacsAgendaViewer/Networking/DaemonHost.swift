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
@Observable
final class DaemonHost {
    /// Lifecycle phase of the bundled daemon. Drives the UI: while in
    /// `.starting`, list views show a connecting spinner instead of the
    /// "Couldn't load" error — the persisted server URL points at
    /// :3002 on every launch, so a view that fires its initial `.task`
    /// before eavd has bound the port would otherwise flash a spurious
    /// network error every cold start.
    ///
    /// `.failedToStart` vs `.crashed` is the signal we cared to capture:
    /// "never came up" (port conflict, missing binary, unsigned helper)
    /// reads differently from "ran, then died" (segfault, panic, OOM,
    /// SIGKILL by user, Emacs went away). Same retry path, different
    /// diagnostic message.
    enum Phase: Equatable {
        case idle
        case starting
        case ready
        case failedToStart(reason: String)
        case crashed(reason: String)
    }
    var phase: Phase = .idle

    private(set) var process: Process?
    private(set) var port: UInt16 = 3002
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    // Held so the kernel's reference count keeps the pipe alive for the
    // helper's lifetime. We never write to it — its existence is the signal:
    // when this app dies (any way), the kernel closes the write end and the
    // helper reads EOF on stdin and exits. See `--watch-parent` in eavd.
    private let stdinPipe = Pipe()

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    var endpointURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Marketing version from Info.plist (CFBundleShortVersionString). Used
    /// for the version handshake against `/api/debug.version`.
    private var bundledVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    func start() async throws {
        guard !isRunning else { return }

        // Version handshake: if a daemon is already serving on :3002, ask it
        // for its version. If it matches the bundled binary, reuse it (skip
        // spawning). If not, tell it to shut down (graceful → SIGTERM →
        // SIGKILL) so we can spawn the new one. Covers the auto-update case
        // where the previous app's helper survived its parent.
        if let existing = await probeRunningDaemon() {
            if existing.version == bundledVersion {
                // Reuse — the existing daemon is fine.
                return
            }
            await replaceRunningDaemon(pid: existing.pid)
        }

        let bin = try locateBinary()
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = [
            "--http-port", String(port),
            "--watch-parent", String(ProcessInfo.processInfo.processIdentifier),
        ]
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = stdinPipe
        // Capture the stderr pipe up-front so the termination handler
        // (which runs on a background queue) can drain it without
        // touching `self`. Pipes are reference types and outlive the
        // weak-self capture safely.
        let stderr = self.stderrPipe
        proc.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            let why = terminated.terminationReason
            // Drain whatever stderr is sitting in the pipe; bound to
            // the last ~8 lines so we don't dump a megabyte into a UI
            // label if something has been chatty.
            let tail: String = {
                let data = stderr.fileHandleForReading.availableData
                guard let s = String(data: data, encoding: .utf8), !s.isEmpty else { return "" }
                let lines = s.split(whereSeparator: \.isNewline)
                return lines.suffix(8).joined(separator: "\n")
            }()
            Task { @MainActor [weak self] in
                self?.handleEarlyExit(status: status, reason: why, stderr: tail)
            }
        }
        try proc.run()
        process = proc
    }

    /// Probe `/api/debug`. Returns nil if nothing is responding, otherwise
    /// the running daemon's `version` and `pid`. 500 ms timeout — fast
    /// enough that "no existing daemon" doesn't delay launch perceptibly.
    private func probeRunningDaemon() async -> (version: String, pid: Int32)? {
        var req = URLRequest(url: endpointURL.appendingPathComponent("api/debug"))
        req.timeoutInterval = 0.5
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let version = (obj["version"] as? String) ?? ""
        let pid: Int32 = (obj["pid"] as? Int32)
            ?? Int32(exactly: (obj["pid"] as? Int) ?? -1)
            ?? -1
        return (version, pid)
    }

    /// Replace the running daemon: hit `/api/shutdown`, wait up to 1 s for
    /// it to actually stop responding, then SIGTERM and finally SIGKILL.
    /// Used when the running version doesn't match the bundled binary
    /// (the auto-update path).
    private func replaceRunningDaemon(pid: Int32) async {
        var req = URLRequest(url: endpointURL.appendingPathComponent("api/shutdown"))
        req.httpMethod = "POST"
        req.timeoutInterval = 1
        _ = try? await URLSession.shared.data(for: req)

        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            if (await probeRunningDaemon()) == nil { return }
        }
        // Still up — escalate.
        if pid > 0 {
            _ = kill(pid, SIGTERM)
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if (await probeRunningDaemon()) == nil { return }
            }
            _ = kill(pid, SIGKILL)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Poll `/api/debug` until it responds 200 OK, with a hard timeout.
    /// Returns true if the daemon is healthy, false otherwise.
    ///
    /// `/api/debug` is served by the daemon itself (no bridge round-trip),
    /// so the normal cold-start path is well under a second — eavd just
    /// needs to bind the port and load its SQLite snapshot. 15 s is the
    /// hard ceiling: long enough to ride out a paged-out binary or a
    /// momentarily-busy machine, short enough that a real failure (port
    /// conflict, missing binary, sandbox-block) surfaces before the
    /// user gives up.
    func waitForReady(timeout: TimeInterval = 15) async -> Bool {
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

    /// React to the helper process exiting on its own. Called by
    /// `terminationHandler` once the process has died. We decide whether
    /// this is a startup failure (we were still in `.starting`) or a
    /// post-ready crash (`.ready`). Already-terminal phases ignore the
    /// signal — the user has the failure UI in front of them already.
    /// `stop()` and the parent-watchdog SIGTERM path don't go through
    /// here because they don't fire the termination handler on graceful
    /// shutdown… actually they do, but in those cases the app is
    /// quitting and the UI isn't visible.
    @MainActor
    private func handleEarlyExit(status: Int32, reason: Process.TerminationReason, stderr: String) {
        let how: String
        switch reason {
        case .exit:
            how = status == 0
              ? "exited normally (status 0)"
              : "exited with status \(status)"
        case .uncaughtSignal:
            // On macOS `terminationStatus` is the signal number for
            // .uncaughtSignal. SIGSEGV=11, SIGBUS=10, SIGABRT=6, etc.
            // We surface the number; users can look it up if they care.
            how = "killed by signal \(status)" + (signalName(status).map { " (\($0))" } ?? "")
        @unknown default:
            how = "terminated (status \(status))"
        }
        let detail = stderr.isEmpty ? how : "\(how)\n\n\(stderr)"
        process = nil
        switch phase {
        case .idle, .starting:
            phase = .failedToStart(reason: detail)
        case .ready:
            phase = .crashed(reason: detail)
        case .failedToStart, .crashed:
            return
        }
    }

    /// Best-effort POSIX-signal-number → name for the failure UI.
    /// Anything not enumerated falls back to just the number.
    private func signalName(_ n: Int32) -> String? {
        switch n {
        case SIGHUP:  return "SIGHUP"
        case SIGINT:  return "SIGINT"
        case SIGQUIT: return "SIGQUIT"
        case SIGABRT: return "SIGABRT"
        case SIGBUS:  return "SIGBUS"
        case SIGSEGV: return "SIGSEGV"
        case SIGPIPE: return "SIGPIPE"
        case SIGTERM: return "SIGTERM"
        case SIGKILL: return "SIGKILL"
        default: return nil
        }
    }

    /// Spawn (or re-spawn) the daemon and re-run the readiness probe.
    /// Used by the "Retry" button in the failed-startup UI; idempotent
    /// against an already-running daemon thanks to `start()`'s reuse
    /// check.
    func restart() async {
        phase = .starting
        do {
            try await start()
        } catch {
            NSLog("eavd restart failed: %@", String(describing: error))
            if case .starting = phase {
                phase = .failedToStart(reason: "Could not launch helper: \(error)")
            }
            return
        }
        let ready = await waitForReady()
        if ready {
            phase = .ready
        } else if case .starting = phase {
            // Handler may have already promoted to .crashed/.failedToStart
            phase = .failedToStart(reason:
                "Polled /api/debug for 15 seconds with no response.")
        }
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

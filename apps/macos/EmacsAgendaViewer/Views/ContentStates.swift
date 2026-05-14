import SwiftUI

struct UnconfiguredStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("Server not configured")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Open Settings and enter the URL of your Emacs Agenda Viewer server (e.g. http://mac.tailnet.ts.net:3001).")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown while the bundled `eavd` is still booting. The race is most
/// visible on cold launch: `serverURLString` is persisted, so views fire
/// their initial `.task` against the (not-yet-bound) :3002 immediately.
/// We render this instead of `ErrorStateView` while
/// `DaemonHost.phase == .starting`, then auto-recover when the phase
/// transitions to `.ready`.
struct ConnectingStateView: View {
    var title: String = "Connecting to server"
    var subtitle: String = "Starting the local daemon — usually under a second."

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.priorityB)
            Text("Couldn't load")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when the bundled `eavd` either never came up or died after
/// running. Distinct from the generic `ErrorStateView`: "Retry" here
/// re-launches the daemon process, not the API call.
///
/// `kind` separates the two cases so the headline and copy can be
/// honest about what happened. Crash messages include the signal name
/// (SIGSEGV, SIGABRT…) when applicable plus a tail of the daemon's
/// stderr — usually the actual error line.
struct DaemonFailedView: View {
    enum Kind { case failedToStart, crashed }
    let kind: Kind
    let reason: String
    let onRetry: () async -> Void
    @State private var retrying = false

    private var headline: String {
        switch kind {
        case .failedToStart: return "Local daemon didn't start"
        case .crashed:       return "Local daemon crashed"
        }
    }

    private var leadCopy: String {
        switch kind {
        case .failedToStart:
            return "Common causes: another process is holding port 3002, "
                + "the bundled eavd is missing or unsigned, or Emacs isn't "
                + "running so the bridge socket never came up."
        case .crashed:
            return "The daemon was running but exited unexpectedly. "
                + "Hit Retry to relaunch it; if it keeps dying, the stderr "
                + "tail below usually explains why."
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: kind == .crashed
                  ? "xmark.octagon.fill"
                  : "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.priorityA)
            Text(headline)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(leadCopy)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .fixedSize(horizontal: false, vertical: true)
            // The captured exit detail (status code or signal name + a
            // stderr tail). Mono so log output reads correctly; selectable
            // so the user can copy-paste a panic message into an issue.
            ScrollView {
                Text(reason)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 520, maxHeight: 140)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surface.opacity(0.6))
            )
            .padding(.horizontal, 32)
            Button {
                guard !retrying else { return }
                retrying = true
                Task {
                    await onRetry()
                    retrying = false
                }
            } label: {
                if retrying { ProgressView().controlSize(.small) }
                else { Text("Retry") }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(retrying)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

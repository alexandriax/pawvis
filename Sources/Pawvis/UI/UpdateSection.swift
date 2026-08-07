import PawvisCore
import SwiftUI

/// The About tab's update controls: current status, a manual check, and the
/// install/relaunch flow.
struct UpdateSection: View {
    @ObservedObject var updater: UpdateChecker
    /// Only true once macOS confirms the user said no — see `isBlocked()`.
    @State private var notificationsBlocked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticChecksEnabled },
                set: { updater.automaticChecksEnabled = $0 }))
                .fixedSize(horizontal: false, vertical: true)

            if updater.automaticChecksEnabled {
                if notificationsBlocked {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(.secondary)
                        Text("Notifications are off for Pawvis, so new versions won't announce themselves — you'll still see them here and in the menu bar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open…") { Permissions.openNotificationSettings() }
                            .controlSize(.small)
                    }
                } else {
                    Text("A new version announces itself once, in a notification with a button back to this page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button("Check Now") { updater.checkNow() }
                    .disabled(isBusy)
                if case .checking = updater.state {
                    ProgressView().controlSize(.small)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .available(let release) = updater.state {
                availableBox(release)
            }

            if case .downloading(let progress) = updater.state {
                ProgressView(value: progress)
                    .frame(maxWidth: 320)
            }

            if case .readyToRelaunch = updater.state {
                HStack(spacing: 10) {
                    Button("Relaunch Now") { updater.relaunchNow() }
                        .keyboardShortcut(.defaultAction)
                    Text("The update is installed and starts when Pawvis relaunches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { notificationsBlocked = await UpdateNotifier.isBlocked() }
    }

    @ViewBuilder
    private func availableBox(_ release: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pawvis \(release.version.description) is available")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            HStack(spacing: 10) {
                Button("Install and Relaunch") { updater.installAvailableUpdate() }
                    .keyboardShortcut(.defaultAction)
                Button("Skip This Version") { updater.skipCurrentOffer() }
                Link("Release Notes", destination: release.pageURL)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private var isBusy: Bool {
        switch updater.state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var statusText: String {
        switch updater.state {
        case .idle:
            guard let last = updater.lastChecked else { return "Not checked yet" }
            return "Last checked \(Self.relative.localizedString(for: last, relativeTo: Date()))"
        case .checking: return "Checking…"
        case .upToDate: return "Pawvis is up to date"
        case .available: return ""
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        case .readyToRelaunch: return ""
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        if case .failed = updater.state { return .red }
        return .secondary
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

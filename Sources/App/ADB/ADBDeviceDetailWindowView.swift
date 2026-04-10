import AppKit
import SwiftUI

struct ADBDeviceProfile: Codable, Equatable, Sendable {
    var persona: String = ""
    var notes: String = ""
    var preferredApps: String = ""

    var scrcpyWindowTitle: String = ""
    var scrcpyMaxFPS: String = ""
    var scrcpyMaxSize: String = ""
    var scrcpyVideoBitRate: String = "8M"
    var scrcpyAlwaysOnTop: Bool = false
    var scrcpyFullscreen: Bool = false
    var scrcpyStayAwake: Bool = false
    var scrcpyTurnScreenOff: Bool = false

    var personaTitle: String {
        let trimmed = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.components(separatedBy: ":").first?.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? trimmed
    }

    var personaEmoji: String {
        DevicePersonaPreset.all.first(where: { $0.title == personaTitle })?.emoji ?? "🙂"
    }

    var hasCustomScrcpyOverrides: Bool {
        !scrcpyWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !scrcpyMaxFPS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !scrcpyMaxSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || scrcpyVideoBitRate.trimmingCharacters(in: .whitespacesAndNewlines) != "8M"
            || scrcpyAlwaysOnTop || scrcpyFullscreen || scrcpyStayAwake || scrcpyTurnScreenOff
    }
}

@MainActor
final class ADBDeviceProfileStore: ObservableObject {
    static let shared = ADBDeviceProfileStore()

    @Published private var profiles: [String: ADBDeviceProfile] {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let storageKey = "aiphone.device.profiles"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([String: ADBDeviceProfile].self, from: data)
        {
            self.profiles = decoded
        } else {
            self.profiles = [:]
        }
    }

    func profile(for deviceID: String?) -> ADBDeviceProfile {
        guard let deviceID else { return ADBDeviceProfile() }
        return profiles[deviceID] ?? ADBDeviceProfile()
    }

    func binding(for deviceID: String) -> Binding<ADBDeviceProfile> {
        Binding(
            get: { self.profiles[deviceID] ?? ADBDeviceProfile() },
            set: { self.profiles[deviceID] = $0 }
        )
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(encoded, forKey: storageKey)
    }
}

private enum DeviceDetailPage: String, Identifiable {
    case home = "Device"
    case fileExplorer = "File Explorer"
    case appManager = "App Manager"
    case screenPreview = "Screen Preview"
    case camera = "Camera"
    case settings = "Settings"
    case details = "Details"

    var id: String { rawValue }
}

private struct DevicePersonaPreset: Identifiable, Hashable, Sendable {
    let title: String
    let emoji: String
    let description: String

    var id: String { title }
    var label: String { "\(emoji) \(title)" }
    var promptValue: String { "\(title): \(description)" }

    static let all: [DevicePersonaPreset] = [
        .init(
            title: "Hacker", emoji: "🧑‍💻",
            description:
                "Loves breaking down systems, automating tasks, and finding unconventional solutions."
        ),
        .init(
            title: "Minimalist", emoji: "⚪",
            description:
                "Prefers simplicity, reduces noise, and focuses only on what truly matters."),
        .init(
            title: "Overthinker", emoji: "🤯",
            description: "Analyzes every possibility deeply, often getting stuck in decision loops."
        ),
        .init(
            title: "Optimist", emoji: "🌈",
            description: "Sees opportunities in every situation and expects positive outcomes."),
        .init(
            title: "Realist", emoji: "🧠",
            description: "Balances logic and practicality, focusing on what is actually achievable."
        ),
        .init(
            title: "Pessimist", emoji: "🌧️",
            description: "Anticipates worst-case scenarios and prepares for potential failures."),
        .init(
            title: "Leader", emoji: "👑",
            description: "Takes charge, guides others, and makes decisions under pressure."),
        .init(
            title: "Follower", emoji: "🐑",
            description: "Prefers clear direction and works best within established structures."),
        .init(
            title: "Lone Wolf", emoji: "🐺",
            description: "Works independently, avoids reliance on others, and values autonomy."),
        .init(
            title: "Social Butterfly", emoji: "🦋",
            description: "Thrives in social environments and builds strong networks easily."),
        .init(
            title: "Workaholic", emoji: "💼",
            description: "Highly driven, often prioritizes work over rest or personal life."),
        .init(
            title: "Lazy Genius", emoji: "😴",
            description: "Finds the most efficient way to achieve results with minimal effort."),
        .init(
            title: "Perfectionist", emoji: "🎯",
            description: "Strives for flawless execution and high standards in everything."),
        .init(
            title: "Chaotic Creative", emoji: "🎨",
            description: "Generates ideas rapidly, often without structure but full of originality."
        ),
        .init(
            title: "Strategist", emoji: "♟️",
            description: "Plans ahead, evaluates risks, and optimizes for long-term success."),
        .init(
            title: "Explorer", emoji: "🧭",
            description: "Seeks new experiences, ideas, and environments constantly."),
        .init(
            title: "Risk Taker", emoji: "🎲",
            description: "Willing to take bold actions despite uncertainty or potential loss."),
        .init(
            title: "Guardian", emoji: "🛡️",
            description: "Protects people, systems, or values and prioritizes stability."),
        .init(
            title: "Rebel", emoji: "🔥",
            description: "Challenges authority and breaks rules to create change."),
        .init(
            title: "Peacemaker", emoji: "☮️",
            description: "Resolves conflicts and seeks harmony in groups."),
        .init(
            title: "Analyst", emoji: "📊",
            description: "Relies on data, metrics, and logical reasoning to make decisions."),
        .init(
            title: "Builder", emoji: "🏗️",
            description: "Focuses on creating tangible products, systems, or infrastructure."),
        .init(
            title: "Dreamer", emoji: "🌙",
            description: "Imagines big possibilities and visionary ideas beyond current limits."),
        .init(
            title: "Executor", emoji: "⚙️",
            description: "Turns plans into action and ensures tasks are completed efficiently."),
        .init(
            title: "Storyteller", emoji: "📖",
            description: "Communicates ideas through narratives and engaging storytelling."),
    ]
}

struct ADBDeviceDetailDialogView: View {
    @EnvironmentObject private var devicesStore: ADBDevicesStore
    @EnvironmentObject private var profileStore: ADBDeviceProfileStore
    @EnvironmentObject private var aiSettings: AISettingsStore
    @EnvironmentObject private var scrcpyLaunchStore: ScrcpyLaunchStore
    @EnvironmentObject private var cameraStreamStore: CameraStreamStore
    @EnvironmentObject private var screenMirrorStore: ScreenMirrorStore
    @EnvironmentObject private var agentRunStore: AgentRunStore
    @Environment(\.colorScheme) private var colorScheme

    let onDismiss: () -> Void

    @State private var selectedPage: DeviceDetailPage = .home
    @State private var lastAutoLaunchSignature = ""
    @State private var activeDetailDeviceID: String?

    var body: some View {
        Group {
            if let snapshot = devicesStore.selectedDetailSnapshot {
                HStack(alignment: .top, spacing: 0) {
                    DeviceOverviewSidebar(
                        snapshot: snapshot,
                        onRefresh: {
                            devicesStore.refreshPreview(for: snapshot.info.deviceID)
                            devicesStore.refreshDetails(for: snapshot.info.deviceID)
                        },
                        onPreviewRectChanged: { _ in }
                    )
                    .frame(width: 220)
                    .padding(16)

                    // Separator
                    Rectangle()
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
                        )
                        .frame(width: 0.5)
                        .padding(.vertical, 16)

                    VStack(alignment: .leading, spacing: 0) {
                        // Page header
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.info.model ?? "Android Device")
                                    .font(.system(size: 17, weight: .semibold))

                                Text(
                                    selectedPage == .home ? "Choose a page" : selectedPage.rawValue
                                )
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                                .tracking(0.5)
                            }

                            Spacer()

                            if selectedPage != .home {
                                Button {
                                    selectedPage = .home
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chevron.left")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text("Back")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(
                                            colorScheme == .dark
                                                ? Color.white.opacity(0.06)
                                                : Color.black.opacity(0.04)
                                        )
                                        .overlay(
                                            Capsule()
                                                .stroke(
                                                    colorScheme == .dark
                                                        ? Color.white.opacity(0.08)
                                                        : Color.black.opacity(0.06), lineWidth: 0.5)
                                        )
                                )
                            }

                            Button {
                                dismissDetail()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            .background(
                                Circle()
                                    .fill(
                                        colorScheme == .dark
                                            ? Color.white.opacity(0.06)
                                            : Color.black.opacity(0.04)
                                    )
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                colorScheme == .dark
                                                    ? Color.white.opacity(0.08)
                                                    : Color.black.opacity(0.06), lineWidth: 0.5)
                                    )
                            )
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                        Group {
                            switch selectedPage {
                            case .home:
                                DeviceLauncherPage(
                                    snapshot: snapshot,
                                    isScrcpyAvailable: scrcpyLaunchStore.isScrcpyAvailable,
                                    onOpenFileExplorer: {
                                        selectedPage = .fileExplorer
                                    },
                                    onOpenAppManager: {
                                        selectedPage = .appManager
                                    },
                                    onOpenScreenMirror: {
                                        openScreenMirror(for: snapshot)
                                    },
                                    onOpenScreenPreview: {
                                        selectedPage = .screenPreview
                                    },
                                    onOpenCamera: {
                                        selectedPage = .camera
                                    },
                                    onOpenSettings: {
                                        selectedPage = .settings
                                    },
                                    onOpenDetails: {
                                        selectedPage = .details
                                    }
                                )
                            case .fileExplorer:
                                ADBFileExplorerView(
                                    deviceID: snapshot.info.deviceID,
                                    deviceName: snapshot.info.model ?? snapshot.info.deviceID
                                )
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                            case .appManager:
                                ADBAppManagerView(
                                    deviceID: snapshot.info.deviceID,
                                    deviceInfo: snapshot.info
                                )
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                            case .screenPreview:
                                EmptyView()
                            case .camera:
                                CameraPageView(deviceID: snapshot.info.deviceID)
                            case .settings:
                                DeviceSettingsTab(
                                    profile: profileStore.binding(for: snapshot.info.deviceID)
                                )
                            case .details:
                                DeviceDetailsTab(
                                    details: devicesStore.details(for: snapshot.info.deviceID),
                                    snapshot: snapshot
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .onAppear {
                    selectedPage = .home
                    activeDetailDeviceID = snapshot.info.deviceID
                    lastAutoLaunchSignature = ""
                    devicesStore.refreshDetails(for: snapshot.info.deviceID)
                    VirtualCameraProvider.shared.refreshExtensionStatus()
                }
                .onChange(of: snapshot.info.deviceID) { newDeviceID in
                    if let activeDetailDeviceID, activeDetailDeviceID != newDeviceID {
                        screenMirrorStore.stopMirror(deviceID: activeDetailDeviceID, tag: "detail")
                    }
                    selectedPage = .home
                    activeDetailDeviceID = newDeviceID
                    lastAutoLaunchSignature = ""
                }
                .onDisappear {
                    if let activeDetailDeviceID {
                        screenMirrorStore.stopMirror(deviceID: activeDetailDeviceID, tag: "detail")
                    }
                    activeDetailDeviceID = nil
                    lastAutoLaunchSignature = ""
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 34, weight: .ultraLight))
                        .foregroundStyle(.quaternary)

                    VStack(spacing: 4) {
                        Text("No Device Selected")
                            .font(.system(size: 14, weight: .medium))

                        Text("Select a device card to inspect it.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func dismissDetail() {
        if let activeDetailDeviceID {
            screenMirrorStore.stopMirror(deviceID: activeDetailDeviceID, tag: "detail")
        }
        activeDetailDeviceID = nil
        onDismiss()
    }

    private func openScreenMirror(for snapshot: ADBDeviceSnapshot) {
        do {
            try scrcpyLaunchStore.launch(
                device: snapshot.info,
                settings: aiSettings,
                profile: profileStore.profile(for: snapshot.info.deviceID)
            )
        } catch {
            agentRunStore.presentIssue(error.localizedDescription)
        }
    }

    private func autoStartMirror(for deviceID: String) {
        guard !screenMirrorStore.isMirroring(deviceID: deviceID, tag: "detail") else { return }
        Task {
            do {
                try await screenMirrorStore.startMirror(deviceID: deviceID, tag: "detail")
            } catch {
                print("[ScreenMirror] Auto-start failed: \(error.localizedDescription)")
            }
        }
    }

    private func autoLaunchScrcpy(for snapshot: ADBDeviceSnapshot, anchorRectOnScreen: CGRect) {
        guard snapshot.info.isAvailable, !anchorRectOnScreen.isEmpty else { return }

        let signature = [
            snapshot.info.deviceID,
            String(Int(anchorRectOnScreen.minX.rounded())),
            String(Int(anchorRectOnScreen.minY.rounded())),
            String(Int(anchorRectOnScreen.width.rounded())),
            String(Int(anchorRectOnScreen.height.rounded())),
        ].joined(separator: ":")

        guard signature != lastAutoLaunchSignature else { return }

        // do {
        //     try scrcpyLaunchStore.launch(
        //         device: snapshot.info,
        //         settings: aiSettings,
        //         profile: profileStore.profile(for: snapshot.info.deviceID),
        //         anchorRectOnScreen: anchorRectOnScreen,
        //         usePreviewAnchoredStyle: true
        //     )
        //     lastAutoLaunchSignature = signature
        // } catch {
        //     agentRunStore.presentIssue(error.localizedDescription)
        // }
    }
}

private struct DeviceOverviewSidebar: View {
    @EnvironmentObject private var profileStore: ADBDeviceProfileStore
    @EnvironmentObject private var screenMirrorStore: ScreenMirrorStore
    @Environment(\.colorScheme) private var colorScheme

    let snapshot: ADBDeviceSnapshot
    let onRefresh: () -> Void
    let onPreviewRectChanged: (CGRect) -> Void

    private var previewImage: NSImage? {
        guard let data = snapshot.screenshotData, !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    private var connectionLabel: String {
        switch snapshot.info.connectionType {
        case .usb: return "USB"
        case .wifi: return "Wi-Fi"
        case .remote: return "Remote"
        }
    }

    private var connectionIcon: String {
        switch snapshot.info.connectionType {
        case .usb: return "cable.connector"
        case .wifi: return "wifi"
        case .remote: return "dot.radiowaves.left.and.right"
        }
    }

    private var statusColor: Color {
        snapshot.info.isAvailable ? .green : .orange
    }

    private var statusText: String {
        snapshot.info.isAvailable ? "Connected" : snapshot.info.status.capitalized
    }

    private var batteryText: String {
        if let batteryLevel = snapshot.batteryLevel {
            return "\(batteryLevel)%"
        }
        return "Battery --"
    }

    private var batteryIcon: String {
        guard let batteryLevel = snapshot.batteryLevel else { return "battery.50" }
        switch batteryLevel {
        case ..<15: return "battery.25"
        case ..<50: return "battery.50"
        case ..<80: return "battery.75"
        default: return "battery.100"
        }
    }

    private var wifiText: String {
        snapshot.wifiStatus.map { "Wi-Fi \($0)" } ?? "Wi-Fi --"
    }

    private var wifiIcon: String {
        let value = snapshot.wifiStatus?.lowercased() ?? ""
        return value == "off" ? "wifi.slash" : "wifi"
    }

    private var dataText: String {
        snapshot.dataStatus.map { "Data \($0)" } ?? "Data --"
    }

    private var personaProfile: ADBDeviceProfile {
        profileStore.profile(for: snapshot.info.deviceID)
    }

    private var personaLabel: String {
        let title = personaProfile.personaTitle
        return title.isEmpty ? "No Persona" : title
    }

    private var personaEmoji: String {
        personaProfile.personaTitle.isEmpty ? "🙂" : personaProfile.personaEmoji
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Phone preview
            ZStack {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.black)
                        .frame(height: 380)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.16), Color.white.opacity(0.04),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                        .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 8)

                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 42, height: 12)
                        .padding(.top, 8)

                    Group {
                        if screenMirrorStore.isMirroring(deviceID: snapshot.info.deviceID, tag: "detail"),
                            let decoder = screenMirrorStore.decoder(for: snapshot.info.deviceID, tag: "detail"),
                            screenMirrorStore.hasActiveVideo(deviceID: snapshot.info.deviceID, tag: "detail")
                        {
                            ScreenMirrorStreamView(decoder: decoder)
                        } else if let previewImage {
                            Image(nsImage: previewImage)
                                .resizable()
                                .scaledToFit()
                        } else if snapshot.isLoadingPreview {
                            VStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading…")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.40))
                            }
                        } else {
                            VStack(spacing: 6) {
                                Image(
                                    systemName: snapshot.info.isAvailable
                                        ? "iphone.rearcamera" : "iphone.slash"
                                )
                                .font(.system(size: 22, weight: .ultraLight))
                                .foregroundStyle(.white.opacity(0.20))
                                Text(snapshot.info.isAvailable ? "No preview" : "Unavailable")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 348)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 18)
                    .padding(.horizontal, 6)
                }
                .background(
                    ScreenRectReporter { rect in
                        let insetRect = rect.insetBy(dx: 6, dy: 18)
                        onPreviewRectChanged(insetRect)
                    })
            }
            .overlay(alignment: .bottom) {
                if snapshot.info.isAvailable {
                    Button(action: {
                        if screenMirrorStore.isMirroring(deviceID: snapshot.info.deviceID, tag: "detail") {
                            screenMirrorStore.stopMirror(deviceID: snapshot.info.deviceID, tag: "detail")
                        } else {
                            Task {
                                try? await screenMirrorStore.startMirror(deviceID: snapshot.info.deviceID, tag: "detail")
                            }
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: screenMirrorStore.isMirroring(deviceID: snapshot.info.deviceID, tag: "detail")
                                ? "stop.fill" : "play.fill")
                                .font(.system(size: 9))
                            Text(screenMirrorStore.isMirroring(deviceID: snapshot.info.deviceID, tag: "detail")
                                ? "Stop Mirror" : "Start Mirror")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(screenMirrorStore.isMirroring(deviceID: snapshot.info.deviceID, tag: "detail")
                            ? .red : .white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    Text(personaEmoji)
                        .font(.system(size: 9))
                    Text(personaLabel)
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                        )
                )
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.60))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!snapshot.info.isAvailable || snapshot.isLoadingPreview)
                .padding(8)
            }

            // Device info
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.info.model ?? "Android Device")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    Text(snapshot.info.deviceID)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                Spacer()
                DeviceStatusBadge(text: statusText, color: statusColor)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                DeviceMetaPill(systemImage: connectionIcon, text: connectionLabel)
                DeviceMetaPill(systemImage: batteryIcon, text: batteryText)
                DeviceMetaPill(systemImage: wifiIcon, text: wifiText)
                DeviceMetaPill(systemImage: "antenna.radiowaves.left.and.right", text: dataText)
            }

            if let currentApp = snapshot.currentApp, !currentApp.isEmpty {
                Text(currentApp)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

private struct DeviceLauncherPage: View {
    let snapshot: ADBDeviceSnapshot
    let isScrcpyAvailable: Bool
    let onOpenFileExplorer: () -> Void
    let onOpenAppManager: () -> Void
    let onOpenScreenMirror: () -> Void
    let onOpenScreenPreview: () -> Void
    let onOpenCamera: () -> Void
    let onOpenSettings: () -> Void
    let onOpenDetails: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                DeviceActionTile(
                    title: "File Explorer",
                    systemImage: "folder",
                    isEnabled: true,
                    action: onOpenFileExplorer
                )

                DeviceActionTile(
                    title: "App Manager",
                    systemImage: "square.grid.2x2",
                    isEnabled: snapshot.info.isAvailable,
                    action: onOpenAppManager
                )

                DeviceActionTile(
                    title: "Screen Mirror",
                    systemImage: "display.2",
                    isEnabled: snapshot.info.isAvailable && isScrcpyAvailable,
                    action: onOpenScreenMirror
                )


                DeviceActionTile(
                    title: "Camera",
                    systemImage: "camera",
                    isEnabled: snapshot.info.isAvailable,
                    action: onOpenCamera
                )

                DeviceActionTile(
                    title: "Settings",
                    systemImage: "gearshape",
                    isEnabled: true,
                    action: onOpenSettings
                )

                DeviceActionTile(
                    title: "Details",
                    systemImage: "info.circle",
                    isEnabled: true,
                    action: onOpenDetails
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

private struct DeviceActionTile: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var tileFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(isEnabled ? 0.06 : 0.03)
            : Color.white.opacity(isEnabled ? 0.60 : 0.35)
    }

    private var tileBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(isEnabled ? 0.10 : 0.05)
            : Color.black.opacity(isEnabled ? 0.06 : 0.03)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(
                        isEnabled ? Color.gray.opacity(0.80) : Color.gray.opacity(0.30))

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isEnabled ? .primary : Color.gray.opacity(0.50))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tileFill)

                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.04) : Color.white.opacity(0.50),
                                    Color.clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.12) : Color.white.opacity(0.80),
                                    tileBorder,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.04), radius: 8, x: 0, y: 4)
    }
}

private struct DeviceComingSoonPage: View {
    let title: String
    let message: String
    let buttonTitle: String
    let onBack: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "hammer")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(.quaternary)

            Text(title)
                .font(.system(size: 15, weight: .medium))

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Button(buttonTitle, action: onBack)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .stroke(Color.accentColor.opacity(0.20), lineWidth: 0.5)
                        )
                )

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeviceSettingsTab: View {
    @Binding var profile: ADBDeviceProfile

    private var selectedPreset: DevicePersonaPreset? {
        DevicePersonaPreset.all.first { $0.promptValue == profile.persona }
    }

    private func randomizePersona() {
        if let randomPreset = DevicePersonaPreset.all.randomElement() {
            profile.persona = randomPreset.promptValue
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DeviceOverviewCard(title: "Device Persona") {
                    Text(
                        "Saved per device. The AI can use this persona to adapt how it behaves on this phone."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Preset")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Picker("Preset", selection: $profile.persona) {
                                Text("Select a persona").tag("")
                                ForEach(DevicePersonaPreset.all) { preset in
                                    Text(preset.label).tag(preset.promptValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 260, alignment: .leading)
                        }

                        Button {
                            randomizePersona()
                        } label: {
                            Label("Randomize", systemImage: "shuffle")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.12))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.accentColor.opacity(0.20), lineWidth: 0.5)
                                )
                        )
                    }

                    if let selectedPreset {
                        HStack(alignment: .top, spacing: 12) {
                            Text(selectedPreset.emoji)
                                .font(.system(size: 26))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedPreset.title)
                                    .font(.system(size: 14, weight: .semibold))

                                Text(selectedPreset.description)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.secondary.opacity(0.10))
                        )
                    } else {
                        Text(
                            "Choose one of the preset personalities or use Randomize to pick one automatically."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }

                    DeviceTextFieldRow(
                        title: "Preferred Apps", prompt: "Instagram, Chrome, WhatsApp",
                        text: $profile.preferredApps)
                    DeviceTextFieldRow(
                        title: "Notes", prompt: "Special account, login status, safety rules",
                        text: $profile.notes)
                }

                DeviceOverviewCard(title: "scrcpy Overrides") {
                    Text("These values only apply to this specific device profile.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    DeviceTextFieldRow(
                        title: "Window Title", prompt: "My Pixel Mirror",
                        text: $profile.scrcpyWindowTitle)
                    DeviceTextFieldRow(
                        title: "Max FPS", prompt: "30 / 60", text: $profile.scrcpyMaxFPS)
                    DeviceTextFieldRow(
                        title: "Max Size", prompt: "1280", text: $profile.scrcpyMaxSize)
                    DeviceTextFieldRow(
                        title: "Video Bit Rate", prompt: "8M", text: $profile.scrcpyVideoBitRate)

                    Toggle("Always on Top", isOn: $profile.scrcpyAlwaysOnTop)
                    Toggle("Fullscreen", isOn: $profile.scrcpyFullscreen)
                    Toggle("Stay Awake", isOn: $profile.scrcpyStayAwake)
                    Toggle("Turn Screen Off", isOn: $profile.scrcpyTurnScreenOff)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }
}

private struct DeviceDetailsTab: View {
    let details: ADBDeviceDetails?
    let snapshot: ADBDeviceSnapshot

    var body: some View {
        ScrollView {
            if let details {
                VStack(alignment: .leading, spacing: 12) {
                    DeviceOverviewCard(title: "Device Information") {
                        DeviceOverviewLine(label: "Status", value: details.status.capitalized)
                        DeviceOverviewLine(
                            label: "Connection", value: details.connectionType.rawValue.uppercased()
                        )
                        DeviceOverviewLine(label: "Model", value: details.model ?? "--")
                        DeviceOverviewLine(
                            label: "Manufacturer", value: details.manufacturer ?? "--")
                        DeviceOverviewLine(label: "Brand", value: details.brand ?? "--")
                        DeviceOverviewLine(label: "Product", value: details.productName ?? "--")
                        DeviceOverviewLine(label: "Device Name", value: details.deviceName ?? "--")
                        DeviceOverviewLine(
                            label: "Serial Number", value: details.serialNumber ?? "--")
                    }

                    DeviceOverviewCard(title: "Hardware") {
                        DeviceOverviewLine(label: "CPU ABI", value: details.cpuABI ?? "--")
                        DeviceOverviewLine(label: "Hardware", value: details.hardware ?? "--")
                        DeviceOverviewLine(label: "Board", value: details.board ?? "--")
                        DeviceOverviewLine(label: "Bootloader", value: details.bootloader ?? "--")
                        DeviceOverviewLine(
                            label: "Resolution", value: details.screenResolution ?? "--")
                        DeviceOverviewLine(label: "Density", value: details.screenDensity ?? "--")
                        DeviceOverviewLine(label: "OpenGL", value: details.openGLVersion ?? "--")
                        DeviceOverviewLine(label: "Total RAM", value: details.totalRAM ?? "--")
                    }

                    DeviceOverviewCard(title: "System") {
                        DeviceOverviewLine(label: "Android", value: details.androidVersion ?? "--")
                        DeviceOverviewLine(label: "SDK", value: details.sdkVersion ?? "--")
                        DeviceOverviewLine(
                            label: "Build Number", value: details.buildNumber ?? "--")
                        DeviceOverviewLine(label: "Build Type", value: details.buildType ?? "--")
                        DeviceOverviewLine(label: "Build Date", value: details.buildDate ?? "--")
                        DeviceOverviewLine(
                            label: "Security Patch", value: details.securityPatch ?? "--")
                        DeviceOverviewLine(
                            label: "Baseband", value: details.basebandVersion ?? "--")
                        DeviceOverviewLine(label: "Kernel", value: details.kernelVersion ?? "--")
                    }

                    DeviceOverviewCard(title: "Storage") {
                        DeviceOverviewLine(
                            label: "Total Storage", value: details.totalStorage ?? "--")
                        DeviceOverviewLine(
                            label: "Available", value: details.availableStorage ?? "--")
                    }

                    DeviceOverviewCard(title: "Network & Connectivity") {
                        DeviceOverviewLine(label: "Wi‑Fi", value: details.wifiStatus ?? "--")
                        DeviceOverviewLine(label: "Data", value: details.dataStatus ?? "--")
                        DeviceOverviewLine(label: "IP Address", value: details.ipAddress ?? "--")
                        DeviceOverviewLine(
                            label: "Bluetooth Name", value: details.bluetoothName ?? "--")
                        DeviceOverviewLine(label: "USB Config", value: details.usbConfig ?? "--")
                    }

                    DeviceOverviewCard(title: "Runtime") {
                        DeviceOverviewLine(
                            label: "Battery", value: details.batteryLevel.map { "\($0)%" } ?? "--")
                        DeviceOverviewLine(label: "Uptime", value: details.uptime ?? "--")
                        DeviceOverviewLine(label: "Current App", value: details.currentApp ?? "--")
                        DeviceOverviewLine(
                            label: "Installed Packages", value: "\(details.packageCount)")
                        DeviceOverviewLine(
                            label: "Play Store",
                            value: details.playStoreInstalled ? "Installed" : "Not Installed")
                    }

                    DeviceOverviewCard(title: "Locale & Security") {
                        DeviceOverviewLine(label: "Locale", value: details.locale ?? "--")
                        DeviceOverviewLine(label: "Timezone", value: details.timezone ?? "--")
                        DeviceOverviewLine(label: "SELinux", value: details.seLinuxStatus ?? "--")
                        DeviceOverviewLine(
                            label: "Encryption", value: details.encryptionState ?? "--")
                    }

                    DeviceOverviewCard(title: "Installed App Hints") {
                        if details.installedAppsPreview.isEmpty {
                            Text("No installed app hints available.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(details.installedAppsPreview.joined(separator: ", "))
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                        }
                    }

                    if let buildFingerprint = details.buildFingerprint, !buildFingerprint.isEmpty {
                        DeviceOverviewCard(title: "Build Fingerprint") {
                            Text(buildFingerprint)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading device details…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct DeviceOverviewCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.50)
                    )

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                colorScheme == .dark
                                    ? Color.white.opacity(0.03) : Color.white.opacity(0.40),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                colorScheme == .dark
                                    ? Color.white.opacity(0.10) : Color.white.opacity(0.70),
                                colorScheme == .dark
                                    ? Color.white.opacity(0.03) : Color.black.opacity(0.04),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
        )
    }
}

private struct DeviceOverviewLine: View {
    let label: String
    let value: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)

            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.02)
                        : Color.black.opacity(0.015))
        )
    }
}

private struct DeviceTextFieldRow: View {
    let title: String
    let prompt: String
    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.05)
                                : Color.black.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.08)
                                : Color.black.opacity(0.08),
                            lineWidth: 0.5
                        )
                )
        }
    }
}

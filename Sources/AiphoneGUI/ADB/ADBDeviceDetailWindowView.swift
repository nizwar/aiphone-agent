import SwiftUI
import AppKit

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
        return trimmed.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
    }

    var personaEmoji: String {
        DevicePersonaPreset.all.first(where: { $0.title == personaTitle })?.emoji ?? "🙂"
    }

    var hasCustomScrcpyOverrides: Bool {
        !scrcpyWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !scrcpyMaxFPS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !scrcpyMaxSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        scrcpyVideoBitRate.trimmingCharacters(in: .whitespacesAndNewlines) != "8M" ||
        scrcpyAlwaysOnTop ||
        scrcpyFullscreen ||
        scrcpyStayAwake ||
        scrcpyTurnScreenOff
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

        if
            let data = defaults.data(forKey: storageKey),
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

private enum DeviceDetailTab: String, CaseIterable, Identifiable {
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
        .init(title: "Hacker", emoji: "🧑‍💻", description: "Loves breaking down systems, automating tasks, and finding unconventional solutions."),
        .init(title: "Minimalist", emoji: "⚪", description: "Prefers simplicity, reduces noise, and focuses only on what truly matters."),
        .init(title: "Overthinker", emoji: "🤯", description: "Analyzes every possibility deeply, often getting stuck in decision loops."),
        .init(title: "Optimist", emoji: "🌈", description: "Sees opportunities in every situation and expects positive outcomes."),
        .init(title: "Realist", emoji: "🧠", description: "Balances logic and practicality, focusing on what is actually achievable."),
        .init(title: "Pessimist", emoji: "🌧️", description: "Anticipates worst-case scenarios and prepares for potential failures."),
        .init(title: "Leader", emoji: "👑", description: "Takes charge, guides others, and makes decisions under pressure."),
        .init(title: "Follower", emoji: "🐑", description: "Prefers clear direction and works best within established structures."),
        .init(title: "Lone Wolf", emoji: "🐺", description: "Works independently, avoids reliance on others, and values autonomy."),
        .init(title: "Social Butterfly", emoji: "🦋", description: "Thrives in social environments and builds strong networks easily."),
        .init(title: "Workaholic", emoji: "💼", description: "Highly driven, often prioritizes work over rest or personal life."),
        .init(title: "Lazy Genius", emoji: "😴", description: "Finds the most efficient way to achieve results with minimal effort."),
        .init(title: "Perfectionist", emoji: "🎯", description: "Strives for flawless execution and high standards in everything."),
        .init(title: "Chaotic Creative", emoji: "🎨", description: "Generates ideas rapidly, often without structure but full of originality."),
        .init(title: "Strategist", emoji: "♟️", description: "Plans ahead, evaluates risks, and optimizes for long-term success."),
        .init(title: "Explorer", emoji: "🧭", description: "Seeks new experiences, ideas, and environments constantly."),
        .init(title: "Risk Taker", emoji: "🎲", description: "Willing to take bold actions despite uncertainty or potential loss."),
        .init(title: "Guardian", emoji: "🛡️", description: "Protects people, systems, or values and prioritizes stability."),
        .init(title: "Rebel", emoji: "🔥", description: "Challenges authority and breaks rules to create change."),
        .init(title: "Peacemaker", emoji: "☮️", description: "Resolves conflicts and seeks harmony in groups."),
        .init(title: "Analyst", emoji: "📊", description: "Relies on data, metrics, and logical reasoning to make decisions."),
        .init(title: "Builder", emoji: "🏗️", description: "Focuses on creating tangible products, systems, or infrastructure."),
        .init(title: "Dreamer", emoji: "🌙", description: "Imagines big possibilities and visionary ideas beyond current limits."),
        .init(title: "Executor", emoji: "⚙️", description: "Turns plans into action and ensures tasks are completed efficiently."),
        .init(title: "Storyteller", emoji: "📖", description: "Communicates ideas through narratives and engaging storytelling.")
    ]
}

struct ADBDeviceDetailWindowView: View {
    @EnvironmentObject private var devicesStore: ADBDevicesStore
    @EnvironmentObject private var profileStore: ADBDeviceProfileStore
    @EnvironmentObject private var aiSettings: AISettingsStore
    @EnvironmentObject private var scrcpyLaunchStore: ScrcpyLaunchStore
    @EnvironmentObject private var agentRunStore: AgentRunStore

    @State private var selectedTab: DeviceDetailTab = .settings
    @State private var lastAutoLaunchSignature = ""
    @State private var activeDetailDeviceID: String?

    var body: some View {
        Group {
            if let snapshot = devicesStore.selectedDetailSnapshot {
                HStack(alignment: .top, spacing: 18) {
                    DeviceOverviewSidebar(
                        snapshot: snapshot,
                        onRefresh: {
                            devicesStore.refreshPreview(for: snapshot.info.deviceID)
                            devicesStore.refreshDetails(for: snapshot.info.deviceID)
                        },
                        onPreviewRectChanged: { rect in
                            // autoLaunchScrcpy(for: snapshot, anchorRectOnScreen: rect)
                        }
                    )
                    .frame(width: 300)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snapshot.info.model ?? "Android Device")
                                    .font(.title2.weight(.semibold))

                                Text(snapshot.info.deviceID)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Picker("", selection: $selectedTab) {
                                ForEach(DeviceDetailTab.allCases) { tab in
                                    Text(tab.rawValue).tag(tab)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }

                        Group {
                            switch selectedTab {
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
                    activeDetailDeviceID = snapshot.info.deviceID
                    lastAutoLaunchSignature = ""
                    devicesStore.refreshDetails(for: snapshot.info.deviceID)
                }
                .onChange(of: snapshot.info.deviceID) { newDeviceID in
                    if let activeDetailDeviceID, activeDetailDeviceID != newDeviceID {
                        scrcpyLaunchStore.terminateSessions(for: activeDetailDeviceID)
                    }
                    activeDetailDeviceID = newDeviceID
                    lastAutoLaunchSignature = ""
                }
                .onDisappear {
                    if let activeDetailDeviceID {
                        scrcpyLaunchStore.terminateSessions(for: activeDetailDeviceID)
                    }
                    activeDetailDeviceID = nil
                    lastAutoLaunchSignature = ""
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("No Device Selected")
                        .font(.headline)

                    Text("Open the Devices window and click a device card to inspect its overview, settings, and details.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .frame(minWidth: 960, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func autoLaunchScrcpy(for snapshot: ADBDeviceSnapshot, anchorRectOnScreen: CGRect) {
        guard snapshot.info.isAvailable, !anchorRectOnScreen.isEmpty else { return }

        let signature = [
            snapshot.info.deviceID,
            String(Int(anchorRectOnScreen.minX.rounded())),
            String(Int(anchorRectOnScreen.minY.rounded())),
            String(Int(anchorRectOnScreen.width.rounded())),
            String(Int(anchorRectOnScreen.height.rounded()))
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
    let snapshot: ADBDeviceSnapshot
    let onRefresh: () -> Void
    let onPreviewRectChanged: (CGRect) -> Void

    private var previewImage: NSImage? {
        guard let data = snapshot.screenshotData, !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Screen Overview")
                    .font(.headline)
                Spacer()
                Button("Refresh", action: onRefresh)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black)

                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(14)
                } else if snapshot.isLoadingPreview {
                    ProgressView("Loading preview…")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Preview unavailable")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .frame(height: 420)
            .background(ScreenRectReporter { rect in
                let insetRect = rect.insetBy(dx: 14, dy: 14)
                onPreviewRectChanged(insetRect)
            })
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )

            DeviceOverviewCard(title: "Live Status") {
                DeviceOverviewLine(label: "Current App", value: snapshot.currentApp ?? "--")
                DeviceOverviewLine(label: "Battery", value: snapshot.batteryLevel.map { "\($0)%" } ?? "--")
                DeviceOverviewLine(label: "Wi‑Fi", value: snapshot.wifiStatus ?? "--")
                DeviceOverviewLine(label: "Data", value: snapshot.dataStatus ?? "--")
            }
        }
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
            VStack(alignment: .leading, spacing: 14) {
                DeviceOverviewCard(title: "Device Persona") {
                    Text("Saved per device. The AI can use this persona to adapt how it behaves on this phone.")
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
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
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
                        Text("Choose one of the preset personalities or use Randomize to pick one automatically.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    DeviceTextFieldRow(title: "Preferred Apps", prompt: "Instagram, Chrome, WhatsApp", text: $profile.preferredApps)
                    DeviceTextFieldRow(title: "Notes", prompt: "Special account, login status, safety rules", text: $profile.notes)
                }

                DeviceOverviewCard(title: "scrcpy Overrides") {
                    Text("These values only apply to this specific device profile.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    DeviceTextFieldRow(title: "Window Title", prompt: "My Pixel Mirror", text: $profile.scrcpyWindowTitle)
                    DeviceTextFieldRow(title: "Max FPS", prompt: "30 / 60", text: $profile.scrcpyMaxFPS)
                    DeviceTextFieldRow(title: "Max Size", prompt: "1280", text: $profile.scrcpyMaxSize)
                    DeviceTextFieldRow(title: "Video Bit Rate", prompt: "8M", text: $profile.scrcpyVideoBitRate)

                    Toggle("Always on Top", isOn: $profile.scrcpyAlwaysOnTop)
                    Toggle("Fullscreen", isOn: $profile.scrcpyFullscreen)
                    Toggle("Stay Awake", isOn: $profile.scrcpyStayAwake)
                    Toggle("Turn Screen Off", isOn: $profile.scrcpyTurnScreenOff)
                }
            }
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
                VStack(alignment: .leading, spacing: 14) {
                    DeviceOverviewCard(title: "Device Information") {
                        DeviceOverviewLine(label: "Status", value: details.status.capitalized)
                        DeviceOverviewLine(label: "Connection", value: details.connectionType.rawValue.uppercased())
                        DeviceOverviewLine(label: "Model", value: details.model ?? "--")
                        DeviceOverviewLine(label: "Manufacturer", value: details.manufacturer ?? "--")
                        DeviceOverviewLine(label: "Brand", value: details.brand ?? "--")
                        DeviceOverviewLine(label: "Product", value: details.productName ?? "--")
                        DeviceOverviewLine(label: "Device Name", value: details.deviceName ?? "--")
                    }

                    DeviceOverviewCard(title: "System") {
                        DeviceOverviewLine(label: "Android", value: details.androidVersion ?? "--")
                        DeviceOverviewLine(label: "SDK", value: details.sdkVersion ?? "--")
                        DeviceOverviewLine(label: "CPU ABI", value: details.cpuABI ?? "--")
                        DeviceOverviewLine(label: "Security Patch", value: details.securityPatch ?? "--")
                        DeviceOverviewLine(label: "Resolution", value: details.screenResolution ?? "--")
                        DeviceOverviewLine(label: "Density", value: details.screenDensity ?? "--")
                    }

                    DeviceOverviewCard(title: "Runtime") {
                        DeviceOverviewLine(label: "Battery", value: details.batteryLevel.map { "\($0)%" } ?? "--")
                        DeviceOverviewLine(label: "Wi‑Fi", value: details.wifiStatus ?? "--")
                        DeviceOverviewLine(label: "Data", value: details.dataStatus ?? "--")
                        DeviceOverviewLine(label: "Current App", value: details.currentApp ?? "--")
                        DeviceOverviewLine(label: "Installed Packages", value: "\(details.packageCount)")
                        DeviceOverviewLine(label: "Play Store", value: details.playStoreInstalled ? "Installed" : "Not Installed")
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
                .padding(.bottom, 12)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView()
                    Text("Loading device details…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 24)
            }
        }
    }
}

private struct DeviceOverviewCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

private struct DeviceOverviewLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)

            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }
}

private struct DeviceTextFieldRow: View {
    let title: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

import SwiftUI
import AppKit

@main
struct AIPhoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var aiSettings = AISettingsStore.shared
    @StateObject private var devicesStore = ADBDevicesStore()
    @StateObject private var deviceProfileStore = ADBDeviceProfileStore.shared
    @StateObject private var scrcpyLaunchStore = ScrcpyLaunchStore.shared
    @StateObject private var agentRunStore = AgentRunStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(aiSettings)
                .environmentObject(devicesStore)
                .environmentObject(deviceProfileStore)
                .environmentObject(scrcpyLaunchStore)
                .environmentObject(agentRunStore)
                .ignoresSafeArea(.container, edges: .top)
                .background(WindowChromeConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 680, height: 108)

        Window("Settings", id: "settings") {
            AISettingsWindowView()
                .environmentObject(aiSettings)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 620, height: 400)

        Window("Devices", id: "devices") {
            ADBDevicesWindowView()
                .environmentObject(devicesStore)
                .environmentObject(deviceProfileStore)
                .environmentObject(aiSettings)
                .environmentObject(scrcpyLaunchStore)
                .environmentObject(agentRunStore)
        }
        .defaultSize(width: 880, height: 620)

        Window("Device Details", id: "device-detail") {
            ADBDeviceDetailWindowView()
                .environmentObject(devicesStore)
                .environmentObject(deviceProfileStore)
                .environmentObject(aiSettings)
                .environmentObject(scrcpyLaunchStore)
                .environmentObject(agentRunStore)
        }
        .defaultSize(width: 980, height: 640)

        Window("Agent Activity", id: "activity") {
            AgentLogWindowView()
                .environmentObject(agentRunStore)
        }
        .defaultSize(width: 760, height: 480)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScrcpyLaunchStore.shared.terminateAll()
    }
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var aiSettings: AISettingsStore
    @EnvironmentObject private var devicesStore: ADBDevicesStore
    @EnvironmentObject private var deviceProfileStore: ADBDeviceProfileStore
    @EnvironmentObject private var scrcpyLaunchStore: ScrcpyLaunchStore
    @EnvironmentObject private var agentRunStore: AgentRunStore
    @State private var prompt = ""
    @State private var promptHistory: [String] = []
    @State private var promptHistoryIndex: Int?
    @State private var draftPromptBeforeHistoryNavigation = ""

    var body: some View {
        ZStack {
            GlassBackgroundView(material: .hudWindow)
                .opacity(2)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ToolbarIconButton(systemName: "slider.horizontal.3", accessibilityLabel: "Settings") {
                        openWindow(id: "settings")
                    }

                    ToolbarIconButton(systemName: "iphone.gen3", accessibilityLabel: "Devices") {
                        openWindow(id: "devices")
                    }

                    ToolbarIconMenu(systemName: "eye", accessibilityLabel: "Open scrcpy") {
                        Button {
                            openScrcpyForAll()
                        } label: {
                            Label("All Devices", systemImage: "square.stack.3d.up")
                        }
                        .disabled(readySnapshots.isEmpty)

                        if readySnapshots.isEmpty {
                            Divider()

                            Text(devicesStore.isRefreshing ? "Loading devices..." : "No ready devices found")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Divider()

                            ForEach(readySnapshots) { snapshot in
                                Button {
                                    openScrcpy(for: snapshot)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Label(snapshot.info.model ?? snapshot.info.deviceID, systemImage: "iphone.gen3")

                                        Text("\(snapshot.info.deviceID) · \(snapshot.info.status)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            devicesStore.refresh()
                        } label: {
                            Label(devicesStore.isRefreshing ? "Refreshing..." : "Refresh Devices", systemImage: "arrow.clockwise")
                        }
                        .disabled(devicesStore.isRefreshing)

                        // Button {
                        //     scrcpyLaunchStore.refreshAvailability()
                        // } label: {
                        //     Label("Refresh scrcpy Check", systemImage: "checkmark.arrow.trianglehead.clockwise")
                        // }
                    }
                    .disabled(!scrcpyLaunchStore.isScrcpyAvailable)
                    .help(eyeButtonHelpText)

                    ToolbarIconButton(systemName: "doc.text", accessibilityLabel: "Log") {
                        openWindow(id: "activity")
                    }

                    Spacer(minLength: 0)

                    ToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close") {
                        NSApp.terminate(nil)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .background(ToolbarDragRegion())

                PromptComposer(
                    prompt: $prompt,
                    statusMessage: agentRunStore.statusMessage,
                    isRunning: agentRunStore.isRunning,
                    onSend: submitPrompt,
                    onStop: { agentRunStore.cancel() },
                    onHistoryUp: navigatePromptHistoryUp,
                    onHistoryDown: navigatePromptHistoryDown
                )
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 680)
        .frame(minHeight: 108, alignment: .top)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .task {
            devicesStore.refreshIfNeeded()
            scrcpyLaunchStore.refreshAvailability()
        }
        .onChange(of: aiSettings.scrcpyExecutablePath) { _ in
            scrcpyLaunchStore.refreshAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            scrcpyLaunchStore.refreshAvailability()
        }
    }

    private var readySnapshots: [ADBDeviceSnapshot] {
        devicesStore.snapshots.filter { $0.info.isAvailable }
    }

    private var eyeButtonHelpText: String {
        if !scrcpyLaunchStore.isScrcpyAvailable {
            return scrcpyLaunchStore.availabilityMessage
        }

        if readySnapshots.isEmpty {
            return devicesStore.isRefreshing ? "Loading devices..." : "No ready devices found for scrcpy."
        }

        return "Open scrcpy for one specific device or all ready devices."
    }

    private func openScrcpyForAll() {
        do {
            try scrcpyLaunchStore.launchAll(
                devices: readySnapshots.map(\.info),
                settings: aiSettings,
                profileStore: deviceProfileStore
            )
        } catch {
            agentRunStore.presentIssue(error.localizedDescription)
        }
    }

    private func openScrcpy(for snapshot: ADBDeviceSnapshot) {
        do {
            try scrcpyLaunchStore.launch(
                device: snapshot.info,
                settings: aiSettings,
                profile: deviceProfileStore.profile(for: snapshot.info.deviceID)
            )
        } catch {
            agentRunStore.presentIssue(error.localizedDescription)
        }
    }

    private func submitPrompt() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        let availableSnapshots = devicesStore.snapshots.filter { $0.info.isAvailable }
        guard !availableSnapshots.isEmpty else {
            agentRunStore.presentIssue("No ready devices found. Connect a device and refresh the list first.")
            return
        }

        let targetDeviceIDs = availableSnapshots.map { $0.info.deviceID }

        let deviceProfiles = Dictionary(uniqueKeysWithValues: targetDeviceIDs.map { deviceID in
            (deviceID, deviceProfileStore.profile(for: deviceID))
        })

        if agentRunStore.run(task: trimmedPrompt, deviceIDs: targetDeviceIDs, settings: aiSettings, deviceProfiles: deviceProfiles) {
            rememberPrompt(trimmedPrompt)
            prompt = ""
        }
    }

    private func rememberPrompt(_ submittedPrompt: String) {
        guard !submittedPrompt.isEmpty else { return }

        if promptHistory.last != submittedPrompt {
            promptHistory.append(submittedPrompt)
        }

        if promptHistory.count > 100 {
            promptHistory.removeFirst(promptHistory.count - 100)
        }

        promptHistoryIndex = nil
        draftPromptBeforeHistoryNavigation = ""
    }

    private func navigatePromptHistoryUp() {
        guard !promptHistory.isEmpty else { return }

        if promptHistoryIndex == nil {
            draftPromptBeforeHistoryNavigation = prompt
            promptHistoryIndex = promptHistory.indices.last
        } else if let index = promptHistoryIndex, index > 0 {
            promptHistoryIndex = index - 1
        }

        if let index = promptHistoryIndex, promptHistory.indices.contains(index) {
            prompt = promptHistory[index]
        }
    }

    private func navigatePromptHistoryDown() {
        guard let index = promptHistoryIndex else { return }

        if index < promptHistory.count - 1 {
            let nextIndex = index + 1
            promptHistoryIndex = nextIndex
            prompt = promptHistory[nextIndex]
        } else {
            promptHistoryIndex = nil
            prompt = draftPromptBeforeHistoryNavigation
        }
    }
}

struct PromptComposer: View {
    @Binding var prompt: String
    let statusMessage: String
    let isRunning: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onHistoryUp: () -> Void
    let onHistoryDown: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if isRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)

                        Text(statusMessage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .padding(.vertical, 12)
                } else {
                    TextField("Your Instructions...", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1...5)
                        .padding(.leading, 14)
                        .padding(.trailing, 10)
                        .padding(.vertical, 12)
                        .onSubmit(onSend)
                        .onMoveCommand { direction in
                            switch direction {
                            case .up:
                                onHistoryUp()
                            case .down:
                                onHistoryDown()
                            default:
                                break
                            }
                        }
                        .help("Press ↑ or ↓ to browse prompt history.")
                }
            }

            Divider()
                .frame(height: 24)
                .overlay(Color.black.opacity(0.10))

            Button(action: isRunning ? onStop : onSend) {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isRunning ? Color.white : Color.black)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(
                                isRunning
                                    ? Color.red.opacity(0.88)
                                    : (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.white.opacity(0.45) : Color.white)
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isRunning && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(isRunning ? "Stop all running operations" : "Send instructions")
            .padding(.trailing, 2)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            ZStack {
                GlassBackgroundView(material: .popover)
                    .opacity(0.80)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.10))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            )
        )
        .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 8)
    }
}

private struct ToolbarIconLabel: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.22))
            )
            .contentShape(Circle())
    }
}

struct ToolbarIconMenu<MenuContent: View>: View {
    let systemName: String
    let accessibilityLabel: String
    @ViewBuilder let content: () -> MenuContent

    var body: some View {
        Menu {
            content()
        } label: {
            ToolbarIconLabel(systemName: systemName)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct ToolbarIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolbarIconLabel(systemName: systemName)
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

private final class ToolbarDragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct ToolbarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ToolbarDragRegionView()
        view.wantsLayer = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct GlassBackgroundView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = material
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.state = .active
    }
}

struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window: window)
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            configure(window: window)
        }
    }

    private func configure(window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.titled)
        window.styleMask.remove(.borderless)
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating

        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = 20
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.masksToBounds = true
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 20
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        window.makeKeyAndOrderFront(nil)
        position(window: window)

        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ].forEach { buttonType in
            window.standardWindowButton(buttonType)?.isHidden = true
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func position(window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let bottomInset = visibleFrame.minY - screenFrame.minY
        let leftInset = visibleFrame.minX - screenFrame.minX
        let rightInset = screenFrame.maxX - visibleFrame.maxX
        let dockIsBottom = bottomInset > 0 && bottomInset >= leftInset && bottomInset >= rightInset

        let targetX = max(
            visibleFrame.minX + 10,
            min(visibleFrame.midX - (window.frame.width / 2), visibleFrame.maxX - window.frame.width - 10)
        )
        let targetY = (dockIsBottom ? visibleFrame.minY : screenFrame.minY) + 10

        window.setFrameOrigin(NSPoint(x: round(targetX), y: round(targetY)))
    }
}

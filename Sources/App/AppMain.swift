import AppKit
import SwiftUI

private enum VisualSystem {
    static let windowCornerRadius: CGFloat = 24
    static let controlCornerRadius: CGFloat = 22
    static let toolbarGlyphSize: CGFloat = 11
    static let toolbarButtonSize: CGFloat = 30
    static let glassBorderWidth: CGFloat = 0.5
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

@main
struct AIPhoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var aiSettings = AISettingsStore.shared
    @StateObject private var devicesStore = ADBDevicesStore()
    @StateObject private var deviceProfileStore = ADBDeviceProfileStore.shared
    @StateObject private var scrcpyLaunchStore = ScrcpyLaunchStore.shared
    @StateObject private var cameraStreamStore = CameraStreamStore.shared
    @StateObject private var screenMirrorStore = ScreenMirrorStore.shared
    @StateObject private var agentRunStore = AgentRunStore()

    var body: some Scene {
        WindowGroup("AIPhone") {
            ContentView()
                .environmentObject(aiSettings)
                .environmentObject(devicesStore)
                .environmentObject(deviceProfileStore)
                .environmentObject(scrcpyLaunchStore)
                .environmentObject(cameraStreamStore)
                .environmentObject(screenMirrorStore)
                .environmentObject(agentRunStore)
                .ignoresSafeArea(.all, edges: .vertical)
                .background(WindowChromeConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 680, height: 84)

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
                .environmentObject(cameraStreamStore)
                .environmentObject(screenMirrorStore)
                .environmentObject(agentRunStore) 
                .background(GeneralGlassy())
        }
        .defaultSize(width: 880, height: 620)

        Window("Agent Activity", id: "activity") {
            AgentLogWindowView()
                .environmentObject(agentRunStore)
        }
        .defaultSize(width: 760, height: 480)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let iconURL = Bundle.main.url(forResource: "BrandMark", withExtension: "png"),
            let iconImage = NSImage(contentsOf: iconURL)
        {
            NSApp.applicationIconImage = iconImage
        }

        setupStatusItem()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScrcpyLaunchStore.shared.terminateAll()
        CameraStreamStore.shared.stopAll()
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let windowEntries: [(title: String, action: Selector)] = [
            ("AIPhone", #selector(showMainWindow)),
            ("Devices", #selector(showDevicesWindow)),
            ("Settings", #selector(showSettingsWindow)),
            ("Agent Activity", #selector(showActivityWindow)),
        ]

        for entry in windowEntries {
            let hasWindow = NSApp.windows.contains(where: {
                $0.title == entry.title && $0.isVisible
            })
            let item = NSMenuItem(title: entry.title, action: entry.action, keyEquivalent: "")
            item.target = self
            if hasWindow {
                item.state = .on
            }
            menu.addItem(item)
        }

        return menu
    }

    @objc private func showDevicesWindow() {
        showOrFocusWindow(titled: "Devices", windowID: "devices")
    }

    @objc private func showSettingsWindow() {
        showOrFocusWindow(titled: "Settings", windowID: "settings")
    }

    @objc private func showActivityWindow() {
        showOrFocusWindow(titled: "Agent Activity", windowID: "activity")
    }

    private func showOrFocusWindow(titled title: String, windowID: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Status Item (Tray Icon)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            if let iconURL = Bundle.main.url(forResource: "BrandMark", withExtension: "png"),
               let iconImage = NSImage(contentsOf: iconURL)
            {
                iconImage.size = NSSize(width: 18, height: 18)
                iconImage.isTemplate = true
                button.image = iconImage
            } else {
                button.image = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: "AIPhone")
            }
            button.toolTip = "AIPhone"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Show AIPhone", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AIPhone", action: #selector(quitApp), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.title == "AIPhone" || $0.identifier?.rawValue == "AIPhone" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Fallback: activate the first available window
            for window in NSApp.windows where !window.title.isEmpty {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ToolbarIconButton(systemName: "slider.horizontal.3", accessibilityLabel: "Settings")
                {
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

                        Text(
                            devicesStore.isRefreshing
                                ? "Loading devices..." : "No ready devices found"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    } else {
                        Divider()

                        ForEach(readySnapshots) { snapshot in
                            Button {
                                openScrcpy(for: snapshot)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(
                                        snapshot.info.model ?? snapshot.info.deviceID,
                                        systemImage: "iphone.gen3")

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
                        Label(
                            devicesStore.isRefreshing ? "Refreshing..." : "Refresh Devices",
                            systemImage: "arrow.clockwise")
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

                ToolbarStatusStrip(
                    deviceCount: devicesStore.snapshots.count,
                    readyCount: readySnapshots.count,
                    modelName: aiSettings.openGLMModel,
                    isRunning: agentRunStore.isRunning
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)

                ToolbarIconButton(systemName: "xmark", accessibilityLabel: "Hide") {
                    NSApp.keyWindow?.orderOut(nil)
                    if NSApp.windows.allSatisfy({ !$0.isVisible || $0.className.contains("StatusBar") }) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
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
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)  //Don't replace this
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(width: 680, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow)

                LinearGradient(
                    colors: [Color.primary.opacity(0.06), Color.primary.opacity(0.01)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RoundedRectangle(cornerRadius: VisualSystem.windowCornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.primary.opacity(0.14), Color.primary.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: VisualSystem.glassBorderWidth
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: VisualSystem.windowCornerRadius, style: .continuous))
        )
        .clipShape(RoundedRectangle(cornerRadius: VisualSystem.windowCornerRadius, style: .continuous))
        .task {
            devicesStore.refreshIfNeeded()
            scrcpyLaunchStore.refreshAvailability()
        }
        .onChange(of: aiSettings.scrcpyExecutablePath) { _ in
            scrcpyLaunchStore.refreshAvailability()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
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
            return devicesStore.isRefreshing
                ? "Loading devices..." : "No ready devices found for scrcpy."
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
            agentRunStore.presentIssue(
                "No ready devices found. Connect a device and refresh the list first.")
            return
        }

        let targetDeviceIDs = availableSnapshots.map { $0.info.deviceID }

        let deviceProfiles = Dictionary(
            uniqueKeysWithValues: targetDeviceIDs.map { deviceID in
                (deviceID, deviceProfileStore.profile(for: deviceID))
            })

        if agentRunStore.run(
            task: trimmedPrompt, deviceIDs: targetDeviceIDs, settings: aiSettings,
            deviceProfiles: deviceProfiles)
        {
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

    @State private var keyMonitor: Any?
    @FocusState private var isPromptFocused: Bool

    private var isEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var iconForeground: Color {
        isRunning ? .white : (isEmpty ? Color.primary.opacity(0.30) : Color.primary.opacity(0.90))
    }

    private var iconBackground: Color {
        isRunning ? Color.red.opacity(0.70) : (isEmpty ? Color.primary.opacity(0.05) : Color.primary.opacity(0.12))
    }

    private var iconBorder: Color {
        isRunning ? Color.red.opacity(0.30) : Color.primary.opacity(0.08)
    }

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
                    .padding(.vertical, 8)
                } else {
                    TextField("Your Instructions...", text: $prompt)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1...5)
                        .padding(.leading, 14)
                        .padding(.trailing, 10)
                        .padding(.vertical, 8)
                        .focused($isPromptFocused)
                        .onSubmit(onSend)
                        .help("Press ↑ or ↓ to browse prompt history.")
                }
            }

            Divider()
                .frame(height: 20)
                .overlay(Color.primary.opacity(0.06))

            Button(action: isRunning ? onStop : onSend) {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconForeground)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(iconBackground)
                            .overlay(
                                Circle()
                                    .stroke(iconBorder, lineWidth: VisualSystem.glassBorderWidth)
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isRunning && isEmpty)
            .help(isRunning ? "Stop all running operations" : "Send instructions")
            .padding(.trailing, 4)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 48)
        .background(
            ZStack {
                RoundedRectangle(
                    cornerRadius: VisualSystem.controlCornerRadius,
                    style: .continuous
                )
                .fill(Color.primary.opacity(0.05))

                RoundedRectangle(
                    cornerRadius: VisualSystem.controlCornerRadius,
                    style: .continuous
                )
                .fill(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.03), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                RoundedRectangle(
                    cornerRadius: VisualSystem.controlCornerRadius,
                    style: .continuous
                )
                .stroke(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: VisualSystem.glassBorderWidth
                )
            }
        )
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard isPromptFocused, !isRunning else { return event }
                if event.keyCode == 126 { // Up arrow
                    onHistoryUp()
                    return nil
                } else if event.keyCode == 125 { // Down arrow
                    onHistoryDown()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
        }
    }
}

private struct ToolbarIconLabel: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: VisualSystem.toolbarGlyphSize, weight: .medium))
            .foregroundStyle(.primary.opacity(0.70))
            .frame(width: VisualSystem.toolbarButtonSize, height: VisualSystem.toolbarButtonSize)
            .background(
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.primary.opacity(0.03), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.03)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: VisualSystem.glassBorderWidth
                            )
                    )
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

struct ToolbarStatusStrip: View {
    @Environment(\.colorScheme) private var colorScheme
    let deviceCount: Int
    let readyCount: Int
    let modelName: String
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 6) {
            statusChip(
                icon: "iphone.gen3",
                text: "\(readyCount)/\(deviceCount)",
                tint: readyCount > 0 ? .green : .secondary
            )

            chipSeparator

            statusChip(
                icon: "cpu",
                text: modelDisplayName,
                tint: .secondary
            )

            chipSeparator

            statusChip(
                icon: isRunning ? "bolt.fill" : "checkmark.circle",
                text: isRunning ? "Running" : "Idle",
                tint: isRunning ? .orange : .green
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(colorScheme == .dark
                    ? Color.white.opacity(0.06)
                    : Color.black.opacity(0.04))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.08)
                        : Color.black.opacity(0.06),
                    lineWidth: 0.5
                )
        )
    }

    private var modelDisplayName: String {
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "No model" }
        if name.count > 18 {
            return String(name.prefix(16)) + "…"
        }
        return name
    }

    private var chipSeparator: some View {
        Text("·")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.primary.opacity(0.20))
    }

    private func statusChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(tint.opacity(0.80))

            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.55))
        }
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
        window.styleMask.remove(.resizable)
        window.styleMask.remove(.unifiedTitleAndToolbar)
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false 
        window.level = .floating

        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = 24
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.masksToBounds = true
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
            frameView.layer?.borderWidth = 0
        }

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 24
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        if let hostingView = window.contentView?.subviews.first {
            hostingView.layoutSubtreeIfNeeded()
            let fittingSize = hostingView.fittingSize

            if fittingSize.width > 0, fittingSize.height > 0 {
                let targetSize = NSSize(
                    width: ceil(fittingSize.width), height: ceil(fittingSize.height))
                if abs(window.contentLayoutRect.width - targetSize.width) > 1
                    || abs(window.contentLayoutRect.height - targetSize.height) > 1
                {
                    window.setContentSize(targetSize)
                }
            }
        }

        window.makeKeyAndOrderFront(nil)
        position(window: window)

        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
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
            min(
                visibleFrame.midX - (window.frame.width / 2),
                visibleFrame.maxX - window.frame.width - 10)
        )
        let targetY = (dockIsBottom ? visibleFrame.minY : screenFrame.minY) + 10

        window.setFrameOrigin(NSPoint(x: round(targetX), y: round(targetY)))
    }
}


struct GeneralGlassy: NSViewRepresentable {
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
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.titled)
        window.styleMask.insert(.resizable)
        window.styleMask.remove(.unifiedTitleAndToolbar)
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false 
        window.level = .normal
    

        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = 24
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.masksToBounds = true
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
            frameView.layer?.borderWidth = 0
        }

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 24
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        if let hostingView = window.contentView?.subviews.first {
            hostingView.layoutSubtreeIfNeeded()
            let fittingSize = hostingView.fittingSize

            if fittingSize.width > 0, fittingSize.height > 0 {
                let targetSize = NSSize(
                    width: ceil(fittingSize.width), height: ceil(fittingSize.height))
                if abs(window.contentLayoutRect.width - targetSize.width) > 1
                    || abs(window.contentLayoutRect.height - targetSize.height) > 1
                {
                    window.setContentSize(targetSize)
                }
            }
        }

        window.makeKeyAndOrderFront(nil)
        position(window: window)

        [
            NSWindow.ButtonType.miniaturizeButton,
            .zoomButton,
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
            min(
                visibleFrame.midX - (window.frame.width / 2),
                visibleFrame.maxX - window.frame.width - 10)
        )
        let targetY = (dockIsBottom ? visibleFrame.minY : screenFrame.minY) + 10

        window.setFrameOrigin(NSPoint(x: round(targetX), y: round(targetY)))
    }
}

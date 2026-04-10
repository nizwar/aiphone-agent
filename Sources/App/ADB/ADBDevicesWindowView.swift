import SwiftUI
import AppKit

struct ADBDeviceSnapshot: Identifiable, Equatable, Sendable {
    var id: String { info.id }

    let info: ADBDeviceInfo
    var screenshotData: Data?
    var currentApp: String?
    var batteryLevel: Int?
    var wifiStatus: String?
    var dataStatus: String?
    var isSensitive: Bool
    var isLoadingPreview: Bool
}

@MainActor
final class ADBDevicesStore: ObservableObject {
    @Published private(set) var snapshots: [ADBDeviceSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var statusMessage: String = "Press Refresh to load connected devices."
    @Published private(set) var detailDeviceID: String?
    @Published private(set) var deviceDetails: [String: ADBDeviceDetails] = [:]

    private let provider: any ADBProviding
    private var hasLoadedOnce = false

    init(provider: any ADBProviding = ADBProvider.shared) {
        self.provider = provider
    }

    var visibleSnapshots: [ADBDeviceSnapshot] {
        snapshots
    }

    var selectedDetailSnapshot: ADBDeviceSnapshot? {
        guard let detailDeviceID else { return nil }
        return snapshots.first(where: { $0.info.deviceID == detailDeviceID })
    }

    func selectDetailDevice(_ deviceID: String) {
        detailDeviceID = deviceID
        refreshDetails(for: deviceID)
    }

    func clearDetailDevice() {
        detailDeviceID = nil
    }

    func details(for deviceID: String) -> ADBDeviceDetails? {
        deviceDetails[deviceID]
    }

    func refreshIfNeeded() {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }

        isRefreshing = true
        statusMessage = "Refreshing ADB devices…"
        let provider = self.provider

        Task { [weak self] in
            guard let self else { return }

            let devices = await Task.detached(priority: .userInitiated) {
                provider.listDevices().sorted { lhs, rhs in
                    if lhs.isAvailable != rhs.isAvailable {
                        return lhs.isAvailable && !rhs.isAvailable
                    }
                    return lhs.deviceID.localizedCompare(rhs.deviceID) == .orderedAscending
                }
            }.value

            let placeholders = devices.map { device in
                ADBDeviceSnapshot(
                    info: device,
                    screenshotData: nil,
                    currentApp: nil,
                    batteryLevel: nil,
                    wifiStatus: nil,
                    dataStatus: nil,
                    isSensitive: false,
                    isLoadingPreview: device.isAvailable
                )
            }

            if let detailDeviceID, !devices.contains(where: { $0.deviceID == detailDeviceID }) {
                self.detailDeviceID = nil
                self.deviceDetails.removeValue(forKey: detailDeviceID)
            }

            snapshots = placeholders
            lastUpdated = Date()

            if devices.isEmpty {
                statusMessage = "No ADB devices connected."
                isRefreshing = false
                return
            }

            let availableCount = devices.filter { $0.isAvailable }.count
            statusMessage = availableCount == 0
                ? "Found \(devices.count) device\(devices.count == 1 ? "" : "s") · no ready devices"
                : "Found \(devices.count) device\(devices.count == 1 ? "" : "s") · loading previews…"

            guard availableCount > 0 else {
                isRefreshing = false
                return
            }

            await withTaskGroup(of: ADBDeviceSnapshot.self) { group in
                for device in devices where device.isAvailable {
                    group.addTask {
                        Self.loadSnapshot(for: device, using: provider, includeScreenshot: true)
                    }
                }

                for await snapshot in group {
                    self.updateSnapshot(snapshot)
                }
            }

            isRefreshing = false
            lastUpdated = Date()

            let previewCount = snapshots.filter { $0.screenshotData != nil }.count
            statusMessage = "Found \(snapshots.count) device\(snapshots.count == 1 ? "" : "s") · \(availableCount) ready · \(previewCount) previews"
        }
    }

    func refreshPreview(for deviceID: String) {
        guard let index = snapshots.firstIndex(where: { $0.info.deviceID == deviceID }) else { return }
        guard snapshots[index].info.isAvailable, !snapshots[index].isLoadingPreview else { return }

        snapshots[index].isLoadingPreview = true
        let device = snapshots[index].info
        let provider = self.provider

        Task { [weak self] in
            guard let self else { return }

            let refreshedSnapshot = await Task.detached(priority: .userInitiated) {
                Self.loadSnapshot(for: device, using: provider, includeScreenshot: true)
            }.value

            updateSnapshot(refreshedSnapshot)
            lastUpdated = Date()
        }
    }

    func refreshDetails(for deviceID: String) {
        let provider = self.provider

        Task { [weak self] in
            guard let self else { return }
            let details = await Task.detached(priority: .userInitiated) {
                provider.getDeviceDetails(deviceID: deviceID)
            }.value
            self.deviceDetails[deviceID] = details
        }
    }

    private func updateSnapshot(_ snapshot: ADBDeviceSnapshot) {
        guard let index = snapshots.firstIndex(where: { $0.id == snapshot.id }) else { return }
        snapshots[index] = snapshot
    }

    private nonisolated static func loadSnapshot(
        for device: ADBDeviceInfo,
        using provider: any ADBProviding,
        includeScreenshot: Bool
    ) -> ADBDeviceSnapshot {
        let screenshot = includeScreenshot ? (try? provider.getScreenshot(deviceID: device.deviceID, includeBase64: false)) : nil
        let screenshotData = (screenshot?.imageData.isEmpty == false && !(screenshot?.isSensitive ?? false)) ? screenshot?.imageData : nil
        let runtimeStatus = provider.getDeviceRuntimeStatus(deviceID: device.deviceID)

        return ADBDeviceSnapshot(
            info: device,
            screenshotData: screenshotData,
            currentApp: runtimeStatus.currentApp,
            batteryLevel: runtimeStatus.batteryLevel,
            wifiStatus: runtimeStatus.wifiStatus,
            dataStatus: runtimeStatus.dataStatus,
            isSensitive: screenshot?.isSensitive ?? false,
            isLoadingPreview: false
        )
    }
}

struct ADBDevicesWindowView: View {
    @EnvironmentObject private var store: ADBDevicesStore
    @EnvironmentObject private var screenMirrorStore: ScreenMirrorStore
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 320), spacing: 16, alignment: .top)
    ]

    private var glassOverlay: some ShapeStyle {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.white.opacity(0.50)
    }

    private var glassBorder: some ShapeStyle {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Devices")
                        .font(.system(size: 20, weight: .semibold))

                    Text(store.statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    if let lastUpdated = store.lastUpdated {
                        Text(lastUpdated.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        store.refresh()
                    } label: {
                        Label(store.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule()
                                    .stroke(Color.accentColor.opacity(0.20), lineWidth: 0.5)
                            )
                    )
                    .disabled(store.isRefreshing)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Content
            Group {
                if store.visibleSnapshots.isEmpty {
                    EmptyDevicesState(isRefreshing: store.isRefreshing)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(store.visibleSnapshots) { snapshot in
                                DeviceCardView(
                                    snapshot: snapshot,
                                    onOpen: {
                                        store.selectDetailDevice(snapshot.info.deviceID)
                                    },
                                    onRefresh: {
                                        store.refreshPreview(for: snapshot.info.deviceID)
                                        store.refreshDetails(for: snapshot.info.deviceID)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 700, minHeight: 580)
        .overlay {
            if store.detailDeviceID != nil {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture {
                            store.clearDetailDevice()
                        }

                    ADBDeviceDetailDialogView(onDismiss: {
                        store.clearDetailDevice()
                    }) 
                    .frame(
                        maxWidth: (NSScreen.main?.visibleFrame.width ?? 1200) * 0.60,
                        maxHeight: (NSScreen.main?.visibleFrame.height ?? 800) * 0.60
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThickMaterial)
                            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.detailDeviceID != nil)
        .background(
            ZStack {
                VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
            }
        )
        .onAppear {
            store.refreshIfNeeded()
        }
    }


}

private struct EmptyDevicesState: View {
    let isRefreshing: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(.quaternary)
            }

            VStack(spacing: 4) {
                Text(isRefreshing ? "Loading devices…" : "No devices detected")
                    .font(.system(size: 14, weight: .medium))

                Text("Connect an Android device with ADB enabled, then click Refresh.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 300)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.40))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                            lineWidth: 0.5
                        )
                )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeviceCardView: View {
    @EnvironmentObject private var profileStore: ADBDeviceProfileStore
    @Environment(\.colorScheme) private var colorScheme

    let snapshot: ADBDeviceSnapshot
    let onOpen: () -> Void
    let onRefresh: () -> Void

    private var previewImage: NSImage? {
        guard let data = snapshot.screenshotData, !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    private var connectionLabel: String {
        switch snapshot.info.connectionType {
        case .usb:
            return "USB"
        case .wifi:
            return "Wi-Fi"
        case .remote:
            return "Remote"
        }
    }

    private var connectionIcon: String {
        switch snapshot.info.connectionType {
        case .usb:
            return "cable.connector"
        case .wifi:
            return "wifi"
        case .remote:
            return "dot.radiowaves.left.and.right"
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
        case ..<15:
            return "battery.25"
        case ..<50:
            return "battery.50"
        case ..<80:
            return "battery.75"
        default:
            return "battery.100"
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

    private var cardFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.55)
    }

    private var cardBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    private var cardHighlight: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.40)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Preview area
            Button(action: onOpen) {
                ZStack {
                    Color.clear

                    VStack {
                        Spacer(minLength: 0)

                        ZStack(alignment: .top) {
                            // Phone body
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.black)
                                .frame(width: 140, height: 278)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(
                                            LinearGradient(
                                                colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 0.5
                                        )
                                )
                                .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 8)

                            // Dynamic island
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 42, height: 12)
                                .padding(.top, 8)

                            // Screen content
                            Group {
                                if let previewImage {
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
                                        Image(systemName: snapshot.info.isAvailable ? "iphone.rearcamera" : "iphone.slash")
                                            .font(.system(size: 22, weight: .ultraLight))
                                            .foregroundStyle(.white.opacity(0.20))

                                        Text(snapshot.info.isAvailable ? "No preview" : "Unavailable")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.25))
                                    }
                                }
                            }
                            .frame(width: 124, height: 254)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(.top, 14)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 300)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    Text(personaEmoji)
                        .font(.system(size: 9))
                    Text(personaLabel)
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .stroke(cardBorder, lineWidth: 0.5)
                        )
                )
                .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Circle()
                                        .stroke(cardBorder, lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!snapshot.info.isAvailable || snapshot.isLoadingPreview)
                .padding(10)
            }

            // Separator
            Rectangle()
                .fill(cardBorder)
                .frame(height: 0.5)
                .padding(.horizontal, 14)

            // Info area
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.info.model ?? "Android Device")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        Text(snapshot.info.deviceID)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    DeviceStatusBadge(text: statusText, color: statusColor)
                }

                // Meta row
                HStack(spacing: 5) {
                    DeviceMetaPill(systemImage: connectionIcon, text: connectionLabel)
                    DeviceMetaPill(systemImage: batteryIcon, text: batteryText)
                    DeviceMetaPill(systemImage: wifiIcon, text: wifiText)

                    if snapshot.isSensitive {
                        DeviceMetaPill(systemImage: "eye.slash", text: "Protected")
                    }
                }

                if let currentApp = snapshot.currentApp, !currentApp.isEmpty {
                    Text(currentApp)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(cardFill)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [cardHighlight, Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                colorScheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.80),
                                colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.08), radius: 12, x: 0, y: 6)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.08 : 0.03), radius: 2, x: 0, y: 1)
    }
}

struct DeviceStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)

            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.10))
                .overlay(
                    Capsule()
                        .stroke(color.opacity(0.15), lineWidth: 0.5)
                )
        )
    }
}

struct DeviceMetaPill: View {
    let systemImage: String
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    .overlay(
                        Capsule()
                            .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 0.5)
                    )
            )
    }
}

struct ScreenRectReporter: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
        DispatchQueue.main.async {
            nsView.installObserversIfNeeded()
            nsView.reportFrameIfNeeded()
        }
    }

    final class TrackingView: NSView {
        var onChange: ((CGRect) -> Void)?
        private var windowObservers: [NSObjectProtocol] = []
        private weak var observedClipView: NSClipView?

        deinit {
            removeObservers()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow !== window {
                removeObservers()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installObserversIfNeeded()
            reportFrameIfNeeded()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            installObserversIfNeeded()
            reportFrameIfNeeded()
        }

        override func layout() {
            super.layout()
            reportFrameIfNeeded()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            reportFrameIfNeeded()
        }

        func installObserversIfNeeded() {
            guard windowObservers.isEmpty, let window else { return }

            let center = NotificationCenter.default
            windowObservers.append(
                center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrameIfNeeded()
                }
            )
            windowObservers.append(
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrameIfNeeded()
                }
            )

            if let clipView = enclosingScrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                observedClipView = clipView
                windowObservers.append(
                    center.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main) { [weak self] _ in
                        self?.reportFrameIfNeeded()
                    }
                )
            }
        }

        func reportFrameIfNeeded() {
            guard let window else { return }
            let rectInWindow = convert(bounds, to: nil)
            let rectOnScreen = window.convertToScreen(rectInWindow)
            onChange?(rectOnScreen)
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            for observer in windowObservers {
                center.removeObserver(observer)
            }
            windowObservers.removeAll()
            observedClipView?.postsBoundsChangedNotifications = false
            observedClipView = nil
        }
    }
}

import SwiftUI
import AppKit

struct ADBDeviceSnapshot: Identifiable, Sendable {
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
        let screenshotData = (screenshot?.pngData.isEmpty == false && !(screenshot?.isSensitive ?? false)) ? screenshot?.pngData : nil
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
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: ADBDevicesStore

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 16, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Devices")
                        .font(.title2.weight(.semibold))

                    Text("ADB-connected devices with live screenshots.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Text(store.statusMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Button(store.isRefreshing ? "Refreshing..." : "Refresh") {
                        store.refresh()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isRefreshing)

                    if let lastUpdated = store.lastUpdated {
                        Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

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
                                        openWindow(id: "device-detail")
                                    },
                                    onRefresh: {
                                        store.refreshPreview(for: snapshot.info.deviceID)
                                        store.refreshDetails(for: snapshot.info.deviceID)
                                    }
                                )
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.refreshIfNeeded()
        }
    }
}

private struct EmptyDevicesState: View {
    let isRefreshing: Bool

    var body: some View {
        VStack(spacing: 12) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(isRefreshing ? "Loading devices..." : "No devices detected")
                .font(.headline)

            Text("Connect an Android device with ADB enabled, then click Refresh.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct DeviceCardView: View {
    @EnvironmentObject private var profileStore: ADBDeviceProfileStore

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Button(action: onOpen) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))

                        VStack {
                            Spacer(minLength: 0)

                            ZStack(alignment: .top) {
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.black.opacity(0.96), Color(nsColor: .darkGray)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: 150, height: 292)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                                            .stroke(Color.white.opacity(0.12), lineWidth: 1.2)
                                    )
                                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)

                                Capsule()
                                    .fill(Color.black.opacity(0.88))
                                    .frame(width: 54, height: 16)
                                    .padding(.top, 10)

                                Group {
                                    if let previewImage {
                                        Image(nsImage: previewImage)
                                            .resizable()
                                            .scaledToFit()
                                    } else if snapshot.isLoadingPreview {
                                        VStack(spacing: 8) {
                                            ProgressView()
                                                .controlSize(.regular)

                                            Text("Loading preview…")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        VStack(spacing: 8) {
                                            Image(systemName: snapshot.info.isAvailable ? "iphone.rearcamera" : "iphone.slash")
                                                .font(.system(size: 28, weight: .semibold))
                                                .foregroundStyle(.secondary)

                                            Text(snapshot.info.isAvailable ? "Screenshot unavailable" : "Device unavailable")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .frame(width: 130, height: 266)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .padding(.top, 18)
                            }

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(height: 320)
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text(personaEmoji)
                    Text(personaLabel)
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    Button(action: onRefresh) {
                        Label(snapshot.isLoadingPreview ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!snapshot.info.isAvailable || snapshot.isLoadingPreview)

                }
                .padding(10)
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.info.model ?? "Android Device")
                        .font(.headline)
                        .lineLimit(1)

                    Text(snapshot.info.deviceID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                DeviceStatusBadge(text: statusText, color: statusColor)
            }

            HStack(spacing: 8) {
                DeviceMetaPill(systemImage: connectionIcon, text: connectionLabel)
                DeviceMetaPill(systemImage: batteryIcon, text: batteryText)

                if snapshot.isSensitive {
                    DeviceMetaPill(systemImage: "eye.slash", text: "Protected")
                }
            }

            HStack(spacing: 8) {
                DeviceMetaPill(systemImage: wifiIcon, text: wifiText)
                DeviceMetaPill(systemImage: "cellularbars", text: dataText)
            }

            if let currentApp = snapshot.currentApp, !currentApp.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current App")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(currentApp)
                        .font(.system(size: 12))
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

private struct DeviceStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }
}

private struct DeviceMetaPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
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

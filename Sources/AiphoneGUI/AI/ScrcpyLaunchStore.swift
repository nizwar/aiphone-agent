import Foundation
import AppKit
import SwiftUI
import ApplicationServices

private enum ScrcpyLaunchError: LocalizedError {
    case unavailable(String)
    case noReadyDevices
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            return message
        case .noReadyDevices:
            return "No ready devices found for scrcpy. Refresh the device list and try again."
        case let .launchFailed(message):
            return message
        }
    }
}

private final class ActiveScrcpySession {
    let deviceID: String
    let slotIndex: Int
    let processID: pid_t
    let process: Process
    var sidecarPanel: NSPanel?
    var syncTimer: Timer?
    var anchorRectOnScreen: CGRect?
    var preferredWindowSize: CGSize?
    var isPreviewAnchoredStyle: Bool

    init(
        deviceID: String,
        slotIndex: Int,
        processID: pid_t,
        process: Process,
        anchorRectOnScreen: CGRect? = nil,
        preferredWindowSize: CGSize? = nil,
        isPreviewAnchoredStyle: Bool = false
    ) {
        self.deviceID = deviceID
        self.slotIndex = slotIndex
        self.processID = processID
        self.process = process
        self.anchorRectOnScreen = anchorRectOnScreen
        self.preferredWindowSize = preferredWindowSize
        self.isPreviewAnchoredStyle = isPreviewAnchoredStyle
    }

    func invalidateSidecar() {
        syncTimer?.invalidate()
        syncTimer = nil
        sidecarPanel?.orderOut(nil)
        sidecarPanel?.close()
        sidecarPanel = nil
    }
}

private struct ScrcpyWindowLayout {
    let position: CGPoint
    let size: CGSize
}

@MainActor
final class ScrcpyLaunchStore: ObservableObject {
    static let shared = ScrcpyLaunchStore()

    @Published private(set) var isScrcpyAvailable = false
    @Published private(set) var availabilityMessage: String = "Checking scrcpy…"

    private var refreshTask: Task<Void, Never>?
    private var activeProcesses: [UUID: ActiveScrcpySession] = [:]
    private var deviceSlotAssignments: [String: Int] = [:]
    private let provider: any ADBProviding = ADBProvider.shared
    private var hasPromptedForAccessibilityTrust = false

    func terminateAll() {
        let sessions = Array(activeProcesses.values)
        guard !sessions.isEmpty else { return }

        for session in sessions {
            session.invalidateSidecar()
            if session.process.isRunning {
                session.process.terminate()
                session.process.waitUntilExit()
            }
        }

        activeProcesses.removeAll()
        deviceSlotAssignments.removeAll()
        availabilityMessage = "Closed \(sessions.count) scrcpy session(s)."
    }

    func terminateSessions(for deviceID: String) {
        let matchingIdentifiers = activeProcesses.compactMap { identifier, session in
            session.deviceID == deviceID ? identifier : nil
        }
        guard !matchingIdentifiers.isEmpty else { return }

        for identifier in matchingIdentifiers {
            terminateSession(identifier)
        }

        availabilityMessage = "Closed scrcpy for \(deviceID)."
    }

    func refreshAvailability() {
        refreshTask?.cancel()
        let configuredPath = ToolPathResolver.scrcpyPath()

        refreshTask = Task { [weak self] in
            guard let self else { return }

            let result = await Task.detached(priority: .utility) {
                Self.validateAvailability(for: configuredPath)
            }.value

            guard !Task.isCancelled else { return }
            self.isScrcpyAvailable = result.isAvailable
            self.availabilityMessage = result.message
        }
    }

    func updateAnchor(for deviceID: String, anchorRectOnScreen: CGRect) {
        guard !anchorRectOnScreen.isEmpty else { return }

        for (identifier, session) in activeProcesses where session.deviceID == deviceID {
            session.anchorRectOnScreen = anchorRectOnScreen
            session.isPreviewAnchoredStyle = true

            let fallbackLayout = ScrcpyWindowLayout(
                position: scrcpyWindowFrame(for: session.processID)?.origin ?? anchorRectOnScreen.origin,
                size: scrcpyWindowFrame(for: session.processID)?.size ?? anchorRectOnScreen.size
            )
            session.preferredWindowSize = anchoredWindowLayout(for: anchorRectOnScreen, fallback: fallbackLayout).size

            ensureSyncTimer(for: identifier)
            syncPreviewAnchoredWindow(for: identifier)
        }
    }

    func launch(
        device: ADBDeviceInfo,
        settings: AISettingsStore,
        profile: ADBDeviceProfile,
        preferredSlotIndex: Int? = nil,
        totalWindowCount: Int? = nil,
        anchorRectOnScreen: CGRect? = nil,
        usePreviewAnchoredStyle: Bool = false
    ) throws {
        let validation = Self.validateAvailability(for: ToolPathResolver.scrcpyPath())
        guard validation.isAvailable else {
            isScrcpyAvailable = false
            availabilityMessage = validation.message
            throw ScrcpyLaunchError.unavailable(validation.message)
        }

        let slotIndex = assignSlot(for: device.deviceID, preferredIndex: preferredSlotIndex)
        let activeDeviceCount = Set(activeProcesses.values.map(\.deviceID)).count
        let resolvedTotalWindowCount = max(totalWindowCount ?? (activeDeviceCount + 1), slotIndex + 1, 1)
        let fallbackLayout = windowLayout(forSlot: slotIndex, totalCount: resolvedTotalWindowCount)

        let layout: ScrcpyWindowLayout
        if let anchorRectOnScreen, !anchorRectOnScreen.isEmpty {
            layout = anchoredWindowLayout(for: anchorRectOnScreen, fallback: fallbackLayout)
        } else {
            layout = fallbackLayout
        }

        if usePreviewAnchoredStyle,
           let existingEntry = activeProcesses.first(where: { $0.value.deviceID == device.deviceID && $0.value.process.isRunning }) {
            let identifier = existingEntry.key
            let session = existingEntry.value
            session.anchorRectOnScreen = anchorRectOnScreen
            session.preferredWindowSize = layout.size
            session.isPreviewAnchoredStyle = true
            ensureSyncTimer(for: identifier)
            syncPreviewAnchoredWindow(for: identifier)
            isScrcpyAvailable = true
            availabilityMessage = "Repositioned preview-aligned scrcpy for \(device.model ?? device.deviceID)."
            return
        }

        let command = settings.scrcpyLaunchConfiguration(
            deviceID: device.deviceID,
            profile: profile,
            windowPosition: layout.position,
            windowSize: layout.size,
            forceAlwaysOnTop: usePreviewAnchoredStyle,
            forceWindowBorderless: usePreviewAnchoredStyle
        )
        let identifier = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let session = self.activeProcesses.removeValue(forKey: identifier)
                session?.invalidateSidecar()

                if let session,
                   !self.activeProcesses.values.contains(where: { $0.deviceID == session.deviceID }) {
                    self.deviceSlotAssignments.removeValue(forKey: session.deviceID)
                }
            }
        }

        do {
            try process.run()
            let processID = process.processIdentifier
            activeProcesses[identifier] = ActiveScrcpySession(
                deviceID: device.deviceID,
                slotIndex: slotIndex,
                processID: processID,
                process: process,
                anchorRectOnScreen: anchorRectOnScreen,
                preferredWindowSize: layout.size,
                isPreviewAnchoredStyle: usePreviewAnchoredStyle
            )
            if usePreviewAnchoredStyle {
                ensureSyncTimer(for: identifier)
                syncPreviewAnchoredWindow(for: identifier)
            }
            // attachControlPanel(for: identifier, device: device, layout: layout)
            isScrcpyAvailable = true
            availabilityMessage = usePreviewAnchoredStyle
                ? "Opened preview-aligned scrcpy for \(device.model ?? device.deviceID) (pid \(processID))."
                : "Opened scrcpy for \(device.model ?? device.deviceID) (pid \(processID))."
        } catch {
            if deviceSlotAssignments[device.deviceID] == slotIndex,
               !activeProcesses.values.contains(where: { $0.deviceID == device.deviceID }) {
                deviceSlotAssignments.removeValue(forKey: device.deviceID)
            }
            throw ScrcpyLaunchError.launchFailed("Failed to open scrcpy for \(device.model ?? device.deviceID): \(error.localizedDescription)")
        }
    }

    func launchAll(devices: [ADBDeviceInfo], settings: AISettingsStore, profileStore: ADBDeviceProfileStore) throws {
        let readyDevices = devices
            .filter { $0.isAvailable }
            .sorted { lhs, rhs in
                lhs.deviceID.localizedCompare(rhs.deviceID) == .orderedAscending
            }
        guard !readyDevices.isEmpty else {
            throw ScrcpyLaunchError.noReadyDevices
        }

        var openedCount = 0
        var failures: [String] = []

        for (index, device) in readyDevices.enumerated() {
            do {
                try launch(
                    device: device,
                    settings: settings,
                    profile: profileStore.profile(for: device.deviceID),
                    preferredSlotIndex: index,
                    totalWindowCount: readyDevices.count
                )
                openedCount += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        if openedCount == 0 {
            throw ScrcpyLaunchError.launchFailed(failures.joined(separator: "\n"))
        }

        if !failures.isEmpty {
            availabilityMessage = "Opened scrcpy for \(openedCount) device(s), with some launch issues."
        } else {
            availabilityMessage = "Opened scrcpy for \(openedCount) device(s) in a sorted grid."
        }
    }

    private func attachControlPanel(for identifier: UUID, device: ADBDeviceInfo, layout: ScrcpyWindowLayout) {
        guard let session = activeProcesses[identifier] else { return }

        let panel = makeControlPanel(
            for: identifier,
            deviceLabel: device.model ?? device.deviceID,
            fallbackOrigin: CGPoint(
                x: layout.position.x - 140,
                y: layout.position.y + max(layout.size.height - 220, 0)
            )
        )

        session.sidecarPanel = panel
        ensureSyncTimer(for: identifier)
        syncSession(for: identifier)
        panel.orderFrontRegardless()
    }

    private func ensureSyncTimer(for identifier: UUID) {
        guard let session = activeProcesses[identifier], session.syncTimer == nil else { return }

        session.syncTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.syncSession(for: identifier)
            }
        }

        if let timer = session.syncTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func syncSession(for identifier: UUID) {
        guard let session = activeProcesses[identifier] else { return }

        if session.isPreviewAnchoredStyle {
            syncPreviewAnchoredWindow(for: identifier)
        }

        if session.sidecarPanel != nil {
            syncControlPanel(for: identifier)
        }
    }

    private func makeControlPanel(for identifier: UUID, deviceLabel: String, fallbackOrigin: CGPoint) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: fallbackOrigin.x, y: fallbackOrigin.y, width: 128, height: 220),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(
            rootView: ScrcpyControlPanelView(
                deviceLabel: deviceLabel,
                onHome: { [weak self] in self?.sendHome(for: identifier) },
                onBack: { [weak self] in self?.sendBack(for: identifier) },
                onApps: { [weak self] in self?.sendAppSwitcher(for: identifier) },
                onClose: { [weak self] in self?.terminateSession(identifier) }
            )
        )
        return panel
    }

    private func syncControlPanel(for identifier: UUID) {
        guard let session = activeProcesses[identifier], let panel = session.sidecarPanel else { return }
        guard let scrcpyFrame = scrcpyWindowFrame(for: session.processID) else { return }

        let desiredFrame = sidecarFrame(attachedTo: scrcpyFrame, currentSize: panel.frame.size)
        if panel.frame.origin != desiredFrame.origin {
            panel.setFrame(desiredFrame, display: true)
        }
    }

    private func syncPreviewAnchoredWindow(for identifier: UUID) {
        guard let session = activeProcesses[identifier], session.isPreviewAnchoredStyle else { return }
        guard let anchorRect = session.anchorRectOnScreen, !anchorRect.isEmpty else { return }

        let currentFrame = scrcpyWindowFrame(for: session.processID)
        let fallbackLayout = ScrcpyWindowLayout(
            position: currentFrame?.origin ?? anchorRect.origin,
            size: currentFrame?.size ?? session.preferredWindowSize ?? anchorRect.size
        )
        let desiredLayout = anchoredWindowLayout(for: anchorRect, fallback: fallbackLayout)
        let targetSize = desiredLayout.size
        session.preferredWindowSize = targetSize

        let desiredFrame = CGRect(origin: desiredLayout.position, size: targetSize)
        if let currentFrame {
            let delta = abs(currentFrame.minX - desiredFrame.minX)
                + abs(currentFrame.minY - desiredFrame.minY)
                + abs(currentFrame.width - desiredFrame.width)
                + abs(currentFrame.height - desiredFrame.height)
            if delta < 2 { return }
        }

        if !moveScrcpyWindow(for: session.processID, to: desiredFrame.origin, size: desiredFrame.size), !hasPromptedForAccessibilityTrust {
            hasPromptedForAccessibilityTrust = true
            _ = AXIsProcessTrustedWithOptions([
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary)
            availabilityMessage = "Enable Accessibility for AIPhone so floated scrcpy windows can follow the Devices window."
        }
    }

    private func sidecarFrame(attachedTo scrcpyFrame: CGRect, currentSize: CGSize) -> CGRect {
        let width = currentSize.width == 0 ? 128 : currentSize.width
        let height = currentSize.height == 0 ? 220 : currentSize.height
        let x = scrcpyFrame.minX - width - 12
        let y = scrcpyFrame.maxY - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func scrcpyWindowFrame(for processID: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let matchingFrames = windowInfoList.compactMap { info -> CGRect? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == processID else {
                return nil
            }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { return nil }
            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return nil
            }

            return appKitFrame(from: bounds)
        }

        return matchingFrames.max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
    }

    private func appKitFrame(from cgBounds: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(cgBounds) }) ?? NSScreen.main else {
            return cgBounds
        }

        let convertedY = screen.frame.maxY - cgBounds.origin.y - cgBounds.height
        return CGRect(x: cgBounds.origin.x, y: convertedY, width: cgBounds.width, height: cgBounds.height)
    }

    private func moveScrcpyWindow(for processID: pid_t, to origin: CGPoint, size: CGSize) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let appElement = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        let fetchError = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard fetchError == .success,
              let windows = value as? [AXUIElement],
              let windowElement = windows.first else {
            return false
        }

        let targetScreen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(CGRect(origin: origin, size: size)) })
            ?? NSScreen.main
        var upperLeft = origin
        if let targetScreen {
            upperLeft.y = targetScreen.frame.maxY - origin.y - size.height
        }

        var movePoint = upperLeft
        guard let positionValue = AXValueCreate(.cgPoint, &movePoint) else { return false }
        let positionError = AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, positionValue)

        var resizeSize = size
        let sizeError: AXError
        if let sizeValue = AXValueCreate(.cgSize, &resizeSize) {
            sizeError = AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)
        } else {
            sizeError = .success
        }

        return positionError == .success && (sizeError == .success || sizeError == .attributeUnsupported)
    }

    private func sendHome(for identifier: UUID) {
        guard let session = activeProcesses[identifier] else { return }
        try? provider.home(deviceID: session.deviceID, delay: nil)
    }

    private func sendBack(for identifier: UUID) {
        guard let session = activeProcesses[identifier] else { return }
        try? provider.back(deviceID: session.deviceID, delay: nil)
    }

    private func sendAppSwitcher(for identifier: UUID) {
        guard let session = activeProcesses[identifier] else { return }
        _ = try? provider.shell("input keyevent KEYCODE_APP_SWITCH", deviceID: session.deviceID)
    }

    private func terminateSession(_ identifier: UUID) {
        guard let session = activeProcesses[identifier] else { return }
        session.invalidateSidecar()
        if session.process.isRunning {
            session.process.terminate()
        }
    }

    private func assignSlot(for deviceID: String, preferredIndex: Int? = nil) -> Int {
        if let existing = deviceSlotAssignments[deviceID] {
            return existing
        }

        let usedSlots = Set(activeProcesses.values.map(\.slotIndex))

        if let preferredIndex, !usedSlots.contains(preferredIndex) {
            deviceSlotAssignments[deviceID] = preferredIndex
            return preferredIndex
        }

        var slotIndex = 0
        while usedSlots.contains(slotIndex) {
            slotIndex += 1
        }

        deviceSlotAssignments[deviceID] = slotIndex
        return slotIndex
    }

    private func windowLayout(forSlot slotIndex: Int, totalCount: Int) -> ScrcpyWindowLayout {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let safeCount = max(totalCount, 1)
        let outerPadding: CGFloat = 24
        let spacing: CGFloat = safeCount > 20 ? 8 : (safeCount > 8 ? 12 : 18)
        let portraitAspectRatio: CGFloat = 9 / 19.5

        let usableWidth = max(visibleFrame.width - (outerPadding * 2), 120)
        let usableHeight = max(visibleFrame.height - (outerPadding * 2), 120)

        var bestColumns = 1
        var bestRows = safeCount
        var bestCellWidth = max(usableWidth, 120)
        var bestCellHeight = max(usableHeight, 220)
        var bestScore = -CGFloat.greatestFiniteMagnitude

        for columns in 1...safeCount {
            let rows = Int(ceil(Double(safeCount) / Double(columns)))
            let maxCellWidth = (usableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let maxCellHeight = (usableHeight - CGFloat(rows - 1) * spacing) / CGFloat(rows)

            guard maxCellWidth > 40, maxCellHeight > 60 else { continue }

            let cellWidth = floor(min(maxCellWidth, maxCellHeight * portraitAspectRatio))
            let cellHeight = floor(min(maxCellHeight, cellWidth / portraitAspectRatio))

            guard cellWidth > 0, cellHeight > 0 else { continue }

            let areaScore = cellWidth * cellHeight
            let balancePenalty = abs(CGFloat(columns - rows)) * 140
            let score = areaScore - balancePenalty

            if score > bestScore {
                bestScore = score
                bestColumns = columns
                bestRows = rows
                bestCellWidth = cellWidth
                bestCellHeight = cellHeight
            }
        }

        let contentWidth = CGFloat(bestColumns) * bestCellWidth + CGFloat(bestColumns - 1) * spacing
        let contentHeight = CGFloat(bestRows) * bestCellHeight + CGFloat(bestRows - 1) * spacing

        let centeredOriginX = visibleFrame.minX + max(outerPadding, (visibleFrame.width - contentWidth) / 2)
        let centeredOriginY = max(outerPadding, (visibleFrame.height - contentHeight) / 2)

        let row = slotIndex / bestColumns
        let column = slotIndex % bestColumns

        return ScrcpyWindowLayout(
            position: CGPoint(
                x: centeredOriginX + CGFloat(column) * (bestCellWidth + spacing),
                y: centeredOriginY + CGFloat(row) * (bestCellHeight + spacing)
            ),
            size: CGSize(width: bestCellWidth, height: bestCellHeight)
        )
    }

    private func anchoredWindowLayout(for anchorRect: CGRect, fallback: ScrcpyWindowLayout) -> ScrcpyWindowLayout {
        guard !anchorRect.isEmpty else { return fallback }

        let visibleFrame = NSScreen.screens.first(where: { $0.visibleFrame.intersects(anchorRect) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let insetRect = anchorRect.insetBy(dx: 1, dy: 1)
        let width = min(max(insetRect.width, 120), visibleFrame.width)
        let height = min(max(insetRect.height, 220), visibleFrame.height)

        let x = min(max(insetRect.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(insetRect.minY, visibleFrame.minY), visibleFrame.maxY - height)

        return ScrcpyWindowLayout(
            position: CGPoint(x: x, y: y),
            size: CGSize(width: width, height: height)
        )
    }

    private nonisolated static func validateAvailability(for configuredPath: String) -> (isAvailable: Bool, message: String) {
        guard let executable = ToolPathResolver.resolveExecutable(configuredPath) else {
            return (false, "scrcpy was not found. Configure it in Settings → Device Connectivity → Scrcpy.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let message = output.isEmpty ? "scrcpy failed validation." : output
                return (false, message)
            }

            return (true, "scrcpy ready at \(executable)")
        } catch {
            return (false, "Failed to validate scrcpy: \(error.localizedDescription)")
        }
    }
}

private struct ScrcpyControlPanelView: View {
    let deviceLabel: String
    let onHome: () -> Void
    let onBack: () -> Void
    let onApps: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 11, weight: .semibold))
                Text(deviceLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
            }
            .foregroundStyle(.primary)

            Divider()

            ScrcpyControlButton(title: "Home", systemImage: "house.fill", action: onHome)
            ScrcpyControlButton(title: "Back", systemImage: "arrow.left", action: onBack)
            ScrcpyControlButton(title: "Apps", systemImage: "square.grid.2x2.fill", action: onApps)
            ScrcpyControlButton(title: "Close", systemImage: "xmark.circle.fill", tint: .red, action: onClose)
        }
        .padding(10)
        .frame(width: 128)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct ScrcpyControlButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.72))
                )
        }
        .buttonStyle(.plain)
    }
}

import AVFoundation
import Foundation
import Network
import SwiftUI

// MARK: - Session

private final class MirrorSession {
    let tag: String
    let handle: ScrcpyServerHandle
    let decoder: H264StreamDecoder
    var connection: NWConnection?

    var deviceID: String { handle.deviceID }
    var port: Int { handle.port }
    var scid: Int { handle.scid }
    var sessionKey: String { "\(deviceID):\(tag)" }

    init(tag: String, handle: ScrcpyServerHandle, decoder: H264StreamDecoder) {
        self.tag = tag
        self.handle = handle
        self.decoder = decoder
    }
}

// MARK: - Store

@MainActor
final class ScreenMirrorStore: ObservableObject {
    static let shared = ScreenMirrorStore()

    @Published private(set) var activeDeviceIDs: Set<String> = []
    @Published private(set) var statusMessage: String = ""

    /// Sessions that have received at least one decoded video frame recently.
    @Published private(set) var sessionsWithVideo: Set<String> = []

    /// Persistent port assignments per device (survives across sessions).
    @Published private(set) var devicePorts: [String: Int] = [:] {
        didSet { persistPorts() }
    }

    private var sessions: [String: MirrorSession] = [:]
    private var nextScid = 1
    private let portsStorageKey = "aiphone.screenMirror.devicePorts"
    private var videoCheckTimer: Timer?

    private init() {
        if let data = UserDefaults.standard.data(forKey: portsStorageKey),
            let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        {
            self.devicePorts = decoded
        } else {
            self.devicePorts = [:]
        }
        startVideoCheckTimer()
    }

    private func startVideoCheckTimer() {
        videoCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSessionsWithVideo()
            }
        }
        if let timer = videoCheckTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func updateSessionsWithVideo() {
        var active = Set<String>()
        for (key, session) in sessions {
            if session.decoder.framesDecoded > 0 && session.decoder.displayLayer.status != .failed {
                active.insert(key)
            }
        }
        if active != sessionsWithVideo {
            sessionsWithVideo = active
        }
    }

    /// Returns true if the given session has received and rendered video frames.
    func hasActiveVideo(deviceID: String, tag: String = "default") -> Bool {
        sessionsWithVideo.contains("\(deviceID):\(tag)")
    }

    private func persistPorts() {
        guard let encoded = try? JSONEncoder().encode(devicePorts) else { return }
        UserDefaults.standard.set(encoded, forKey: portsStorageKey)
    }

    /// Returns the remembered port for a device, if any.
    func port(for deviceID: String) -> Int? {
        devicePorts[deviceID]
    }

    func isMirroring(deviceID: String, tag: String = "default") -> Bool {
        sessions["\(deviceID):\(tag)"] != nil
    }

    func decoder(for deviceID: String, tag: String = "default") -> H264StreamDecoder? {
        sessions["\(deviceID):\(tag)"]?.decoder
    }

    func startMirror(deviceID: String, tag: String = "default", maxSize: Int = 720) async throws {
        let sessionKey = "\(deviceID):\(tag)"
        guard sessions[sessionKey] == nil else {
            statusMessage =
                "Already mirroring \(deviceID) [\(tag)] on port \(sessions[sessionKey]?.port ?? 0)."
            return
        }

        statusMessage = "Pushing scrcpy-server to \(deviceID)…"

        let port = allocatePort(for: sessionKey)
        let scid = allocateScid()

        let config = ScrcpyServerConfig(
            deviceID: deviceID,
            port: port,
            scid: scid,
            maxSize: maxSize,
            uniqueJar: true,
            cleanup: true
        )

        let handle = try await ScrcpyServerProvider.launch(config: config)

        statusMessage = "Launching server on \(deviceID) [\(tag)]…"

        // Set up decoder and session
        let decoder = H264StreamDecoder()
        decoder.startWatchdog()
        decoder.onFirstFrame = { [weak self] in
            Task { @MainActor in
                self?.updateSessionsWithVideo()
            }
        }
        let session = MirrorSession(tag: tag, handle: handle, decoder: decoder)

        handle.process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handleSessionEnd(sessionKey: sessionKey)
            }
        }

        sessions[sessionKey] = session
        activeDeviceIDs.insert(deviceID)
        statusMessage = "Connecting to display stream [\(tag)]…"

        // Connect TCP and start reading H.264
        let connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        session.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.statusMessage = "Mirroring \(deviceID) [\(tag)] on port \(port)."
                    self.startReading(
                        connection: connection, decoder: decoder, sessionKey: sessionKey)
                case .failed(let error):
                    self.statusMessage = "Connection failed: \(error.localizedDescription)"
                    self.handleSessionEnd(sessionKey: sessionKey)
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }

        connection.start(queue: .global(qos: .userInteractive))
    }

    func stopMirror(deviceID: String, tag: String = "default") {
        let sessionKey = "\(deviceID):\(tag)"
        guard let session = sessions.removeValue(forKey: sessionKey) else { return }
        teardownSession(session)
        recomputeActiveDeviceIDs()
        statusMessage = "Mirror stopped for \(deviceID) [\(tag)]."
    }

    func stopAll() {
        let allSessions = sessions
        sessions.removeAll()
        activeDeviceIDs.removeAll()

        for (_, session) in allSessions {
            teardownSession(session)
        }

        if !allSessions.isEmpty {
            statusMessage = "Stopped \(allSessions.count) mirror session(s)."
        }
    }

    // MARK: - Private

    private nonisolated func startReading(
        connection: NWConnection, decoder: H264StreamDecoder, sessionKey: String
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self, weak decoder] content, _, isComplete, error in
            if let content, !content.isEmpty {
                DispatchQueue.main.async {
                    decoder?.feed(content)
                }
            }

            if isComplete || error != nil {
                Task { @MainActor in self?.handleSessionEnd(sessionKey: sessionKey) }
                return
            }

            guard let decoder else { return }
            self?.startReading(connection: connection, decoder: decoder, sessionKey: sessionKey)
        }
    }

    private func handleSessionEnd(sessionKey: String) {
        guard let session = sessions.removeValue(forKey: sessionKey) else { return }
        teardownSession(session)
        recomputeActiveDeviceIDs()
        statusMessage = "Mirror ended for \(session.deviceID) [\(session.tag)]."
    }

    func refreshDecoder(for deviceID: String, tag: String = "default") {
        sessions["\(deviceID):\(tag)"]?.decoder.forceRefresh()
    }

    private func recomputeActiveDeviceIDs() {
        activeDeviceIDs = Set(sessions.values.map(\.deviceID))
    }

    private func teardownSession(_ session: MirrorSession) {
        session.connection?.cancel()
        session.decoder.reset()
        ScrcpyServerProvider.teardown(handle: session.handle)
    }

    private func allocatePort(for sessionKey: String) -> Int {
        if let remembered = devicePorts[sessionKey] {
            let usedPorts = Set(sessions.values.map(\.port))
            if !usedPorts.contains(remembered) {
                return remembered
            }
        }

        let port = findFreePort()
        devicePorts[sessionKey] = port
        return port
    }

    private func findFreePort() -> Int {
        let usedPorts = Set(sessions.values.map(\.port))
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return 27200 }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_port = 0

        var result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { return 27200 }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        result = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard result == 0 else { return 27200 }

        let port = Int(UInt16(bigEndian: bound.sin_port))
        if usedPorts.contains(port) { return findFreePort() }
        return port
    }

    private func allocateScid() -> Int {
        let usedScids = Set(sessions.values.map(\.scid))
        var scid = nextScid
        while usedScids.contains(scid) {
            scid += 1
        }
        nextScid = scid + 1
        return scid
    }
}

// MARK: - SwiftUI Views

struct ScreenMirrorStreamView: NSViewRepresentable {
    let decoder: H264StreamDecoder

    /// NSView subclass that keeps the AVSampleBufferDisplayLayer
    /// sized to its bounds on every layout pass, working around
    /// CALayer.autoresizingMask not being reliable under SwiftUI.
    final class DisplayLayerContainerView: NSView {
        weak var currentDisplayLayer: AVSampleBufferDisplayLayer?

        override func layout() {
            super.layout()
            guard let dl = currentDisplayLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dl.frame = bounds
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let dl = currentDisplayLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dl.frame = bounds
            CATransaction.commit()
        }
    }

    final class Coordinator {
        weak var container: DisplayLayerContainerView?
        let decoder: H264StreamDecoder

        init(decoder: H264StreamDecoder) {
            self.decoder = decoder
        }

        func attachCurrentLayer() {
            guard let container else { return }
            container.layer?.sublayers?
                .filter { $0 is AVSampleBufferDisplayLayer }
                .forEach { $0.removeFromSuperlayer() }

            let layer = decoder.displayLayer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = container.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.backgroundColor = NSColor.black.cgColor
            layer.needsDisplayOnBoundsChange = true
            CATransaction.commit()
            container.currentDisplayLayer = layer
            container.layer?.addSublayer(layer)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(decoder: decoder)
    }

    func makeNSView(context: Context) -> DisplayLayerContainerView {
        let container = DisplayLayerContainerView()
        container.wantsLayer = true

        let coordinator = context.coordinator
        coordinator.container = container
        coordinator.attachCurrentLayer()

        decoder.onLayerRecreated = { [weak coordinator] in
            coordinator?.attachCurrentLayer()
        }

        return container
    }

    func updateNSView(_ nsView: DisplayLayerContainerView, context: Context) {
        context.coordinator.container = nsView
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        decoder.displayLayer.frame = nsView.bounds
        CATransaction.commit()
    }
}

struct ScreenMirrorPageView: View {
    let deviceID: String
    var tag: String = "preview"
    @EnvironmentObject private var screenMirrorStore: ScreenMirrorStore
    @EnvironmentObject private var agentRunStore: AgentRunStore

    var body: some View {
        VStack(spacing: 0) {
            if screenMirrorStore.isMirroring(deviceID: deviceID, tag: tag),
                let decoder = screenMirrorStore.decoder(for: deviceID, tag: tag)
            {
                ScreenMirrorStreamView(decoder: decoder)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(16)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 34, weight: .ultraLight))
                        .foregroundStyle(.quaternary)

                    Text("Screen preview not active")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Button {
                        Task {
                            do {
                                try await screenMirrorStore.startMirror(
                                    deviceID: deviceID, tag: tag)
                            } catch {
                                agentRunStore.presentIssue(error.localizedDescription)
                            }
                        }
                    } label: {
                        Label("Start Preview", systemImage: "play.rectangle.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Bottom status bar
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        screenMirrorStore.isMirroring(deviceID: deviceID, tag: tag)
                            ? Color.green : Color.gray
                    )
                    .frame(width: 6, height: 6)

                Text(
                    screenMirrorStore.statusMessage.isEmpty
                        ? "Ready" : screenMirrorStore.statusMessage
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer()

                if screenMirrorStore.isMirroring(deviceID: deviceID, tag: tag) {
                    Button {
                        screenMirrorStore.refreshDecoder(for: deviceID, tag: tag)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button {
                        screenMirrorStore.stopMirror(deviceID: deviceID, tag: tag)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

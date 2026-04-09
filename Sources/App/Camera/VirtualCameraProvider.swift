import Foundation
import CoreVideo
import AVFoundation
import AppKit
import SystemExtensions
import Network
import os.log

private let vcamLog = OSLog(subsystem: "id.wblue.aiphone.app", category: "VirtualCamera")

// MARK: - Virtual Camera Provider

/// Manages an independent scrcpy-server → H.264 decode → SharedFrameBuffer pipeline
/// that feeds the Camera Extension. Completely separate from the preview camera.
final class VirtualCameraProvider: NSObject, ObservableObject {
    static let shared = VirtualCameraProvider()

    // MARK: Published State

    @Published private(set) var isRunning = false
    @Published private(set) var extensionInstalled = false
    @Published private(set) var installStatus: String = ""
    @Published private(set) var streamingDeviceID: String?

    // MARK: Private

    private let frameBuffer = SharedFrameBuffer()
    private let extensionBundleID = "id.wblue.aiphone.app.CameraExtension"
    private let cameraDeviceName = "AIPhone Camera"

    private var handle: ScrcpyServerHandle?
    private var decoder: H264StreamDecoder?
    private var connection: NWConnection?
    private var enqueueCount: Int = 0

    override init() {
        super.init()
        refreshExtensionStatus()
    }

    // MARK: - Streaming (own scrcpy pipeline)

    @MainActor
    func startStreaming(deviceID: String) async throws {
        guard !isRunning else {
            os_log("Already running for %{public}@", log: vcamLog, type: .default, streamingDeviceID ?? "?")
            return
        }

        os_log("Starting streaming for device %{public}@", log: vcamLog, type: .default, deviceID)

        // 1. Create shared frame buffer for writing
        guard frameBuffer.createForWriting() else {
            os_log("Failed to create shared frame buffer at %{public}@", log: vcamLog, type: .error, SharedFrameBuffer.filePath)
            return
        }

        // 2. Launch a dedicated scrcpy-server for camera
        let port = Self.allocatePort()
        let scid = Int.random(in: 200..<10000)
        let opts = CameraOptionsStore.shared

        let config = ScrcpyServerConfig(
            deviceID: deviceID,
            port: port,
            scid: scid,
            maxSize: opts.maxSize,
            extraParams: opts.scrcpyExtraParams,
            uniqueJar: true,
            cleanup: false
        )

        let serverHandle: ScrcpyServerHandle
        do {
            serverHandle = try await ScrcpyServerProvider.launch(config: config)
        } catch {
            os_log("Failed to launch scrcpy-server: %{public}@", log: vcamLog, type: .error, error.localizedDescription)
            frameBuffer.close()
            throw error
        }

        // 3. Set up H.264 decoder
        let h264Decoder = H264StreamDecoder()
        h264Decoder.onDecodedFrame = { [weak self] pixelBuffer in
            self?.enqueueFrame(pixelBuffer)
        }

        serverHandle.process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                os_log("scrcpy-server terminated", log: vcamLog, type: .default)
                self?.stopStreaming()
            }
        }

        self.handle = serverHandle
        self.decoder = h264Decoder
        self.streamingDeviceID = deviceID
        self.isRunning = true
        self.enqueueCount = 0

        os_log("Connecting to scrcpy on port %d", log: vcamLog, type: .default, port)

        // 4. Connect TCP and read H.264
        let conn = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    os_log("TCP connected, reading H.264 stream", log: vcamLog, type: .default)
                    self.startReading(connection: conn, decoder: h264Decoder)
                case .failed(let error):
                    os_log("TCP connection failed: %{public}@", log: vcamLog, type: .error, error.localizedDescription)
                    self.stopStreaming()
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }

        conn.start(queue: .global(qos: .userInteractive))
    }

    @MainActor
    func stopStreaming() {
        guard isRunning else { return }
        os_log("Stopping streaming for %{public}@", log: vcamLog, type: .default, streamingDeviceID ?? "?")

        connection?.cancel()
        connection = nil

        decoder?.reset()
        decoder = nil

        if let handle {
            ScrcpyServerProvider.teardown(handle: handle)
            self.handle = nil
        }

        frameBuffer.close()
        frameBuffer.unlink()

        isRunning = false
        streamingDeviceID = nil
        enqueueCount = 0
    }

    private func enqueueFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRunning else { return }
        frameBuffer.writeFrame(pixelBuffer)
        enqueueCount += 1
        if enqueueCount <= 3 || enqueueCount % 300 == 0 {
            os_log("enqueue frame #%d (%dx%d)", log: vcamLog, type: .default, enqueueCount, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        }
    }

    private nonisolated func startReading(connection: NWConnection, decoder: H264StreamDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let content, !content.isEmpty {
                DispatchQueue.main.async {
                    decoder.feed(content)
                }
            }

            if isComplete || error != nil {
                Task { @MainActor in
                    self?.stopStreaming()
                }
                return
            }

            self?.startReading(connection: connection, decoder: decoder)
        }
    }

    // MARK: - Extension Status

    func refreshExtensionStatus() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        let found = discovery.devices.contains { $0.localizedName == cameraDeviceName }
        DispatchQueue.main.async { self.extensionInstalled = found }
    }

    // MARK: - Extension Installation

    func installExtension() {
        guard ensureInApplicationsFolder() else { return }

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        installStatus = "Requesting installation…"
    }

    // MARK: - Port Allocation

    private static func allocatePort() -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return 27300 }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_port = 0

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { return 27300 }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result2 = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard result2 == 0 else { return 27300 }

        return Int(UInt16(bigEndian: bound.sin_port))
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension VirtualCameraProvider: OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        DispatchQueue.main.async {
            self.installStatus = "Waiting for approval in System Settings…"
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        DispatchQueue.main.async {
            if result == .completed {
                self.extensionInstalled = true
                self.installStatus = "Installed"
                Self.showAlert(
                    .informational,
                    title: "Camera Extension Installed",
                    detail: "\"AIPhone Camera\" is now available as a virtual camera in any app."
                )
                // Delay the discovery check to give the system time to register the camera
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.refreshExtensionStatus()
                }
            } else {
                self.installStatus = "Finished with status \(result.rawValue)"
                self.refreshExtensionStatus()
            }
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.installStatus = ""
            Self.showAlert(.critical, title: "Camera Extension Failed", detail: error.localizedDescription)
        }
    }
}

// MARK: - Helpers

private extension VirtualCameraProvider {

    /// Returns `true` if the app is in /Applications. Shows a move dialog otherwise.
    func ensureInApplicationsFolder() -> Bool {
        let appPath = Bundle.main.bundlePath
        if appPath.hasPrefix("/Applications") { return true }

        let alert = NSAlert()
        alert.messageText = "Move to Applications"
        alert.informativeText = "Camera extensions require the app to be in /Applications.\n\nCurrent location:\n\(appPath)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move & Relaunch")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        moveToApplicationsAndRelaunch()
        return false
    }

    func moveToApplicationsAndRelaunch() {
        let src = Bundle.main.bundlePath
        let appName = (src as NSString).lastPathComponent
        let dst = "/Applications/\(appName)"

        let script = """
        do shell script "rm -rf '\(dst)' && cp -R '\(src)' '\(dst)'" with administrator privileges
        do shell script "open '\(dst)'"
        """
        guard let appleScript = NSAppleScript(source: script) else { return }

        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            Self.showAlert(.critical, title: "Failed to Move App", detail: "\(error)")
        } else {
            NSApp.terminate(nil)
        }
    }

    static func showAlert(_ style: NSAlert.Style, title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

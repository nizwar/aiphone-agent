import Foundation
import SwiftUI
import AVFoundation
import VideoToolbox
import Network

// MARK: - H.264 NAL unit parser + AVSampleBufferDisplayLayer feeder

final class H264StreamDecoder {
    private(set) var displayLayer = AVSampleBufferDisplayLayer()

    private var spsData: Data?
    private var ppsData: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var nalBuffer = Data()
    private var decompressionSession: VTDecompressionSession?
    private var waitingForKeyframe = false
    private var consecutiveDrops: Int = 0
    private let maxDropsBeforeFlush = 30

    /// Called on a VideoToolbox thread with each decoded pixel buffer.
    var onDecodedFrame: ((CVPixelBuffer) -> Void)?

    /// Called on main thread when the display layer has been recreated.
    /// The view must swap the old sublayer for the new one.
    var onLayerRecreated: (() -> Void)?

    /// Fires once when the first frame is enqueued (framesDecoded goes from 0 → 1).
    var onFirstFrame: (() -> Void)?

    // Watchdog: detect silent stalls and recreate the layer
    private var watchdogTimer: Timer?
    private var framesEnqueuedSinceCheck: Int = 0

    init() {
        displayLayer.videoGravity = .resizeAspect
    }

    deinit {
        watchdogTimer?.invalidate()
    }

    private var totalBytesReceived: Int = 0
    private(set) var framesDecoded: Int = 0

    func feed(_ data: Data) {
        totalBytesReceived += data.count
        nalBuffer.append(data)
        processNALUnits()
    }

    func reset() {
        stopWatchdog()
        spsData = nil
        ppsData = nil
        formatDescription = nil
        nalBuffer.removeAll()
        displayLayer.flush()
        waitingForKeyframe = true
        consecutiveDrops = 0
        framesEnqueuedSinceCheck = 0
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
    }

    /// Start a periodic watchdog that recreates the display layer if it goes silent.
    func startWatchdog() {
        stopWatchdog()
        framesEnqueuedSinceCheck = 0
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.watchdogCheck()
        }
        if let timer = watchdogTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// Manually force-recreate the display layer (called from UI refresh button).
    func forceRefresh() {
        recreateDisplayLayer()
    }

    private func watchdogCheck() {
        if framesEnqueuedSinceCheck > 0 {
            // We are feeding frames — check if the layer is actually alive
            if displayLayer.status == .failed {
                print("[H264] Watchdog: layer status failed, recreating")
                recreateDisplayLayer()
            }
        }
        framesEnqueuedSinceCheck = 0
    }

    private func recreateDisplayLayer() {
        let oldLayer = displayLayer
        oldLayer.flush()
        oldLayer.removeFromSuperlayer()

        let newLayer = AVSampleBufferDisplayLayer()
        newLayer.videoGravity = .resizeAspect
        newLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        displayLayer = newLayer
        waitingForKeyframe = true
        consecutiveDrops = 0

        print("[H264] Display layer recreated")
        onLayerRecreated?()
    }

    // MARK: - Private

    private func processNALUnits() {
        // Scan for Annex B start codes (00 00 00 01) and split into NAL units
        while let range = findNextStartCode(in: nalBuffer, from: 0) {
            let nextRange = findNextStartCode(in: nalBuffer, from: range.upperBound)
            let nalEnd = nextRange?.lowerBound ?? nalBuffer.count

            // If we haven't found the end of the NAL unit yet, wait for more data
            guard nextRange != nil || nalBuffer.count > range.upperBound + 65536 else { break }

            let nalUnitData = nalBuffer[range.upperBound ..< nalEnd]
            guard !nalUnitData.isEmpty else {
                nalBuffer.removeSubrange(0 ..< nalEnd)
                continue
            }

            handleNALUnit(Data(nalUnitData))

            nalBuffer.removeSubrange(0 ..< nalEnd)
        }

        // Prevent unbounded growth if no start codes are found
        if nalBuffer.count > 2_000_000 {
            print("[Camera/H264] WARNING: NAL buffer exceeded 2MB with no start codes found, flushing. Total bytes received: \(totalBytesReceived)")
            nalBuffer.removeAll()
        }
    }

    private func findNextStartCode(in data: Data, from offset: Int) -> Range<Int>? {
        guard data.count >= offset + 4 else { return nil }
        return data.withUnsafeBytes { buffer -> Range<Int>? in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var i = offset
            while i + 3 < bytes.count {
                if bytes[i] == 0x00 && bytes[i+1] == 0x00 && bytes[i+2] == 0x00 && bytes[i+3] == 0x01 {
                    return i ..< (i + 4)
                }
                i += 1
            }
            return nil
        }
    }

    private func handleNALUnit(_ nal: Data) {
        guard !nal.isEmpty else { return }
        let nalType = nal[nal.startIndex] & 0x1F

        switch nalType {
        case 7: // SPS
            print("[Camera/H264] Got SPS (\(nal.count) bytes)")
            spsData = nal
            tryCreateFormatDescription()
        case 8: // PPS
            print("[Camera/H264] Got PPS (\(nal.count) bytes)")
            ppsData = nal
            tryCreateFormatDescription()
        case 5: // IDR slice (keyframe)
            if formatDescription != nil {
                print("[Camera/H264] IDR keyframe (\(nal.count) bytes), total decoded: \(framesDecoded)")
                enqueueSampleBuffer(from: nal, isKeyframe: true)
            } else {
                print("[Camera/H264] IDR received but no format description yet, dropping")
            }
        case 1: // Non-IDR slice
            if formatDescription != nil {
                enqueueSampleBuffer(from: nal, isKeyframe: false)
            } else {
                print("[Camera/H264] Non-IDR received but no format description yet, dropping")
            }
        default:
            print("[Camera/H264] Unknown NAL type \(nalType) (\(nal.count) bytes)")
            break
        }
    }

    private func tryCreateFormatDescription() {
        guard let sps = spsData, let pps = ppsData else { return }

        var desc: CMVideoFormatDescription?
        let parameterSets: [Data] = [sps, pps]
        let pointers = parameterSets.map { data -> UnsafePointer<UInt8> in
            data.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
        }
        let sizes = parameterSets.map { $0.count }

        let status = pointers.withUnsafeBufferPointer { pointersBuffer in
            sizes.withUnsafeBufferPointer { sizesBuffer in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointersBuffer.baseAddress!,
                    parameterSetSizes: sizesBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }

        if status == noErr, let desc {
            formatDescription = desc
            print("[Camera/H264] Format description created successfully: \(desc)")
            createDecompressionSession()
        } else {
            print("[Camera/H264] Failed to create format description, status=\(status)")
        }
    }

    private func createDecompressionSession() {
        guard let formatDescription else { return }

        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        let outputAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: outputAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        if status == noErr, let session {
            decompressionSession = session
            print("[Camera/H264] VTDecompressionSession created for virtual camera")
        } else {
            print("[Camera/H264] Failed to create decompression session: \(status)")
        }
    }

    private func enqueueSampleBuffer(from nalUnit: Data, isKeyframe: Bool) {
        guard let formatDescription else { return }

        // Convert from Annex B to AVCC: replace start code with 4-byte length prefix
        let nalLength = UInt32(nalUnit.count)
        var lengthBE = nalLength.bigEndian
        var avccData = Data(bytes: &lengthBE, count: 4)
        avccData.append(nalUnit)

        var blockBuffer: CMBlockBuffer?
        let avccCount = avccData.count
        avccData.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            if let blockBuffer {
                CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: avccCount
                )
            }
        }

        guard let blockBuffer else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccData.count
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard let sampleBuffer else { return }

        // Mark every frame for immediate display (live preview, no PTS buffering)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary]
        if let dict = attachments?.first {
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        // Recover from failed layer state
        if displayLayer.status == .failed {
            print("[Camera/H264] Display layer failed, flushing. Error: \(String(describing: displayLayer.error))")
            displayLayer.flush()
            waitingForKeyframe = true
        }

        // After a flush, wait for the next keyframe before enqueuing
        if waitingForKeyframe {
            if isKeyframe {
                waitingForKeyframe = false
                print("[Camera/H264] Recovered — re-seeding with IDR keyframe")
            } else {
                return
            }
        }

        // Don't enqueue if the layer's internal queue is full — detect stalls
        if !displayLayer.isReadyForMoreMediaData {
            consecutiveDrops += 1
            if consecutiveDrops > maxDropsBeforeFlush {
                print("[Camera/H264] Layer stalled (\(consecutiveDrops) drops), flushing")
                displayLayer.flush()
                waitingForKeyframe = true
                consecutiveDrops = 0
            }
            return
        }
        consecutiveDrops = 0

        displayLayer.enqueue(sampleBuffer)
        framesDecoded += 1
        framesEnqueuedSinceCheck += 1
        if framesDecoded == 1 {
            onFirstFrame?()
        }
        if framesDecoded <= 5 || framesDecoded % 300 == 0 {
            print("[Camera/H264] Enqueued frame #\(framesDecoded) (\(isKeyframe ? "IDR" : "P")) layer.status=\(displayLayer.status.rawValue)")
        }

        // Also decompress to CVPixelBuffer for virtual camera
        if let session = decompressionSession, onDecodedFrame != nil {
            VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [],
                infoFlagsOut: nil
            ) { [weak self] status, _, imageBuffer, _, _ in
                guard status == noErr, let pixelBuffer = imageBuffer else { return }
                self?.onDecodedFrame?(pixelBuffer)
            }
        }
    }
}

// MARK: - Camera Session

private final class CameraSession {
    let handle: ScrcpyServerHandle
    let decoder: H264StreamDecoder
    var connection: NWConnection?

    var deviceID: String { handle.deviceID }
    var port: Int { handle.port }

    init(handle: ScrcpyServerHandle, decoder: H264StreamDecoder) {
        self.handle = handle
        self.decoder = decoder
    }
}

// MARK: - Errors

enum CameraServiceError: LocalizedError {
    case alreadyInUse(String)

    var errorDescription: String? {
        switch self {
        case .alreadyInUse(let deviceID):
            return "Camera service is already in use by \(deviceID). Stop it first before starting on another device."
        }
    }
}

// MARK: - Store

@MainActor
final class CameraStreamStore: ObservableObject {
    static let shared = CameraStreamStore()

    @Published private(set) var activeDeviceIDs: Set<String> = []
    @Published private(set) var statusMessage: String = ""

    private var sessions: [String: CameraSession] = [:]
    private var nextScid = 100

    func isStreaming(deviceID: String) -> Bool {
        activeDeviceIDs.contains(deviceID)
    }

    func decoder(for deviceID: String) -> H264StreamDecoder? {
        sessions[deviceID]?.decoder
    }

    func startCamera(deviceID: String) async throws {
        // Only one device can use camera service at a time
        if let existingID = sessions.keys.first, existingID != deviceID {
            statusMessage = "Camera service is already in use by \(existingID)."
            throw CameraServiceError.alreadyInUse(existingID)
        }

        guard sessions[deviceID] == nil else {
            statusMessage = "Camera is already streaming for \(deviceID)."
            return
        }

        statusMessage = "Pushing scrcpy-server to \(deviceID)…"

        let port = allocatePort()
        let scid = allocateScid()
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

        let handle = try await ScrcpyServerProvider.launch(config: config)

        statusMessage = "Launching camera server on \(deviceID)…"

        let decoder = H264StreamDecoder()
        decoder.startWatchdog()

        let session = CameraSession(handle: handle, decoder: decoder)

        handle.process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handleSessionEnd(deviceID: deviceID)
            }
        }

        sessions[deviceID] = session
        activeDeviceIDs.insert(deviceID)

        statusMessage = "Connecting to camera stream on port \(port)…"

        // Connect TCP and start reading raw H.264 stream
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        session.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.statusMessage = "Camera streaming for \(deviceID) at port \(port)."
                    self.startReading(connection: connection, decoder: decoder, deviceID: deviceID)
                case .failed(let error):
                    self.statusMessage = "Connection failed: \(error.localizedDescription)"
                    self.handleSessionEnd(deviceID: deviceID)
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }

        connection.start(queue: .global(qos: .userInteractive))
    }

    func stopCamera(deviceID: String) {
        guard let session = sessions.removeValue(forKey: deviceID) else { return }
        teardownSession(session)
        activeDeviceIDs.remove(deviceID)
        statusMessage = "Camera stopped for \(deviceID)."
    }

    func stopAll() {
        let allSessions = sessions
        sessions.removeAll()
        activeDeviceIDs.removeAll()

        for (_, session) in allSessions {
            teardownSession(session)
        }

        if !allSessions.isEmpty {
            statusMessage = "Stopped \(allSessions.count) camera session(s)."
        }
    }

    // MARK: - Private

    private nonisolated func startReading(connection: NWConnection, decoder: H264StreamDecoder, deviceID: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let content, !content.isEmpty {
                DispatchQueue.main.async {
                    decoder.feed(content)
                }
            }

            if isComplete || error != nil {
                Task { @MainActor in
                    self?.handleSessionEnd(deviceID: deviceID)
                }
                return
            }

            self?.startReading(connection: connection, decoder: decoder, deviceID: deviceID)
        }
    }

    private func handleSessionEnd(deviceID: String) {
        guard let session = sessions.removeValue(forKey: deviceID) else { return }
        teardownSession(session)
        activeDeviceIDs.remove(deviceID)
        statusMessage = "Camera ended for \(deviceID)."
    }

    func refreshDecoder(for deviceID: String) {
        sessions[deviceID]?.decoder.forceRefresh()
    }

    private func teardownSession(_ session: CameraSession) {
        session.connection?.cancel()
        session.decoder.reset()
        ScrcpyServerProvider.teardown(handle: session.handle)
    }

    private func allocatePort() -> Int {
        let usedPorts = Set(sessions.values.map(\.port))
        // Bind to port 0 to let the OS pick a free port
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
        if usedPorts.contains(port) { return allocatePort() }
        return port
    }

    private func allocateScid() -> Int {
        let usedScids = Set(sessions.values.map { $0.handle.scid })
        var scid = nextScid
        while usedScids.contains(scid) {
            scid += 1
        }
        nextScid = scid + 1
        return scid
    }
}

// MARK: - SwiftUI View

struct CameraStreamView: NSViewRepresentable {
    let decoder: H264StreamDecoder

    final class Coordinator {
        weak var container: NSView?
        let decoder: H264StreamDecoder

        init(decoder: H264StreamDecoder) {
            self.decoder = decoder
        }

        func attachCurrentLayer() {
            guard let container else { return }
            // Remove any old display sublayers
            container.layer?.sublayers?
                .filter { $0 is AVSampleBufferDisplayLayer }
                .forEach { $0.removeFromSuperlayer() }

            let layer = decoder.displayLayer
            layer.frame = container.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.backgroundColor = NSColor.black.cgColor
            container.layer?.addSublayer(layer)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(decoder: decoder)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let coordinator = context.coordinator
        coordinator.container = container
        coordinator.attachCurrentLayer()

        decoder.onLayerRecreated = { [weak coordinator] in
            coordinator?.attachCurrentLayer()
        }

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.container = nsView
        decoder.displayLayer.frame = nsView.bounds
    }
}

struct CameraPageView: View {
    let deviceID: String
    @EnvironmentObject private var cameraStreamStore: CameraStreamStore
    @EnvironmentObject private var agentRunStore: AgentRunStore
    @ObservedObject private var virtualCamera = VirtualCameraProvider.shared
    @ObservedObject private var cameraOptions = CameraOptionsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // Top controls row: camera options + extension controls
            HStack(spacing: 3) {
                // Camera options (left side)
                cameraOptionsRow

                Divider()
                    .frame(height: 16)

                // Extension controls (right side)
                virtualCameraRow

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if cameraStreamStore.isStreaming(deviceID: deviceID),
               let decoder = cameraStreamStore.decoder(for: deviceID) {
                CameraStreamView(decoder: decoder)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(16)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "camera")
                        .font(.system(size: 34, weight: .ultraLight))
                        .foregroundStyle(.quaternary)

                    Text("Camera not active")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Button {
                        Task {
                            do {
                                try await cameraStreamStore.startCamera(deviceID: deviceID)
                            } catch {
                                agentRunStore.presentIssue(error.localizedDescription)
                            }
                        }
                    } label: {
                        Label("Start Camera", systemImage: "camera.fill")
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
                    .fill(cameraStreamStore.isStreaming(deviceID: deviceID) ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)

                Text(cameraStreamStore.statusMessage.isEmpty ? "Ready" : cameraStreamStore.statusMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if cameraStreamStore.isStreaming(deviceID: deviceID) {
                    Button {
                        let id = deviceID
                        cameraStreamStore.stopCamera(deviceID: id)
                        Task {
                            try? await cameraStreamStore.startCamera(deviceID: id)
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button {
                        cameraStreamStore.stopCamera(deviceID: deviceID)
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
        .onAppear {
            cameraOptions.queryDeviceCameras(deviceID: deviceID)
        }
    }

    private var virtualCameraBinding: Binding<Bool> {
        Binding(
            get: { virtualCamera.isRunning },
            set: { newValue in
                Task {
                    if newValue {
                        try? await virtualCamera.startStreaming(deviceID: deviceID)
                    } else {
                        virtualCamera.stopStreaming()
                    }
                }
            }
        )
    }

    // MARK: - Camera Options Row

    @ViewBuilder
    private var cameraOptionsRow: some View {
        // Camera picker
        Picker("", selection: $cameraOptions.selectedCameraID) {
            if cameraOptions.cameras.isEmpty {
                Text("Camera 0").tag("0")
            }
            ForEach(cameraOptions.cameras) { cam in
                Text(cam.name).tag(cam.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 100)
        .controlSize(.mini)
        .onChange(of: cameraOptions.selectedCameraID) { newID in
            cameraOptions.selectCamera(newID)
        }

        // Resolution picker
        Picker("", selection: $cameraOptions.selectedSize) {
            if cameraOptions.sizes.isEmpty {
                Text("720p").tag(nil as CameraSize?)
            }
            ForEach(cameraOptions.sizes) { size in
                Text(size.label).tag(size as CameraSize?)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 100)
        .controlSize(.mini)

        // FPS picker
        Picker("", selection: $cameraOptions.selectedFPS) {
            ForEach(cameraOptions.fpsOptions, id: \.self) { fps in
                Text("\(fps) fps").tag(fps)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 70)
        .controlSize(.mini)
    }

    // MARK: - Virtual Camera Row

    @ViewBuilder
    private var virtualCameraRow: some View {
        if virtualCamera.extensionInstalled || virtualCamera.installStatus == "Installed" {
            Toggle(isOn: virtualCameraBinding) {
                Label("Virtual Camera", systemImage: "web.camera")
                    .font(.system(size: 10, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if virtualCamera.isRunning {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Streaming")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        } else {
            Button {
                virtualCamera.installExtension()
            } label: {
                Label("Install Camera Extension", systemImage: "camera.badge.ellipsis")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)

            if !virtualCamera.installStatus.isEmpty {
                Text(virtualCamera.installStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import os.log

private let extLog = OSLog(subsystem: "id.wblue.aiphone.app.CameraExtension", category: "Extension")

// MARK: - Provider Source

final class CameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    var provider: CMIOExtensionProvider!

    var availableProperties: Set<CMIOExtensionProperty> { [] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        CMIOExtensionProviderProperties(dictionary: [:])
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}
}

// MARK: - Device Source

final class CameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    var device: CMIOExtensionDevice!

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            props.transportType = 0
        }
        if properties.contains(.deviceModel) {
            props.model = "AIPhone Virtual Camera"
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

// MARK: - Stream Source

final class CameraExtensionStreamSource: NSObject, CMIOExtensionStreamSource {
    var stream: CMIOExtensionStream!

    private let frameBuffer = SharedFrameBuffer()
    private var lastSequence: UInt64 = 0
    private var isStreaming = false
    private var frameTimer: DispatchSourceTimer?
    private var pixelBufferPool: CVPixelBufferPool?
    private var sharedFileOpen = false
    private var frameOpenLogCount = 0
    private var openRetryCount = 0
    private let maxOpenRetries = 300  // ~5 seconds at 60fps
    private var hasReceivedRealFrame = false

    private let defaultWidth: Int32 = 1920
    private let defaultHeight: Int32 = 1080

    // MARK: Format

    /// Advertise multiple common resolutions so apps can negotiate.
    /// The actual frames adapt to whatever the host writes.
    var formats: [CMIOExtensionStreamFormat] {
        let resolutions: [(Int32, Int32)] = [
            (1920, 1080),
            (1280, 720),
            (640, 480),
        ]
        return resolutions.compactMap { (w, h) in
            var desc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCVPixelFormatType_32BGRA,
                width: w, height: h,
                extensions: nil,
                formatDescriptionOut: &desc
            )
            guard let desc else { return nil }
            return CMIOExtensionStreamFormat(
                formatDescription: desc,
                maxFrameDuration: CMTime(value: 1, timescale: 15),
                minFrameDuration: CMTime(value: 1, timescale: 60),
                validFrameDurations: nil
            )
        }
    }

    // MARK: Properties

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { props.frameDuration = CMTime(value: 1, timescale: 30) }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    // MARK: Lifecycle

    func startStream() throws {
        isStreaming = true
        lastSequence = 0
        sharedFileOpen = false
        hasReceivedRealFrame = false
        frameOpenLogCount = 0
        openRetryCount = 0
        frameLogCount = 0
        pixelBufferPool = nil
        os_log("[AIPhoneCamExt] startStream called, filePath=%{public}@", log: extLog, type: .default, SharedFrameBuffer.filePath)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in self?.pumpFrame() }
        timer.resume()
        frameTimer = timer
    }

    func stopStream() throws {
        isStreaming = false
        frameTimer?.cancel()
        frameTimer = nil
        frameBuffer.close()
        sharedFileOpen = false
        hasReceivedRealFrame = false
        pixelBufferPool = nil
    }

    // MARK: Frame Pump

    private var poolWidth = 0
    private var poolHeight = 0

    private func ensurePool(w: Int, h: Int) {
        if pixelBufferPool == nil || poolWidth != w || poolHeight != h {
            pixelBufferPool = nil
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pixelBufferPool)
            poolWidth = w
            poolHeight = h
        }
    }

    private func sendPixelBuffer(_ pb: CVPixelBuffer) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: now, decodeTimeStamp: .invalid)

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &formatDesc)
        guard let formatDesc else { return }

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDesc, sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return }

        stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: UInt64(now.seconds * 1_000_000_000))
    }

    /// Send a black frame so the camera always appears functional to apps/browsers.
    private func sendBlankFrame() {
        ensurePool(w: Int(defaultWidth), h: Int(defaultHeight))
        guard let pool = pixelBufferPool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            // Fill with BGRA black (0,0,0,255)
            let h = CVPixelBufferGetHeight(pb)
            let rowBytes = CVPixelBufferGetBytesPerRow(pb)
            let total = h * rowBytes
            memset(base, 0, total)
            // Set alpha to 0xFF for each pixel
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 3, to: total, by: 4) {
                ptr[i] = 0xFF
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        sendPixelBuffer(pb)
    }

    private var frameLogCount = 0

    /// Track consecutive nil headers to detect host shutdown.
    private var consecutiveNilHeaders = 0

    private func pumpFrame() {
        guard isStreaming else { return }

        // Try to open the shared file from the host app
        if !sharedFileOpen {
            openRetryCount += 1
            if openRetryCount > 10 && openRetryCount % 60 != 0 {
                // While waiting, send blank frames so the camera stays visible
                sendBlankFrame()
                return
            }
            sharedFileOpen = frameBuffer.openForReading()
            if !sharedFileOpen {
                if frameOpenLogCount < 5 {
                    os_log("[AIPhoneCamExt] Shared file not ready at %{public}@ (attempt %d), sending blank", log: extLog, type: .default, SharedFrameBuffer.filePath, openRetryCount)
                    frameOpenLogCount += 1
                }
                sendBlankFrame()
                return
            }
            os_log("[AIPhoneCamExt] Opened shared file successfully after %d attempts", log: extLog, type: .default, openRetryCount)
            consecutiveNilHeaders = 0
        }

        // Read real frame from shared buffer
        let header = frameBuffer.readHeader()
        if header == nil {
            consecutiveNilHeaders += 1
            // Host has stopped (notify state zeroed) — reset so we re-open on next restart
            if consecutiveNilHeaders > 30 {  // ~0.5s of nil headers
                os_log("[AIPhoneCamExt] Host appears stopped, resetting for reconnect", log: extLog, type: .default)
                frameBuffer.close()
                sharedFileOpen = false
                hasReceivedRealFrame = false
                lastSequence = 0
                openRetryCount = 0
                frameOpenLogCount = 0
                frameLogCount = 0
                consecutiveNilHeaders = 0
            }
            if !hasReceivedRealFrame { sendBlankFrame() }
            return
        }
        consecutiveNilHeaders = 0

        // Detect host restart: sequence wrapped back to a lower value
        if header!.sequence < lastSequence {
            os_log("[AIPhoneCamExt] Sequence reset detected (got %llu, had %llu) — host restarted, re-opening", log: extLog, type: .default, header!.sequence, lastSequence)
            frameBuffer.close()
            sharedFileOpen = false
            hasReceivedRealFrame = false
            lastSequence = 0
            openRetryCount = 0
            frameOpenLogCount = 0
            frameLogCount = 0
            pixelBufferPool = nil
            return
        }

        guard header!.sequence > lastSequence else {
            // No new frame yet — skip (previous frame persists in the stream)
            return
        }

        if frameLogCount < 10 {
            os_log("[AIPhoneCamExt] Got frame seq=%llu %dx%d bpr=%d", log: extLog, type: .default,
                   header!.sequence, header!.width, header!.height, header!.bytesPerRow)
            frameLogCount += 1
        }

        ensurePool(w: Int(header!.width), h: Int(header!.height))
        guard let pool = pixelBufferPool else { return }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let pb = pixelBuffer else { return }

        let seq = frameBuffer.readFrame(into: pb)
        guard seq > lastSequence else { return }
        lastSequence = seq
        hasReceivedRealFrame = true

        sendPixelBuffer(pb)
    }
}

// MARK: - Entry Point

@main
struct CameraExtensionMain {
    private static let deviceUUID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
    private static let streamUUID = UUID(uuidString: "FEDCBA98-7654-3210-FEDC-BA9876543210")!
    private static let cameraName = "AIPhone Camera"

    static func main() {
        let providerSource = CameraExtensionProviderSource()

        let deviceSource = CameraExtensionDeviceSource()
        let device = CMIOExtensionDevice(localizedName: cameraName, deviceID: deviceUUID, legacyDeviceID: nil, source: deviceSource)
        deviceSource.device = device

        let streamSource = CameraExtensionStreamSource()
        let stream = CMIOExtensionStream(localizedName: cameraName, streamID: streamUUID, direction: .source, clockType: .hostTime, source: streamSource)
        streamSource.stream = stream

        do {
            try device.addStream(stream)
        } catch {
            os_log("[AIPhoneCamExt] Failed to add stream: %{public}@", log: extLog, type: .error, error.localizedDescription)
            return
        }

        let provider = CMIOExtensionProvider(source: providerSource, clientQueue: nil)
        providerSource.provider = provider

        do {
            try provider.addDevice(device)
        } catch {
            os_log("[AIPhoneCamExt] Failed to add device: %{public}@", log: extLog, type: .error, error.localizedDescription)
            return
        }

        CMIOExtensionProvider.startService(provider: provider)
        CFRunLoopRun()
    }
}

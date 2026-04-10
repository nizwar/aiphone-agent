import Foundation
import AVFoundation
import VideoToolbox

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
            print("[DECODER] WARNING: NAL buffer exceeded 2MB with no start codes found, flushing. Total bytes received: \(totalBytesReceived)")
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
            print("[DECODER] Got SPS (\(nal.count) bytes)")
            spsData = nal
            tryCreateFormatDescription()
        case 8: // PPS
            print("[DECODER] Got PPS (\(nal.count) bytes)")
            ppsData = nal
            tryCreateFormatDescription()
        case 5: // IDR slice (keyframe)
            if formatDescription == nil {
                tryCreateFormatDescription()
            }
            if formatDescription != nil {
                print("[DECODER] IDR keyframe (\(nal.count) bytes), total decoded: \(framesDecoded)")
                enqueueSampleBuffer(from: nal, isKeyframe: true)
            } else {
                print("[DECODER] IDR received but no format description yet, dropping")
            }
        case 1: // Non-IDR slice
            if formatDescription == nil {
                tryCreateFormatDescription()
            }
            if formatDescription != nil {
                enqueueSampleBuffer(from: nal, isKeyframe: false)
            }
        case 6, 9, 11, 12, 14:
            // 6=SEI, 9=AUD, 11=End of stream, 12=Filler, 14=Prefix NAL (SVC) — skip silently
            break
        default:
            print("[DECODER] Unknown NAL type \(nalType) (\(nal.count) bytes)")
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
            print("[DECODER] Format description created successfully: \(desc)")
            createDecompressionSession()
        } else {
            print("[DECODER] Failed to create format description, status=\(status)")
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
            print("[DECODER] VTDecompressionSession created for virtual camera")
        } else {
            print("[DECODER] Failed to create decompression session: \(status)")
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
            print("[DECODER] Display layer failed, flushing. Error: \(String(describing: displayLayer.error))")
            displayLayer.flush()
            waitingForKeyframe = true
        }

        // After a flush, wait for the next keyframe before enqueuing
        if waitingForKeyframe {
            if isKeyframe {
                waitingForKeyframe = false
                print("[DECODER] Recovered — re-seeding with IDR keyframe")
            } else {
                return
            }
        }

        // Don't enqueue if the layer's internal queue is full — detect stalls
        if !displayLayer.isReadyForMoreMediaData {
            consecutiveDrops += 1
            if consecutiveDrops > maxDropsBeforeFlush {
                print("[DECODER] Layer stalled (\(consecutiveDrops) drops), flushing")
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
            print("[DECODER] Enqueued frame #\(framesDecoded) (\(isKeyframe ? "IDR" : "P")) layer.status=\(displayLayer.status.rawValue)")
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

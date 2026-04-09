import Foundation
import CoreVideo
import IOSurface
import os.log

private let sfbLog = OSLog(subsystem: "id.wblue.aiphone.app", category: "SharedFrame")

// Darwin notify API — cross-process state sharing via notifyd.
// These work across sandbox boundaries and user identities.
@_silgen_name("notify_register_check")
private func _notify_register_check(_ name: UnsafePointer<CChar>,
                                     _ out_token: UnsafeMutablePointer<Int32>) -> UInt32
@_silgen_name("notify_set_state")
private func _notify_set_state(_ token: Int32, _ state64: UInt64) -> UInt32

@_silgen_name("notify_get_state")
private func _notify_get_state(_ token: Int32, _ state64: UnsafeMutablePointer<UInt64>) -> UInt32

@_silgen_name("notify_cancel")
private func _notify_cancel(_ token: Int32) -> UInt32

// Shared frame buffer for passing decoded video frames from the
// host app to the Camera Extension process.
//
// Uses IOSurface (kernel-managed shared memory) for pixel data and
// Darwin notify API for metadata (surface ID, frame dimensions, sequence).
//
// This combination works across App Sandbox and user boundaries because
// IOSurface is a kernel service and notify goes through notifyd.
//
// Main app:  writer (creates IOSurface + writes frames)
// Extension: reader (looks up IOSurface + reads frames)

struct SharedFrameHeader {
    var width: UInt32
    var height: UInt32
    var bytesPerRow: UInt32
    var _pad: UInt32
    var sequence: UInt64
    var timestamp: UInt64
}

final class SharedFrameBuffer {
    /// Notify name for the IOSurface ID (uint32, stored in lower 32 bits).
    private static let surfaceNotify = "id.wblue.aiphone.vcam.surfid"
    /// Notify name for frame info: sequence(32) | height(16) | width(16).
    private static let frameNotify = "id.wblue.aiphone.vcam.frame"

    /// For backward-compatible log messages in CameraExtensionMain.
    static let filePath: String = surfaceNotify

    private static let maxWidth = 1920
    private static let maxHeight = 1080
    static let headerSize = MemoryLayout<SharedFrameHeader>.size
    static let maxPixelBytes = maxWidth * maxHeight * 4
    static let totalSize = maxPixelBytes

    private var surface: IOSurface?
    private var sequence: UInt64 = 0
    private var surfaceToken: Int32 = 0
    private var frameToken: Int32 = 0

    deinit { close() }

    // MARK: - Writer (main app)

    func createForWriting() -> Bool {
        os_log("createForWriting IOSurface", log: sfbLog, type: .default)

        let props: [IOSurfacePropertyKey: Any] = [
            .width: Self.maxWidth,
            .height: Self.maxHeight,
            .bytesPerElement: 4,
            .bytesPerRow: Self.maxWidth * 4,
            .pixelFormat: UInt32(kCVPixelFormatType_32BGRA),
            IOSurfacePropertyKey(rawValue: kIOSurfaceIsGlobal as String): true
        ]
        surface = IOSurface(properties: props)
        guard let surface else {
            os_log("IOSurface creation failed", log: sfbLog, type: .error)
            return false
        }

        // Publish the surface ID so the extension can look it up.
        let sid = UInt64(IOSurfaceGetID(surface))
        _notify_register_check(Self.surfaceNotify, &surfaceToken)
        _notify_set_state(surfaceToken, sid)

        // Register frame-info token; initial state = 0 (no frames yet).
        _notify_register_check(Self.frameNotify, &frameToken)
        _notify_set_state(frameToken, 0)

        os_log("Writer IOSurface id=%llu (%dx%d)", log: sfbLog, type: .default,
               sid, Self.maxWidth, Self.maxHeight)
        return true
    }

    func writeFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let surface else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let dstRowBytes = surface.bytesPerRow
        let copyRowBytes = min(srcRowBytes, dstRowBytes)
        let maxH = min(h, Self.maxHeight)

        surface.lock(options: [], seed: nil)
        let dest = surface.baseAddress
        for row in 0..<maxH {
            memcpy(dest.advanced(by: row * dstRowBytes),
                   base.advanced(by: row * srcRowBytes),
                   copyRowBytes)
        }
        surface.unlock(options: [], seed: nil)

        sequence &+= 1
        // Pack: sequence(upper 32) | height(16) | width(16)
        let packed: UInt64 = (sequence << 32)
            | (UInt64(UInt16(clamping: h)) << 16)
            | UInt64(UInt16(clamping: w))
        _notify_set_state(frameToken, packed)
    }

    // MARK: - Reader (camera extension)

    func openForReading() -> Bool {
        // Cancel any previously registered tokens to avoid leaks
        if surfaceToken != 0 { _notify_cancel(surfaceToken); surfaceToken = 0 }
        if frameToken != 0 { _notify_cancel(frameToken); frameToken = 0 }

        _notify_register_check(Self.surfaceNotify, &surfaceToken)
        var sid: UInt64 = 0
        _notify_get_state(surfaceToken, &sid)
        guard sid > 0 else {
            os_log("No IOSurface ID published yet", log: sfbLog, type: .error)
            return false
        }

        surface = IOSurfaceLookup(IOSurfaceID(sid))
        guard surface != nil else {
            os_log("IOSurfaceLookup(%llu) failed", log: sfbLog, type: .error, sid)
            return false
        }

        _notify_register_check(Self.frameNotify, &frameToken)
        os_log("Reader mapped IOSurface id=%llu, frameToken=%d", log: sfbLog, type: .default, sid, frameToken)
        return true
    }

    private var headerLogCount = 0

    func readHeader() -> SharedFrameHeader? {
        guard surface != nil else { return nil }
        var packed: UInt64 = 0
        let rc = _notify_get_state(frameToken, &packed)
        let seq = packed >> 32
        let h = UInt32((packed >> 16) & 0xFFFF)
        let w = UInt32(packed & 0xFFFF)
        if headerLogCount < 5 {
            os_log("readHeader: rc=%u packed=0x%llx seq=%llu w=%u h=%u token=%d", log: sfbLog, type: .default,
                   rc, packed, seq, w, h, frameToken)
            headerLogCount += 1
        }
        guard seq > 0, w > 0, h > 0 else { return nil }
        return SharedFrameHeader(
            width: w, height: h,
            bytesPerRow: UInt32(surface!.bytesPerRow),
            _pad: 0, sequence: seq, timestamp: 0
        )
    }

    func readFrame(into pixelBuffer: CVPixelBuffer) -> UInt64 {
        guard let surface else { return 0 }
        var packed: UInt64 = 0
        _notify_get_state(frameToken, &packed)
        let seq = packed >> 32
        let h = Int((packed >> 16) & 0xFFFF)
        guard seq > 0, h > 0 else { return 0 }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let dest = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let srcRowBytes = surface.bytesPerRow
        let dstRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let copyRowBytes = min(srcRowBytes, dstRowBytes)
        let maxH = min(h, CVPixelBufferGetHeight(pixelBuffer))

        surface.lock(options: .readOnly, seed: nil)
        let src = surface.baseAddress
        for row in 0..<maxH {
            memcpy(dest.advanced(by: row * dstRowBytes),
                   src.advanced(by: row * srcRowBytes),
                   copyRowBytes)
        }
        surface.unlock(options: .readOnly, seed: nil)
        return seq
    }

    // MARK: - Cleanup

    func close() {
        surface = nil
        if surfaceToken != 0 { _notify_cancel(surfaceToken); surfaceToken = 0 }
        if frameToken != 0 { _notify_cancel(frameToken); frameToken = 0 }
    }

    func unlink() {
        // Clear the notify state so readers know the surface is gone.
        if surfaceToken != 0 { _notify_set_state(surfaceToken, 0) }
        if frameToken != 0 { _notify_set_state(frameToken, 0) }
    }
}

import Foundation
import CoreVideo

/// A minimal placeholder for a shared frame buffer that will eventually back
/// a virtual camera via shared memory. This implementation keeps the last
/// frame in memory so the project compiles and runs without crashing.
///
/// TODO: Replace with a shared-memory implementation (e.g., POSIX shm + mmap)
/// that coordinates with the Camera Extension process.
final class SharedFrameBuffer {
    private let queue = DispatchQueue(label: "com.aiphone.sharedframebuffer", qos: .userInitiated)
    private var isOpenForWriting = false
    private var lastFramePixelBuffer: CVPixelBuffer?
    
    /// Prepare the buffer for writing frames.
    /// Return true on success.
    @discardableResult
    func createForWriting() -> Bool {
        var success = false
        queue.sync {
            // Placeholder: mark as open. In a real implementation, create/open
            // a shared memory region and write a header describing the frame format.
            self.isOpenForWriting = true
            success = true
        }
        return success
    }
    
    /// Write a frame into the buffer. No-op if not open.
    func writeFrame(_ pixelBuffer: CVPixelBuffer) {
        queue.async {
            guard self.isOpenForWriting else { return }
            // Placeholder: retain the last frame so callers can verify flow.
            // In a real implementation, copy pixel data into shared memory
            // with appropriate synchronization.
            self.lastFramePixelBuffer = pixelBuffer
        }
    }
    
    /// Close the buffer and release resources.
    func close() {
        queue.sync {
            // Placeholder: mark closed. In a real implementation, unmap memory
            // and close file descriptors.
            self.isOpenForWriting = false
        }
    }
    
    /// Remove the shared memory object if applicable.
    func unlink() {
        queue.sync {
            // Placeholder: nothing to unlink for in-memory storage.
            self.lastFramePixelBuffer = nil
        }
    }
}

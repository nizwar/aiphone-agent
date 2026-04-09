import Foundation
import Combine
import os.log

private let camOptLog = OSLog(subsystem: "id.wblue.aiphone.app", category: "CameraOptions")

// MARK: - Models

struct DeviceCamera: Identifiable, Hashable {
    let id: String          // e.g. "0", "1"
    let name: String        // e.g. "back (0)", "front (1)"
    let facing: String      // "back" or "front"
    let fpsValues: [Int]    // e.g. [15, 20, 24, 30]
}

struct CameraSize: Identifiable, Hashable {
    var id: String { "\(width)x\(height)" }
    let width: Int
    let height: Int
    var label: String { "\(width)×\(height)" }
}

// MARK: - Store

/// Shared store for camera options (camera selection, resolution, FPS).
/// Queries the Android device's cameras via scrcpy-server.
final class CameraOptionsStore: ObservableObject {
    static let shared = CameraOptionsStore()

    // MARK: Published

    @Published var cameras: [DeviceCamera] = []
    @Published var selectedCameraID: String = "0"

    @Published var sizes: [CameraSize] = []
    @Published var selectedSize: CameraSize?

    @Published var fpsOptions: [Int] = [30]
    @Published var selectedFPS: Int = 30

    @Published private(set) var isQuerying = false

    private var queriedDeviceID: String?
    /// Cached sizes per camera from last query — avoids re-querying when switching cameras.
    private var cachedSizesByCamera: [String: [CameraSize]] = [:]

    // MARK: - Query

    /// Query all camera info (cameras + sizes + fps) in one call.
    /// Uses `list_camera_sizes=true` which includes both camera list and sizes.
    func queryDeviceCameras(deviceID: String) {
        guard !isQuerying else { return }
        isQuerying = true
        queriedDeviceID = deviceID

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 0. Push scrcpy-server jar to the device (required before querying)
            do {
                let localJar = try ScrcpyServerProvider.bundledServerPath()
                let pushResult = ScrcpyServerProvider.runADB(
                    arguments: ["push", localJar, "/data/local/tmp/scrcpy-server.jar"],
                    deviceID: deviceID
                )
                if !pushResult.succeeded {
                    os_log("Failed to push scrcpy-server: %{public}@", log: camOptLog, type: .error, pushResult.errorMessage)
                }
            } catch {
                os_log("scrcpy-server not found in bundle: %{public}@", log: camOptLog, type: .error, error.localizedDescription)
                DispatchQueue.main.async { self?.isQuerying = false }
                return
            }

            // 1. Clear logcat
            _ = ScrcpyServerProvider.runADB(arguments: ["logcat", "-c"], deviceID: deviceID)

            // 2. Run list_camera_sizes (includes camera list + all sizes)
            let result = ScrcpyServerProvider.runADB(
                arguments: ["shell", "CLASSPATH=/data/local/tmp/scrcpy-server.jar",
                            "app_process", "/", "com.genymobile.scrcpy.Server",
                            kScrcpyServerVersion, "list_camera_sizes=true", "log_level=INFO"],
                deviceID: deviceID
            )

            // 3. Wait for logcat and collect
            Thread.sleep(forTimeInterval: 2)
            let logcat = ScrcpyServerProvider.runADB(
                arguments: ["logcat", "-d", "-s", "scrcpy:I"],
                deviceID: deviceID
            )

            let combined = result.stdout + "\n" + result.stderr + "\n" + logcat.stdout
            os_log("list_camera_sizes output:\n%{public}@", log: camOptLog, type: .default, combined)

            let parsed = Self.parseAll(from: combined)

            DispatchQueue.main.async {
                guard let self else { return }
                self.cameras = parsed.cameras
                self.cachedSizesByCamera = parsed.sizesByCamera

                // Select camera
                if !parsed.cameras.isEmpty && !(parsed.cameras.contains { $0.id == self.selectedCameraID }) {
                    self.selectedCameraID = parsed.cameras[0].id
                }

                // Apply sizes/fps for the selected camera from cache
                self.applyCameraSelection(self.selectedCameraID)
                self.isQuerying = false
            }
        }
    }

    /// Update sizes and FPS when camera selection changes (uses cached data, no re-query).
    func selectCamera(_ cameraID: String) {
        selectedCameraID = cameraID
        applyCameraSelection(cameraID)
    }

    /// Apply the cached sizes and FPS for a given camera ID.
    private func applyCameraSelection(_ cameraID: String) {
        // FPS from camera model
        if let cam = cameras.first(where: { $0.id == cameraID }), !cam.fpsValues.isEmpty {
            fpsOptions = cam.fpsValues
            if !cam.fpsValues.contains(selectedFPS) {
                selectedFPS = cam.fpsValues.last ?? 30
            }
        }

        // Sizes from cache
        let cameraSizes = cachedSizesByCamera[cameraID] ?? []
        sizes = cameraSizes
        if !cameraSizes.contains(where: { $0 == selectedSize }) {
            selectedSize = cameraSizes.first(where: { $0.width == 1280 && $0.height == 720 })
                ?? cameraSizes.first(where: { min($0.width, $0.height) >= 720 })
                ?? cameraSizes.first
        }
    }

    // MARK: - Scrcpy Extra Params

    var scrcpyExtraParams: [String] {
        var params = ["video_source=camera", "camera_id=\(selectedCameraID)"]
        if let size = selectedSize {
            params.append("camera_size=\(size.width)x\(size.height)")
        }
        params.append("camera_fps=\(selectedFPS)")
        return params
    }

    var maxSize: Int {
        guard let size = selectedSize else { return 720 }
        return min(size.width, size.height)
    }

    // MARK: - Parsing

    private struct ParseResult {
        var cameras: [DeviceCamera]
        var sizesByCamera: [String: [CameraSize]]  // camera ID → sizes
    }

    /// Parse the combined output of `list_camera_sizes=true`.
    ///
    /// Format:
    /// ```
    ///     --camera-id=0    (back, 4000x3000, fps=[15, 20, 24, 30])
    ///         - 3968x2976
    ///         - 1920x1080
    ///     --camera-id=1    (front, 3264x2448, fps=[15, 20, 24, 30])
    ///         - 3264x2448
    /// ```
    private static func parseAll(from output: String) -> ParseResult {
        var cameras: [DeviceCamera] = []
        var sizesByCamera: [String: [CameraSize]] = [:]
        var currentCameraID: String?

        let lines = output.components(separatedBy: .newlines)
        var seen = Set<String>()  // avoid duplicates from stdout + logcat

        for line in lines {
            // Match: --camera-id=0    (back, 4000x3000, fps=[15, 20, 24, 30])
            if line.contains("--camera-id=") {
                // Extract camera ID
                guard let idRange = line.range(of: #"--camera-id=(\d+)"#, options: .regularExpression) else { continue }
                let camID = String(line[idRange]).replacingOccurrences(of: "--camera-id=", with: "")

                // Skip duplicates
                if seen.contains(camID) {
                    currentCameraID = nil
                    continue
                }

                // Extract facing: first word inside parentheses
                var facing = "unknown"
                if let parenRange = line.range(of: #"\((\w+)"#, options: .regularExpression) {
                    facing = String(line[parenRange]).replacingOccurrences(of: "(", with: "")
                }

                // Extract FPS: fps=[15, 20, 24, 30]
                var fpsValues: [Int] = []
                if let fpsRange = line.range(of: #"fps=\[([^\]]+)\]"#, options: .regularExpression) {
                    let fpsStr = String(line[fpsRange])
                        .replacingOccurrences(of: "fps=[", with: "")
                        .replacingOccurrences(of: "]", with: "")
                    fpsValues = fpsStr.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }

                let name = "\(facing) (\(camID))"
                cameras.append(DeviceCamera(id: camID, name: name, facing: facing, fpsValues: fpsValues))
                sizesByCamera[camID] = []
                currentCameraID = camID
                seen.insert(camID)

            } else if let camID = currentCameraID {
                // Match size lines: "        - 1920x1080"
                if let sizeRange = line.range(of: #"(\d{3,5})x(\d{3,5})"#, options: .regularExpression) {
                    let sizeStr = String(line[sizeRange])
                    let parts = sizeStr.components(separatedBy: "x")
                    if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                        let size = CameraSize(width: w, height: h)
                        if !(sizesByCamera[camID]?.contains(size) ?? false) {
                            sizesByCamera[camID, default: []].append(size)
                        }
                    }
                }
            }
        }

        return ParseResult(cameras: cameras, sizesByCamera: sizesByCamera)
    }
}

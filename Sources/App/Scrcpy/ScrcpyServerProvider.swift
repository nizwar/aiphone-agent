import Foundation
import Network

// MARK: - Shared scrcpy-server helpers

/// Version of the bundled scrcpy-server jar.
let kScrcpyServerVersion = "3.3.4"

/// Result of an ADB shell command.
struct ADBCommandOutput: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
    var errorMessage: String { stderr.isEmpty ? stdout : stderr }
}

/// Errors from scrcpy-server lifecycle operations.
enum ScrcpyServerError: LocalizedError {
    case serverNotFound
    case pushFailed(String)
    case forwardFailed(String)
    case serverDied(String)

    var errorDescription: String? {
        switch self {
        case .serverNotFound:
            return "scrcpy-server not found in app bundle."
        case .pushFailed(let msg):
            return "Failed to push scrcpy-server: \(msg)"
        case .forwardFailed(let msg):
            return "Failed to set up ADB port forwarding: \(msg)"
        case .serverDied(let msg):
            return "scrcpy server failed: \(msg)"
        }
    }
}

/// Configuration for launching a scrcpy-server instance.
struct ScrcpyServerConfig {
    let deviceID: String
    let port: Int
    let scid: Int
    let maxSize: Int
    /// Extra server parameters appended after the defaults (e.g. `video_source=camera`).
    var extraParams: [String] = []
    /// Whether a unique jar should be pushed per session (`true` for multi-instance support).
    var uniqueJar: Bool = true
    /// Cleanup flag sent to scrcpy-server.
    var cleanup: Bool = true

    var socketName: String { String(format: "scrcpy_%08x", scid) }
}

/// A running scrcpy-server on a device, ready for TCP connection.
final class ScrcpyServerHandle {
    let deviceID: String
    let port: Int
    let scid: Int
    let remotePath: String
    let process: Process
    let stderrPipe: Pipe

    init(deviceID: String, port: Int, scid: Int, remotePath: String, process: Process, stderrPipe: Pipe) {
        self.deviceID = deviceID
        self.port = port
        self.scid = scid
        self.remotePath = remotePath
        self.process = process
        self.stderrPipe = stderrPipe
    }
}

/// Shared provider for scrcpy-server lifecycle: push, forward, launch, connect, cleanup.
enum ScrcpyServerProvider {

    // MARK: - ADB command execution

    nonisolated static func runADB(arguments: [String], deviceID: String? = nil) -> ADBCommandOutput {
        let adbPath = ToolPathResolver.resolveExecutable(ToolPathResolver.adbPath()) ?? "adb"
        return runADB(adbPath: adbPath, arguments: arguments, deviceID: deviceID)
    }

    nonisolated static func runADB(adbPath: String, arguments: [String], deviceID: String?) -> ADBCommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var args = [adbPath]
        if let deviceID, !deviceID.isEmpty {
            args.append(contentsOf: ["-s", deviceID])
        }
        args.append(contentsOf: arguments)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return ADBCommandOutput(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
        } catch {
            return ADBCommandOutput(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }
    }

    // MARK: - Bundled server jar

    nonisolated static func bundledServerPath() throws -> String {
        var searchBundles: [Bundle] = [.main]
        #if SWIFT_PACKAGE
        searchBundles.append(.module)
        #endif
        for bundle in searchBundles {
            if let url = bundle.url(forResource: "scrcpy-server", withExtension: nil) {
                return url.path
            }
            if let resourceURL = bundle.resourceURL {
                let fallback = resourceURL.appendingPathComponent("scrcpy-server")
                if FileManager.default.fileExists(atPath: fallback.path) {
                    return fallback.path
                }
            }
        }
        throw ScrcpyServerError.serverNotFound
    }

    // MARK: - Full launch sequence: push → forward → start server

    /// Push the server jar, set up port forwarding, and launch the scrcpy-server process.
    /// Returns a `ScrcpyServerHandle` ready for TCP connection on `localhost:<config.port>`.
    nonisolated static func launch(config: ScrcpyServerConfig) async throws -> ScrcpyServerHandle {
        let localJarPath = try bundledServerPath()
        let adbPath = ToolPathResolver.resolveExecutable(ToolPathResolver.adbPath()) ?? "adb"
        let deviceID = config.deviceID
        let port = config.port
        let socketName = config.socketName

        // Determine the remote jar path (unique per session or shared).
        let remotePath: String
        if config.uniqueJar {
            let suffix = String(format: "%08x", Int.random(in: 0...Int(Int32.max)))
            remotePath = "/data/local/tmp/scrcpy-server-\(suffix).jar"
        } else {
            remotePath = "/data/local/tmp/scrcpy-server.jar"
        }

        // Remove stale forward for this port.
        let _ = await Task.detached {
            runADB(adbPath: adbPath, arguments: ["forward", "--remove", "tcp:\(port)"], deviceID: deviceID)
        }.value
        try await Task.sleep(nanoseconds: 300_000_000)

        // Push server jar.
        let pushResult = await Task.detached {
            runADB(adbPath: adbPath, arguments: ["push", localJarPath, remotePath], deviceID: deviceID)
        }.value
        guard pushResult.succeeded else {
            throw ScrcpyServerError.pushFailed(pushResult.errorMessage)
        }

        // Forward TCP port to the unique abstract socket.
        let forwardResult = await Task.detached {
            runADB(adbPath: adbPath, arguments: ["forward", "tcp:\(port)", "localabstract:\(socketName)"], deviceID: deviceID)
        }.value
        guard forwardResult.succeeded else {
            throw ScrcpyServerError.forwardFailed(forwardResult.errorMessage)
        }

        // Build server arguments.
        var serverArgs = [
            adbPath, "-s", deviceID, "shell",
            "CLASSPATH=\(remotePath)",
            "app_process", "/", "com.genymobile.scrcpy.Server", kScrcpyServerVersion,
            "scid=\(String(format: "%08x", config.scid))",
            "tunnel_forward=true",
            "audio=false",
            "control=false",
            "cleanup=\(config.cleanup)",
            "raw_stream=false",
            "send_frame_meta=true",
            "video_codec=h264",
            "max_size=\(config.maxSize)",
        ]
        serverArgs.append(contentsOf: config.extraParams)

        // Launch the server process.
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = serverArgs
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()

        // Wait for the server to bind its socket.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        guard process.isRunning else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            removeForward(port: port, deviceID: deviceID)
            removeRemoteJar(remotePath: remotePath, deviceID: deviceID)
            throw ScrcpyServerError.serverDied(stderrText.isEmpty ? "Server exited immediately" : stderrText)
        }

        return ScrcpyServerHandle(
            deviceID: deviceID,
            port: port,
            scid: config.scid,
            remotePath: remotePath,
            process: process,
            stderrPipe: stderrPipe
        )
    }

    // MARK: - TCP connection

    /// Open a TCP connection to a running server handle and start reading H.264 into the decoder.
    /// `onSessionEnd` is called when the connection closes or fails.
    @MainActor
    static func connect(
        handle: ScrcpyServerHandle,
        decoder: H264StreamDecoder,
        onSessionEnd: @escaping @Sendable () -> Void
    ) -> NWConnection {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: UInt16(handle.port))!,
            using: .tcp
        )

        connection.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready:
                    readLoop(connection: connection, decoder: decoder, onEnd: onSessionEnd)
                case .failed:
                    onSessionEnd()
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }

        connection.start(queue: .global(qos: .userInteractive))
        return connection
    }

    // MARK: - Cleanup

    nonisolated static func teardown(handle: ScrcpyServerHandle) {
        if handle.process.isRunning {
            handle.process.terminate()
        }
        removeForward(port: handle.port, deviceID: handle.deviceID)
        removeRemoteJar(remotePath: handle.remotePath, deviceID: handle.deviceID)
    }

    nonisolated static func removeForward(port: Int, deviceID: String) {
        _ = runADB(arguments: ["forward", "--remove", "tcp:\(port)"], deviceID: deviceID)
    }

    nonisolated static func removeRemoteJar(remotePath: String, deviceID: String) {
        _ = runADB(arguments: ["shell", "rm", "-f", remotePath], deviceID: deviceID)
    }

    // MARK: - Private

    private nonisolated static func readLoop(
        connection: NWConnection,
        decoder: H264StreamDecoder,
        onEnd: @escaping @Sendable () -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
            if let content, !content.isEmpty {
                DispatchQueue.main.async {
                    decoder.feed(content)
                }
            }

            if isComplete || error != nil {
                onEnd()
                return
            }

            readLoop(connection: connection, decoder: decoder, onEnd: onEnd)
        }
    }
}

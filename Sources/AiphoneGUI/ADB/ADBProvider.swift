import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

protocol ADBProviding: Sendable {
    func listDevices() -> [ADBDeviceInfo]
    func getDeviceInfo(deviceID: String?) -> ADBDeviceInfo?
    func isConnected(deviceID: String?) -> Bool

    func connect(_ address: String) -> (Bool, String)
    func disconnect(_ address: String?) -> (Bool, String)
    func enableTCPIP(port: Int, deviceID: String?) -> (Bool, String)
    func getDeviceIP(deviceID: String?) -> String?
    func getDeviceIPs(deviceID: String?) -> [String]
    func restartServer() -> (Bool, String)

    func shell(_ command: String, deviceID: String?) throws -> String
    func getCurrentApp(deviceID: String?) throws -> String
    func tap(x: Int, y: Int, deviceID: String?, delay: TimeInterval?) throws
    func doubleTap(x: Int, y: Int, deviceID: String?, delay: TimeInterval?) throws
    func longPress(x: Int, y: Int, durationMS: Int, deviceID: String?, delay: TimeInterval?) throws
    func swipe(startX: Int, startY: Int, endX: Int, endY: Int, durationMS: Int?, deviceID: String?, delay: TimeInterval?) throws
    func back(deviceID: String?, delay: TimeInterval?) throws
    func home(deviceID: String?, delay: TimeInterval?) throws
    func listInstalledPackages(deviceID: String?) -> [String]
    func getDeviceDetails(deviceID: String?) -> ADBDeviceDetails
    func launchApp(_ appName: String, deviceID: String?, delay: TimeInterval?) throws -> ADBAppLaunchResult

    func typeText(_ text: String, deviceID: String?) throws
    func clearText(deviceID: String?) throws

    func getScreenshot(deviceID: String?, includeBase64: Bool) throws -> ADBScreenshot
    func getDeviceRuntimeStatus(deviceID: String?) -> ADBDeviceRuntimeStatus
}

extension ADBProviding {
    func getScreenshot(deviceID: String?) throws -> ADBScreenshot {
        try getScreenshot(deviceID: deviceID, includeBase64: true)
    }
}

final class ADBProvider: ADBProviding, @unchecked Sendable {
    static let shared = ADBProvider()

    private struct CachedScreenshotEntry {
        let screenshot: ADBScreenshot
        let capturedAt: Date
    }

    private let fallbackADBPath: String
    private let screenshotCacheLock = NSLock()
    private var screenshotCache: [String: CachedScreenshotEntry] = [:]
    private let screenshotReuseInterval: TimeInterval = 0.25

    init(adbPath: String = "adb") {
        let trimmedPath = adbPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fallbackADBPath = trimmedPath.isEmpty ? "adb" : trimmedPath
    }

    private var resolvedADBPath: String {
        let configuredPath = UserDefaults.standard.string(forKey: AppSettingsKeys.adbExecutablePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configuredPath.isEmpty ? fallbackADBPath : configuredPath
    }

    // MARK: - Connection management

    func listDevices() -> [ADBDeviceInfo] {
        do {
            let result = try runADB(["devices", "-l"])
            return parseDevices(from: result.standardOutput)
        } catch {
            return []
        }
    }

    func getDeviceInfo(deviceID: String? = nil) -> ADBDeviceInfo? {
        let devices = listDevices()
        guard !devices.isEmpty else { return nil }

        guard let deviceID else {
            return devices.first
        }

        return devices.first(where: { $0.deviceID == deviceID })
    }

    func isConnected(deviceID: String? = nil) -> Bool {
        let devices = listDevices()
        guard !devices.isEmpty else { return false }

        guard let deviceID else {
            return devices.contains(where: { $0.status == "device" })
        }

        return devices.contains(where: { $0.deviceID == deviceID && $0.status == "device" })
    }

    func connect(_ address: String) -> (Bool, String) {
        let normalizedAddress = address.contains(":") ? address : "\(address):5555"

        do {
            let result = try runADB(["connect", normalizedAddress])
            let output = result.combinedOutput.lowercased()

            if output.contains("connected") || output.contains("already connected") {
                return (true, result.combinedOutput.isEmpty ? "Connected to \(normalizedAddress)" : result.combinedOutput)
            }

            return (false, result.combinedOutput.isEmpty ? "Failed to connect to \(normalizedAddress)" : result.combinedOutput)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func disconnect(_ address: String? = nil) -> (Bool, String) {
        do {
            var arguments = ["disconnect"]
            if let address, !address.isEmpty {
                arguments.append(address)
            }

            let result = try runADB(arguments)
            return (true, result.combinedOutput.isEmpty ? "Disconnected" : result.combinedOutput)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func enableTCPIP(port: Int = 5555, deviceID: String? = nil) -> (Bool, String) {
        do {
            let result = try runADB(["tcpip", String(port)], deviceID: deviceID)
            let output = result.combinedOutput.lowercased()

            if output.contains("restarting") || result.succeeded {
                Thread.sleep(forTimeInterval: ADBTiming.adbRestartDelay)
                return (true, "TCP/IP mode enabled on port \(port)")
            }

            return (false, result.combinedOutput)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func getDeviceIP(deviceID: String? = nil) -> String? {
        getDeviceIPs(deviceID: deviceID).first
    }

    func getDeviceIPs(deviceID: String? = nil) -> [String] {
        let commands: [[String]] = [
            ["shell", "ip", "route"],
            ["shell", "ip", "addr", "show"],
            ["shell", "ifconfig"],
            ["shell", "getprop", "dhcp.wlan0.ipaddress"],
            ["shell", "getprop", "dhcp.eth0.ipaddress"],
            ["shell", "getprop", "dhcp.ap.br0.ipaddress"],
            ["shell", "sh", "-c", "if command -v curl >/dev/null 2>&1; then curl -fsS --max-time 4 https://api.ipify.org; elif command -v wget >/dev/null 2>&1; then wget -qO- https://api.ipify.org; fi"]
        ]

        var seen = Set<String>()
        var addresses: [String] = []

        for command in commands {
            guard let output = try? runADB(command, deviceID: deviceID).standardOutput else {
                continue
            }

            for address in extractIPAddresses(from: output) where seen.insert(address).inserted {
                addresses.append(address)
            }
        }

        return addresses
    }

    func restartServer() -> (Bool, String) {
        do {
            _ = try runADB(["kill-server"])
            Thread.sleep(forTimeInterval: ADBTiming.serverRestartDelay)
            _ = try runADB(["start-server"])
            return (true, "ADB server restarted")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Device control

    func shell(_ command: String, deviceID: String? = nil) throws -> String {
        let result = try runADB(["shell", "sh", "-c", command], deviceID: deviceID)
        if !result.succeeded && !result.combinedOutput.isEmpty {
            throw ADBProviderError.commandFailed(result.combinedOutput)
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func getCurrentApp(deviceID: String? = nil) throws -> String {
        let result = try runADB(["shell", "dumpsys", "window"], deviceID: deviceID)
        let output = result.standardOutput

        guard !output.isEmpty else {
            throw ADBProviderError.missingOutput("No output from `dumpsys window`.")
        }

        for line in output.split(separator: "\n") {
            let currentLine = String(line)
            guard currentLine.contains("mCurrentFocus") || currentLine.contains("mFocusedApp") else {
                continue
            }

            if let package = extractFocusedPackage(from: currentLine) {
                return ADBAppCatalog.appName(for: package) ?? package
            }
        }

        return "System Home"
    }

    func tap(x: Int, y: Int, deviceID: String? = nil, delay: TimeInterval? = nil) throws {
        _ = try runADB(["shell", "input", "tap", String(x), String(y)], deviceID: deviceID)
        Thread.sleep(forTimeInterval: delay ?? ADBTiming.defaultTapDelay)
    }

    func doubleTap(x: Int, y: Int, deviceID: String? = nil, delay: TimeInterval? = nil) throws {
        _ = try runADB(["shell", "input", "tap", String(x), String(y)], deviceID: deviceID)
        Thread.sleep(forTimeInterval: ADBTiming.doubleTapInterval)
        _ = try runADB(["shell", "input", "tap", String(x), String(y)], deviceID: deviceID)
        Thread.sleep(forTimeInterval: delay ?? ADBTiming.defaultDoubleTapDelay)
    }

    func longPress(x: Int, y: Int, durationMS: Int = 3000, deviceID: String? = nil, delay: TimeInterval? = nil) throws {
        _ = try runADB(["shell", "input", "swipe", String(x), String(y), String(x), String(y), String(durationMS)], deviceID: deviceID)
        Thread.sleep(forTimeInterval: delay ?? ADBTiming.defaultLongPressDelay)
    }

    func swipe(
        startX: Int,
        startY: Int,
        endX: Int,
        endY: Int,
        durationMS: Int? = nil,
        deviceID: String? = nil,
        delay: TimeInterval? = nil
    ) throws {
        let resolvedDuration: Int = {
            if let durationMS {
                return durationMS
            }
            let distanceSquared = (startX - endX) * (startX - endX) + (startY - endY) * (startY - endY)
            return max(1000, min(distanceSquared / 1000, 2000))
        }()

        _ = try runADB(
            [
                "shell", "input", "swipe",
                String(startX), String(startY),
                String(endX), String(endY),
                String(resolvedDuration)
            ],
            deviceID: deviceID
        )

        Thread.sleep(forTimeInterval: delay ?? ADBTiming.defaultSwipeDelay)
    }

    func back(deviceID: String? = nil, delay: TimeInterval? = nil) throws {
        _ = try runADB(["shell", "input", "keyevent", "4"], deviceID: deviceID)
        Thread.sleep(forTimeInterval: delay ?? ADBTiming.defaultBackDelay)
    }

    func home(deviceID: String? = nil, delay: TimeInterval? = nil) throws {
        _ = try runADB(["shell", "input", "keyevent", "KEYCODE_HOME"], deviceID: deviceID)
        Thread.sleep(forTimeInterval: delay ?? ADBTiming.defaultHomeDelay)
    }

    func listInstalledPackages(deviceID: String? = nil) -> [String] {
        (try? queryInstalledPackages(deviceID: deviceID)) ?? []
    }

    func launchApp(_ appName: String, deviceID: String? = nil, delay: TimeInterval? = nil) throws -> ADBAppLaunchResult {
        let trimmedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAppName.isEmpty else {
            return ADBAppLaunchResult(
                succeeded: false,
                appName: appName,
                packageName: nil,
                didOpenStore: false,
                message: "No app name or package was provided to Launch."
            )
        }

        for candidate in ADBAppCatalog.candidatePackages(for: trimmedAppName) {
            if try launchInstalledPackage(candidate, deviceID: deviceID, delay: delay) {
                let resolvedName = ADBAppCatalog.appName(for: candidate) ?? trimmedAppName
                return ADBAppLaunchResult(
                    succeeded: true,
                    appName: resolvedName,
                    packageName: candidate,
                    didOpenStore: false,
                    message: "Opened \(resolvedName) using package \(candidate)."
                )
            }
        }

        if let storeResult = try? openStoreListing(for: trimmedAppName, deviceID: deviceID, delay: delay) {
            return ADBAppLaunchResult(
                succeeded: storeResult.succeeded,
                appName: storeResult.appName,
                packageName: storeResult.packageName,
                didOpenStore: storeResult.didOpenStore,
                message: "Could not directly launch \(trimmedAppName), so Google Play was opened."
            )
        }

        return ADBAppLaunchResult(
            succeeded: false,
            appName: trimmedAppName,
            packageName: nil,
            didOpenStore: false,
            message: "Could not launch \(trimmedAppName) or open its Play Store listing."
        )
    }

    // MARK: - Keyboard input

    func typeText(_ text: String, deviceID: String? = nil) throws {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalizedText.isEmpty else { return }

        if try typeTextWithADBKeyboard(normalizedText, deviceID: deviceID) {
            return
        }

        try typeTextWithFallback(normalizedText, deviceID: deviceID)
    }

    func clearText(deviceID: String? = nil) throws {
        if try clearTextWithADBKeyboard(deviceID: deviceID) {
            return
        }

        _ = try? runADB(["shell", "input", "keyevent", "KEYCODE_MOVE_END"], deviceID: deviceID)

        for _ in 0..<80 {
            _ = try? runADB(["shell", "input", "keyevent", "67"], deviceID: deviceID)
        }
    }

    // MARK: - Screenshot

    func getScreenshot(deviceID: String? = nil, includeBase64: Bool = true) throws -> ADBScreenshot {
        let cacheKey = deviceID ?? "__default__"
        if let cached = cachedScreenshot(for: cacheKey, includeBase64: includeBase64) {
            return cached
        }

        let prefersShellCapture = (deviceID?.hasPrefix("emulator-") == true)
        let attempts: [([String], Bool)] = prefersShellCapture
            ? [
                (["shell", "screencap", "-p"], true),
                (["exec-out", "screencap", "-p"], false),
                (["shell", "sh", "-c", "screencap -p 2>/dev/null"], true)
            ]
            : [
                (["exec-out", "screencap", "-p"], false),
                (["shell", "screencap", "-p"], true),
                (["shell", "sh", "-c", "screencap -p 2>/dev/null"], true)
            ]

        var lastError: Error?

        for (arguments, normalizesLineEndings) in attempts {
            do {
                if let screenshot = try captureScreenshot(
                    arguments: arguments,
                    deviceID: deviceID,
                    normalizesLineEndings: normalizesLineEndings,
                    includeBase64: includeBase64
                ) {
                    cacheScreenshot(screenshot, for: cacheKey)
                    return screenshot
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }

        throw ADBProviderError.invalidImageData
    }

    func getDeviceRuntimeStatus(deviceID: String? = nil) -> ADBDeviceRuntimeStatus {
        let batteryOutput = (try? runADB(["shell", "dumpsys", "battery"], deviceID: deviceID)).map(\ .standardOutput) ?? ""
        let wifiOutput = (try? runADB(["shell", "cmd", "wifi", "status"], deviceID: deviceID)).map(\ .standardOutput) ??
            ((try? runADB(["shell", "dumpsys", "wifi"], deviceID: deviceID)).map(\ .standardOutput) ?? "")
        let mobileDataOutput = (try? runADB(["shell", "settings", "get", "global", "mobile_data"], deviceID: deviceID)).map(\ .standardOutput) ??
            ((try? runADB(["shell", "dumpsys", "telephony.registry"], deviceID: deviceID)).map(\ .standardOutput) ?? "")
        let currentApp = try? getCurrentApp(deviceID: deviceID)

        return ADBDeviceRuntimeStatus(
            batteryLevel: parseBatteryLevel(from: batteryOutput),
            wifiStatus: parseWiFiStatus(from: wifiOutput),
            dataStatus: parseMobileDataStatus(from: mobileDataOutput),
            currentApp: currentApp
        )
    }

    func getDeviceDetails(deviceID: String? = nil) -> ADBDeviceDetails {
        let info = getDeviceInfo(deviceID: deviceID)
        let runtime = getDeviceRuntimeStatus(deviceID: deviceID)
        let packages = listInstalledPackages(deviceID: deviceID)
        let propsOutput = (try? runADB(["shell", "getprop"], deviceID: deviceID)).map(\ .standardOutput) ?? ""
        let properties = parseDeviceProperties(from: propsOutput)
        let wmSize = try? shell("wm size 2>/dev/null | head -n 1", deviceID: deviceID)
        let wmDensity = try? shell("wm density 2>/dev/null | head -n 1", deviceID: deviceID)

        return ADBDeviceDetails(
            deviceID: info?.deviceID ?? (deviceID ?? "Unknown"),
            status: info?.status ?? "unknown",
            connectionType: info?.connectionType ?? .usb,
            model: info?.model ?? properties["ro.product.model"],
            manufacturer: properties["ro.product.manufacturer"],
            brand: properties["ro.product.brand"],
            productName: properties["ro.product.name"],
            deviceName: properties["ro.product.device"],
            androidVersion: info?.androidVersion ?? properties["ro.build.version.release"],
            sdkVersion: properties["ro.build.version.sdk"],
            cpuABI: properties["ro.product.cpu.abi"],
            buildFingerprint: properties["ro.build.fingerprint"],
            securityPatch: properties["ro.build.version.security_patch"],
            screenResolution: cleanedWMValue(from: wmSize),
            screenDensity: cleanedWMValue(from: wmDensity),
            batteryLevel: runtime.batteryLevel,
            wifiStatus: runtime.wifiStatus,
            dataStatus: runtime.dataStatus,
            currentApp: runtime.currentApp,
            packageCount: packages.count,
            playStoreInstalled: packages.contains("com.android.vending"),
            installedAppsPreview: ADBAppCatalog.installedAppHints(from: packages, limit: 40)
        )
    }

    // MARK: - Python-style aliases

    func quick_connect(_ address: String) -> (Bool, String) {
        connect(address)
    }

    func list_devices() -> [ADBDeviceInfo] {
        listDevices()
    }

    func get_device_info(device_id: String? = nil) -> ADBDeviceInfo? {
        getDeviceInfo(deviceID: device_id)
    }

    func is_connected(device_id: String? = nil) -> Bool {
        isConnected(deviceID: device_id)
    }

    func enable_tcpip(_ port: Int = 5555, device_id: String? = nil) -> (Bool, String) {
        enableTCPIP(port: port, deviceID: device_id)
    }

    func get_device_ip(device_id: String? = nil) -> String? {
        getDeviceIP(deviceID: device_id)
    }

    func get_device_ips(device_id: String? = nil) -> [String] {
        getDeviceIPs(deviceID: device_id)
    }

    func restart_server() -> (Bool, String) {
        restartServer()
    }

    func get_screenshot(device_id: String? = nil) throws -> ADBScreenshot {
        try getScreenshot(deviceID: device_id)
    }

    func get_current_app(device_id: String? = nil) throws -> String {
        try getCurrentApp(deviceID: device_id)
    }

    func type_text(_ text: String, device_id: String? = nil) throws {
        try typeText(text, deviceID: device_id)
    }

    func clear_text(device_id: String? = nil) throws {
        try clearText(deviceID: device_id)
    }

    func tap(_ x: Int, _ y: Int, device_id: String? = nil, delay: TimeInterval? = nil) throws {
        try tap(x: x, y: y, deviceID: device_id, delay: delay)
    }

    func double_tap(_ x: Int, _ y: Int, device_id: String? = nil, delay: TimeInterval? = nil) throws {
        try doubleTap(x: x, y: y, deviceID: device_id, delay: delay)
    }

    func long_press(_ x: Int, _ y: Int, duration_ms: Int = 3000, device_id: String? = nil, delay: TimeInterval? = nil) throws {
        try longPress(x: x, y: y, durationMS: duration_ms, deviceID: device_id, delay: delay)
    }

    func swipe(
        _ startX: Int,
        _ startY: Int,
        _ endX: Int,
        _ endY: Int,
        duration_ms: Int? = nil,
        device_id: String? = nil,
        delay: TimeInterval? = nil
    ) throws {
        try swipe(startX: startX, startY: startY, endX: endX, endY: endY, durationMS: duration_ms, deviceID: device_id, delay: delay)
    }

    func back(device_id: String? = nil, delay: TimeInterval? = nil) throws {
        try back(deviceID: device_id, delay: delay)
    }

    func home(device_id: String? = nil, delay: TimeInterval? = nil) throws {
        try home(deviceID: device_id, delay: delay)
    }

    func launch_app(_ app_name: String, device_id: String? = nil, delay: TimeInterval? = nil) throws -> ADBAppLaunchResult {
        try launchApp(app_name, deviceID: device_id, delay: delay)
    }

    // MARK: - Internals

    private func runADB(_ arguments: [String], deviceID: String? = nil) throws -> ADBCommandResult {
        let result = try runADBData(arguments, deviceID: deviceID)
        return ADBCommandResult(
            standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
            standardError: String(decoding: result.standardError, as: UTF8.self),
            exitCode: result.exitCode
        )
    }

    private func runADBData(_ arguments: [String], deviceID: String? = nil) throws -> (standardOutput: Data, standardError: Data, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var fullArguments = [resolvedADBPath]
        if let deviceID, !deviceID.isEmpty {
            fullArguments.append(contentsOf: ["-s", deviceID])
        }
        fullArguments.append(contentsOf: arguments)
        process.arguments = fullArguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutReader = capturePipeOutput(from: stdoutPipe)
        let stderrReader = capturePipeOutput(from: stderrPipe)

        try process.run()

        // Let slower devices finish naturally instead of force-stopping ADB commands.
        process.waitUntilExit()

        let stdout = stdoutReader()
        let stderr = stderrReader()

        if process.terminationStatus != 0 && stdout.isEmpty && !stderr.isEmpty {
            let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ADBProviderError.commandFailed(message.isEmpty ? "ADB command failed." : message)
        }

        return (stdout, stderr, process.terminationStatus)
    }

    private func capturePipeOutput(from pipe: Pipe) -> () -> Data {
        let fileHandle = pipe.fileHandleForReading
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.aiphone.adb.pipe.\(UUID().uuidString)")
        var capturedData = Data()

        group.enter()
        queue.async {
            capturedData = fileHandle.readDataToEndOfFile()
            group.leave()
        }

        return {
            group.wait()
            return capturedData
        }
    }

    private func captureScreenshot(
        arguments: [String],
        deviceID: String?,
        normalizesLineEndings: Bool,
        includeBase64: Bool
    ) throws -> ADBScreenshot? {
        let result = try runADBData(arguments, deviceID: deviceID)
        let stderr = String(decoding: result.standardError, as: UTF8.self).lowercased()

        if stderr.contains("status: -1") || stderr.contains("failed") {
            return ADBScreenshot(
                pngData: Data(),
                base64Data: "",
                imageMimeType: "image/png",
                width: 0,
                height: 0,
                isSensitive: true
            )
        }

        let pngData = normalizesLineEndings ? normalizedPNGData(result.standardOutput) : result.standardOutput
        guard !pngData.isEmpty, let originalSize = decodePNGSize(from: pngData) else {
            return nil
        }

        let payload = includeBase64 ? transportImagePayload(from: pngData) : nil

        return ADBScreenshot(
            pngData: pngData,
            base64Data: payload?.data.base64EncodedString() ?? "",
            imageMimeType: payload?.mimeType ?? "image/png",
            width: originalSize.width,
            height: originalSize.height,
            isSensitive: false
        )
    }

    private func typeTextWithADBKeyboard(_ text: String, deviceID: String?) throws -> Bool {
        let adbKeyboardID = "com.android.adbkeyboard/.AdbIME"

        guard let imeList = try? runADB(["shell", "ime", "list", "-s"], deviceID: deviceID),
              imeList.standardOutput.contains(adbKeyboardID) else {
            return false
        }

        let currentIME = (try? runADB(["shell", "settings", "get", "secure", "default_input_method"], deviceID: deviceID))?
            .combinedOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if currentIME != adbKeyboardID {
            _ = try? runADB(["shell", "ime", "set", adbKeyboardID], deviceID: deviceID)
        }

        let encodedText = Data(text.utf8).base64EncodedString()
        let result = try runADB(
            ["shell", "am", "broadcast", "-a", "ADB_INPUT_B64", "--es", "msg", encodedText],
            deviceID: deviceID
        )

        let output = result.combinedOutput.lowercased()
        return result.succeeded && !output.contains("exception") && !output.contains("nullpointerexception")
    }

    private func clearTextWithADBKeyboard(deviceID: String?) throws -> Bool {
        let result = try runADB(["shell", "am", "broadcast", "-a", "ADB_CLEAR_TEXT"], deviceID: deviceID)
        let output = result.combinedOutput.lowercased()
        return result.succeeded && !output.contains("exception")
    }

    private func typeTextWithFallback(_ text: String, deviceID: String?) throws {
        let lines = text.components(separatedBy: .newlines)

        for (lineIndex, line) in lines.enumerated() {
            if !line.isEmpty {
                for chunk in textChunks(for: line, maxLength: 48) {
                    let escapedChunk = escapeTextForADBInput(chunk)
                    guard !escapedChunk.isEmpty else { continue }

                    do {
                        _ = try runADB(["shell", "input", "text", escapedChunk], deviceID: deviceID)
                    } catch {
                        for character in chunk {
                            let escapedCharacter = escapeTextForADBInput(String(character))
                            guard !escapedCharacter.isEmpty else { continue }
                            _ = try runADB(["shell", "input", "text", escapedCharacter], deviceID: deviceID)
                        }
                    }
                }
            }

            if lineIndex < lines.count - 1 {
                _ = try runADB(["shell", "input", "keyevent", "66"], deviceID: deviceID)
            }
        }
    }

    private func textChunks(for text: String, maxLength: Int) -> [String] {
        guard !text.isEmpty, maxLength > 0 else { return [] }

        var chunks: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if current.count >= maxLength {
                chunks.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private func escapeTextForADBInput(_ text: String) -> String {
        var escaped = ""

        for scalar in text.unicodeScalars {
            switch scalar {
            case " ":
                escaped += "%s"
            case "\n", "\r":
                continue
            case "\"":
                escaped += "\\\""
            case "'":
                escaped += "\\'"
            case "&":
                escaped += "\\&"
            case "<":
                escaped += "\\<"
            case ">":
                escaped += "\\>"
            case "(":
                escaped += "\\("
            case ")":
                escaped += "\\)"
            case ";":
                escaped += "\\;"
            case "|":
                escaped += "\\|"
            case "$":
                escaped += "\\$"
            case "*":
                escaped += "\\*"
            case "?":
                escaped += "\\?"
            case "#":
                escaped += "\\#"
            case "%":
                escaped += "\\%"
            default:
                escaped.append(String(scalar))
            }
        }

        return escaped
    }

    private func extractIPAddresses(from output: String) -> [String] {
        guard !output.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#) else {
            return []
        }

        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        var seen = Set<String>()

        return matches.compactMap { match in
            guard match.range.location != NSNotFound else { return nil }
            let address = nsOutput.substring(with: match.range)
            guard seen.insert(address).inserted, isUsableIPAddress(address) else { return nil }
            return address
        }
    }

    private func isUsableIPAddress(_ candidate: String) -> Bool {
        let octets = candidate.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }

        switch (octets[0], octets[1]) {
        case (0, _), (127, _), (169, 254), (255, _):
            return false
        default:
            return true
        }
    }

    private func parseDevices(from output: String) -> [ADBDeviceInfo] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .compactMap { line in
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 2 else { return nil }

                let deviceID = parts[0]
                let status = parts[1]
                let connectionType: ADBConnectionType = deviceID.contains(":") ? .remote : .usb
                let model = parts.first(where: { $0.hasPrefix("model:") })?.replacingOccurrences(of: "model:", with: "")

                return ADBDeviceInfo(
                    deviceID: deviceID,
                    status: status,
                    connectionType: connectionType,
                    model: model,
                    androidVersion: nil
                )
            }
    }

    private func queryInstalledPackages(deviceID: String?) throws -> [String] {
        let output = try shell("pm list packages", deviceID: deviceID)
        guard !output.isEmpty else { return [] }

        return output
            .split(separator: "\n")
            .map { line in
                String(line)
                    .replacingOccurrences(of: "package:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private func launchInstalledPackage(_ package: String, deviceID: String?, delay: TimeInterval?) throws -> Bool {
        let result = try runADB(
            ["shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1"],
            deviceID: deviceID
        )

        let output = result.combinedOutput.lowercased()
        let didFailToLaunch = !result.succeeded ||
            output.contains("no activities found") ||
            output.contains("monkey aborted") ||
            output.contains("cannot find") ||
            output.contains("not found")

        guard !didFailToLaunch else { return false }
        Thread.sleep(forTimeInterval: delay ?? ADBTiming.defaultLaunchDelay)
        return true
    }

    private func resolveInstalledPackage(for appName: String, installedPackages: [String]) -> String? {
        guard !installedPackages.isEmpty else { return nil }

        let normalizedQuery = normalizedLookupKey(appName)
        guard !normalizedQuery.isEmpty else { return nil }

        if let exactMatch = installedPackages.first(where: { normalizedLookupKey($0) == normalizedQuery }) {
            return exactMatch
        }

        let candidates = ADBAppCatalog.candidatePackages(for: appName)
        if let mappedMatch = candidates.first(where: { installedPackages.contains($0) }) {
            return mappedMatch
        }

        let scoredMatches = installedPackages.compactMap { package -> (package: String, score: Int)? in
            let normalizedPackage = normalizedLookupKey(package)
            guard normalizedPackage.contains(normalizedQuery) || normalizedQuery.contains(normalizedPackage) else {
                return nil
            }

            let score: Int
            if normalizedPackage == normalizedQuery {
                score = 100
            } else if normalizedPackage.hasSuffix(normalizedQuery) {
                score = 90
            } else if normalizedPackage.contains(normalizedQuery) {
                score = 75
            } else {
                score = 50
            }
            return (package, score)
        }

        return scoredMatches.max(by: { $0.score < $1.score })?.package
    }

    private func openStoreListing(for appName: String, deviceID: String?, delay: TimeInterval?) throws -> ADBAppLaunchResult {
        let encodedQuery = appName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appName
        let installedPackages = listInstalledPackages(deviceID: deviceID)
        let destination = installedPackages.contains("com.android.vending")
            ? "market://search?q=\(encodedQuery)&c=apps"
            : "https://play.google.com/store/search?q=\(encodedQuery)&c=apps"

        _ = try runADB(
            ["shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", destination],
            deviceID: deviceID
        )

        Thread.sleep(forTimeInterval: delay ?? ADBTiming.defaultLaunchDelay)
        return ADBAppLaunchResult(
            succeeded: true,
            appName: appName,
            packageName: nil,
            didOpenStore: true,
            message: "\(appName) is not installed, so Google Play was opened."
        )
    }

    private func normalizedLookupKey(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }

    private func parseDeviceProperties(from output: String) -> [String: String] {
        var properties: [String: String] = [:]

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("[") else { continue }

            let components = line.components(separatedBy: "]: [")
            guard components.count == 2 else { continue }

            let key = components[0].replacingOccurrences(of: "[", with: "")
            let value = components[1].replacingOccurrences(of: "]", with: "")
            properties[key] = value
        }

        return properties
    }

    private func cleanedWMValue(from output: String?) -> String? {
        guard let output else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let separator = trimmed.firstIndex(of: ":") {
            return trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func parseBatteryLevel(from output: String) -> Int? {
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("level:") else { continue }
            let value = line.replacingOccurrences(of: "level:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(value)
        }
        return nil
    }

    private func parseWiFiStatus(from output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("wifi is connected") || lower.contains("wi-fi is connected") {
            return "Connected"
        }
        if lower.contains("wifi is enabled") || lower.contains("wi-fi is enabled") {
            return "On"
        }
        if lower.contains("wifi is disabled") || lower.contains("wi-fi is disabled") {
            return "Off"
        }
        return nil
    }

    private func parseMobileDataStatus(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "1" {
            return "On"
        }
        if trimmed == "0" {
            return "Off"
        }

        let lower = output.lowercased()
        if lower.contains("mdataconnectionstate=2") || lower.contains("dataregstate=0") {
            return "Connected"
        }
        if lower.contains("mdataconnectionstate=0") {
            return "Off"
        }
        return nil
    }

    private func extractFocusedPackage(from line: String) -> String? {
        let pattern = #"([A-Za-z0-9_\.]+)/[A-Za-z0-9_\.$]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsLine = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
            return nil
        }

        return nsLine.substring(with: match.range(at: 1))
    }

    private func decodePNGSize(from data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }

        return (width, height)
    }

    private func cachedScreenshot(for cacheKey: String, includeBase64: Bool) -> ADBScreenshot? {
        screenshotCacheLock.lock()
        defer { screenshotCacheLock.unlock() }

        guard let cached = screenshotCache[cacheKey] else { return nil }
        guard Date().timeIntervalSince(cached.capturedAt) <= screenshotReuseInterval else {
            screenshotCache.removeValue(forKey: cacheKey)
            return nil
        }

        if includeBase64 || cached.screenshot.base64Data.isEmpty == false {
            if includeBase64, cached.screenshot.base64Data.isEmpty, !cached.screenshot.pngData.isEmpty {
                let payload = transportImagePayload(from: cached.screenshot.pngData)
                let updated = ADBScreenshot(
                    pngData: cached.screenshot.pngData,
                    base64Data: payload.data.base64EncodedString(),
                    imageMimeType: payload.mimeType,
                    width: cached.screenshot.width,
                    height: cached.screenshot.height,
                    isSensitive: cached.screenshot.isSensitive
                )
                screenshotCache[cacheKey] = CachedScreenshotEntry(screenshot: updated, capturedAt: cached.capturedAt)
                return updated
            }
            return cached.screenshot
        }

        return cached.screenshot
    }

    private func cacheScreenshot(_ screenshot: ADBScreenshot, for cacheKey: String) {
        screenshotCacheLock.lock()
        screenshotCache[cacheKey] = CachedScreenshotEntry(screenshot: screenshot, capturedAt: Date())
        screenshotCacheLock.unlock()
    }

    private func transportImagePayload(from pngData: Data) -> (data: Data, mimeType: String) {
        if let webpData = webPData(from: pngData, quality: 0.5), webpData.count < pngData.count {
            return (webpData, "image/webp")
        }
        return (pngData, "image/png")
    }

    private func webPData(from imageData: Data, quality: CGFloat) -> Data? {
        let supportedTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard supportedTypes.contains(UTType.webP.identifier) else { return nil }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else {
            return nil
        }

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData, UTType.webP.identifier as CFString, 1, nil) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return outputData as Data
    }

    private func normalizedPNGData(_ data: Data) -> Data {
        var normalized = Data()
        normalized.reserveCapacity(data.count)

        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]

            if byte == 0x0D {
                let nextIndex = data.index(after: index)
                if nextIndex < data.endIndex, data[nextIndex] == 0x0A {
                    normalized.append(0x0A)
                    index = data.index(after: nextIndex)
                    continue
                }
            }

            normalized.append(byte)
            index = data.index(after: index)
        }

        return normalized
    }

    private func makeFallbackScreenshot(isSensitive: Bool) -> ADBScreenshot {
        let width = 1080
        let height = 2400

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return ADBScreenshot(pngData: Data(), base64Data: "", imageMimeType: "image/png", width: width, height: height, isSensitive: isSensitive)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let pngData = bitmap.representation(using: .png, properties: [:]) ?? Data()
        return ADBScreenshot(
            pngData: pngData,
            base64Data: pngData.base64EncodedString(),
            imageMimeType: "image/png",
            width: width,
            height: height,
            isSensitive: isSensitive
        )
    }
}
